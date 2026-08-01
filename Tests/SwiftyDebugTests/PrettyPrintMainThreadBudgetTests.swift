//
//  PrettyPrintMainThreadBudgetTests.swift
//  SwiftyDebugTests
//
//  `dataToPrettyPrintString()` runs while a detail screen is being built, and
//  `JSONExporter` runs it again inside a COPY tap. Both are the main thread.
//
//  The order-preserving writer costs ~1 µs per JSON node and almost nothing per
//  byte, so a byte-only ceiling is the wrong ceiling: two 2 MB bodies measured
//  13x apart (a 2 MB body of 13-byte objects took 1084 ms; a 1.6 MB body of 50k
//  long-stringed keys took 84 ms). At the old 2 MB ceiling a perfectly ordinary
//  response froze the app for over a second, and COPY on a 10 MB body — which
//  the capture layer stores, `maxCapturedResponseBytes` is 10 MB — took 1.8 s.
//
//  These are wall-clock assertions with a lot of headroom. They are here to
//  catch a ceiling being removed or a per-node cost being added, not to police
//  milliseconds on a busy CI box.
//

import XCTest
@testable import SwiftyDebug

final class PrettyPrintMainThreadBudgetTests: XCTestCase {

    private func elapsedMS(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start) * 1000
    }

    /// The shape that cost 1084 ms before the node ceiling: a 2 MB body that is
    /// almost entirely structure.
    func testDenseTwoMegabyteBodyStaysWellUnderASecond() {
        let body = "[" + Array(repeating: #"{"a":1,"b":2}"#, count: 150_000).joined(separator: ",") + "]"
        let data = Data(body.utf8)
        XCTAssertGreaterThan(data.count, 2_000_000)

        var out: String?
        let ms = elapsedMS { out = data.dataToPrettyPrintString() }

        XCTAssertNotNil(out)
        XCTAssertTrue(Data((out ?? "").utf8).isJSONPayload)
        XCTAssertLessThan(ms, 600, "a 2 MB body must not hold the main thread; measured \(Int(ms)) ms")
    }

    /// COPY had no ceiling at all: it re-printed whatever it was handed. On a
    /// 10 MB body that was 1.8 s inside a button tap.
    /// CONTRACT CHANGED at the maintainer's request: copy is no longer bounded by
    /// a main-thread budget, because it no longer RUNS on the main thread —
    /// `ClipboardFormatter` moves it to a background queue behind a blocking
    /// overlay that names the size. What must still hold is that the work is
    /// finite and the result is complete; the main-thread budget now belongs to
    /// the PREVIEW path, which keeps its ceiling and is tested above.
    func testCopyOfATenMegabyteBodyCompletesAndIsAskedToShowProgress() {
        let row = #"{"id":%d,"name":"item %d","price":19.99,"active":true}"#
        var rows: [String] = []
        rows.reserveCapacity(200_000)
        for i in 0..<200_000 { rows.append(String(format: row, i, i)) }
        let body = "[" + rows.joined(separator: ",") + "]"
        XCTAssertGreaterThan(body.utf8.count, 10_000_000)

        var out: String?
        let ms = elapsedMS { out = JSONExporter.prettyJSONString(from: body) }

        XCTAssertNotNil(out, "a 10 MB JSON body is still JSON and must still copy")
        XCTAssertTrue(ClipboardFormatter.needsProgressUI(byteCount: body.utf8.count),
                      "A body this size must be copied behind the overlay, not inline")
        XCTAssertLessThan(ms, 30_000, "formatting took \(Int(ms)) ms — finite, but implausibly slow")
    }

    /// The counter that decides it is a byte scan, not a parse — it has to stay
    /// negligible next to the work it is deciding whether to do.
    func testTheCeilingCheckItselfIsFree() {
        let data = Data(("[" + Array(repeating: #"{"a":1,"b":2}"#, count: 150_000).joined(separator: ",") + "]").utf8)
        let ms = elapsedMS { for _ in 0..<20 { _ = data.canPrettyPrintInSourceOrder } }
        XCTAssertLessThan(ms, 200, "20 ceiling checks over 2 MB took \(Int(ms)) ms")
    }

    /// An ordinary payload must NOT be pushed onto the unordered path by the
    /// ceiling — preserving the server's key order is the point of all this.
    func testOrdinaryPayloadsKeepTheOrderPreservingPath() {
        let row = #"{"zulu":%d,"alpha":"a","mike":true}"#
        for rows in [10, 500, 5_000] {
            let body = "[" + (0..<rows).map { String(format: row, $0) }.joined(separator: ",") + "]"
            XCTAssertTrue(Data(body.utf8).canPrettyPrintInSourceOrder,
                          "\(rows) rows should still render in the server's order")
        }
        let keys = "{" + (0..<10_000).map { "\"key_\($0)\":\"value \($0)\"" }.joined(separator: ",") + "}"
        XCTAssertTrue(Data(keys.utf8).canPrettyPrintInSourceOrder, "a 10k-key object is cheap to order")
    }
}
