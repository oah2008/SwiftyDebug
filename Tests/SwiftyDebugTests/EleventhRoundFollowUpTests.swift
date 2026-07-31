//
//  EleventhRoundFollowUpTests.swift
//  SwiftyDebugTests
//
//  The defects the eleven fixes themselves introduced. Fixing a bug and shipping
//  a smaller one in its place is still shipping a bug.
//

import XCTest
@testable import SwiftyDebug

final class EleventhRoundFollowUpTests: XCTestCase {

    // MARK: - A blocked XHR must not poison the object for reuse

    func testTheReadyStateShimIsWritableAndConfigurable() {
        // A getter-only own property made the next `open()` throw on any
        // implementation whose readyState is a writable own property, so a page
        // reusing one XHR object broke after a single blocked request.
        let js = WebViewInjectedScript.networkCapture
        XCTAssertTrue(js.contains("set:function(v)"),
                      "The readyState shim needs a setter, or reusing the object throws")
        XCTAssertTrue(js.contains("configurable:true"),
                      "It must stay configurable so it can be replaced")
        XCTAssertTrue(js.contains("this._cd.blocked=false"),
                      "Re-opening a blocked object must clear the blocked state")
    }

    // MARK: - A blocked fetch must look like a network failure

    func testABlockedFetchRejectsWithTypeError() {
        // Pages branch on `e instanceof TypeError` to tell "network down" from
        // "application error". Rejecting with a plain Error made a SwiftyDebug
        // block read as an application error.
        let js = WebViewInjectedScript.networkCapture
        XCTAssertTrue(js.contains("new TypeError('Blocked by SwiftyDebug intercept rule')"),
                      "A blocked fetch must reject the way a real network failure does")
    }

    // MARK: - Notices must not drown each other

    func testRepeatingTheSameNoticeDoesNotEvictEverythingElse() {
        BreakpointCenter.shared.clearNotices()
        defer { BreakpointCenter.shared.clearNotices() }

        let url = URL(string: "https://api.example.com/poll")!
        BreakpointCenter.shared.note("something else entirely", for: URL(string: "https://a.com/x")!)
        for _ in 0..<40 {
            BreakpointCenter.shared.note("mocked, so the breakpoint was skipped", for: url)
        }

        let notices = BreakpointCenter.shared.notices
        let repeated = notices.filter { $0.message == "mocked, so the breakpoint was skipped" }
        XCTAssertEqual(repeated.count, 1, "A polled endpoint must not fill every slot")
        XCTAssertTrue(notices.contains { $0.message == "something else entirely" },
                      "Repetition must not evict unrelated notices")
    }

    func testTheNewestOccurrenceOfARepeatedNoticeWins() {
        BreakpointCenter.shared.clearNotices()
        defer { BreakpointCenter.shared.clearNotices() }

        let url = URL(string: "https://api.example.com/poll")!
        BreakpointCenter.shared.note("same", for: url)
        BreakpointCenter.shared.note("other", for: URL(string: "https://b.com/y")!)
        BreakpointCenter.shared.note("same", for: url)

        XCTAssertEqual(BreakpointCenter.shared.notices.first?.message, "same",
                       "The most recent occurrence should be at the top")
    }

    func testTheSameMessageOnDifferentURLsIsNotCollapsed() {
        BreakpointCenter.shared.clearNotices()
        defer { BreakpointCenter.shared.clearNotices() }

        BreakpointCenter.shared.note("skipped", for: URL(string: "https://a.com/one")!)
        BreakpointCenter.shared.note("skipped", for: URL(string: "https://a.com/two")!)

        XCTAssertEqual(BreakpointCenter.shared.notices.count, 2,
                       "De-duplication is per URL — two endpoints are two facts")
    }
}
