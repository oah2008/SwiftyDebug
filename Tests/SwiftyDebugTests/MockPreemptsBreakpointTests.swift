//
//  MockPreemptsBreakpointTests.swift
//  SwiftyDebugTests
//
//  A rule can arm a mock and a breakpoint at the same time. The mock wins —
//  `startLoading` answers locally and returns before the breakpoint is ever
//  parked — so the pause the developer armed never happens. That was SILENT:
//  the inbox stayed empty and nothing anywhere said why.
//
//  The same rule combination has said so for response rewrites since day one
//  (`deliverMock` records a skip reason, and the rule editor warns in its
//  section footer). These pin the breakpoint half of it, through the channel the
//  developer is actually staring at: the inbox's DIDN'T PAUSE section.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class MockPreemptsBreakpointTests: XCTestCase {

    private static let mockBody = #"{"from":"mock"}"#

    private var savedHoldSeconds: TimeInterval = 0

    override func setUpWithError() throws {
        try super.setUpWithError()

        SwiftyDebugRuntime.markActive()
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.urls = []
        Settings.shared.networkConditionerPreset = .off
        NetworkMonitor.shared.enable()
        savedHoldSeconds = Settings.shared.breakpointHoldSeconds
        Settings.shared.breakpointHoldSeconds = 600

        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        BreakpointCenter.shared.clearNotices()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDownWithError() throws {
        Settings.shared.breakpointHoldSeconds = savedHoldSeconds
        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        BreakpointCenter.shared.clearNotices()
        InterceptRuleStore.shared.removeAll()
        NetworkMonitor.shared.disable()
        SwiftyDebug.monitorAllUrls = false
        try super.tearDownWithError()
    }

    // MARK: - Harness

    /// A rule that answers `path` from a mock, optionally with a breakpoint
    /// armed on the same rule.
    private func armRule(path: String, breakpoint: BreakpointMode, mockEnabled: Bool = true) {
        var rule = InterceptRule(matchEndpoint: path, matchMode: .exact)
        rule.isEnabled = true
        rule.breakpointMode = breakpoint
        rule.mock = MockResponse(isEnabled: mockEnabled, statusCode: 200, body: Self.mockBody)
        InterceptRuleStore.shared.addOrUpdate(rule)

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: Self.url(path))
        XCTAssertEqual(resolved?.breakpointMode, breakpoint,
                       "the rule did not resolve — the rest of the test would be meaningless")
        XCTAssertEqual(resolved?.mock.isEnabled, mockEnabled)
    }

    /// Deliberately a host nothing listens on: if the mock ever stopped
    /// answering locally, the request would fail rather than quietly hit a
    /// server and let the test pass for the wrong reason.
    private static func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:9\(path)")!
    }

    private struct Outcome {
        var data: Data?
        var response: HTTPURLResponse?
        var error: NSError?
    }

    private func fire(_ path: String) -> Outcome {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var outcome = Outcome()
        let done = expectation(description: "task completes")
        session.dataTask(with: Self.url(path)) { data, response, error in
            outcome.data = data
            outcome.response = response as? HTTPURLResponse
            outcome.error = error as NSError?
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 25)
        return outcome
    }

    // MARK: - The reported defect

    /// `.beforeSend` + a mock: the request never leaves the app, so the pause
    /// cannot happen. It must SAY so, in the inbox, naming the mock as the cause.
    func testABeforeSendBreakpointOnAMockedRuleSaysWhyItNeverPaused() throws {
        armRule(path: "/mocked-before", breakpoint: .beforeSend)

        let out = fire("/mocked-before")

        XCTAssertNil(out.error)
        XCTAssertEqual(String(data: out.data ?? Data(), encoding: .utf8), Self.mockBody,
                       "precondition: the mock answered")
        XCTAssertTrue(BreakpointCenter.shared.pausedRequests.isEmpty,
                      "precondition: the mock short-circuits before the breakpoint parks")

        let notices = BreakpointCenter.shared.notices
        XCTAssertEqual(notices.count, 1,
                       "An armed breakpoint that never fires has to explain itself. The developer "
                       + "is looking at an empty inbox with no idea the mock is the reason.")
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notice.message,
                       CustomHTTPProtocol.mockPreemptedBreakpointMessage(.beforeSend))
        XCTAssertTrue(notice.message.lowercased().contains("mock"),
                      "the reason has to name the mock: \(notice.message)")
        XCTAssertEqual(notice.url, Self.url("/mocked-before").absoluteString,
                       "the notice has to say WHICH request it is about")
    }

    /// `.afterResponse` + a mock: there is no server response to hold, because
    /// the network was never touched.
    func testAnAfterResponseBreakpointOnAMockedRuleSaysWhyItNeverPaused() throws {
        armRule(path: "/mocked-after", breakpoint: .afterResponse)

        let out = fire("/mocked-after")

        XCTAssertNil(out.error)
        XCTAssertTrue(BreakpointCenter.shared.pausedRequests.isEmpty)
        let notice = try XCTUnwrap(BreakpointCenter.shared.notices.first,
                                   "the after-response stage is skipped just as silently")
        XCTAssertEqual(notice.message,
                       CustomHTTPProtocol.mockPreemptedBreakpointMessage(.afterResponse))
    }

    /// The reason has to reach the screen, not just the store: the inbox's
    /// DIDN'T PAUSE section is where a developer waiting for a pause ends up.
    func testTheInboxShowsTheReasonInItsDidntPauseSection() throws {
        armRule(path: "/mocked-inbox", breakpoint: .beforeSend)
        _ = fire("/mocked-inbox")
        XCTAssertFalse(BreakpointCenter.shared.notices.isEmpty, "precondition: a notice exists")

        let inbox = BreakpointInboxViewController()
        inbox.loadViewIfNeeded()
        inbox.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        inbox.tableView.reloadData()
        inbox.view.layoutIfNeeded()

        XCTAssertEqual(inbox.numberOfSections(in: inbox.tableView), 2,
                       "the notice section is missing from the inbox")
        XCTAssertEqual(inbox.tableView(inbox.tableView, titleForHeaderInSection: 1), "DIDN'T PAUSE")
        XCTAssertEqual(inbox.tableView(inbox.tableView, numberOfRowsInSection: 1), 1)
        let cell = inbox.tableView(inbox.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(cell.textLabel?.text,
                       CustomHTTPProtocol.mockPreemptedBreakpointMessage(.beforeSend))
        XCTAssertEqual(cell.detailTextLabel?.text, Self.url("/mocked-inbox").absoluteString)
    }

    // MARK: - Adjacent behaviour

    /// A mock with NO breakpoint must stay quiet — a notice for every mocked
    /// request would turn the section into noise and bury the real one.
    func testAMockWithoutABreakpointRecordsNoNotice() {
        armRule(path: "/mocked-only", breakpoint: .off)

        let out = fire("/mocked-only")

        XCTAssertNil(out.error)
        XCTAssertEqual(String(data: out.data ?? Data(), encoding: .utf8), Self.mockBody)
        XCTAssertTrue(BreakpointCenter.shared.notices.isEmpty,
                      "nothing was skipped, so there is nothing to report")
    }

    /// The mock itself must be unaffected: same status, same bytes, and a
    /// `Content-Length` that describes them (a stale one truncates the body).
    func testTheMockStillDeliversWithACorrectContentLength() throws {
        armRule(path: "/mocked-length", breakpoint: .beforeSend)

        let out = fire("/mocked-length")

        XCTAssertNil(out.error)
        XCTAssertEqual(out.response?.statusCode, 200)
        XCTAssertEqual(out.data, Data(Self.mockBody.utf8))
        XCTAssertEqual(out.response?.value(forHTTPHeaderField: "Content-Length"),
                       "\(Data(Self.mockBody.utf8).count)")
    }

    /// The control: with the mock switched OFF the breakpoint has to park as it
    /// always did. (The rule still resolves; only the mock is gone.)
    func testTheBreakpointStillParksWhenTheMockIsSwitchedOff() throws {
        armRule(path: "/not-mocked", breakpoint: .beforeSend, mockEnabled: false)

        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let done = expectation(description: "task completes")
        let task = session.dataTask(with: Self.url("/not-mocked")) { _, _, _ in done.fulfill() }

        var parked: BreakpointCenter.PausedRequest?
        let didPark = expectation(description: "request parked")
        didPark.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main) { _ in
                if let first = BreakpointCenter.shared.pausedRequests.first, parked == nil {
                    parked = first
                    didPark.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        task.resume()
        wait(for: [didPark], timeout: 20)
        XCTAssertEqual(parked?.stage, .beforeSend,
                       "without a mock in the way the breakpoint must still pause the request")
        XCTAssertTrue(BreakpointCenter.shared.notices.isEmpty,
                      "nothing was skipped here")

        // Release it so the task finishes and nothing is left holding.
        BreakpointCenter.shared.abort(try XCTUnwrap(parked))
        wait(for: [done], timeout: 25)
    }

    /// The rewrite skip reason is a separate channel and must keep working — the
    /// breakpoint notice is added alongside it, not instead of it.
    func testAMockedRuleStillRecordsItsResponseRewriteSkipReason() throws {
        var rule = InterceptRule(matchEndpoint: "/mocked-rewrite", matchMode: .exact)
        rule.isEnabled = true
        rule.breakpointMode = .beforeSend
        rule.mock = MockResponse(isEnabled: true, statusCode: 200, body: Self.mockBody)
        rule.responseRewrites = [ResponseRewrite(pattern: "from", action: .setValue("rewritten"))]
        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertEqual(InterceptRuleStore.shared
            .resolvedRule(forURL: Self.url("/mocked-rewrite"))?.hasActiveResponseRewrites, true)

        _ = fire("/mocked-rewrite")

        var model: NetworkTransaction?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            model = NetworkRequestStore.shared.snapshot().first {
                ($0.url as URL?)?.path == "/mocked-rewrite"
            }
        }
        let captured = try XCTUnwrap(model, "the mocked request was never captured")
        XCTAssertEqual(captured.rewriteSkippedReason?.contains("mock"), true,
                       "the rewrite skip reason was lost: \(String(describing: captured.rewriteSkippedReason))")
        XCTAssertFalse(BreakpointCenter.shared.notices.isEmpty,
                       "and the breakpoint reason is recorded alongside it")
        NetworkRequestStore.shared.remove(captured)
    }
}
