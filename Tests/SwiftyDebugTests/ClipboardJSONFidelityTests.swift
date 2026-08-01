//
//  ClipboardJSONFidelityTests.swift
//  SwiftyDebugTests
//
//  The copy button is what the maintainer actually reported: the clipboard
//  disagreed with the preview about the same body. `JSONExporter` — which every
//  section's COPY calls — was still round-tripping through `JSONSerialization`,
//  so keys came back in hash order and numbers were respelled.
//
//  The same function also read with `.fragmentsAllowed` and wrote without it, so
//  copying a body of `"OK"` raised an ObjC exception `try?` cannot catch and took
//  the host app down.
//

import XCTest
@testable import SwiftyDebug

final class ClipboardJSONFidelityTests: XCTestCase {

    /// Deliberately not alphabetical, so sorted output is unmistakable.
    private let body = #"{"status":"ok","id":7,"total":19.99,"currency":"SAR","createdAt":"2026-01-01","active":true}"#

    // MARK: - Order

    func testCopyKeepsTheServersKeyOrder() throws {
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        let offsets = ["status", "id", "total", "currency", "createdAt", "active"]
            .compactMap { copied.range(of: "\"\($0)\"")?.lowerBound }

        XCTAssertEqual(offsets.count, 6, "every key must survive the copy")
        XCTAssertEqual(offsets, offsets.sorted(),
                       "The clipboard re-ordered the server's keys:\n\(copied)")
    }

    func testCopyKeepsTheServersNumberSpelling() throws {
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        XCTAssertTrue(copied.contains("19.99"),
                      "19.99 was respelled on the clipboard: \(copied)")
    }

    func testPreviewAndCopyAgree() throws {
        // The reported symptom, stated directly.
        let data = Data(body.utf8)
        let preview = try XCTUnwrap(data.dataToPrettyPrintString())
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        XCTAssertEqual(preview, copied,
                       "The preview and the clipboard must show the same bytes")
    }

    // MARK: - Valid, complete, untrimmed

    func testCopiedTextIsValidJSON() throws {
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(copied.utf8)),
                         "The clipboard must hold parseable JSON")
    }

    func testCopiedTextHasNoLeadingOrTrailingWhitespace() throws {
        let copied = try XCTUnwrap(JSONExporter.clipboardString(from: body))
        XCTAssertEqual(copied, copied.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testEveryKeyOfALargeBodySurvives() throws {
        // "no redacted at all" — the clipboard must carry the whole body.
        let pairs = (0..<200).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        let big = "{\(pairs)}"
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: big))
        for i in [0, 99, 199] {
            XCTAssertTrue(copied.contains("\"k\(i)\""), "k\(i) is missing from the copy")
        }
    }

    // MARK: - The fragment crash

    func testCopyingATopLevelFragmentDoesNotCrash() {
        // Read with .fragmentsAllowed, written without it: NSInvalidArgumentException,
        // uncatchable by `try?`, taking the host app with it.
        for fragment in ["\"OK\"", "42", "true", "null", "19.99"] {
            _ = JSONExporter.prettyJSONString(from: fragment)
            _ = JSONExporter.clipboardString(from: fragment)
        }
        XCTAssertTrue(true, "reaching here means no ObjC exception escaped")
    }

    func testANonJSONBodyIsStillCopiedVerbatim() {
        let html = "<html><body>hi</body></html>"
        XCTAssertEqual(JSONExporter.clipboardString(from: html), html,
                       "Non-JSON must be preserved, not turned into null or dropped")
    }
}
