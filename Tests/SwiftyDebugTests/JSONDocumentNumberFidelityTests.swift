//
//  JSONDocumentNumberFidelityTests.swift
//  SwiftyDebugTests
//
//  A point edit used to re-serialise the whole document through
//  `JSONSerialization`, so every *untouched* value round-tripped through
//  Foundation's writer and came back changed:
//
//      19.99  ->  19.989999999999998
//      0.1    ->  0.10000000000000001
//      29.7   ->  29.699999999999999
//
//  ...and every object key came back in hash order. That output is not a debug
//  view: it is handed to the HOST APP by response rewrites, breakpoint response
//  edits and "start from the real response" mock seeding. The app under test
//  received prices and coordinates that were subtly wrong.
//
//  These assert the whole serialised body, byte for byte, because "the value I
//  edited is right" was already true while the bug was live.
//

import XCTest
@testable import SwiftyDebug

final class JSONDocumentNumberFidelityTests: XCTestCase {

    /// Every number here is one Foundation's writer re-spells, plus an integer
    /// too large for a Double and a key order that is not alphabetical.
    private let source = #"{"price":19.99,"discount":0.1,"temperature":29.7,"ratio":0.30000000000000004,"quantity":3,"factor":1.0,"id":123456789012345678901,"where":{"lat":51.5074,"lon":-0.1278},"history":[19.99,0.1,29.7]}"#

    // MARK: - The headline guarantee

    func testUnmodifiedDocumentSerialisesBackToItsOwnSource() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertEqual(doc.minifiedText(), source,
                       "Parsing and re-writing a body must be a no-op, decimals and key order included")
    }

    func testEditingOneValueLeavesEveryOtherByteAlone() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        let newValue = JSONInlineValueCoder.value(from: "24.5", kind: .number)
        XCTAssertTrue(doc.setValue(newValue, at: [.key("price")]))

        let expected = source.replacingOccurrences(of: #""price":19.99"#, with: #""price":24.5"#)
        XCTAssertEqual(doc.minifiedText(), expected)

        // Belt and braces: the exact corrupted spellings that reached the app.
        let text = doc.minifiedText()
        XCTAssertFalse(text.contains("19.989999999999998"))
        XCTAssertFalse(text.contains("0.10000000000000001"))
        XCTAssertFalse(text.contains("29.699999999999999"))
    }

    func testEditingAnArrayElementLeavesItsSiblingsAlone() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "5", kind: .number),
                                   at: [.key("history"), .index(1)]))
        let expected = source.replacingOccurrences(of: #""history":[19.99,0.1,29.7]"#,
                                                   with: #""history":[19.99,5,29.7]"#)
        XCTAssertEqual(doc.minifiedText(), expected)
    }

    func testEditingANestedValueLeavesTheSiblingCoordinateAlone() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "48.8566", kind: .number),
                                   at: [.key("where"), .key("lat")]))
        let expected = source.replacingOccurrences(of: #""lat":51.5074"#, with: #""lat":48.8566"#)
        XCTAssertEqual(doc.minifiedText(), expected,
                       "lon must still read -0.1278, not -0.12780000000000001")
    }

    /// `data()` is what the rewrite engine actually delivers to the app.
    func testDeliveredBytesMatchTheEditedSource() throws {
        let doc = try XCTUnwrap(JSONDocument(data: Data(source.utf8)))
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "0", kind: .number),
                                   at: [.key("discount")]))
        let delivered = try XCTUnwrap(doc.data())
        let expected = source.replacingOccurrences(of: #""discount":0.1"#, with: #""discount":0"#)
        XCTAssertEqual(String(data: delivered, encoding: .utf8), expected)
    }

    func testTheBigIntegerKeepsAllOfItsDigits() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.setValue("x", at: [.key("price")]))
        XCTAssertTrue(doc.minifiedText().contains(#""id":123456789012345678901"#),
                      "A 21-digit id must not be shortened to 1.2345678901234568e+20")
    }

    // MARK: - Without a source text to lean on

    /// The rewrite engine builds its document from an already-parsed tree, so
    /// there is no original spelling to copy. Shortest-round-trip formatting
    /// still has to keep the value exact.
    func testATreeWithNoSourceTextStillDoesNotRoundDecimals() {
        let doc = JSONDocument(root: ["price": 19.99, "discount": 0.1, "temperature": 29.7])
        XCTAssertFalse(doc.preservesSourceFormatting)
        let text = doc.minifiedText()
        XCTAssertTrue(text.contains("19.99"), text)
        XCTAssertTrue(text.contains("0.1"), text)
        XCTAssertTrue(text.contains("29.7"), text)
        XCTAssertFalse(text.contains("19.989999999999998"), text)
        XCTAssertFalse(text.contains("0.10000000000000001"), text)
        XCTAssertFalse(text.contains("29.699999999999999"), text)
    }

    func testDocumentFromTextAdvertisesThatItPreservesFormatting() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.preservesSourceFormatting)
    }

    // MARK: - Mutations that are not point edits

    func testUndoBringsTheOriginalBytesBack() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "1", kind: .number),
                                   at: [.key("price")]))
        doc.undo()
        XCTAssertEqual(doc.minifiedText(), source)
    }

    func testRenameKeepsThePositionItPromises() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"a":1,"b":2,"c":3}"#))
        XCTAssertTrue(doc.renameKey(at: [.key("b")], to: "bb"))
        XCTAssertEqual(doc.minifiedText(), #"{"a":1,"bb":2,"c":3}"#,
                       "\"preserving its position among siblings\" has to be true, not aspirational")
    }

    func testAddedKeyLandsAtTheEndAndRemovalLeavesOrderIntact() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zeta":1,"alpha":2}"#))
        XCTAssertTrue(doc.addKey("mid", value: "x", toObjectAt: []))
        XCTAssertEqual(doc.minifiedText(), #"{"zeta":1,"alpha":2,"mid":"x"}"#)
        XCTAssertTrue(doc.remove(at: [.key("zeta")]))
        XCTAssertEqual(doc.minifiedText(), #"{"alpha":2,"mid":"x"}"#)
    }

    /// After an insert the recorded literals no longer line up with the array
    /// indices. A stale literal must never be believed.
    func testInsertingIntoAnArrayCannotResurrectAnOldNumber() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"v":[1.50,2.50]}"#))
        XCTAssertTrue(doc.duplicateElement(at: [.key("v"), .index(0)]))
        let values = try XCTUnwrap(doc.value(at: [.key("v")]) as? [Any])
        XCTAssertEqual(values.count, 3)
        let text = doc.minifiedText()
        XCTAssertEqual(JSONDocument(text: text)?.value(at: [.key("v"), .index(2)]) as? Double, 2.5,
                       "The tail element must still be 2.5, however it is spelled: \(text)")
    }

    func testReplacingAWholeObjectDoesNotStrandTheOldKeyOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"o":{"a":1,"b":2}}"#))
        XCTAssertTrue(doc.setValue(["c": 3, "a": 9] as [String: Any], at: [.key("o")]))
        // Unknown order falls back to sorted — deterministic, and complete.
        XCTAssertEqual(doc.minifiedText(), #"{"o":{"a":9,"c":3}}"#)
    }

    // MARK: - Shapes the writer has to get right on its own

    func testPrettyTextRoundTripsToTheSameBody() throws {
        let doc = try XCTUnwrap(JSONDocument(text: source))
        let pretty = doc.prettyText()
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertEqual(JSONDocument(text: pretty)?.minifiedText(), source,
                       "Formatting must not be a lossy operation")
    }

    func testSortedKeysStillHonoured() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"b":1,"a":2}"#))
        let sorted = doc.prettyText(sortKeys: true)
        let a = try XCTUnwrap(sorted.range(of: "\"a\""))
        let b = try XCTUnwrap(sorted.range(of: "\"b\""))
        XCTAssertTrue(a.lowerBound < b.lowerBound, sorted)
    }

    func testStringEscapingSurvivesARoundTrip() throws {
        let text = #"{"nl":"a\nb","quote":"say \"hi\"","slash":"https://a.com/b","tab":"a\tb","uni":"café"}"#
        let doc = try XCTUnwrap(JSONDocument(text: text))
        XCTAssertEqual(doc.minifiedText(), text)
        XCTAssertFalse(doc.minifiedText().contains(#"\/"#), "Slashes stay readable")
    }

    /// A raw control character has to come back out as an escape, or the body
    /// stops being parseable JSON the moment it is delivered.
    func testControlCharactersAreEscaped() throws {
        let doc = JSONDocument(root: ["c": "x\u{01}y", "back": "a\u{08}b"])
        let text = doc.minifiedText()
        let escape = "\\u0001"   // backslash-u-0001, not the raw byte
        XCTAssertTrue(text.contains("x" + escape + "y"), text)
        XCTAssertTrue(text.contains(#"a\bb"#), text)
        let reparsed = try XCTUnwrap(JSONDocument(text: text))
        XCTAssertEqual(reparsed.value(at: [.key("c")]) as? String, "x\u{01}y")
    }

    func testFragmentsAndEmptyContainers() {
        XCTAssertEqual(JSONDocument(root: 7).minifiedText(), "7")
        XCTAssertEqual(JSONDocument(root: "hi").minifiedText(), #""hi""#)
        XCTAssertEqual(JSONDocument(root: NSNull()).minifiedText(), "null")
        XCTAssertEqual(JSONDocument(root: true).minifiedText(), "true")
        XCTAssertEqual(JSONDocument(text: "{}")?.minifiedText(), "{}")
        XCTAssertEqual(JSONDocument(text: "[]")?.minifiedText(), "[]")
        XCTAssertEqual(JSONDocument(text: #"{"a":[],"b":{}}"#)?.minifiedText(), #"{"a":[],"b":{}}"#)
    }

    func testBooleansNeverDegradeIntoNumbers() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"on":true,"off":false,"one":1}"#))
        XCTAssertEqual(doc.minifiedText(), #"{"on":true,"off":false,"one":1}"#)
    }

    func testTopLevelArrayOfObjectsKeepsOrderAndSpelling() throws {
        let text = #"[{"id":1,"cost":9.95},{"id":2,"cost":0.1}]"#
        let doc = try XCTUnwrap(JSONDocument(text: text))
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "3", kind: .number),
                                   at: [.index(1), .key("id")]))
        XCTAssertEqual(doc.minifiedText(), #"[{"id":1,"cost":9.95},{"id":3,"cost":0.1}]"#)
    }

    func testKeysThatNeedEscapingStillMatchTheParsedTree() throws {
        let text = #"{"a\"b":1.10,"c\nd":2.20,"e":3.30}"#
        let doc = try XCTUnwrap(JSONDocument(text: text))
        XCTAssertEqual(doc.minifiedText(), text,
                       "An escaped key must decode to the same key JSONSerialization produced")
    }

    func testWhitespaceInTheSourceDoesNotConfuseTheIndex() throws {
        let spaced = "{\n  \"price\" : 19.99,\n  \"list\" : [ 0.1 , 29.7 ]\n}"
        let doc = try XCTUnwrap(JSONDocument(text: spaced))
        XCTAssertEqual(doc.minifiedText(), #"{"price":19.99,"list":[0.1,29.7]}"#)
    }
}
