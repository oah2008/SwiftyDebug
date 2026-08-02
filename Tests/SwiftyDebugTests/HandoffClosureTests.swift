//
//  HandoffClosureTests.swift
//  SwiftyDebugTests
//
//  Three defects that were reported, handed off to an agent that did not own the
//  file, and then never applied. Two rounds of "the inbox reports it, so it isn't
//  silent" is not the same as reporting it where the developer is looking.
//

import XCTest
@testable import SwiftyDebug

final class HandoffClosureTests: XCTestCase {

    // MARK: - The skip reason reaches the request, not just the inbox

    func testABreakpointSkipReasonSurvivesOntoTheTransaction() {
        let model = NetworkTransaction()
        model.breakpointSkippedReason = "This rule returns a mock, so the breakpoint never paused."

        XCTAssertTrue(model.hasRewriteInfo,
                      "The detail screen builds its explanation section off this flag")
    }

    func testTheSkipReasonSurvivesPinningAndReloading() throws {
        // Pinning is the only path where a transaction outlives the process, so
        // it is the only persistence the explanation needs.
        let model = NetworkTransaction()
        model.requestId = "handoff-test-\(UUID().uuidString)"
        model.url = NSURL(string: "https://api.example.com/x")
        model.isPinned = true
        model.breakpointSkippedReason = "mocked, so it never paused"
        model.savePinToDisk()
        defer { model.removePinFromDisk() }

        let restored = NetworkTransaction.loadPinnedFromDisk()
            .first { $0.requestId == model.requestId }
        XCTAssertEqual(try XCTUnwrap(restored).breakpointSkippedReason,
                       "mocked, so it never paused",
                       "A pinned request must keep its explanation across a relaunch")
    }

    func testABreakpointReasonIsSeparateFromARewriteReason() {
        // They are different promises. Merging them is what put the breakpoint
        // explanation under a RESPONSE REWRITES heading.
        let model = NetworkTransaction()
        model.breakpointSkippedReason = "breakpoint fact"
        XCTAssertNil(model.rewriteSkippedReason,
                     "A breakpoint skip must not masquerade as a rewrite skip")
    }

    // MARK: - One bad storage value must not blank the list

    func testStorageEnumerationIsolatesEachKey() {
        // A lone surrogate in ONE value used to make the single JSON.stringify at
        // the end throw, and the catch returned '{}' — so one bad value hid every
        // other key in the store.
        let js = WebViewStorageService.enumerationScriptSource(for: .local)
        XCTAssertTrue(js.contains("JSON.stringify(v)"),
                      "Each value must be encoded on its own, not only in one final pass")
        XCTAssertTrue(js.contains("cannot be displayed"),
                      "An unencodable value needs a visible marker, not silence")
        XCTAssertTrue(js.contains("catch(e){if(k!==null)"),
                      "A failing key must be caught individually, not abort the whole loop")
    }
}
