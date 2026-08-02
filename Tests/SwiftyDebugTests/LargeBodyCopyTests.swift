//
//  LargeBodyCopyTests.swift
//  SwiftyDebugTests
//
//  Copy is the feature the maintainer cares about most. A large body used to copy
//  MINIFIED — valid JSON, but silently different from the small body beside it,
//  because formatting it would have stalled the main thread. Now it formats off
//  the main thread behind a blocking overlay that says what is happening.
//

import XCTest
@testable import SwiftyDebug

final class LargeBodyCopyTests: XCTestCase {

    /// Deliberately non-alphabetical and multi-megabyte.
    private func largeBody(rows: Int) -> String {
        let items = (0..<rows).map {
            #"{"zebra":\#($0),"alpha":"row \#($0)","total":19.99,"middle":{"inner":[1,2,3]}}"#
        }
        return "[\(items.joined(separator: ","))]"
    }

    // MARK: - A large body copies FORMATTED, in the server's order

    func testALargeBodyCopiesPrettyPrintedNotMinified() throws {
        let body = largeBody(rows: 8_000)
        XCTAssertGreaterThan(body.utf8.count, Data.maxOrderPreservingBytes / 4,
                             "precondition: this is a big body")

        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        XCTAssertTrue(copied.contains("\n"),
                      "A large body copied minified — the same body small would have been formatted")
    }

    func testALargeBodyKeepsTheServersKeyOrder() throws {
        let body = largeBody(rows: 8_000)
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))

        let z = try XCTUnwrap(copied.range(of: "\"zebra\""))
        let a = try XCTUnwrap(copied.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound,
                          "Order must not depend on how big the body happens to be")
    }

    func testALargeBodyStillParses() throws {
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: largeBody(rows: 4_000)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(copied.utf8)))
    }

    // MARK: - The overlay decision

    func testASmallBodyCopiesWithoutAnyOverlay() {
        let small = #"{"a":1,"b":2}"#
        XCTAssertFalse(ClipboardFormatter.needsProgressUI(byteCount: small.utf8.count),
                       "A tap on a small body must stay instant and silent")
    }

    func testALargeBodyAsksForTheOverlay() {
        XCTAssertTrue(ClipboardFormatter.needsProgressUI(byteCount: 2 * 1024 * 1024),
                      "Work the user can perceive needs an explanation")
    }

    func testTheThresholdIsTheBoundary() {
        XCTAssertFalse(ClipboardFormatter.needsProgressUI(
            byteCount: ClipboardFormatter.asyncThresholdBytes))
        XCTAssertTrue(ClipboardFormatter.needsProgressUI(
            byteCount: ClipboardFormatter.asyncThresholdBytes + 1))
    }

    func testTheOverlayNamesTheSize() {
        let described = ClipboardFormatter.sizeDescription(byteCount: 4_200_000)
        XCTAssertFalse(described.isEmpty)
        XCTAssertTrue(described.contains("MB"),
                      "The message should say how much, not just that it is busy. Got: \(described)")
    }
}
