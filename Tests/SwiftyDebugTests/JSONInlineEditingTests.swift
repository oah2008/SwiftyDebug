//
//  JSONInlineEditingTests.swift
//  SwiftyDebugTests
//
//  The JSON tree editor now edits values in place: the row grows a multi-line
//  field, and long values are pushed to their own page instead. Three things
//  have to be right for that to be safe, and all three are pure functions —
//  pinned here so they can't drift:
//
//   1. The height math clamps, so a growing row can never outgrow the gap above
//      the keyboard (it scrolls internally instead).
//   2. The "too long to edit in a row" rule, which decides inline vs full page.
//   3. Text -> value coercion and write-back BY PATH. Cells are reused and the
//      tree re-flattens on every mutation, so an edit committed by row index
//      would land on whatever node happens to sit there now.
//

import XCTest
@testable import SwiftyDebug

final class JSONInlineEditingTests: XCTestCase {

    // MARK: - Height math

    func testHeightNeverCollapsesBelowOneLine() {
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: 0),
                       JSONInlineEditMetrics.minHeight,
                       "An empty value must still show a tappable field")
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: 5),
                       JSONInlineEditMetrics.minHeight)
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: -20),
                       JSONInlineEditMetrics.minHeight)
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: .nan),
                       JSONInlineEditMetrics.minHeight)
    }

    func testHeightGrowsWithContentBetweenTheBounds() {
        let mid = (JSONInlineEditMetrics.minHeight + JSONInlineEditMetrics.maxHeight) / 2
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: mid), mid)

        let small = JSONInlineEditMetrics.clampedHeight(forContentHeight: mid - 20)
        let large = JSONInlineEditMetrics.clampedHeight(forContentHeight: mid + 20)
        XCTAssertLessThan(small, large, "More text must mean a taller field")
    }

    func testHeightRoundsUpSoDescendersAreNotClipped() {
        let mid = (JSONInlineEditMetrics.minHeight + JSONInlineEditMetrics.maxHeight) / 2
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: mid + 0.2),
                       (mid + 0.2).rounded(.up))
    }

    func testHeightStopsAtTheMaximumAndScrollsInstead() {
        XCTAssertEqual(JSONInlineEditMetrics.clampedHeight(forContentHeight: 10_000),
                       JSONInlineEditMetrics.maxHeight,
                       "The row must never grow past the keyboard")
        XCTAssertTrue(JSONInlineEditMetrics.scrollsInternally(contentHeight: 10_000))
        XCTAssertFalse(JSONInlineEditMetrics.scrollsInternally(
            contentHeight: JSONInlineEditMetrics.maxHeight))
        XCTAssertFalse(JSONInlineEditMetrics.scrollsInternally(contentHeight: 10))
        XCTAssertLessThan(JSONInlineEditMetrics.minHeight, JSONInlineEditMetrics.maxHeight)
    }

    func testTheFieldOpensBigEnoughToReadWhatYouAreEditing() {
        // A single-line box is technically typeable and practically useless — you
        // cannot see the value you are changing. These floors are the point of
        // inline editing, so a future tweak must not quietly undo them.
        XCTAssertGreaterThanOrEqual(JSONInlineEditMetrics.minHeight, 80,
                                    "The inline field must open around three lines tall")
        XCTAssertGreaterThanOrEqual(JSONInlineEditMetrics.maxHeight, 240,
                                    "It must be able to grow well past its opening size")
        // And it must still leave room for the keyboard on the smallest phone.
        XCTAssertLessThanOrEqual(JSONInlineEditMetrics.maxHeight, 300)
    }

    // MARK: - Line counting

    func testLineCount() {
        XCTAssertEqual(JSONInlineEditMetrics.lineCount(of: ""), 1)
        XCTAssertEqual(JSONInlineEditMetrics.lineCount(of: "one line"), 1)
        XCTAssertEqual(JSONInlineEditMetrics.lineCount(of: "a\nb"), 2)
        XCTAssertEqual(JSONInlineEditMetrics.lineCount(of: "a\nb\nc\n"), 4,
                       "A trailing newline opens a new, empty line")
    }

    // MARK: - Inline vs. full page

    func testShortScalarsEditInline() {
        XCTAssertFalse(JSONInlineEditMetrics.prefersFullPage(text: "hello", kind: .string))
        XCTAssertFalse(JSONInlineEditMetrics.prefersFullPage(text: "42", kind: .number))
        XCTAssertFalse(JSONInlineEditMetrics.prefersFullPage(text: "", kind: .string))
        XCTAssertTrue(JSONInlineEditMetrics.isInlineEditable(.string))
        XCTAssertTrue(JSONInlineEditMetrics.isInlineEditable(.number))
    }

    func testLongValuesPreferTheFullPage() {
        let long = String(repeating: "x", count: JSONInlineEditMetrics.fullPageCharacterThreshold + 1)
        XCTAssertTrue(JSONInlineEditMetrics.prefersFullPage(text: long, kind: .string),
                      "A token/base64-sized value is miserable in a row")

        let atThreshold = String(repeating: "x", count: JSONInlineEditMetrics.fullPageCharacterThreshold)
        XCTAssertFalse(JSONInlineEditMetrics.prefersFullPage(text: atThreshold, kind: .string),
                       "The threshold itself still fits inline")
    }

    func testMultiLineValuesPreferTheFullPage() {
        let lines = Array(repeating: "line", count: JSONInlineEditMetrics.fullPageLineThreshold)
        XCTAssertTrue(JSONInlineEditMetrics.prefersFullPage(text: lines.joined(separator: "\n"),
                                                            kind: .string))
        XCTAssertFalse(JSONInlineEditMetrics.prefersFullPage(text: "a\nb", kind: .string))
    }

    func testNonTypedKindsAlwaysUseTheFullPage() {
        // Bool needs a switch, null needs no field, containers are edited in the
        // tree — none of them get an inline text field.
        for kind in [JSONValueKind.bool, .null, .object, .array] {
            XCTAssertTrue(JSONInlineEditMetrics.prefersFullPage(text: "", kind: kind),
                          "\(kind) must not open an inline text field")
            XCTAssertFalse(JSONInlineEditMetrics.isInlineEditable(kind))
        }
    }

    // MARK: - Value <-> text

    func testTextForValue() {
        XCTAssertEqual(JSONInlineValueCoder.text(for: "hello"), "hello")
        XCTAssertEqual(JSONInlineValueCoder.text(for: NSNumber(value: 42)), "42")
        XCTAssertEqual(JSONInlineValueCoder.text(for: true), "true",
                       "CFBoolean is an NSNumber — it must not read as \"1\"")
        XCTAssertEqual(JSONInlineValueCoder.text(for: false), "false")
        XCTAssertEqual(JSONInlineValueCoder.text(for: NSNull()), "")
        XCTAssertEqual(JSONInlineValueCoder.text(for: nil), "")
    }

    func testValueFromTextKeepsIntegersIntegral() {
        let value = JSONInlineValueCoder.value(from: "7", kind: .number)
        XCTAssertEqual(value as? NSNumber, NSNumber(value: 7))
        // Round-tripping must not turn 7 into 7.0.
        XCTAssertEqual(JSONDocument(root: value).minifiedText(), "7")
    }

    func testValueFromTextParsesDecimalsAndFallsBackToZero() throws {
        let decimal = try XCTUnwrap(JSONInlineValueCoder.value(from: " 3.5 ", kind: .number) as? NSNumber)
        XCTAssertEqual(decimal.doubleValue, 3.5, accuracy: 0.0001,
                       "Surrounding whitespace must not break a number")

        let junk = try XCTUnwrap(JSONInlineValueCoder.value(from: "abc", kind: .number) as? NSNumber)
        XCTAssertEqual(junk.doubleValue, 0, accuracy: 0.0001)
    }

    func testValueFromTextForStringsIsVerbatim() {
        XCTAssertEqual(JSONInlineValueCoder.value(from: "  keep  spaces  ", kind: .string) as? String,
                       "  keep  spaces  ",
                       "A string is whatever was typed — trimming would corrupt payloads")
        XCTAssertEqual(JSONInlineValueCoder.value(from: "line\nbreak", kind: .string) as? String,
                       "line\nbreak")
    }

    func testValueFromTextForBoolAndNull() {
        for truthy in ["true", "TRUE", " yes ", "1", "on"] {
            XCTAssertEqual(JSONInlineValueCoder.value(from: truthy, kind: .bool) as? Bool, true, truthy)
        }
        for falsy in ["false", "no", "", "0"] {
            XCTAssertEqual(JSONInlineValueCoder.value(from: falsy, kind: .bool) as? Bool, false, falsy)
        }
        XCTAssertTrue(JSONInlineValueCoder.value(from: "anything", kind: .null) is NSNull)
    }

    func testValueFromTextForContainers() {
        let parsed = JSONInlineValueCoder.value(from: "{\"a\":1}", kind: .object)
        XCTAssertEqual((parsed as? [String: Any])?["a"] as? Int, 1)
        // Junk must not be written into the tree as a container.
        XCTAssertEqual((JSONInlineValueCoder.value(from: "not json", kind: .object) as? [String: Any])?.count, 0)
        XCTAssertEqual((JSONInlineValueCoder.value(from: "not json", kind: .array) as? [Any])?.count, 0)
    }

    func testUnchangedDraftIsDetected() {
        XCTAssertTrue(JSONInlineValueCoder.isUnchanged(draft: "hello", current: "hello"),
                      "A no-op edit must not push an undo entry")
        XCTAssertTrue(JSONInlineValueCoder.isUnchanged(draft: "42", current: NSNumber(value: 42)))
        XCTAssertFalse(JSONInlineValueCoder.isUnchanged(draft: "hello ", current: "hello"))
        XCTAssertFalse(JSONInlineValueCoder.isUnchanged(draft: "x", current: nil))
    }

    // MARK: - Write-back by path

    /// Exactly what the editor does when an inline edit is committed: resolve the
    /// node's kind, skip no-ops, and write through the path API.
    @discardableResult
    private func commitInline(_ draft: String, at path: JSONPath, in doc: JSONDocument) -> Bool {
        guard let kind = doc.kind(at: path), JSONInlineEditMetrics.isInlineEditable(kind) else { return false }
        guard !JSONInlineValueCoder.isUnchanged(draft: draft, current: doc.value(at: path)) else { return false }
        return doc.setValue(JSONInlineValueCoder.value(from: draft, kind: kind), at: path)
    }

    private func makeDocument() -> JSONDocument {
        JSONDocument(root: [
            "name": "Ada",
            "age": NSNumber(value: 36),
            "items": [
                ["id": NSNumber(value: 1), "label": "first"],
                ["id": NSNumber(value: 2), "label": "second"],
            ] as [Any],
        ] as [String: Any])
    }

    func testCommitWritesToTheAddressedNodeOnly() {
        let doc = makeDocument()
        XCTAssertTrue(commitInline("Grace", at: [.key("name")], in: doc))

        XCTAssertEqual(doc.value(at: [.key("name")]) as? String, "Grace")
        XCTAssertEqual((doc.value(at: [.key("age")]) as? NSNumber)?.intValue, 36,
                       "Siblings must be untouched")
        XCTAssertEqual((doc.value(at: [.key("items")]) as? [Any])?.count, 2)
    }

    func testCommitReachesNestedArrayElements() {
        let doc = makeDocument()
        let path: JSONPath = [.key("items"), .index(1), .key("label")]
        XCTAssertTrue(commitInline("edited", at: path, in: doc))

        XCTAssertEqual(doc.value(at: path) as? String, "edited")
        XCTAssertEqual(doc.value(at: [.key("items"), .index(0), .key("label")]) as? String, "first",
                       "The sibling element must not be touched")
    }

    func testCommitKeepsTheNodesTypeInsteadOfStringifyingIt() {
        let doc = makeDocument()
        XCTAssertTrue(commitInline("41", at: [.key("age")], in: doc))
        XCTAssertEqual(doc.kind(at: [.key("age")]), .number,
                       "Typing into a number node must not turn it into a string")
        XCTAssertEqual((doc.value(at: [.key("age")]) as? NSNumber)?.intValue, 41)
    }

    func testCommitByPathSurvivesTheTreeReflattening() {
        // The tree sorts object keys, so inserting "aaa" moves every row below it
        // down. An edit committed by row index would land on the wrong node; the
        // path must still resolve to the same one.
        let doc = makeDocument()
        XCTAssertTrue(doc.addKey("aaa", value: "inserted", toObjectAt: []))
        XCTAssertTrue(commitInline("Grace", at: [.key("name")], in: doc))

        XCTAssertEqual(doc.value(at: [.key("name")]) as? String, "Grace")
        XCTAssertEqual(doc.value(at: [.key("aaa")]) as? String, "inserted",
                       "The newly inserted row must not have absorbed the edit")
    }

    func testUnchangedCommitIsSkippedSoUndoStaysMeaningful() {
        let doc = makeDocument()
        XCTAssertFalse(commitInline("Ada", at: [.key("name")], in: doc),
                       "Focusing a field and typing nothing is not an edit")
        XCTAssertFalse(doc.canUndo)

        XCTAssertTrue(commitInline("Grace", at: [.key("name")], in: doc))
        XCTAssertTrue(doc.canUndo)
        doc.undo()
        XCTAssertEqual(doc.value(at: [.key("name")]) as? String, "Ada",
                       "One inline edit is one undo step")
    }

    func testCommitToAVanishedPathIsRefused() {
        let doc = makeDocument()
        XCTAssertTrue(doc.remove(at: [.key("name")]))
        XCTAssertFalse(commitInline("Grace", at: [.key("name")], in: doc),
                       "A deleted node must not be resurrected by a stale draft")
        XCTAssertNil(doc.value(at: [.key("name")]))
    }

    func testCommitIsRefusedForKindsThatHaveNoInlineField() {
        let doc = makeDocument()
        XCTAssertFalse(commitInline("[]", at: [.key("items")], in: doc))
        XCTAssertEqual((doc.value(at: [.key("items")]) as? [Any])?.count, 2,
                       "Containers are edited in the tree, never through the row field")
    }
}
