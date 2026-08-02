//
//  UncatchableExceptionGuardTests.swift
//  SwiftyDebugTests
//
//  Apple's JSON PARSER accepts a literal that overflows a Double (-1e999) and
//  hands back -inf. Apple's JSON WRITER then raises NSInvalidArgumentException —
//  an ObjC exception `try?` cannot catch, so it terminates the host app.
//
//  Two sites were reachable: the rewrite preview (on the networking thread) and
//  Copy-as-cURL. A third class of bug shares the same root: `prettyText()`
//  returns "" rather than nil for such a document, so `?? fallback` never fired
//  and an EMPTY body was delivered instead.
//

import XCTest
@testable import SwiftyDebug

final class UncatchableExceptionGuardTests: XCTestCase {

    /// Parses fine, cannot be written.
    private let overflowing = #"{"items":[{"price":-1e999}],"name":"widget"}"#

    func testTheOverflowingLiteralReallyIsTheHazard() throws {
        // Pin the premise, so this suite still means something if Foundation changes.
        let parsed = try JSONSerialization.jsonObject(with: Data(overflowing.utf8))
        XCTAssertFalse(JSONSerialization.isValidJSONObject(parsed),
                       "If this becomes writable, the guards below are no longer load-bearing")
    }

    // MARK: - The rewrite preview must not take the app down

    func testRewritePreviewSurvivesAValueJSONCannotWrite() {
        let rewrite = ResponseRewrite(pattern: "items", action: .setValue("x"))
        let rows = ResponseRewriteEngine.preview(rewrite, on: Data(overflowing.utf8), limit: 10)
        XCTAssertNotNil(rows, "reaching here at all means no ObjC exception escaped")
    }

    func testRewriteApplySurvivesTheSameBody() {
        let rewrite = ResponseRewrite(pattern: "name", action: .setValue("gadget"))
        let (data, _) = ResponseRewriteEngine.apply([rewrite], to: Data(overflowing.utf8))
        XCTAssertFalse(data.isEmpty, "The original bytes must survive, not vanish")
    }

    // MARK: - Copy as cURL must not take the app down

    func testCopyAsCurlSurvivesAnUnwritableBody() {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/1/indexes/*/queries")
        model.method = "POST"
        model.requestData = Data(#"{"requests":[{"params":"q=a&p=0","bad":-1e999}]}"#.utf8)

        let curl = model.cURLDescription()
        XCTAssertFalse(curl.isEmpty, "cURL export must still produce something")
    }

    // MARK: - An unrepresentable body must never render as empty

    func testPrettyTextReturnsEmptyNotNilForSuchADocument() throws {
        // The trap itself: `?? fallback` cannot fire on an empty string.
        let doc = try XCTUnwrap(JSONDocument(text: overflowing))
        XCTAssertTrue(doc.prettyText().isEmpty,
                      "If this ever returns nil instead, the `?? fallback` sites can be simplified")
    }

    // MARK: - Copy still holds its guarantee on this input

    func testCopyOfAnUnwritableBodyIsStillValidOrVerbatim() {
        let copied = JSONExporter.clipboardString(from: overflowing)
        XCTAssertFalse(copied.isEmpty, "Copy must never yield nothing for a body that has content")
        if let data = copied.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return  // valid JSON out
        }
        XCTAssertEqual(copied, overflowing.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Not valid JSON, so it must be the original verbatim")
    }
}
