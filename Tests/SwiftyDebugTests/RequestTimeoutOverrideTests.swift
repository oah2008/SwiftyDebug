//
//  RequestTimeoutOverrideTests.swift
//  SwiftyDebugTests
//
//  Covers the guarantee that merely enabling SwiftyDebug does NOT change the
//  host app's request timeouts. `extendTimeoutsForBreakpoints` used to default
//  to ON, which silently raised every request in the app to the breakpoint hold
//  budget (600 s) — an unrequested change to production networking behaviour.
//  These tests pin the new default (OFF), the untouched pass-through while off,
//  the raise while on, and the restart-required reporting the settings UI relies
//  on to decide whether to prompt.
//

import XCTest
@testable import SwiftyDebug

final class RequestTimeoutOverrideTests: XCTestCase {

    private var savedExtend = false
    private var savedHold: TimeInterval = 600
    private var savedActive = true
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        savedExtend = Settings.shared.extendTimeoutsForBreakpoints
        savedHold = Settings.shared.breakpointHoldSeconds
        savedActive = SwiftyDebugRuntime.isActive
        suiteName = "RequestTimeoutOverrideTests.\(UUID().uuidString)"
        SwiftyDebugRuntime.markActive()
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
    }

    override func tearDown() {
        Settings.shared.extendTimeoutsForBreakpoints = savedExtend
        Settings.shared.breakpointHoldSeconds = savedHold
        if savedActive { SwiftyDebugRuntime.markActive() } else { SwiftyDebugRuntime.markStopped() }
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var key: String { SettingsKey.extendTimeoutsForBreakpoints.rawValue }

    // MARK: - The default is OFF

    func testDefaultIsFalseWhenNothingWasEverStored() {
        // The old ON-by-default was never written to disk (property observers do
        // not run inside Settings.init), so an existing install that never
        // touched the toggle is exactly this case: absent key.
        let defaults = freshDefaults()
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertFalse(Settings.extendTimeoutsDefault(in: defaults),
                       "An install that never touched this setting must not inherit the old ON default.")
    }

    func testStoredTrueIsHonoured() {
        // Somebody explicitly turned it on. That is a real choice, not a leftover
        // default, so it survives.
        let defaults = freshDefaults()
        defaults.set(true, forKey: key)
        XCTAssertTrue(Settings.extendTimeoutsDefault(in: defaults))
    }

    func testStoredFalseIsHonoured() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: key)
        XCTAssertFalse(Settings.extendTimeoutsDefault(in: defaults))
    }

    // MARK: - OFF: the app's own timeout, untouched

    func testTimeoutPassesThroughUnchangedWhenOff() {
        Settings.shared.extendTimeoutsForBreakpoints = false
        Settings.shared.breakpointHoldSeconds = 600

        for requested: TimeInterval in [0, 1, 10, 30, 60, 599, 600, 601, 3600] {
            XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(requested), requested,
                           "Requested \(requested)s must be returned verbatim while the setting is off.")
        }
    }

    func testTimeoutPassesThroughUnchangedWhenSDKIsFullyStopped() {
        // Full stop must also mean "hands off the host app's networking".
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600
        SwiftyDebugRuntime.markStopped()

        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(10), 10)
    }

    // MARK: - ON: raised to the hold budget

    func testTimeoutIsRaisedToHoldBudgetWhenOn() {
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600

        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(10), 600)
        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(0), 600)
        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(599), 600)
    }

    func testAppAskingForLongerThanHoldBudgetKeepsItsOwnValue() {
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600

        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(900), 900)
    }

    func testRaiseFollowsTheConfiguredHoldBudget() {
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 120

        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(10), 120)
        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(300), 300)
    }

    // MARK: - Public switch

    func testPublicSwitchReadsAndWritesTheSetting() {
        SwiftyDebug.extendTimeoutsForBreakpoints = true
        XCTAssertTrue(Settings.shared.extendTimeoutsForBreakpoints)
        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(5),
                       Settings.shared.breakpointHoldSeconds)

        SwiftyDebug.extendTimeoutsForBreakpoints = false
        XCTAssertFalse(Settings.shared.extendTimeoutsForBreakpoints)
        XCTAssertEqual(CustomHTTPProtocol.effectiveRequestTimeout(5), 5)
    }

    // MARK: - Does the change need a restart?

    func testChangeAppliesImmediatelyWhenNothingWasBuiltYet() {
        Settings.shared.extendTimeoutsForBreakpoints = false
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()

        XCTAssertEqual(SwiftyDebug.setExtendTimeoutsForBreakpoints(true), .appliesImmediately)
        XCTAssertFalse(SwiftyDebug.extendTimeoutsChangeEffect.requiresRestart)
    }

    func testChangeNeedsRestartOnceATimeoutWasDecidedUnderTheOldValue() {
        Settings.shared.breakpointHoldSeconds = 600
        Settings.shared.extendTimeoutsForBreakpoints = false
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()

        // The app built a session configuration asking for 10s: its timeout is
        // now frozen into every URLSession created from it.
        CustomHTTPProtocol.recordTimeoutDecision(requested: 10)

        let effect = SwiftyDebug.setExtendTimeoutsForBreakpoints(true)
        XCTAssertEqual(effect, .restartRequiredForExistingSessions)
        XCTAssertTrue(effect.requiresRestart)
        XCTAssertFalse(effect.message.isEmpty)
    }

    func testConfigurationsAboveTheHoldBudgetNeverRequireARestart() {
        Settings.shared.breakpointHoldSeconds = 600
        Settings.shared.extendTimeoutsForBreakpoints = false
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()

        // 900s is what the app gets whether the setting is on or off, so no
        // session built from it can be holding a stale value.
        CustomHTTPProtocol.recordTimeoutDecision(requested: 900)

        XCTAssertEqual(SwiftyDebug.extendTimeoutsChangeEffect, .appliesImmediately)
    }

    func testSettingTheValueItAlreadyHasNeverPromptsForRestart() {
        Settings.shared.extendTimeoutsForBreakpoints = true
        CustomHTTPProtocol.recordTimeoutDecision(requested: 10)

        XCTAssertEqual(SwiftyDebug.setExtendTimeoutsForBreakpoints(true), .appliesImmediately)
        XCTAssertTrue(Settings.shared.extendTimeoutsForBreakpoints)
    }
}
