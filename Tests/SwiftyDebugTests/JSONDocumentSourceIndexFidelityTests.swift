//
//  JSONDocumentSourceIndexFidelityTests.swift
//  SwiftyDebugTests
//
//  `JSONDocument` keeps a source index — the original key order and the
//  original spelling of every number — because the text it produces is not a
//  debug view: response rewrites, breakpoint edits and mock seeding hand it to
//  the HOST APP. A payload that comes back alphabetised, or with `1.50` spelled
//  `1.5`, is a payload no server ever sent.
//
//  Three ways that index used to fall out of step with the tree, all of them
//  invisible to a test that only checks values:
//
//   1. `undo()` restored the tree but not the index, so renaming a key and
//      changing your mind left the *renamed* order behind.
//   2. The index is keyed by path, and an array path contains the element's
//      index — so deleting, moving or duplicating an element re-pointed every
//      record at its neighbour and the writer degraded to `keys.sorted()`.
//   3. An integral double was written `1000.0` / `1e+16` where Foundation and
//      every server write `1000` / `10000000000000000`.
//
//  Every assertion here is on the WHOLE serialised body, because "the value I
//  edited is right" stayed true through all three bugs.
//

import XCTest
@testable import SwiftyDebug

final class JSONDocumentSourceIndexFidelityTests: XCTestCase {

    // MARK: - Payloads

    /// 30 keys, declaration order, none of it alphabetical: a user profile of
    /// the shape these editors actually open.
    private let profile = #"{"id":90071992547409931,"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","age":36,"isActive":true,"score":19.99,"balance":1250.00,"tier":"gold","createdAt":"2026-01-05T10:00:00Z","updatedAt":"2026-06-30T23:59:59Z","lastLoginAt":"2026-07-27T08:15:00Z","loginCount":412,"country":"GB","city":"London","postcode":"NW1 6XE","latitude":51.5074,"longitude":-0.1278,"timezone":"Europe/London","locale":"en_GB","currency":"GBP","referrer":"newsletter","tags":["beta","vip"],"preferences":{"theme":"dark","emails":false},"avatarUrl":"https://cdn.example.com/a/ada.png","phone":"+44 20 7946 0958","notes":null,"discount":0.1,"ratio":0.30000000000000004,"weight":-0.0}"#

    /// An array of objects whose elements do NOT agree on key order or key set —
    /// which is what real collections look like once a field is optional or two
    /// services serialise the same row.
    private let orders = #"{"orders":[{"id":1001,"status":"shipped","total":19.99,"items":2},{"status":"pending","id":1002,"total":1.50,"items":1,"note":"gift"},{"total":250.00,"id":1003,"status":"paid","items":7}],"count":3}"#

    private let order0 = #"{"id":1001,"status":"shipped","total":19.99,"items":2}"#
    private let order1 = #"{"status":"pending","id":1002,"total":1.50,"items":1,"note":"gift"}"#
    private let order2 = #"{"total":250.00,"id":1003,"status":"paid","items":7}"#

    /// Arrays inside arrays: reordering the outer one has to carry the inner
    /// ones' key order with it, not just the top level.
    private let groups = #"{"groups":[{"name":"north","rows":[{"sku":"a","qty":2},{"qty":5,"sku":"b"}]},{"name":"south","rows":[{"qty":9,"sku":"c"}]}]}"#

    private func makeDoc(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> JSONDocument {
        let doc = try XCTUnwrap(JSONDocument(text: text), file: file, line: line)
        XCTAssertTrue(doc.preservesSourceFormatting, file: file, line: line)
        return doc
    }

    private func ordersText(_ elements: [String], count: String = "3") -> String {
        #"{"orders":["# + elements.joined(separator: ",") + #"],"count":"# + count + "}"
    }

    // MARK: - 1. Undo / redo must restore the index, not just the tree

    /// The headline: rename a key in a 30-key object, change your mind, and the
    /// body must be byte-identical to what the server sent. With the tree
    /// restored but the index left renamed, the old key drops out of the
    /// recorded order and reappears at the end — a key order no server produced.
    func testUndoAfterRenameRestoresTheOriginalKeyOrder() throws {
        let doc = try makeDoc(profile)
        XCTAssertTrue(doc.renameKey(at: [.key("email")], to: "emailAddress"))
        XCTAssertEqual(doc.minifiedText(),
                       profile.replacingOccurrences(of: #""email":"#, with: #""emailAddress":"#),
                       "The rename itself must keep the key in its original slot")

        doc.undo()
        XCTAssertEqual(doc.minifiedText(), profile,
                       "Undoing a rename must put the key back where it was, not at the end")
    }

    /// Redo has to walk forward through the *intermediate* bodies, not just
    /// arrive at the last one. Stepping back three edits and forward one left
    /// the tree at edit 1 wearing the key order of edit 3.
    func testRedoWalksForwardThroughEveryIntermediateBodyItRecorded() throws {
        let doc = try makeDoc(orders)
        let renamedOrder1 = #"{"status":"pending","id":1002,"total":1.50,"items":1,"giftNote":"gift"}"#

        var stages = [doc.minifiedText()]
        XCTAssertTrue(doc.renameKey(at: [.key("orders"), .index(1), .key("note")], to: "giftNote"))
        stages.append(doc.minifiedText())
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        stages.append(doc.minifiedText())
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(0)]))
        stages.append(doc.minifiedText())

        XCTAssertEqual(stages[1], ordersText([order0, renamedOrder1, order2]))
        XCTAssertEqual(stages[2], ordersText([renamedOrder1, order2, order0]))
        XCTAssertEqual(stages[3], ordersText([order2, order0]))

        for _ in 0..<3 { doc.undo() }
        XCTAssertEqual(doc.minifiedText(), stages[0])

        doc.redo()
        XCTAssertEqual(doc.minifiedText(), stages[1],
                       "Redoing one step must rebuild edit 1, not edit 1 in edit 3's key order")
        doc.redo()
        XCTAssertEqual(doc.minifiedText(), stages[2])
        doc.redo()
        XCTAssertEqual(doc.minifiedText(), stages[3])
    }

    /// Undo has to roll the *added* key out of the recorded order too, or the
    /// next key added lands behind a key that is no longer in the document.
    func testUndoAfterAddKeyRollsTheKeyOutOfTheRecordedOrder() throws {
        let doc = try makeDoc(#"{"zeta":1,"alpha":2}"#)
        XCTAssertTrue(doc.addKey("omega", value: 9, toObjectAt: []))
        doc.undo()

        XCTAssertTrue(doc.addKey("beta", value: 1, toObjectAt: []))
        XCTAssertTrue(doc.addKey("omega", value: 2, toObjectAt: []))
        XCTAssertEqual(doc.minifiedText(), #"{"zeta":1,"alpha":2,"beta":1,"omega":2}"#,
                       "Keys must sit in the order they were actually added to this document")
    }

    /// Undoing an array move must also undo the index move, or the survivors
    /// come back wearing each other's key order.
    func testUndoAfterMovingAnArrayElementRestoresTheWholeBody() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        XCTAssertNotEqual(doc.minifiedText(), orders)
        doc.undo()
        XCTAssertEqual(doc.minifiedText(), orders,
                       "Undoing a drag-to-reorder must restore the original bytes")
    }

    /// Edit / undo / redo has to converge: running the same cycle three times
    /// must land on the same two strings every time, never drift.
    func testRepeatedEditUndoRedoCyclesConvergeInsteadOfDrifting() throws {
        let doc = try makeDoc(orders)
        var edited: [String] = []
        var reverted: [String] = []

        for _ in 0..<3 {
            XCTAssertTrue(doc.renameKey(at: [.key("orders"), .index(1), .key("note")], to: "giftNote"))
            XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 2, to: 0))
            XCTAssertTrue(doc.addKey("channel", value: "web", toObjectAt: [.key("orders"), .index(0)]))
            XCTAssertTrue(doc.remove(at: [.key("orders"), .index(2)]))
            edited.append(doc.minifiedText())

            doc.undo(); doc.undo(); doc.undo(); doc.undo()
            reverted.append(doc.minifiedText())

            doc.redo(); doc.redo(); doc.redo(); doc.redo()
            XCTAssertEqual(doc.minifiedText(), edited[0], "Redo must land on the same body every time")

            doc.undo(); doc.undo(); doc.undo(); doc.undo()
        }

        XCTAssertEqual(Set(edited).count, 1, "The same four edits must always produce the same body: \(edited)")
        XCTAssertEqual(Set(reverted).count, 1, "Undoing them must always produce the same body: \(reverted)")
        XCTAssertEqual(reverted[0], orders, "Four undos must land exactly on the server's bytes")
    }

    // MARK: - 2. Array mutations must carry each element's own key order

    func testDeletingAnArrayElementKeepsEverySurvivorsOwnKeyOrder() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(0)]))
        XCTAssertEqual(doc.minifiedText(), ordersText([order1, order2]),
                       "The survivors kept their keys where the server put them, and 1.50 is still 1.50")
    }

    func testDeletingFromTheMiddleShiftsOnlyTheElementsBehindIt() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(1)]))
        XCTAssertEqual(doc.minifiedText(), ordersText([order0, order2]))
    }

    func testMovingAnArrayElementCarriesItsKeyOrderAndNumberSpellingWithIt() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        XCTAssertEqual(doc.minifiedText(), ordersText([order1, order2, order0]),
                       "Drag-to-reorder must move the elements, not rewrite them")
    }

    func testDuplicatingAnArrayElementDoesNotAlphabetiseTheElementsBehindIt() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.duplicateElement(at: [.key("orders"), .index(0)]))
        XCTAssertEqual(doc.minifiedText(), ordersText([order0, order0, order1, order2], count: "3"),
                       "The array grew past the recorded indices — the tail must not fall back to sorted keys")
    }

    /// "Add item" appends a template built from the siblings. The elements the
    /// user just dragged into place must not notice.
    func testAppendingToAReorderedArrayLeavesTheReorderedElementsAlone() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        XCTAssertTrue(doc.appendElement(["id": 1004] as [String: Any], toArrayAt: [.key("orders")]))
        XCTAssertEqual(doc.minifiedText(), ordersText([order1, order2, order0, #"{"id":1004}"#]))
    }

    /// A shrunk-then-grown array must not hand the new element the records of
    /// the element that used to sit at that index.
    func testAnAppendedElementDoesNotInheritADeletedElementsKeyOrder() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(2)]))
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(1)]))
        XCTAssertTrue(doc.appendElement(["status": "new", "id": 1004] as [String: Any],
                                        toArrayAt: [.key("orders")]))
        XCTAssertEqual(doc.minifiedText(), ordersText([order0, #"{"id":1004,"status":"new"}"#]),
                       "A brand-new object has no source order — sorted is the only honest answer")
    }

    func testReorderingTheOuterArrayCarriesTheNestedArraysKeyOrderToo() throws {
        let doc = try makeDoc(groups)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("groups")], from: 0, to: 1))
        XCTAssertEqual(doc.minifiedText(),
                       #"{"groups":[{"name":"south","rows":[{"qty":9,"sku":"c"}]},{"name":"north","rows":[{"sku":"a","qty":2},{"qty":5,"sku":"b"}]}]}"#,
                       "Rows two levels down must travel with the group that owns them")
    }

    func testDeletingANestedRowLeavesItsSiblingRowsAlone() throws {
        let doc = try makeDoc(groups)
        XCTAssertTrue(doc.remove(at: [.key("groups"), .index(0), .key("rows"), .index(0)]))
        XCTAssertEqual(doc.minifiedText(),
                       #"{"groups":[{"name":"north","rows":[{"qty":5,"sku":"b"}]},{"name":"south","rows":[{"qty":9,"sku":"c"}]}]}"#)
    }

    /// A top-level array is the other half of the use case: no key path in front
    /// of the index at all.
    func testTopLevelArrayReorderKeepsEachObjectsKeyOrder() throws {
        let text = #"[{"id":1,"cost":9.95},{"cost":0.10,"id":2},{"id":3,"cost":1.00,"note":"x"}]"#
        let doc = try makeDoc(text)
        XCTAssertTrue(doc.moveElement(inArrayAt: [], from: 2, to: 0))
        XCTAssertEqual(doc.minifiedText(),
                       #"[{"id":3,"cost":1.00,"note":"x"},{"id":1,"cost":9.95},{"cost":0.10,"id":2}]"#)
    }

    // MARK: - 3. `appendKey` — a new key belongs at the end, in the order added

    func testKeysAddedToAnObjectStayInTheOrderTheyWereAdded() throws {
        let doc = try makeDoc(#"{"zeta":1,"alpha":2}"#)
        XCTAssertTrue(doc.addKey("omega", value: "last", toObjectAt: []))
        XCTAssertTrue(doc.addKey("beta", value: "later", toObjectAt: []))
        XCTAssertEqual(doc.minifiedText(), #"{"zeta":1,"alpha":2,"omega":"last","beta":"later"}"#,
                       "A key the user just typed belongs where they put it, not in alphabetical order")
    }

    func testKeysAddedToAnObjectInsideAnArrayLandAtThatObjectsEnd() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.addKey("sku", value: "W-1", toObjectAt: [.key("orders"), .index(0)]))
        XCTAssertTrue(doc.addKey("channel", value: "web", toObjectAt: [.key("orders"), .index(0)]))
        let grown = #"{"id":1001,"status":"shipped","total":19.99,"items":2,"sku":"W-1","channel":"web"}"#
        XCTAssertEqual(doc.minifiedText(), ordersText([grown, order1, order2]))
    }

    func testAKeyAddedToAMovedElementLandsAtThatElementsEnd() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 2, to: 0))
        XCTAssertTrue(doc.addKey("refund", value: true, toObjectAt: [.key("orders"), .index(0)]))
        let grown = #"{"total":250.00,"id":1003,"status":"paid","items":7,"refund":true}"#
        XCTAssertEqual(doc.minifiedText(), ordersText([grown, order0, order1]))
    }

    // MARK: - 4. Integral doubles are spelled the way JSON spells integers

    /// The tree the rewrite engine builds has no source text to copy from, so
    /// every number is formatted from scratch. `1000.0` and `1e+16` are the two
    /// spellings Foundation never produced.
    func testIntegralDoublesAreWrittenWithoutAFractionOrAnExponent() {
        let doc = JSONDocument(root: ["count": 1000.0,
                                      "big": 1e16,
                                      "negative": -42.0,
                                      "zero": 0.0] as [String: Any])
        XCTAssertFalse(doc.preservesSourceFormatting)
        XCTAssertEqual(doc.minifiedText(),
                       #"{"big":10000000000000000,"count":1000,"negative":-42,"zero":0}"#)
    }

    func testIntegralDoublesStayIntegersThroughAnEditAndReparse() throws {
        let doc = try makeDoc(#"{"limit":3,"used":1}"#)
        XCTAssertTrue(doc.setValue(2.0, at: [.key("limit")]))
        XCTAssertEqual(doc.minifiedText(), #"{"limit":2,"used":1}"#,
                       "An edit that happens to arrive as a Double must not spell it \"2.0\"")
        let reparsed = try XCTUnwrap(JSONDocument(text: doc.minifiedText()))
        XCTAssertEqual((reparsed.value(at: [.key("limit")]) as? NSNumber)?.intValue, 2)
    }

    func testFractionsKeepTheirShortestRoundTripSpelling() {
        let doc = JSONDocument(root: ["price": 19.99, "discount": 0.1, "third": 1.0 / 3.0] as [String: Any])
        let text = doc.minifiedText()
        XCTAssertTrue(text.contains(#""price":19.99"#), text)
        XCTAssertTrue(text.contains(#""discount":0.1"#), text)
        XCTAssertTrue(text.contains(#""third":0.3333333333333333"#), text)
        XCTAssertNotNil(JSONDocument(text: text), "Still parseable JSON")
    }

    /// Beyond `Int64` the digits stop being writable this way and Foundation
    /// gives up too (`1e+20`), so the round-trip spelling has to stand.
    func testIntegralDoublesTooBigForAnInt64KeepTheirRoundTripSpelling() throws {
        let doc = JSONDocument(root: ["huge": 1e20, "low": -1e20] as [String: Any])
        let text = doc.minifiedText()
        XCTAssertEqual(text, #"{"huge":1e+20,"low":-1e+20}"#)
        let reparsed = try XCTUnwrap(JSONDocument(text: text))
        XCTAssertEqual(reparsed.value(at: [.key("huge")]) as? NSNumber, NSNumber(value: 1e20))
    }

    func testNegativeZeroIsWrittenTheWayFoundationWritesIt() {
        let doc = JSONDocument(root: ["drift": -0.0] as [String: Any])
        XCTAssertEqual(doc.minifiedText(), #"{"drift":-0}"#)
        XCTAssertTrue(JSONDocument.validate(doc.minifiedText()).isValid)
    }

    func testBooleansAreStillBooleansAndNotIntegralNumbers() {
        let doc = JSONDocument(root: ["on": true, "off": false, "one": 1.0] as [String: Any])
        XCTAssertEqual(doc.minifiedText(), #"{"off":false,"on":true,"one":1}"#)
    }

    // MARK: - 5. Numbers of every shape, and the literal that must not outlive its value

    /// Integers past 2^53, an unsigned value past `Int64.max`, a 21-digit
    /// decimal, exponents in both directions and a negative zero — untouched,
    /// the body has to come back byte for byte.
    func testEveryNumberShapeSurvivesAnUntouchedRoundTrip() throws {
        let text = #"{"maxSafe":9007199254740993,"unsigned":18446744073709551615,"huge":123456789012345678901,"exp":1.0e3,"expNeg":2.5E-4,"negZero":-0.0,"zero":0,"trailing":250.00,"tiny":0.000001,"negative":-42,"pi":3.141592653589793}"#
        let doc = try makeDoc(text)
        XCTAssertEqual(doc.minifiedText(), text)
    }

    func testEditingOneNumberLeavesEveryOtherShapeSpelledAsItWas() throws {
        let text = #"{"maxSafe":9007199254740993,"huge":123456789012345678901,"exp":1.0e3,"trailing":250.00,"tiny":0.000001}"#
        let doc = try makeDoc(text)
        XCTAssertTrue(doc.setValue(JSONInlineValueCoder.value(from: "9007199254740992", kind: .number),
                                   at: [.key("maxSafe")]))
        XCTAssertEqual(doc.minifiedText(),
                       text.replacingOccurrences(of: "9007199254740993", with: "9007199254740992"),
                       "An id one away from the source value must not re-emit the source spelling")
    }

    /// A 21-digit id parses as an `NSDecimalNumber`, which carries more digits
    /// than a `Double`. Judging the recorded literal by `Double` equality is
    /// therefore exactly as blind as it was for a big `Int`: the neighbouring
    /// id rounds to the same `Double`, so the ORIGINAL id was re-emitted and the
    /// rewrite that replaced it vanished with `changed: 1` reported.
    func testReplacingA21DigitIdWithItsNeighbourIsNotSwallowedByTheSourceLiteral() throws {
        let doc = try makeDoc(#"{"accountId":123456789012345678901,"name":"Ada"}"#)
        let replacement = NSDecimalNumber(string: "123456789012345678902")
        XCTAssertTrue(doc.setValue(replacement, at: [.key("accountId")]))
        XCTAssertEqual(doc.minifiedText(), #"{"accountId":123456789012345678902,"name":"Ada"}"#)
    }

    /// A `UInt64` above `Int64.max` reports an *integer* CFNumber type, but
    /// `intValue` on it wraps to -1 — so a recorded `-1` was judged to "describe"
    /// a real 64-bit device id and got written back over it.
    func testAnUnsignedIdAboveInt64MaxIsNotConfusedWithAWrappedMinusOne() throws {
        let doc = try makeDoc(#"{"seq":-1,"name":"probe"}"#)
        XCTAssertTrue(doc.setValue(NSNumber(value: UInt64.max), at: [.key("seq")]))
        XCTAssertEqual(doc.minifiedText(), #"{"seq":18446744073709551615,"name":"probe"}"#,
                       "The recorded -1 must not survive on top of the value that replaced it")
    }

    // MARK: - 6. The three fixes together on one document

    /// One editing session: reorder the collection, delete a row, rename a
    /// field, add a field, drop in a computed integral number — then undo the
    /// lot. Nothing about the server's bytes may survive the round trip.
    func testAFullEditingSessionUndoesBackToTheServersBytes() throws {
        let doc = try makeDoc(orders)
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        XCTAssertTrue(doc.remove(at: [.key("orders"), .index(1)]))
        XCTAssertTrue(doc.renameKey(at: [.key("orders"), .index(0), .key("note")], to: "giftNote"))
        XCTAssertTrue(doc.addKey("refundedAt", value: NSNull(), toObjectAt: [.key("orders"), .index(0)]))
        XCTAssertTrue(doc.setValue(2.0, at: [.key("count")]))

        let expected = ordersText([#"{"status":"pending","id":1002,"total":1.50,"items":1,"giftNote":"gift","refundedAt":null}"#,
                                   order0],
                                  count: "2")
        XCTAssertEqual(doc.minifiedText(), expected)

        for _ in 0..<5 { doc.undo() }
        XCTAssertEqual(doc.minifiedText(), orders)
        XCTAssertFalse(doc.canUndo)

        for _ in 0..<5 { doc.redo() }
        XCTAssertEqual(doc.minifiedText(), expected)
    }
}
