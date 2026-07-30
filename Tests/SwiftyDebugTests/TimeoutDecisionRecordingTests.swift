//
//  TimeoutDecisionRecordingTests.swift
//  SwiftyDebugTests
//
//  Pins WHERE a request-timeout decision is recorded.
//
//  `injectProtocol(into:)` used to record the decision only on the branch where
//  it changed nothing, and delegate the other branch to the swizzled
//  `setTimeoutIntervalForRequest:`. That setter records `requested: value` — and
//  by then `value` is the already-applied 600, which can never satisfy
//  `recordTimeoutDecision`'s `requested < breakpointHoldSeconds` guard.
//
//  So the configurations SwiftyDebug actually MODIFIED — the only ones that can
//  be holding a stale 600 s timeout — were the only ones never counted. Turning
//  "Extend Request Timeouts" back OFF then reported `.appliesImmediately`, the
//  UI showed no restart prompt, and every live session kept its 600 s idle
//  timeout for the rest of the launch.
//

import XCTest
@testable import SwiftyDebug

final class TimeoutDecisionRecordingTests: XCTestCase {

    private var savedExtend = false
    private var savedHold: TimeInterval = 600
    private var savedActive = true

    override func setUp() {
        super.setUp()
        savedExtend = Settings.shared.extendTimeoutsForBreakpoints
        savedHold = Settings.shared.breakpointHoldSeconds
        savedActive = SwiftyDebugRuntime.isActive
        SwiftyDebugRuntime.markActive()
        Settings.shared.breakpointHoldSeconds = 600
        Settings.shared.extendTimeoutsForBreakpoints = false
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
    }

    override func tearDown() {
        Settings.shared.extendTimeoutsForBreakpoints = savedExtend
        Settings.shared.breakpointHoldSeconds = savedHold
        if savedActive { SwiftyDebugRuntime.markActive() } else { SwiftyDebugRuntime.markStopped() }
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        super.tearDown()
    }

    /// Builds a configuration whose timeout is `seconds`, with the setting OFF so
    /// the value lands verbatim whether or not the setter swizzle is installed in
    /// this process.
    private func configuration(askingFor seconds: TimeInterval) -> URLSessionConfiguration {
        Settings.shared.extendTimeoutsForBreakpoints = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds
        XCTAssertEqual(config.timeoutIntervalForRequest, seconds,
                       "Precondition: with the setting off the app's value is untouched.")
        return config
    }

    // MARK: - The regression

    func testAConfigurationSwiftyDebugRaisedIsCountedAgainstItsORIGINALValue() {
        let config = configuration(askingFor: 10)

        Settings.shared.extendTimeoutsForBreakpoints = true
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        CustomHTTPProtocol.injectProtocol(into: config)

        XCTAssertEqual(config.timeoutIntervalForRequest, 600,
                       "Precondition: this is the branch that MODIFIES the config.")
        XCTAssertEqual(CustomHTTPProtocol.timeoutSettingChangeEffect,
                       .restartRequiredForExistingSessions,
                       "The config we just raised from 10 s to 600 s is exactly the one that can "
                       + "be holding a stale timeout, so it must be counted.")
    }

    func testTurningTheSettingOffAfterARaisePromptsForRestart() {
        let config = configuration(askingFor: 10)

        // The app turns the feature on; a session configuration is built and raised.
        Settings.shared.extendTimeoutsForBreakpoints = true
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        CustomHTTPProtocol.injectProtocol(into: config)

        // Now they turn it back off. Sessions already built from that config keep 600 s.
        let effect = SwiftyDebug.setExtendTimeoutsForBreakpoints(false)
        XCTAssertEqual(effect, .restartRequiredForExistingSessions)
        XCTAssertTrue(effect.requiresRestart,
                      "Without the prompt the developer is told the change took effect while live "
                      + "sessions sit on a 600 s idle timeout.")
    }

    // MARK: - The branch that already worked stays working

    func testAConfigurationLeftAloneBelowTheBudgetIsStillCounted() {
        // Setting OFF: applied == requested, nothing is written, but the config
        // still holds a value that WOULD have differed had the setting been on.
        let config = configuration(askingFor: 30)
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        CustomHTTPProtocol.injectProtocol(into: config)

        XCTAssertEqual(config.timeoutIntervalForRequest, 30,
                       "With the setting off the config must be left literally untouched.")
        XCTAssertEqual(CustomHTTPProtocol.timeoutSettingChangeEffect,
                       .restartRequiredForExistingSessions)
    }

    // MARK: - Configs the setting can never reach are still never counted

    func testAConfigurationAboveTheHoldBudgetIsNeverCounted() {
        let config = configuration(askingFor: 900)

        Settings.shared.extendTimeoutsForBreakpoints = true
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        CustomHTTPProtocol.injectProtocol(into: config)

        XCTAssertEqual(config.timeoutIntervalForRequest, 900,
                       "A config asking for more than the hold budget keeps its own value.")
        XCTAssertEqual(CustomHTTPProtocol.timeoutSettingChangeEffect, .appliesImmediately,
                       "900 s is what this config gets either way, so it can never be stale and "
                       + "must not trigger a restart prompt.")
    }

    func testInjectingIntoAConfigurationStillInstallsTheProtocol() {
        // The timeout bookkeeping must not have cost the function its actual job.
        let config = configuration(askingFor: 30)
        config.protocolClasses = []
        CustomHTTPProtocol.injectProtocol(into: config)

        let installed = (config.protocolClasses ?? []).contains { $0 == CustomHTTPProtocol.self }
        XCTAssertTrue(installed)
    }

    func testInjectingTwiceDoesNotDuplicateTheProtocol() {
        let config = configuration(askingFor: 30)
        config.protocolClasses = []
        CustomHTTPProtocol.injectProtocol(into: config)
        CustomHTTPProtocol.injectProtocol(into: config)

        let count = (config.protocolClasses ?? []).filter { $0 == CustomHTTPProtocol.self }.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - The "is this SwiftyDebug's own config?" flag

    func testRecordingFromManyThreadsAtOnceIsSafeAndCounts() {
        // `isBuildingOwnConfiguration` used to be a shared static Bool: written on
        // a CFNetwork thread inside swift_once and read here, from host-app
        // threads. That is a data race Thread Sanitizer reports against the SDK —
        // and wrong besides, since a host config built on another thread during
        // that window was misfiled as SwiftyDebug's own and dropped from the
        // restart bookkeeping. It is per-thread state now; this exercises the
        // read path concurrently so TSan has something to catch it on.
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            CustomHTTPProtocol.recordTimeoutDecision(requested: 10)
        }

        XCTAssertEqual(CustomHTTPProtocol.timeoutSettingChangeEffect,
                       .restartRequiredForExistingSessions,
                       "A decision taken on any thread is a host-app decision and must count.")
    }
}
