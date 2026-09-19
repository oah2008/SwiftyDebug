//
//  ClipboardAffixTests.swift
//  SwiftyDebugTests
//
//  A copied request body arrived with an invisible leading character and would
//  not paste into Algolia. The trim that was supposed to prevent that used
//  `.whitespacesAndNewlines`, which contains none of the characters at fault.
//

import XCTest
@testable import SwiftyDebug

final class ClipboardAffixTests: XCTestCase {

    // MARK: - The character set that was actually wrong

    /// The premise of the bug, asserted directly so nobody re-introduces the old
    /// trim believing it covers these.
    func testWhitespacesAndNewlinesDoesNotContainTheCharactersAtFault() {
        // Measured, not assumed: Foundation counts U+200B as whitespace but none
        // of these, which is exactly why the old trim looked right and did
        // nothing.
        for scalar: Unicode.Scalar in ["\u{FEFF}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{2060}", "\u{00AD}"] {
            XCTAssertFalse(CharacterSet.whitespacesAndNewlines.contains(scalar),
                           "U+\(String(scalar.value, radix: 16, uppercase: true)) is not whitespace to Foundation")
        }
        for scalar: Unicode.Scalar in ["\u{FEFF}", "\u{200B}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{2060}", "\u{00AD}"] {
            XCTAssertTrue(ClipboardText.strippableAffixes.contains(scalar),
                          "U+\(String(scalar.value, radix: 16, uppercase: true)) must be strippable")
        }
    }

    // MARK: - Normalisation

    func testLeadingInvisiblesAreRemoved() {
        for prefix in ["\u{FEFF}", "\u{200B}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{2060}", "\u{00AD}",
                       " \u{FEFF}", "\u{FEFF}\u{FEFF}", "\n\u{200E} "] {
            let normalized = ClipboardText.normalized(prefix + "query=shoes")
            XCTAssertEqual(normalized, "query=shoes", "failed for prefix \(prefix.debugDescription)")
        }
    }

    func testTrailingInvisiblesAreRemoved() {
        XCTAssertEqual(ClipboardText.normalized("query=shoes\u{FEFF}\n "), "query=shoes")
    }

    /// The whole point of trimming only the ends: a payload's interior is data.
    func testInteriorInvisiblesAndNewlinesAreUntouched() {
        let body = "{\"a\":\"x\u{200D}y\",\"b\":\"line1\nline2\"}"
        XCTAssertEqual(ClipboardText.normalized(body), body)
    }

    func testNormalisationIsIdempotentAndSafeOnEdgeInputs() {
        XCTAssertEqual(ClipboardText.normalized(""), "")
        XCTAssertEqual(ClipboardText.normalized("\u{FEFF}\u{200B} \n"), "")
        let once = ClipboardText.normalized("\u{FEFF} body ")
        XCTAssertEqual(ClipboardText.normalized(once), once)
    }

    /// An emoji built from a ZWJ sequence must not be cut apart by the scalar
    /// loop — only a leading or trailing invisible is removed.
    func testAGraphemeContainingAZeroWidthJoinerSurvives() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(ClipboardText.normalized(family), family)
        XCTAssertEqual(ClipboardText.normalized(" " + family + " "), family)
    }

    func testHasStrippableAffixReportsTheDefectItself() {
        XCTAssertTrue(ClipboardText.hasStrippableAffix("\u{FEFF}{\"a\":1}"))
        XCTAssertFalse(ClipboardText.hasStrippableAffix("{\"a\":1}"))
    }

    // MARK: - The real clipboard path

    func testCopyingAJSONBodyNeverStartsOrEndsWithAnInvisible() {
        let algolia = "{\"requests\":[{\"indexName\":\"products\",\"params\":\"query=shoes&page=0\"}]}"
        for prefix in ["", " ", "\n", "\u{FEFF}", "\u{200E}", " \u{FEFF}"] {
            let copied = JSONExporter.clipboardString(from: prefix + algolia)
            let first = try? XCTUnwrap(copied.unicodeScalars.first)
            XCTAssertEqual(first, "{", "leading scalar wrong for prefix \(prefix.debugDescription): \(copied.prefix(8).debugDescription)")
            XCTAssertFalse(ClipboardText.hasStrippableAffix(copied))
        }
    }

    /// Non-JSON is preserved verbatim apart from its affixes — a form body, a
    /// GraphQL document or an XML payload must not be reshaped.
    func testCopyingANonJSONBodyPreservesItExactlyMinusAffixes() {
        let form = "query=shoes&page=0&facets=%5B%22brand%22%5D"
        XCTAssertEqual(JSONExporter.clipboardString(from: "\u{FEFF}" + form), form)
        XCTAssertEqual(JSONExporter.clipboardString(from: form), form)
    }

    func testCopiedJSONRemainsParseable() {
        let source = "\u{200E}{\"b\":2,\"a\":1}"
        let copied = JSONExporter.clipboardString(from: source)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(copied.utf8)))
    }

    /// Key order is the server's, not the alphabet's — the existing guarantee,
    /// re-asserted here so the affix fix cannot quietly regress it.
    func testCopyStillPreservesSourceKeyOrder() {
        let copied = JSONExporter.clipboardString(from: "\u{FEFF}{\"zulu\":1,\"alpha\":2,\"mike\":3}")
        guard let z = copied.range(of: "zulu"), let a = copied.range(of: "alpha"), let m = copied.range(of: "mike") else {
            return XCTFail("keys missing from \(copied)")
        }
        XCTAssertTrue(z.lowerBound < a.lowerBound && a.lowerBound < m.lowerBound, copied)
    }
}
