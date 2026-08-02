//
//  AdversarialSmartArrayAddTests.swift
//  SwiftyDebugTests
//
//  "Add item" attacked with the arrays a real API actually returns and with the
//  arrays written to break a reader:
//
//    * every element type, including the ones that are not a type at all — an
//      empty array, an all-null array, and a mixed one;
//    * an array of objects whose rows DISAGREE (missing keys, conflicting types
//      for the same key, nested arrays of objects);
//    * a 50 000-element array, where the inference must not read past its
//      sample and the append must not walk the document;
//    * the fidelity requirement: appending inside a source-indexed document
//      must leave every existing element's key order and number spelling
//      byte-identical;
//    * add / undo / redo / add again — the document has to converge on the same
//      text, not drift a little further each round;
//    * the promise in the menu subtitle against the value that is actually
//      inserted, for every shape above.
//
//  Everything asserts on SERIALISED TEXT wherever it can. A template that is
//  right in memory and wrong in the payload is still wrong: the payload is what
//  the host app is handed.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class AdversarialSmartArrayAddTests: XCTestCase {

    // MARK: - Helpers

    private func doc(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> JSONDocument {
        try XCTUnwrap(JSONDocument(text: text), file: file, line: line)
    }

    /// Reads the template, appends it, and hands back both the words and the
    /// resulting document text — the two things that have to agree.
    private func addItem(to json: String, at path: JSONPath,
                         file: StaticString = #filePath, line: UInt = #line)
    throws -> (template: JSONArrayElementTemplate, before: String, after: String) {
        let document = try doc(json, file: file, line: line)
        let before = document.prettyText()
        let template = document.arrayElementTemplate(forArrayAt: path)
        XCTAssertTrue(document.appendElement(template.value, toArrayAt: path),
                      "append refused", file: file, line: line)
        return (template, before, document.prettyText())
    }

    /// The JSON text of the LAST element of the array at `path`.
    private func lastElement(of document: JSONDocument, at path: JSONPath) throws -> Any {
        let array = try XCTUnwrap(document.value(at: path) as? [Any])
        return try XCTUnwrap(array.last)
    }

    // MARK: - 1. The subtitle and the inserted value must describe each other

    /// One table, every element shape. `summary` is what the user reads BEFORE
    /// tapping; `kind` is what a type picker preselects; the value is what lands
    /// in the payload. A row where those three disagree is the whole bug class.
    func testTheMenuWordsMatchTheTypeThatIsActuallyInserted() throws {
        let cases: [(json: String, path: JSONPath, expectedKind: JSONValueKind,
                     summaryContains: String, inferred: Bool)] = [
            (#"{"a":["x","y"]}"#,            [.key("a")], .string, "string",  true),
            (#"{"a":[1,2]}"#,                [.key("a")], .number, "number",  true),
            (#"{"a":[19.99,1.50]}"#,         [.key("a")], .number, "number",  true),
            (#"{"a":[true,false]}"#,         [.key("a")], .bool,   "bool",    true),
            (#"{"a":[null,null]}"#,          [.key("a")], .null,   "null",    true),
            (#"{"a":[{"k":1}]}"#,            [.key("a")], .object, "object",  true),
            (#"{"a":[[1],[2]]}"#,            [.key("a")], .array,  "array",   true),
            (#"{"a":[1,"x",true]}"#,         [.key("a")], .number, "mixed",   false),
            (#"{"a":[]}"#,                   [.key("a")], .string, "empty array", false),
        ]

        for c in cases {
            let result = try addItem(to: c.json, at: c.path)
            XCTAssertEqual(result.template.kind, c.expectedKind,
                           "wrong kind for \(c.json): \(result.template.summary)")
            XCTAssertEqual(JSONValueKind.of(result.template.value), c.expectedKind,
                           "the VALUE is not the kind the menu names, for \(c.json)")
            XCTAssertTrue(result.template.summary.contains(c.summaryContains),
                          "\(c.json) → \"\(result.template.summary)\" does not mention \(c.summaryContains)")
            XCTAssertEqual(result.template.isInferred, c.inferred,
                           "\(c.json) presented a \(c.inferred ? "guess as a match" : "match as a guess")")
            XCTAssertFalse(result.after.isEmpty, "\(c.json) stopped serialising after the add")
        }
    }

    /// A guess must not be dressed up as a reading. `isInferred == false` is
    /// what the menu uses to withhold the accent colour, so an array that could
    /// not be read has to say so.
    func testAnUnreadableArrayIsNeverPresentedAsAMatch() throws {
        for json in [#"{"a":[]}"#, #"{"a":[1,"x"]}"#, #"{"a":[{"k":1},"x"]}"#] {
            let d = try doc(json)
            XCTAssertFalse(d.arrayElementTemplate(forArrayAt: [.key("a")]).isInferred,
                           "\(json) claimed to have read its items")
        }
    }

    // MARK: - 2. Rows that disagree

    /// The union case: three rows, three different key sets. The template has to
    /// carry all of them, each with the type that key really has somewhere.
    func testUnionOfKeysAcrossRowsThatDisagree() throws {
        let result = try addItem(
            to: #"{"r":[{"id":1,"name":"a"},{"id":2,"admin":true},{"id":3,"score":1.5,"name":"c"}]}"#,
            at: [.key("r")])
        let added = try XCTUnwrap(result.template.value as? [String: Any])
        XCTAssertEqual(Set(added.keys), ["id", "name", "admin", "score"])
        XCTAssertEqual(added["id"] as? NSNumber, 0)
        XCTAssertEqual(added["name"] as? String, "")
        XCTAssertEqual(added["admin"] as? Bool, false)
        XCTAssertEqual((added["score"] as? NSNumber)?.doubleValue, 0)
        XCTAssertTrue(result.template.summary.contains("4 keys"),
                      "the menu undercounts the union: \(result.template.summary)")
    }

    /// The same key holding different types on different rows. Whatever it
    /// resolves to, the appended element must still be a legal JSON value, the
    /// document must still serialise — and the menu must SAY the rows disagree
    /// rather than presenting the first row's type as the answer.
    func testConflictingTypesForOneKeyAreSaidOutLoudNotGuessedSilently() throws {
        let result = try addItem(to: #"{"r":[{"v":1},{"v":"s"},{"v":[1,2]}]}"#, at: [.key("r")])
        let added = try XCTUnwrap(result.template.value as? [String: Any])
        XCTAssertEqual(Set(added.keys), ["v"])
        XCTAssertNotNil(added["v"], "the conflicting key was dropped from the template")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.after.utf8)),
                        "the document stopped being valid JSON")
        XCTAssertTrue(result.template.summary.contains("disagree"),
                      "a silent guess: \(result.template.summary)")
        XCTAssertTrue(result.template.summary.contains("\u{201C}v\u{201D}"),
                      "the disagreeing field is not named: \(result.template.summary)")
    }

    /// The note has to be reserved for rows that really do disagree — a key
    /// that is simply MISSING from some rows, or null on some rows, is not a
    /// disagreement and must not be flagged as one.
    func testRowsThatAgreeAreNeverFlaggedAsDisagreeing() throws {
        for json in [#"{"r":[{"id":1,"t":"x"},{"id":2,"e":true}]}"#,      // missing keys
                     #"{"r":[{"note":null},{"note":"hi"}]}"#,             // null vs value
                     #"{"r":[{"note":null},{"note":null}]}"#,             // null everywhere
                     #"{"r":[{"n":[1]},{"n":[2,3]}]}"#] {                 // same shapes
            let d = try doc(json)
            let summary = d.arrayElementTemplate(forArrayAt: [.key("r")]).summary
            XCTAssertFalse(summary.contains("disagree"),
                           "\(json) was wrongly reported as disagreeing: \(summary)")
        }
    }

    /// A long list of disagreeing fields must not turn the subtitle into a wall
    /// of text.
    func testTheDisagreementNoteIsCapped() throws {
        let first = (0..<12).map { "\"k\($0)\":1" }.joined(separator: ",")
        let second = (0..<12).map { "\"k\($0)\":\"s\"" }.joined(separator: ",")
        let d = try doc("{\"r\":[{\(first)},{\(second)}]}")
        let summary = d.arrayElementTemplate(forArrayAt: [.key("r")]).summary
        XCTAssertTrue(summary.contains("and 9 more"), summary)
        XCTAssertLessThan(summary.count, 140, "the subtitle is unreadable: \(summary)")
    }

    /// A row's field is null on the first row and a real value further down.
    /// Taking the first row's null would type the field as null forever.
    func testANullOnTheFirstRowDoesNotTypeTheField() throws {
        let d = try doc(#"{"r":[{"note":null,"n":null},{"note":"hi","n":7},{"note":null,"n":null}]}"#)
        let added = try XCTUnwrap(d.templateElement(forArrayAt: [.key("r")]) as? [String: Any])
        XCTAssertEqual(added["note"] as? String, "")
        XCTAssertEqual(added["n"] as? NSNumber, 0)
    }

    /// Nested arrays of objects: the shape has to keep going down, and the
    /// nested array slot has to be an ARRAY, not an object or a string.
    func testNestedArraysOfObjectsAreShapedNotFlattened() throws {
        let d = try doc(#"{"r":[{"lines":[{"sku":"a","qty":2}],"total":9.99}]}"#)
        let added = try XCTUnwrap(d.templateElement(forArrayAt: [.key("r")]) as? [String: Any])
        XCTAssertNotNil(added["lines"] as? [Any], "a nested array of objects lost its type")
        XCTAssertEqual((added["lines"] as? [Any])?.count, 0)
        XCTAssertEqual((added["total"] as? NSNumber)?.doubleValue, 0)

        // ...and the nested array itself can then be added to, with its own
        // shape read from the row above it.
        XCTAssertTrue(d.appendElement(added, toArrayAt: [.key("r")]))
        let nested = d.arrayElementTemplate(forArrayAt: [.key("r"), .index(1), .key("lines")])
        let row = try XCTUnwrap(nested.value as? [String: Any],
                                "an empty nested array did not read its sibling: \(nested.summary)")
        XCTAssertEqual(Set(row.keys), ["sku", "qty"])
    }

    // MARK: - 3. Empty arrays read their siblings

    func testAnEmptyArrayTakesItsShapeFromTheSameKeyOnOtherRows() throws {
        let d = try doc(#"{"rows":[{"tags":["beta"]},{"tags":[]}]}"#)
        let t = d.arrayElementTemplate(forArrayAt: [.key("rows"), .index(1), .key("tags")])
        XCTAssertEqual(t.kind, .string)
        XCTAssertTrue(t.isInferred)
        XCTAssertTrue(t.summary.contains("empty"), t.summary)
    }

    func testAnEmptyArrayWithNothingToLearnFromFallsBackAndSaysSo() throws {
        // No siblings at all.
        let alone = try doc(#"{"top":{"a":[]}}"#)
        let t1 = alone.arrayElementTemplate(forArrayAt: [.key("top"), .key("a")])
        XCTAssertFalse(t1.isInferred)
        XCTAssertEqual(t1.value as? String, "")

        // Siblings that are themselves empty teach nothing either.
        let empties = try doc(#"{"rows":[{"t":[]},{"t":[]}]}"#)
        let t2 = empties.arrayElementTemplate(forArrayAt: [.key("rows"), .index(0), .key("t")])
        XCTAssertFalse(t2.isInferred)

        // The document root being an empty array has no siblings by definition.
        let root = try doc("[]")
        let t3 = root.arrayElementTemplate(forArrayAt: [])
        XCTAssertFalse(t3.isInferred)
        XCTAssertEqual(t3.value as? String, "")
    }

    /// An empty array sitting past the sample window still finds siblings: the
    /// scan looks at the first 64 NEIGHBOURS, not at 64 elements starting from
    /// itself.
    func testAnEmptyArrayLateInALongListStillReadsItsNeighbours() throws {
        var rows: [String] = (0..<100).map { _ in #"{"tags":["x"]}"# }
        rows[99] = #"{"tags":[]}"#
        let d = try doc(#"{"rows":["# + rows.joined(separator: ",") + "]}")
        let t = d.arrayElementTemplate(forArrayAt: [.key("rows"), .index(99), .key("tags")])
        XCTAssertEqual(t.kind, .string, "summary was: \(t.summary)")
        XCTAssertTrue(t.isInferred)
    }

    // MARK: - 4. Bounded on a 50 000-element array

    /// Reading the shape of a huge array has to cost what reading a small one
    /// costs. The budget is deliberately loose — it is there to catch a full
    /// scan (which is ~1 000x this), not to measure the machine.
    func testInferenceOnAFiftyThousandElementArrayIsBounded() throws {
        var rows = ""
        for i in 0..<50_000 {
            if i > 0 { rows += "," }
            rows += "{\"id\":\(i),\"name\":\"n\(i)\",\"price\":\(Double(i) + 0.5)}"
        }
        let d = try doc("{\"rows\":[" + rows + "]}")

        let started = Date()
        let template = d.arrayElementTemplate(forArrayAt: [.key("rows")])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.25, "the inference walked the whole array")
        XCTAssertEqual(template.kind, .object)
        XCTAssertEqual(Set((template.value as? [String: Any])?.keys ?? [:].keys),
                       ["id", "name", "price"])
        XCTAssertTrue(template.summary.contains("first \(JSONArrayShapeReader.sampleLimit) of 50000"),
                      "the menu implies the whole array was read: \(template.summary)")

        // Appending is a single array mutation, not a walk either.
        let appendStarted = Date()
        XCTAssertTrue(d.appendElement(template.value, toArrayAt: [.key("rows")]))
        XCTAssertLessThan(Date().timeIntervalSince(appendStarted), 0.25)
        XCTAssertEqual((d.value(at: [.key("rows")]) as? [Any])?.count, 50_001)
    }

    /// Depth is bounded too: a body nested far past `maxDepth` must return a
    /// template rather than recursing the stack away.
    func testDeeplyNestedRowsDoNotRecurseAway() throws {
        func nest(_ level: Int) -> String {
            level == 0 ? "1" : "{\"k\":\(nest(level - 1))}"
        }
        // 200 levels — well past `JSONArrayShapeReader.maxDepth`.
        let d = try doc("{\"r\":[\(nest(200))]}")
        let t = d.arrayElementTemplate(forArrayAt: [.key("r")])
        XCTAssertEqual(t.kind, .object)
        XCTAssertTrue(d.appendElement(t.value, toArrayAt: [.key("r")]))
        XCTAssertFalse(d.prettyText().isEmpty)
    }

    // MARK: - 5. Fidelity: nothing already in the document may change

    /// The guarantee that matters most. Every existing element's key order and
    /// number spelling must be byte-identical after an append — including after
    /// the array has already been reordered and had an element deleted.
    func testAppendingNeverRewritesWhatIsAlreadyThere() throws {
        let source = #"""
        {"rows":[{"zeta":1250.00,"alpha":"a","mid":19.99},{"zeta":2,"alpha":"b","mid":0.1},{"zeta":3,"alpha":"c","mid":1e3}],"tail":true}
        """#
        let d = try doc(source)
        let before = d.prettyText()
        XCTAssertTrue(d.preservesSourceFormatting)

        let t = d.arrayElementTemplate(forArrayAt: [.key("rows")])
        XCTAssertTrue(d.appendElement(t.value, toArrayAt: [.key("rows")]))
        let after = d.prettyText()

        // Everything that was there is still spelled the way the server spelled
        // it, in the order the server sent it.
        for fragment in ["\"zeta\" : 1250.00", "\"zeta\" : 2", "\"mid\" : 19.99",
                         "\"mid\" : 0.1", "\"mid\" : 1e3", "\"tail\" : true"] {
            XCTAssertTrue(after.contains(fragment), "append respelled \(fragment)")
        }
        XCTAssertTrue(after.hasPrefix(String(before.dropLast(String("\n  ]\n}").count))) || after.contains("\"zeta\" : 1250.00"),
                      "the head of the document moved")

        // Now do it again after a reorder and a delete — the source index has to
        // follow the elements, not the slots.
        XCTAssertTrue(d.moveElement(inArrayAt: [.key("rows")], from: 0, to: 2))
        XCTAssertTrue(d.remove(at: [.key("rows"), .index(0)]))
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: [.key("rows")]),
                                      toArrayAt: [.key("rows")]))
        let moved = d.prettyText()
        XCTAssertTrue(moved.contains("\"zeta\" : 1250.00"),
                      "the moved element lost its number spelling:\n\(moved)")
        XCTAssertTrue(moved.contains("\"mid\" : 1e3"), "a survivor lost its number spelling")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(moved.utf8)))
    }

    /// Appending inside a nested array must not disturb the outer rows either.
    func testAppendingInsideARowLeavesTheOtherRowsAlone() throws {
        let d = try doc(#"{"rows":[{"zeta":1250.00,"tags":["x"]},{"zeta":2,"tags":["y"]}]}"#)
        XCTAssertTrue(d.appendElement("NEW", toArrayAt: [.key("rows"), .index(0), .key("tags")]))
        let text = d.prettyText()
        XCTAssertTrue(text.contains("\"zeta\" : 1250.00"))
        // Row 1 is untouched, keys still in source order.
        let rowOne = try XCTUnwrap(text.range(of: "\"zeta\" : 2"))
        XCTAssertLessThan(rowOne.lowerBound, try XCTUnwrap(text.range(of: "\"y\"")).lowerBound,
                          "row 1's keys were reordered")
    }

    // MARK: - 5b. Editing the row that was just added cannot reach the others

    /// The appended row has no recorded key order of its own — it is spelled
    /// `keys.sorted()`, which is deliberate (see `appendElement`) and means an
    /// added row reads differently from the rows above it. What must NEVER
    /// happen is the reverse: an edit to the new row rewriting a real one.
    ///
    /// Renaming a key and adding a key both write into the source index, and
    /// both used to be the way a new element reached into its neighbours'
    /// records.
    func testEditingTheAppendedRowLeavesTheRealRowsByteForByte() throws {
        let d = try doc(#"{"r":[{"zeta":1250.00,"alpha":"a"},{"zeta":2,"alpha":"b"}]}"#)
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: [.key("r")]), toArrayAt: [.key("r")]))
        XCTAssertTrue(d.renameKey(at: [.key("r"), .index(2), .key("zeta")], to: "ZETA"))
        XCTAssertTrue(d.addKey("added", value: "x", toObjectAt: [.key("r"), .index(2)]))

        let text = d.minifiedText()
        XCTAssertTrue(text.hasPrefix(#"{"r":[{"zeta":1250.00,"alpha":"a"},{"zeta":2,"alpha":"b"},"#),
                      "editing the appended row rewrote a real one:\n\(text)")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    // MARK: - 6. Add / undo / redo / add again converges

    func testAddUndoRedoAddConvergesRatherThanDrifting() throws {
        let source = #"{"rows":[{"zeta":1250.00,"alpha":"a"},{"zeta":2,"alpha":"b"}]}"#
        let d = try doc(source)
        let base = d.prettyText()

        func addOne() {
            d.appendElement(d.templateElement(forArrayAt: [.key("rows")]), toArrayAt: [.key("rows")])
        }

        addOne()
        let afterOne = d.prettyText()
        d.undo()
        XCTAssertEqual(d.prettyText(), base, "undo did not restore the document")
        d.redo()
        XCTAssertEqual(d.prettyText(), afterOne, "redo did not restore the addition")
        d.undo()
        XCTAssertEqual(d.prettyText(), base)
        addOne()
        XCTAssertEqual(d.prettyText(), afterOne,
                       "adding again after undo produced a DIFFERENT document")

        // Five rounds of the same thing must land in the same place every time.
        for _ in 0..<5 {
            d.undo()
            XCTAssertEqual(d.prettyText(), base)
            d.redo()
            XCTAssertEqual(d.prettyText(), afterOne)
        }

        // And a long run of adds unwinds completely.
        for _ in 0..<10 { addOne() }
        for _ in 0..<11 { d.undo() }
        XCTAssertEqual(d.prettyText(), base, "the document drifted over 11 adds and 11 undos")
    }

    /// Undo has to restore the source index, not just the tree: a delete
    /// followed by an undo used to leave the previous shape behind.
    func testUndoRestoresNumberSpellingAndKeyOrderNotJustValues() throws {
        let d = try doc(#"{"rows":[{"zeta":1250.00,"alpha":"a"},{"zeta":2,"alpha":"b"}]}"#)
        let base = d.prettyText()
        XCTAssertTrue(d.remove(at: [.key("rows"), .index(0)]))
        XCTAssertTrue(d.appendElement(["zeta": 0, "alpha": ""], toArrayAt: [.key("rows")]))
        d.undo()
        d.undo()
        XCTAssertEqual(d.prettyText(), base)
    }

    // MARK: - 7. The escape hatch inserts what it advertises

    func testPickingADifferentTypeInsertsThatTypeAndNothingElse() throws {
        for kind in JSONValueKind.allCases {
            let d = try doc(#"{"a":["x"]}"#)
            XCTAssertTrue(d.appendElement(kind.emptyValue, toArrayAt: [.key("a")]))
            let added = try lastElement(of: d, at: [.key("a")])
            XCTAssertEqual(JSONValueKind.of(added), kind,
                           "picking \(kind.badge) inserted a \(JSONValueKind.of(added).badge)")
            XCTAssertFalse(d.prettyText().isEmpty, "\(kind.badge) broke serialisation")
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(d.prettyText().utf8)))
        }
    }

    // MARK: - 8. Appending to something that is not an array is a no-op

    func testAppendingToANonArrayChangesNothing() throws {
        let d = try doc(#"{"a":{"b":1}}"#)
        let before = d.prettyText()
        XCTAssertFalse(d.appendElement("x", toArrayAt: [.key("a")]))
        XCTAssertFalse(d.appendElement("x", toArrayAt: [.key("nope")]))
        XCTAssertEqual(d.prettyText(), before)
        XCTAssertFalse(d.canUndo, "a refused append still pushed an undo step")
    }
}
