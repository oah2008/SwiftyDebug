//
//  BreakpointHoldCountdownTests.swift
//  SwiftyDebugTests
//
//  The paused inbox shows "held Ns · Ns left". That countdown ran against
//  `breakpointHoldSeconds` (600), which is only the real budget while "Extend
//  Request Timeouts" is ON — and that now defaults OFF. So the label promised
//  nine minutes on a request the app would abandon after its own timeout,
//  typically 60s and often far less.
//

import XCTest
@testable import SwiftyDebug

final class BreakpointHoldCountdownTests: XCTestCase {

    private func paused(timeout: TimeInterval) -> BreakpointCenter.PausedRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/slow")!)
        request.timeoutInterval = timeout
        return BreakpointCenter.PausedRequest(stage: .afterResponse,
                                              request: request,
                                              resume: { _ in }, abort: {})
    }

    func testTheCountdownUsesTheRequestsOwnTimeout() throws {
        // An app that asked for 15 seconds must not be told it has 600.
        let item = paused(timeout: 15)
        let left = try XCTUnwrap(item.remainingHoldTime)
        XCTAssertLessThanOrEqual(left, 15,
                                 "The countdown promised more time than the app will wait")
        XCTAssertGreaterThan(left, 10, "and it should still be counting down from 15")
    }

    func testAShortTimeoutIsNotInflatedToTheHoldBudget() throws {
        let item = paused(timeout: 5)
        let left = try XCTUnwrap(item.remainingHoldTime)
        XCTAssertLessThanOrEqual(left, 5)
        XCTAssertNotEqual(Int(left), Int(Settings.shared.breakpointHoldSeconds),
                          "This is the exact lie: a 5s request showing the 600s budget")
    }

    func testAnExtendedTimeoutStillGetsTheFullBudget() throws {
        // With the toggle ON the swizzle has already raised the request's timeout,
        // so reading the request is still the right answer — no special case.
        let item = paused(timeout: Settings.shared.breakpointHoldSeconds)
        let left = try XCTUnwrap(item.remainingHoldTime)
        XCTAssertGreaterThan(left, Settings.shared.breakpointHoldSeconds - 5)
    }

    func testASettledRequestHasNoCountdown() {
        let item = paused(timeout: 60)
        BreakpointCenter.shared.park(item)
        BreakpointCenter.shared.expire(item)
        XCTAssertNil(item.remainingHoldTime, "A settled request is not still counting down")
    }

    func testAZeroTimeoutFallsBackToTheHoldBudget() throws {
        // URLRequest reports 0 for "unset"; that must not read as "no time left".
        let item = paused(timeout: 0)
        let left = try XCTUnwrap(item.remainingHoldTime)
        XCTAssertGreaterThan(left, 0, "An unset timeout must not show 0s left")
    }
}
