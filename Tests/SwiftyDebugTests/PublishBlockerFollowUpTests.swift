//
//  PublishBlockerFollowUpTests.swift
//  SwiftyDebugTests
//
//  The leftovers from the open-source readiness review — the items that fell
//  between agents because each needed a file its owner did not hold. Every one
//  of these was reproduced by execution before being fixed.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class PublishBlockerFollowUpTests: XCTestCase {

    // MARK: - The host app must never be soft-locked

    func testTouchesArePassedThroughWhenNothingIsActuallyPresented() {
        // `displayedList` was set BEFORE presenting, so a presentation that never
        // happened (no window) left the flag stuck true — and the debug window
        // then claimed every touch on screen. The host app was dead to input
        // except for a 25x25 bubble, with no escape but a relaunch.
        let vc = SwiftyDebugViewController()
        vc.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        vc.view.layoutIfNeeded()

        let saved = DebugWindowPresenter.shared.displayedList
        defer { DebugWindowPresenter.shared.displayedList = saved }

        DebugWindowPresenter.shared.displayedList = true
        XCTAssertNil(vc.presentedViewController, "precondition: nothing presented")

        XCTAssertFalse(vc.shouldReceive(point: CGPoint(x: 200, y: 700)),
                       "A stuck flag must not let the SDK swallow the host app's touches")
    }

    func testBubbleStillReceivesItsOwnTouchesWhileTheFlagIsStuck() {
        // The escape hatch has to keep working: with the flag stuck true and
        // nothing presented, a touch ON the bubble must still be claimed, or the
        // user has no way back into the debugger.
        let vc = SwiftyDebugViewController()
        vc.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        vc.view.layoutIfNeeded()

        let saved = DebugWindowPresenter.shared.displayedList
        defer { DebugWindowPresenter.shared.displayedList = saved }
        DebugWindowPresenter.shared.displayedList = true

        let bubble = vc.view.subviews.first { !($0 is UILabel) && $0.frame.width < 120 && $0.frame.width > 0 }
        let inside = try? XCTUnwrap(bubble).frame
        if let inside {
            XCTAssertTrue(vc.shouldReceive(point: CGPoint(x: inside.midX, y: inside.midY)),
                          "The bubble must keep receiving its own touches — it is the only way back")
        } else {
            XCTFail("No bubble view found; the escape hatch cannot be verified")
        }
        XCTAssertFalse(vc.shouldReceive(point: CGPoint(x: 200, y: 700)),
                       "Everything outside the bubble must pass through to the host app")
    }

    // MARK: - A rewrite must not reshape the server's body

    func testRewritingOneValueKeepsTheServersKeyOrder() throws {
        // Without a source text the writer falls back to sorted keys, so every
        // rewritten response came back alphabetised — a change no server made.
        let body = Data(#"{"zebra":19.99,"alpha":0.1,"name":"widget","middle":29.7}"#.utf8)
        let rewrite = ResponseRewrite(pattern: "name", action: .setValue("gadget"))

        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: body)
        XCTAssertTrue(report.didChange)

        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        let keys = ["zebra", "alpha", "name", "middle"].map { text.range(of: "\"\($0)\"")?.lowerBound }
        let offsets = keys.compactMap { $0 }
        XCTAssertEqual(offsets.count, 4, "every key must survive")
        XCTAssertEqual(offsets, offsets.sorted(), "keys must stay in the server's original order")
    }

    func testRewritingOneValueLeavesEveryOtherNumberByteIdentical() throws {
        let body = Data(#"{"price":19.99,"ratio":0.1,"size":29.7,"name":"widget"}"#.utf8)
        let rewrite = ResponseRewrite(pattern: "name", action: .setValue("gadget"))

        let out = ResponseRewriteEngine.apply([rewrite], to: body).data
        let text = try XCTUnwrap(String(data: out, encoding: .utf8))

        for spelling in ["19.99", "0.1", "29.7"] {
            XCTAssertTrue(text.contains(spelling),
                          "\(spelling) was re-serialised — the app receives a different number "
                          + "than the server sent. Got: \(text)")
        }
    }

    // MARK: - Non-finite input must be refused, not coerced to zero

    func testSettingANonFiniteNumberIsRefusedRatherThanWritingZero() {
        // Double("inf") SUCCEEDS, so the old guard let it through and the
        // coercion wrote 0 into the app's live response body, reporting
        // changed = 1 with no error at all.
        let body = Data(#"{"price":19.99}"#.utf8)

        for spelling in ["inf", "-inf", "nan", "Infinity", "-Infinity"] {
            let rewrite = ResponseRewrite(pattern: "price", action: .setValue(spelling))
            let (out, _) = ResponseRewriteEngine.apply([rewrite], to: body)
            let text = String(data: out, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("\"price\":0"),
                           "\(spelling) silently became 0 in the delivered body")
        }
    }

    // MARK: - Exact integers past 2^53

    func testEditingAnIntegerAboveTwoToThe53IsNotDiscarded() throws {
        // The writer reuses the author's original spelling when it still
        // "describes" the value — but that comparison was done in Double, which
        // cannot distinguish 9007199254740993 from 9007199254740992. The edit was
        // dropped from the bytes while the in-memory tree claimed success.
        let source = #"{"id":9007199254740993}"#
        let doc = try XCTUnwrap(JSONDocument(text: source))

        XCTAssertTrue(doc.setValue(NSNumber(value: 9007199254740992 as Int), at: [.key("id")]))

        let out = doc.prettyText()
        XCTAssertTrue(out.contains("9007199254740992"),
                      "The edit was silently discarded in the output. Got: \(out)")
        XCTAssertFalse(out.contains("9007199254740993"),
                       "The original spelling was re-emitted over the edit")
    }

    func testAnUneditedLargeIntegerKeepsItsExactSpelling() throws {
        let source = #"{"id":9007199254740993,"other":1}"#
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.setValue("x", at: [.key("other")]),
                      "precondition: the unrelated edit must land")

        XCTAssertTrue(doc.prettyText().contains("9007199254740993"),
                      "An untouched 64-bit id must survive byte-for-byte")
    }
}
