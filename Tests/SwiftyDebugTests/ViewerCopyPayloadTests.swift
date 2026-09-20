//
//  ViewerCopyPayloadTests.swift
//  SwiftyDebugTests
//
//  The full-screen JSON viewer is a third-party web component. Its copy button
//  hands the native bridge the value's JSON *literal*, so copying a string value
//  produced `"eyJhbGciOi…"` — quotes included — and pasting that into curl, a
//  browser or Algolia was wrong every time.
//

import XCTest
@testable import SwiftyDebug

final class ViewerCopyPayloadTests: XCTestCase {

    private func copied(_ payload: String) -> String {
        JSONExporter.clipboardString(forViewerPayload: payload)
    }

    // MARK: - The defect

    func testACopiedStringValueLosesItsJSONQuotes() {
        XCTAssertEqual(copied("\"eyJhbGciOiJIUzI1NiJ9.abc\""), "eyJhbGciOiJIUzI1NiJ9.abc")
        XCTAssertEqual(copied("\"https://api.salla.dev/v1/items?page=2\""),
                       "https://api.salla.dev/v1/items?page=2")
        XCTAssertEqual(copied("\"\""), "", "an empty string value copies as nothing, not as two quotes")
    }

    /// The component JSON-escapes what it wraps, so the unwrap has to DECODE,
    /// not just strip the outer characters.
    func testAnEscapedStringValueIsDecodedNotJustUnwrapped() {
        XCTAssertEqual(copied("\"a\\\"b\""), "a\"b")
        XCTAssertEqual(copied("\"line1\\nline2\""), "line1\nline2")
        XCTAssertEqual(copied("\"c:\\\\path\""), "c:\\path")
        XCTAssertEqual(copied("\"\\u0645\\u0631\\u062d\\u0628\\u0627\""), "مرحبا")
    }

    // MARK: - Everything else keeps its JSON form

    func testContainersStayValidJSON() {
        let object = copied("{\"a\":1}")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(object.utf8)))
        XCTAssertTrue(object.contains("\"a\""), "an object's KEYS keep their quotes")

        let array = copied("[1,2,3]")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(array.utf8)))
    }

    func testNonStringScalarsAreUnchanged() {
        XCTAssertEqual(copied("42"), "42")
        XCTAssertEqual(copied("true"), "true")
        XCTAssertEqual(copied("null"), "null")
        XCTAssertEqual(copied("1250.00"), "1250.00", "a number's spelling is not re-printed")
    }

    /// A string CONTAINING JSON is still a string: unwrapping must give back the
    /// inner text, not re-print it as a document.
    func testAStringWhoseContentsLookLikeJSONIsStillUnwrapped() {
        XCTAssertEqual(copied("\"{\\\"a\\\":1}\""), "{\"a\":1}")
    }

    /// Nothing that merely starts and ends with a quote qualifies — two adjacent
    /// strings are not one string.
    func testTextThatOnlyLooksQuotedIsNotUnwrapped() {
        let payload = "\"a\", \"b\""
        XCTAssertEqual(copied(payload), payload)
    }

    // MARK: - The affix guarantee still holds

    func testInvisibleAffixesAreStillStripped() {
        XCTAssertEqual(copied("\u{FEFF}\"token\""), "token")
        XCTAssertFalse(ClipboardText.hasStrippableAffix(copied("\u{200E}{\"a\":1}")))
    }
}
