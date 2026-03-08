//
//  NSLogHook.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit
import OSLog

class NSLogHook: NSObject {

    private static var hooked = false
    private static var savedStdoutFD: Int32 = -1
    private static var stdoutPipe: Pipe?

    // Pipe buffering — accumulate data, flush every 100ms instead of per-read
    private static var pendingPipeData = Data()
    private static var pipeFlushScheduled = false
    private static let pipeBufferQueue = DispatchQueue(label: "com.swiftydebug.pipebuffer", qos: .utility)

    /// The host app's executable name, used for classifying OSLogStore entries
    static let hostExecutableName: String = {
        return Bundle.main.executableURL?.lastPathComponent ?? ""
    }()

    /// SwiftyDebug's own binary name — used to filter out SDK-internal logs
    private static let sdkBinaryName: String = {
        return Bundle(for: NSLogHook.self).executableURL?.lastPathComponent ?? "SwiftyDebug"
    }()

    // MARK: - Polling state

    private static var pollTimer: DispatchSourceTimer?
    private static var lastPollDate = Date()
    private static let pollQueue = DispatchQueue(label: "com.swiftydebug.oslogpoll", qos: .utility)

    // Cached OSLogStore — avoids expensive re-creation every poll cycle.
    // Type-erased to avoid @available requirement on stored properties.
    private static var _cachedStore: Any?

    @available(iOS 15.0, *)
    private static var cachedStore: OSLogStore? {
        get { _cachedStore as? OSLogStore }
        set { _cachedStore = newValue }
    }

    // Adaptive polling interval
    private static var currentInterval: TimeInterval = 0.5
    private static var consecutiveEmptyPolls: Int = 0
    private static let backoffThreshold: Int = 4

    // Two-tier throttling: fast when debug UI is visible, slow when hidden
    /// Set by LogViewController on appear/disappear
    static var debugUIVisible = false {
        didSet {
            guard debugUIVisible != oldValue else { return }
            if debugUIVisible {
                // Snap to fast polling when UI opens
                currentInterval = activeMinInterval
                consecutiveEmptyPolls = 0
                if !isPaused { scheduleNextPoll() }
            } else {
                // Switch to slow polling when UI closes
                currentInterval = hiddenMinInterval
            }
        }
    }

    // Fast intervals (UI visible)
    private static let activeMinInterval: TimeInterval = 0.5
    private static let activeMaxInterval: TimeInterval = 2.0
    // Slow intervals (UI hidden)
    private static let hiddenMinInterval: TimeInterval = 2.0
    private static let hiddenMaxInterval: TimeInterval = 5.0

    private static var effectiveMinInterval: TimeInterval {
        debugUIVisible ? activeMinInterval : hiddenMinInterval
    }
    private static var effectiveMaxInterval: TimeInterval {
        debugUIVisible ? activeMaxInterval : hiddenMaxInterval
    }

    // Background pause
    private static var isPaused = false

    // Notification coalescing
    private static var pendingRefreshNotification = false

    /// Call this once (e.g. from `SwiftyDebug.enable()`) to start capturing logs.
    /// The method is idempotent.
    static func enableIfNeeded() {
        guard !hooked else { return }
        hooked = true

        // Ignore SIGPIPE — writing to a pipe whose read end closed must not
        // kill the process. This is standard practice for any app using pipes.
        signal(SIGPIPE, SIG_IGN)

        // Redirect stdout only — this is the only way to capture print() output.
        // stderr is NOT redirected, so NSLog goes to Xcode console untouched.
        redirectStdout()

        // OSLogStore captures everything else (NSLog, os_log, Logger) read-only.
        startOSLogStorePolling()

        // Pause/resume polling on app lifecycle
        observeAppLifecycle()
    }

    // MARK: - stdout pipe (for print() only)

    /// Write all bytes to a file descriptor, retrying on partial writes
    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private static func redirectStdout() {
        let pipe = Pipe()
        stdoutPipe = pipe
        savedStdoutFD = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)

        // Buffered pipe reads: accumulate data, flush at adaptive interval.
        // Xcode forwarding is still immediate (no delay).
        // Flush interval: 100ms when UI visible, 500ms when hidden.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Forward to Xcode console immediately (zero delay)
            if savedStdoutFD >= 0 {
                writeAll(fd: savedStdoutFD, data: data)
            }

            // Accumulate on buffer queue, flush at adaptive interval
            pipeBufferQueue.async {
                pendingPipeData.append(data)

                guard !pipeFlushScheduled else { return }
                pipeFlushScheduled = true

                let flushInterval: TimeInterval = debugUIVisible ? 0.1 : 0.5
                pipeBufferQueue.asyncAfter(deadline: .now() + flushInterval) {
                    let buffered = pendingPipeData
                    pendingPipeData = Data()
                    pipeFlushScheduled = false

                    guard let str = String(data: buffered, encoding: .utf8), !str.isEmpty else { return }
                    DispatchQueue.main.async {
                        LogStore.shared.appendConsoleLineCache(text: str)
                    }
                }
            }
        }
    }

    // MARK: - OSLogStore polling (adaptive, self-scheduling)

    private static func startOSLogStorePolling() {
        lastPollDate = Date()
        scheduleNextPoll()
    }

    private static func scheduleNextPoll() {
        guard !isPaused else { return }

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + currentInterval)
        timer.setEventHandler {
            if #available(iOS 15.0, *) {
                pollOSLogStore()
            }
            scheduleNextPoll()
        }
        timer.resume()

        // Cancel previous timer AFTER new one is ready
        pollTimer?.cancel()
        pollTimer = timer
    }

    @available(iOS 15.0, *)
    private static func pollOSLogStore() {
        do {
            // Reuse cached store — avoids expensive re-creation
            let store: OSLogStore
            if let cached = cachedStore {
                store = cached
            } else {
                store = try OSLogStore(scope: .currentProcessIdentifier)
                cachedStore = store
            }

            let position = store.position(date: lastPollDate)
            let entries = try store.getEntries(at: position)

            // Fast-path: check first element before allocating arrays
            var iterator = entries.makeIterator()
            guard let firstEntry = iterator.next() else {
                // No entries at all — increase backoff
                consecutiveEmptyPolls += 1
                if consecutiveEmptyPolls > backoffThreshold {
                    currentInterval = min(currentInterval * 1.5, effectiveMaxInterval)
                }
                return
            }

            var newModels: [LogRecord] = []
            var latestDate = lastPollDate

            // Process first entry (already fetched)
            processEntry(firstEntry, into: &newModels, latestDate: &latestDate)

            // Process remaining entries
            while let entry = iterator.next() {
                processEntry(entry, into: &newModels, latestDate: &latestDate)
            }

            lastPollDate = latestDate

            // Adaptive interval: snap back on activity, backoff when idle
            if !newModels.isEmpty {
                consecutiveEmptyPolls = 0
                currentInterval = effectiveMinInterval
            } else {
                consecutiveEmptyPolls += 1
                if consecutiveEmptyPolls > backoffThreshold {
                    currentInterval = min(currentInterval * 1.5, effectiveMaxInterval)
                }
            }

            // Dispatch to main with coalesced notification
            if !newModels.isEmpty {
                // Pre-collect console lines on background thread to batch DB insert
                var consoleLines: [(text: String, colorCode: Int)] = []
                for model in newModels {
                    if model.logSource == .app {
                        let timeStr = LogCell.formatTime(model.date ?? Date())
                        let colorCode = (model.color == .systemRed) ? 1 : 0
                        consoleLines.append((text: "[\(timeStr)] \(model.content ?? "")", colorCode: colorCode))
                    }
                }

                // Single batch DB insert (background queue inside batchInsert)
                if !consoleLines.isEmpty {
                    LogStore.shared.consoleDB.batchInsert(lines: consoleLines)
                }

                DispatchQueue.main.async {
                    for model in newModels {
                        LogStore.shared.addLog(model)
                    }

                    // Coalesce: one UI refresh per run loop tick
                    if !pendingRefreshNotification {
                        pendingRefreshNotification = true
                        DispatchQueue.main.async {
                            pendingRefreshNotification = false
                            NotificationCenter.default.post(
                                name: .logEntriesUpdated,
                                object: nil,
                                userInfo: nil
                            )
                        }
                    }
                }
            }
        } catch {
            // Store became stale — discard and recreate next cycle
            cachedStore = nil
        }
    }

    // MARK: - Per-entry processing (extracted for fast-path pattern)

    @available(iOS 15.0, *)
    private static func processEntry(
        _ entry: OSLogEntry,
        into models: inout [LogRecord],
        latestDate: inout Date
    ) {
        guard let logEntry = entry as? OSLogEntryLog else { return }

        // Skip entries at or before our last poll date
        guard logEntry.date > lastPollDate else { return }

        // Track latest date for next poll
        if logEntry.date > latestDate {
            latestDate = logEntry.date
        }

        // Skip empty messages
        let message = logEntry.composedMessage
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let sender = logEntry.sender
        let subsystemRaw = logEntry.subsystem

        // Skip SwiftyDebug's own entries
        if sender == sdkBinaryName || sender == "SwiftyDebug" { return }
        // Allocation-free case-insensitive check (uses CFStringFind internally)
        if subsystemRaw.range(of: "swiftydebug", options: .caseInsensitive) != nil { return }

        // Skip Apple system frameworks
        if isAppleSystemSender(sender) { return }
        if subsystemRaw.hasPrefix("com.apple.") { return }
        if subsystemRaw.range(of: "apple", options: .caseInsensitive) != nil { return }

        // Classify: host app → .app, everything else → .thirdParty
        let isHostApp = (sender == hostExecutableName)

        let sourceName: String
        if isHostApp {
            sourceName = hostExecutableName
        } else {
            let name = sender.isEmpty ? subsystemRaw : sender
            sourceName = name.isEmpty ? "Unknown" : name
        }

        // Color based on log level
        let color: UIColor
        switch logEntry.level {
        case .error, .fault:
            color = .systemRed
        default:
            color = .white
        }

        // Build fileInfo for the model
        let model = LogRecord(
            content: message,
            color: color,
            fileInfo: "\(sourceName)\n",
            isTag: false,
            type: .none
        )
        model.logSource = isHostApp ? .app : .thirdParty
        model.sourceName = sourceName
        model.logTypeTag = isHostApp ? .nslog : .oslog
        model.subsystem = subsystemRaw
        model.category = logEntry.category
        model.date = logEntry.date

        models.append(model)
    }

    // MARK: - App lifecycle (pause polling when backgrounded)

    private static func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { _ in
            isPaused = true
            // Current timer will fire but scheduleNextPoll() will no-op
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil
        ) { _ in
            guard isPaused else { return }
            isPaused = false
            // Reset to appropriate polling — catch entries from background period
            currentInterval = effectiveMinInterval
            consecutiveEmptyPolls = 0
            lastPollDate = Date().addingTimeInterval(-2)
            scheduleNextPoll()
        }
    }

    // MARK: - System framework filter

    /// Returns true if the sender is a known Apple system framework or library
    private static func isAppleSystemSender(_ sender: String) -> Bool {
        if sender.isEmpty { return false }  // Don't filter unknown — capture everything
        // Apple system libraries (libdispatch, libsystem_*, etc.)
        if sender.hasPrefix("libsystem") || sender.hasPrefix("libdispatch") ||
           sender.hasPrefix("libxpc") || sender.hasPrefix("libnotify") ||
           sender.hasPrefix("libobjc") || sender.hasPrefix("libnetwork") { return true }
        return appleFrameworks.contains(sender)
    }

    private static let appleFrameworks: Set<String> = [
        "UIKitCore", "UIKit", "UIKitMacHelper",
        "Foundation", "CoreFoundation",
        "QuartzCore", "CoreGraphics", "CoreAnimation", "CoreImage",
        "CFNetwork", "Security", "SystemConfiguration",
        "CoreData", "CoreLocation", "MapKit",
        "AVFoundation", "MediaPlayer", "CoreMedia", "CoreAudio",
        "Metal", "MetalKit", "MetalPerformanceShaders",
        "StoreKit", "GameKit", "CloudKit",
        "UserNotifications", "BackgroundTasks",
        "CoreBluetooth", "CoreNFC", "CoreTelephony",
        "CoreML", "Vision", "NaturalLanguage",
        "AuthenticationServices", "LocalAuthentication",
        "Combine", "SwiftUI",
        "Network", "NetworkExtension",
        "RunningBoardServices", "FrontBoardServiceKit",
        "AssertionServices", "BaseBoard",
        "GraphicsServices", "IOKit",
        "PowerLog", "Symptoms",
        "MediaAccessibility", "AppSupport",
        "ManagedConfiguration", "DeviceIdentity",
        "AppleMediaServices", "iTunesCloud",
        "PhotoLibraryServices", "PhotosFormats",
        "SpringBoardServices", "TCC",
        "MobileCoreServices", "LaunchServices",
        "ContactsFoundation", "PhoneNumbers",
        "CoreSpotlight", "CoreServices",
        "WebKit", "SafariServices", "WebCore",
        "JavaScriptCore", "WKWebView",
        "AppSSO", "ShareSheet",
        "HealthKit", "HealthKitUI",
        "ARKit", "RealityKit",
        "CoreMotion", "CoreHaptics",
        "MultipeerConnectivity", "ExternalAccessory",
        "PassKit", "WalletCore",
        "EventKit", "EventKitUI",
        "MessageUI", "Messages",
        "Photos", "PhotosUI",
        "Contacts", "ContactsUI",
        "AddressBook", "AddressBookUI",
        "NotificationCenter", "WidgetKit",
        "IntentsUI", "Intents",
        "ActivityKit",
        "PushKit", "CallKit",
        "PDFKit", "QuickLook",
        "SpriteKit", "SceneKit",
        "ReplayKit", "AVKit",
        "CryptoKit", "CryptoTokenKit",
        "OSLog",
        // Privacy & tracking
        "ScreenTimeCore", "ScreenTime", "UsageTracking",
        "AppTrackingTransparency", "ATTrackingManager",
        "ContentFilterExclusion",
        // Additional system
        "CarPlay", "CoreWLAN", "DeviceCheck",
        "FamilyControls", "ManagedSettings", "ManagedSettingsUI",
        "MetricKit", "OSAnalytics",
        "AppIntents", "ShazamKit", "SoundAnalysis",
        "ClassKit", "AutomaticAssessmentConfiguration",
        "GroupActivities", "SharedWithYou",
        "WeatherKit", "SensorKit",
        "DeviceActivity", "DeviceActivityUI",
        "ScreenCaptureKit",
    ]
}
