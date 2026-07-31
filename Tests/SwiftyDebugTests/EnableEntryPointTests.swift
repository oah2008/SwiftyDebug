//
//  EnableEntryPointTests.swift
//  SwiftyDebugTests
//
//  `SwiftyDebug.enable()` is the SDK's only entry point, and until now no test
//  ever called it. Its three lifecycle guarantees were pinned as *extracted
//  helpers* (`activateRuntimeForEnable`, `sweepPreviousSessionBodiesIfNeeded`,
//  `applyMonitorFlags(from:)`) — so all three could be unwired from
//  `initializationMethod()` and every one of those tests stayed green while the
//  shipped `enable()` did none of it.
//
//  These tests call the real public API and assert on the effects a host app
//  can observe:
//
//   1. `enable()` after `fullStop()` genuinely resumes capture (the runtime gate
//      is opened, and it is opened FIRST — everything below it in
//      `initializationMethod` short-circuits while it is closed).
//   2. `SwiftyDebug.monitorAllUrls = true` written *before* `enable()` — the
//      README quick start — survives `enable()` and is pushed into Settings.
//   3. A second `enable()` does not delete the bodies captured after the first.
//
//  Everything global that `enable()` touches is saved in `setUp` and put back in
//  `tearDown`; console capture is forced off for the duration so the real hook
//  never takes the test process's stdout.
//

import XCTest
@testable import SwiftyDebug

final class EnableEntryPointTests: XCTestCase {

    private var savedMonitorAllUrls = false
    private var savedMonitorMedia = false
    private var savedSettingsMonitorAll = false
    private var savedSettingsMonitorMedia = false
    private var savedURLs: [String] = []
    private var savedConsoleCapture = true
    private var savedRuntimeActive = true
    private var savedNetworkEnabled = false
    private var savedPrintEnabled = false
    private var savedBubbleVisible = false
    private var savedDebugUIVisible = false
    private var savedShakeEnabled = false
    private var savedPresenterRoot: UIViewController?
    private var savedPresenterHidden = true

    override func setUp() {
        super.setUp()
        savedMonitorAllUrls = SwiftyDebug.monitorAllUrls
        savedMonitorMedia = SwiftyDebug.monitorMedia
        savedSettingsMonitorAll = Settings.shared.monitorAllRequests
        savedSettingsMonitorMedia = Settings.shared.monitorMediaEnabled
        savedURLs = SwiftyDebug.urls
        savedConsoleCapture = SwiftyDebug.enableConsoleLog
        savedRuntimeActive = SwiftyDebugRuntime.isActive
        savedNetworkEnabled = NetworkMonitor.shared.isNetworkEnable
        savedPrintEnabled = PrintInterceptor.shared.enable
        savedBubbleVisible = Settings.shared.bubbleVisible
        savedDebugUIVisible = Settings.shared.debugUIVisible
        savedShakeEnabled = Settings.shared.shakeGestureEnabled
        savedPresenterRoot = DebugWindowPresenter.shared.window.rootViewController
        savedPresenterHidden = DebugWindowPresenter.shared.window.isHidden

        // `enable()` calls `NSLogHook.enableIfNeeded()`, which redirects stdout
        // through a pipe. Keep it gated off: this suite is about lifecycle, not
        // about capturing the test runner's own output.
        SwiftyDebug.enableConsoleLog = false

        // The one-shot previous-session sweep is process-scoped, and whether it
        // is still armed depends on which suites ran first. Disarm it with a
        // no-op so the real disk sweep can never run from here and delete other
        // suites' captured bodies — and so every `enable()` below is, by
        // definition, a *second* enable.
        SwiftyDebug.sweepPreviousSessionBodiesIfNeeded { }
    }

    override func tearDown() {
        Settings.shared.monitorAllRequests = savedSettingsMonitorAll
        Settings.shared.monitorMediaEnabled = savedSettingsMonitorMedia
        SwiftyDebug.monitorAllUrls = savedMonitorAllUrls
        SwiftyDebug.monitorMedia = savedMonitorMedia
        SwiftyDebug.urls = savedURLs
        SwiftyDebug.enableConsoleLog = savedConsoleCapture
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        PrintInterceptor.shared.enable = savedPrintEnabled
        Settings.shared.bubbleVisible = savedBubbleVisible
        Settings.shared.debugUIVisible = savedDebugUIVisible
        Settings.shared.shakeGestureEnabled = savedShakeEnabled
        DebugWindowPresenter.shared.window.rootViewController = savedPresenterRoot
        DebugWindowPresenter.shared.window.isHidden = savedPresenterHidden
        BreakpointOverlay.shared.stop()
        if savedRuntimeActive {
            SwiftyDebugRuntime.markActive()
        } else {
            SwiftyDebugRuntime.markStopped()
        }
        super.tearDown()
    }

    // MARK: - 1. enable() reverses fullStop()

    /// The public API has to be able to undo the SDK's own kill switch. It could
    /// not: `markActive()` was only reachable from `resumeFromFullStop()` (the
    /// shake gesture), so after a full stop `SwiftyDebug.enable()` handed back a
    /// fully navigable UI that captured nothing at all.
    func testEnableAfterAFullStopResumesCapture() {
        SwiftyDebug.urls = []
        Settings.shared.monitorAllRequests = false
        SwiftyDebug.monitorAllUrls = true

        SwiftyDebug.fullStop()
        XCTAssertFalse(SwiftyDebugRuntime.isActive, "Precondition: the SDK is fully stopped.")

        SwiftyDebug.enable()

        XCTAssertTrue(SwiftyDebugRuntime.isActive,
                      "enable() must open the runtime gate. Every capture path in the SDK — "
                      + "URLProtocol.canInit, the log hooks, the web-view push — short-circuits "
                      + "while it is closed, so without this enable() is decorative.")

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/me")!)
        XCTAssertTrue(CustomHTTPProtocol.canInit(with: request),
                      "After enable() the SDK must actually intercept again.")
    }

    /// A full stop unregisters the URLProtocol as well as closing the gate, so
    /// `enable()` has to put *both* back. This is the same call from the host
    /// app's point of view — "turn the debugger back on" — and it is the one
    /// that used to be impossible without a relaunch.
    func testEnableAfterAFullStopReArmsTheNetworkMonitorToo() {
        SwiftyDebug.urls = []
        Settings.shared.monitorAllRequests = false
        SwiftyDebug.monitorAllUrls = true

        SwiftyDebug.fullStop()
        XCTAssertFalse(NetworkMonitor.shared.isNetworkEnable,
                       "Precondition: a full stop stops native interception.")

        SwiftyDebug.enable()

        XCTAssertTrue(NetworkMonitor.shared.isNetworkEnable)
        XCTAssertTrue(SwiftyDebugRuntime.isActive)
    }

    // MARK: - 2. The host app's pre-enable assignment survives

    /// The documented quick start:
    ///
    ///     SwiftyDebug.monitorAllUrls = true
    ///     SwiftyDebug.enable()
    ///
    /// `enable()` used to overwrite both flags from `Settings`, so from the
    /// second launch onward this captured nothing and the App-tab toggle showed
    /// OFF over it.
    func testMonitorAllUrlsSetBeforeEnableSurvivesEnable() {
        SwiftyDebug.urls = []
        // The persisted App-tab toggle says off — the state that used to win.
        Settings.shared.monitorAllRequests = false
        SwiftyDebug.monitorAllUrls = true

        SwiftyDebug.enable()

        XCTAssertTrue(SwiftyDebug.monitorAllUrls,
                      "enable() discarded the host app's assignment, so the README quick start "
                      + "captured nothing from the second launch onward.")
        XCTAssertTrue(Settings.shared.monitorAllRequests,
                      "The App-tab toggle must reflect the live capture, not sit OFF over it.")

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/me")!)
        XCTAssertTrue(CustomHTTPProtocol.canInit(with: request),
                      "The whole point of the flag: requests are captured after enable().")
    }

    /// The other half of the same reconciliation: a toggle the user switched on
    /// from the App tab last launch must still be on when the host app assigns
    /// nothing.
    func testAPersistedToggleStillWinsWhenTheHostAppAssignsNothing() {
        SwiftyDebug.monitorMedia = false          // "never assigned"
        Settings.shared.monitorMediaEnabled = true // switched on last launch
        SwiftyDebug.monitorMedia = false           // the didSet above wrote through; undo it

        SwiftyDebug.enable()

        XCTAssertTrue(SwiftyDebug.monitorMedia,
                      "A toggle switched on from the App tab must survive the next launch.")
    }

    // MARK: - 3. A second enable() keeps what the first one captured

    /// `enable()` is not rare-by-contract: a re-entrant setup path, a second
    /// scene connecting, or a host app that simply calls it twice all reach it.
    /// It used to run `NetworkTransaction.clearDiskCache()` every time, deleting
    /// every body captured since the first call while the rows stayed in the
    /// list — every request in the UI rendered empty, with no explanation.
    func testASecondEnableDoesNotDeleteBodiesCapturedByTheFirst() throws {
        let directory = NetworkTransaction.diskCacheDirectory()
        let path = (directory as NSString)
            .appendingPathComponent("EnableEntryPointTests-\(UUID().uuidString).body")
        let body = Data("captured after enable()".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: body),
                      "Precondition: the disk cache directory is writable.")
        defer { try? FileManager.default.removeItem(atPath: path) }

        SwiftyDebug.enable()
        SwiftyDebug.enable()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "enable() wiped the captured bodies off disk. The rows stay in the list, "
                      + "so every request renders with an empty body and no explanation.")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), body)
    }
}
