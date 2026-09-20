//
//  CaptureCoreAuditFixTests.swift
//  SwiftyDebugTests
//
//  The capture core's silent failures — the ones where the SDK changed what the
//  host app did, or told the developer nothing about why it did it:
//
//   1. A request body stream was drained with `hasBytesAvailable` as the end
//      marker and closed unconditionally. A mutable copy of an NSURLRequest does
//      NOT copy the stream, so the SDK closed the app's own stream and installed
//      whatever it had managed to read — nothing at all for a bound-pair
//      (streamed multipart) body, a silent truncation for one that stalled
//      mid-way.
//   2. A rule that blocks AND mocks explained the conflict for breakpoints only.
//      The mock and the response rewrites died in total silence.
//   3. The App tab's "Console Logs" switch was AND-gated with a host-app flag no
//      UI could set, so it rendered ON over a dead capture and was inert in both
//      directions.
//   4. "Clear Pinned Requests" posted the clear notification with no surviving
//      count, and the bubble reads that as zero.
//   5. `disable()` undid two of the six subsystems `enable()` starts — the
//      runtime gate stayed open, so log capture, the OSLog poll timer and every
//      WKWebView's injected JS kept running for the life of the process.
//
//  Everything global these tests touch is saved in `setUp` and put back in
//  `tearDown`; console capture is forced off for the duration so the real hook
//  never takes the test process's stdout.
//

import XCTest
@testable import SwiftyDebug

final class CaptureCoreAuditFixTests: XCTestCase {

    private var savedConsoleCapture = true
    private var savedConsoleLogsEnabled = false
    private var savedRuntimeActive = true
    private var savedNetworkEnabled = false
    private var savedPrintEnabled = false
    private var savedBubbleVisible = false
    private var savedShakeEnabled = false
    private var addedModels: [NetworkTransaction] = []

    override func setUp() {
        super.setUp()
        savedConsoleCapture = SwiftyDebug.enableConsoleLog
        savedConsoleLogsEnabled = Settings.shared.consoleLogsEnabled
        savedRuntimeActive = SwiftyDebugRuntime.isActive
        savedNetworkEnabled = NetworkMonitor.shared.isNetworkEnable
        savedPrintEnabled = PrintInterceptor.shared.enable
        savedBubbleVisible = Settings.shared.bubbleVisible
        savedShakeEnabled = Settings.shared.shakeGestureEnabled

        // The console switch now writes through to `SwiftyDebug.enableConsoleLog`,
        // and a `true` here would install the stdout pipe in the test process.
        // Start from a known-off pair; each test sets what it needs.
        Settings.shared.consoleLogsEnabled = false
        SwiftyDebug.enableConsoleLog = false
    }

    override func tearDown() {
        for model in addedModels {
            NetworkRequestStore.shared.remove(model)
        }
        addedModels.removeAll()

        // The host flag gates the switch, so it is restored FIRST — otherwise
        // the switch's own didSet evaluates against a stale gate.
        SwiftyDebug.enableConsoleLog = savedConsoleCapture
        Settings.shared.consoleLogsEnabled = savedConsoleLogsEnabled
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        PrintInterceptor.shared.enable = savedPrintEnabled
        Settings.shared.bubbleVisible = savedBubbleVisible
        Settings.shared.shakeGestureEnabled = savedShakeEnabled
        BreakpointOverlay.shared.stop()
        if savedRuntimeActive {
            SwiftyDebugRuntime.markActive()
        } else {
            SwiftyDebugRuntime.markStopped()
        }
        super.tearDown()
    }

    // MARK: - 1. Request body streams are never consumed at all

    /// The SDK does not read the host app's request body stream. This pins the
    /// two facts that make any other policy unsafe, so nobody reintroduces the
    /// drain that was removed.
    ///
    /// 1. `mutableCopy()` of an `NSURLRequest` does NOT copy the body stream —
    ///    the copy points at the very object the app handed to `URLSession`.
    /// 2. A bound-pair read stream (what every streamed multipart upload sits
    ///    on) reports `hasBytesAvailable == false` while merely STARVED, at
    ///    `.open` rather than `.atEnd`. A drain that stops there has already
    ///    taken bytes that cannot be put back, and the same half-drained stream
    ///    then goes out as the request's body.
    ///
    /// Together those mean a speculative read corrupts the app's upload, with
    /// no way to detect it in advance and no way to undo it. Hence: no read.
    func testACopiedRequestSharesTheAppsBodyStreamObject() {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &input, outputStream: &output)
        guard let stream = input, let sink = output else {
            return XCTFail("Could not create a bound stream pair.")
        }
        defer { sink.close(); stream.close() }

        let original = NSMutableURLRequest(url: URL(string: "https://example.com/upload")!)
        original.httpMethod = "POST"
        original.httpBodyStream = stream

        let copy = original.mutableCopy() as! NSMutableURLRequest
        XCTAssertTrue(copy.httpBodyStream === stream,
                      "The copy shares the app's stream. Anything read out of it here is read "
                      + "out of the bytes the app is about to send.")
    }

    func testAStarvedBoundPairLooksExactlyLikeAFinishedOne() {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &input, outputStream: &output)
        guard let stream = input, let sink = output else {
            return XCTFail("Could not create a bound stream pair.")
        }
        defer { sink.close(); stream.close() }
        sink.open()
        let head = Array("--boundary\r\nContent-Disposition: form-data".utf8)
        XCTAssertEqual(sink.write(head, maxLength: head.count), head.count,
                       "Setup failed: nothing was written into the bound pair.")

        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var drained = Data()
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            drained.append(buffer, count: n)
        }

        XCTAssertEqual(drained.count, head.count,
                       "The producer's first chunk was consumed.")
        XCTAssertNotEqual(stream.streamStatus, .atEnd,
                          "It is NOT finished — the producer has more to write.")
        XCTAssertFalse(stream.hasBytesAvailable,
                       "Yet it looks finished. This indistinguishability is the whole problem: "
                       + "a drain cannot tell 'done' from 'starved', and the bytes it has "
                       + "already taken cannot be put back into the stream the request will send.")
    }

    // MARK: - 2. A blocking rule says what it preempted

    /// Wording is pinned here for the same reason the breakpoint equivalent is:
    /// this sentence is the only place a developer finds out why the mock they
    /// armed never answered.
    func testBlockPreemptedMockMessageNamesTheMockAndTheRewrites() {
        let message = CustomHTTPProtocol.blockPreemptedMockMessage(mockEnabled: true)

        XCTAssertTrue(message.contains("blocks the request"))
        XCTAssertTrue(message.contains("mock"),
                      "A blocked mock has to be named — this is the whole point of the message.")
        XCTAssertTrue(message.contains("response rewrites"),
                      "Rewrites die with the mock and were equally silent.")
        XCTAssertTrue(message.contains("Turn off Block Request"),
                      "The message has to say what to do about it, like its siblings do.")
    }

    /// Rewrites can be armed without a mock, and the message must not then claim
    /// a mock was skipped.
    func testBlockPreemptedMockMessageMentionsOnlyRewritesWhenNoMockIsArmed() {
        let message = CustomHTTPProtocol.blockPreemptedMockMessage(mockEnabled: false)

        XCTAssertTrue(message.contains("response rewrites"))
        XCTAssertFalse(message.contains("mock"),
                       "No mock was armed, so the report must not invent one.")
        XCTAssertTrue(message.contains("Turn off Block Request"))
    }

    /// The two block messages must stay distinguishable: a rule that blocks a
    /// breakpoint and a mock produces both, in different places (the inbox and
    /// the rewrite report), and identical wording would read as a duplicate.
    func testBlockPreemptionMessagesAreDistinct() {
        XCTAssertNotEqual(CustomHTTPProtocol.blockPreemptedMockMessage(mockEnabled: true),
                          CustomHTTPProtocol.blockPreemptedBreakpointMessage(.beforeSend))
    }

    // MARK: - 3. The Console Logs switch tells the truth and has real control

    /// The host app's opt-out is NOT written into the user preference.
    ///
    /// `SwiftyDebug.enableConsoleLog` belongs to the host app and is transient;
    /// `Settings.consoleLogsEnabled` is persisted to `UserDefaults`. Copying one
    /// into the other made them indistinguishable, so a host that opted out for
    /// one build turned console capture off permanently — on every later launch,
    /// including ones where the opt-out had been removed.
    func testHostConsoleOptOutIsNotPersistedIntoTheUserPreference() {
        Settings.shared.consoleLogsEnabled = true
        SwiftyDebug.enableConsoleLog = false

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(Settings.shared.consoleLogsEnabled,
                      "The user's own preference must survive the host app's opt-out. The App "
                      + "tab renders the row off and DISABLED while the host opts out, which "
                      + "tells the truth without overwriting anything.")
    }

    /// The flag defaults to `true`, so only an explicit opt-out carries
    /// information: reconciliation must not force a switch the user turned on
    /// back off.
    func testReconciliationLeavesTheSwitchAloneWhenTheHostDidNotOptOut() {
        Settings.shared.consoleLogsEnabled = true
        SwiftyDebug.enableConsoleLog = true

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(Settings.shared.consoleLogsEnabled)
    }

    /// The host app's opt-out is ABSOLUTE: the debug switch cannot overrule it,
    /// and the SDK never writes to the host's public flag.
    ///
    /// This is the knob an app with tokens or PII in its logs sets. A
    /// write-through made it settable from the debug UI of a shipped build.
    func testTheSwitchCannotTurnCaptureOnOverAHostOptOut() {
        SwiftyDebug.enableConsoleLog = false

        Settings.shared.consoleLogsEnabled = true
        XCTAssertFalse(SwiftyDebug.enableConsoleLog,
                       "The SDK must never write to the host app's own opt-out flag.")
        XCTAssertFalse(PrintInterceptor.shared.enable,
                       "And nothing may start capturing: the switch ANDs with the host flag.")

        SwiftyDebug.enableConsoleLog = true
        Settings.shared.consoleLogsEnabled = true
        XCTAssertTrue(PrintInterceptor.shared.enable,
                      "With no opt-out in force the switch has full control, as before.")
    }

    // MARK: - 4. Clearing pinned requests reports what survived

    /// The bubble reads the surviving count out of the notification and falls
    /// back to zero, so a bare post made the badge claim the whole list was
    /// gone when only the pinned rows were.
    func testClearPinnedPostsTheSurvivingRequestCount() {
        let survivor = makeTransaction("https://api.example.com/survivor-\(UUID().uuidString)",
                                       pinned: false)
        XCTAssertTrue(NetworkRequestStore.shared.addHttpRequset(survivor))
        addedModels.append(survivor)

        var reported: Int?
        let token = NotificationCenter.default.addObserver(
            forName: .allLogsCleared, object: nil, queue: nil
        ) { note in
            reported = note.userInfo?["pinnedCount"] as? Int
        }
        defer { NotificationCenter.default.removeObserver(token) }

        NetworkRequestStore.shared.clearPinned()

        XCTAssertNotNil(reported,
                        "clearPinned() posted no count at all, and the bubble reads a missing "
                        + "count as zero — the badge dropped to 0 with the list still full.")
        XCTAssertEqual(reported, NetworkRequestStore.shared.transactionCount,
                       "The count posted has to be what is actually left in the store.")
        XCTAssertGreaterThan(reported ?? 0, 0,
                             "An unpinned request survived the clear, so the count cannot be zero.")
    }

    // MARK: - 5. disable() is the real off-switch

    /// `disable()` closes the runtime gate — the ONLY thing gating web-view
    /// capture, the stdout pipe handler and the OSLog poll loop. Leaving it open
    /// is what kept all three feeding the stores after the host app asked for
    /// the SDK to be off.
    func testDisableClosesTheRuntimeGate() {
        SwiftyDebugRuntime.markActive()

        SwiftyDebug.disable()

        XCTAssertFalse(SwiftyDebugRuntime.isActive,
                       "disable() has to be the real kill-switch: every capture path in the "
                       + "SDK short-circuits on this flag and nothing else stops them.")
    }

    /// The same call has to stop native interception and mute the print
    /// interceptor — the parts `disable()` already did — so delegating to
    /// `fullStop()` is not a regression for them.
    func testDisableStillStopsNativeCaptureAndPrintInterception() {
        SwiftyDebugRuntime.markActive()
        NetworkMonitor.shared.isNetworkEnable = true
        PrintInterceptor.shared.enable = true

        SwiftyDebug.disable()

        XCTAssertFalse(NetworkMonitor.shared.isNetworkEnable)
        XCTAssertFalse(PrintInterceptor.shared.enable)
        XCTAssertFalse(Settings.shared.shakeGestureEnabled)
    }

    // MARK: - Fixtures

    private func makeTransaction(_ urlString: String, pinned: Bool) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: urlString)
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "application/json"
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = model.startTime
        model.totalDuration = "0.010000 (s)"
        model.isPinned = pinned
        return model
    }
}
