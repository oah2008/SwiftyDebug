//
//  JSONArrayElementTemplateTests.swift
//  SwiftyDebugTests
//
//  "Add item" on an array must add another item of the SAME type as the ones
//  already there. Reproduction of what it actually did first:
//
//   * an array of objects whose values are themselves objects or arrays got a
//     template with `{}` / `[]` in those slots — the shape stopped one level
//     down, so "same shape" was only true of flat rows;
//   * a key that is `null` in the first element and a string in the second was
//     templated as `null`, because the first element seen won;
//   * an array of decimals got an integer `0`;
//   * an EMPTY array got an empty *string* — a silent type change, with nothing
//     on screen to say a guess had been made;
//   * a MIXED array got the first element's type, again silently;
//   * every element of a 10,000-row array was read to work that out.
//
//  Everything here is pure logic: no screen, no document even, for the reader.
//

import XCTest
@testable import SwiftyDebug

final class JSONArrayElementTemplateTests: XCTestCase {

    // MARK: - Helpers

    private func doc(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> JSONDocument {
        try XCTUnwrap(JSONDocument(text: text), file: file, line: line)
    }

    // MARK: - 1. Objects are shaped all the way down

    /// The headline reproduction: a row whose fields are themselves a nested
    /// object and a nested array. "Shaped like the existing items" has to mean
    /// the whole shape, or the new row is missing every field that matters.
    func testTemplateForAnArrayOfObjectsShapesNestedObjectsAndArrays() throws {
        let d = try doc(#"""
        {"rows":[{"id":1,"user":{"id":7,"name":"Ada","admin":true},"tags":["beta"],"note":"x"}]}
        """#)
        let template = try XCTUnwrap(d.templateElement(forArrayAt: [.key("rows")]) as? [String: Any])

        XCTAssertEqual(Set(template.keys), ["id", "user", "tags", "note"])
        XCTAssertEqual(template["id"] as? NSNumber, 0)
        XCTAssertEqual(template["note"] as? String, "")

        let user = try XCTUnwrap(template["user"] as? [String: Any],
                                 "a nested object must be shaped, not left as {}")
        XCTAssertEqual(Set(user.keys), ["id", "name", "admin"])
        XCTAssertEqual(user["id"] as? NSNumber, 0)
        XCTAssertEqual(user["name"] as? String, "")
        XCTAssertEqual(user["admin"] as? Bool, false)

        // A nested array is added empty on purpose — a seeded junk element would
        // have to be deleted every time — but it must still BE an array.
        XCTAssertEqual((template["tags"] as? [Any])?.count, 0)
    }

    /// Three levels: the shape has to keep going, not stop at the second.
    func testNestedObjectsAreShapedMoreThanOneLevelDown() throws {
        let d = try doc(#"{"a":[{"b":{"c":{"d":5,"e":"x"}}}]}"#)
        let template = try XCTUnwrap(d.templateElement(forArrayAt: [.key("a")]) as? [String: Any])
        let b = try XCTUnwrap(template["b"] as? [String: Any])
        let c = try XCTUnwrap(b["c"] as? [String: Any])
        XCTAssertEqual(c["d"] as? NSNumber, 0)
        XCTAssertEqual(c["e"] as? String, "")
    }

    /// A key present in some elements and absent from others still belongs in
    /// the template — that is the whole point of unioning.
    func testTemplateUnionsKeysAcrossElements() throws {
        let d = try doc(#"{"items":[{"id":1,"title":"x"},{"id":2,"extra":true}]}"#)
        let template = try XCTUnwrap(d.templateElement(forArrayAt: [.key("items")]) as? [String: Any])
        XCTAssertEqual(Set(template.keys), ["id", "title", "extra"])
        XCTAssertEqual(template["id"] as? NSNumber, 0)
        XCTAssertEqual(template["title"] as? String, "")
        XCTAssertEqual(template["extra"] as? Bool, false)
    }

    /// "each value defaulted to that key's OWN observed type rather than to
    /// null": a field that is null on the row that happens to be first is not a
    /// null field, it is an optional one.
    func testAKeyThatIsNullInOneElementTakesTheTypeItHasInAnother() throws {
        let d = try doc(#"{"rows":[{"note":null,"count":null},{"note":"hi","count":3}]}"#)
        let template = try XCTUnwrap(d.templateElement(forArrayAt: [.key("rows")]) as? [String: Any])
        XCTAssertEqual(template["note"] as? String, "",
                       "null in the first row must not win over a string in the second")
        XCTAssertEqual(template["count"] as? NSNumber, 0)
    }

    /// A key that is null in EVERY element has no other observed type, so null
    /// is the honest answer.
    func testAKeyThatIsNullEverywhereStaysNull() throws {
        let d = try doc(#"{"rows":[{"note":null},{"note":null}]}"#)
        let template = try XCTUnwrap(d.templateElement(forArrayAt: [.key("rows")]) as? [String: Any])
        XCTAssertTrue(template["note"] is NSNull)
    }

    // MARK: - 2. Primitive arrays

    func testArrayOfStringsAppendsAnEmptyString() throws {
        let d = try doc(#"{"tags":["a","b"]}"#)
        XCTAssertEqual(d.templateElement(forArrayAt: [.key("tags")]) as? String, "")
    }

    func testArrayOfIntegersAppendsAnInteger() throws {
        let d = try doc(#"{"ids":[4,9]}"#)
        let value = try XCTUnwrap(d.templateElement(forArrayAt: [.key("ids")]) as? NSNumber)
        XCTAssertEqual(value, 0)
        XCTAssertFalse(CFNumberIsFloatType(value as CFNumber),
                       "an array of integers must not hand back a floating-point 0")
    }

    /// "matching integer vs decimal to the siblings": an array of prices should
    /// hand you a decimal zero, not an integer one.
    func testArrayOfDecimalsAppendsADecimalZero() throws {
        let d = try doc(#"{"prices":[19.99,1.50]}"#)
        let value = try XCTUnwrap(d.templateElement(forArrayAt: [.key("prices")]) as? NSNumber)
        XCTAssertEqual(value.doubleValue, 0)
        XCTAssertTrue(CFNumberIsFloatType(value as CFNumber),
                      "an array of decimals must not hand back an integer 0")
    }

    func testArrayOfBoolsAppendsFalse() throws {
        let d = try doc(#"{"flags":[true,false]}"#)
        let value = d.templateElement(forArrayAt: [.key("flags")])
        XCTAssertEqual(value as? Bool, false)
        XCTAssertEqual(JSONValueKind.of(value), .bool, "false must stay a bool, not become 0")
    }

    func testArrayOfNullsAppendsNull() throws {
        let d = try doc(#"{"slots":[null,null]}"#)
        XCTAssertTrue(d.templateElement(forArrayAt: [.key("slots")]) is NSNull)
    }

    func testArrayOfArraysAppendsAnArray() throws {
        let d = try doc(#"{"matrix":[[1,2],[3,4]]}"#)
        let value = d.templateElement(forArrayAt: [.key("matrix")])
        XCTAssertEqual(JSONValueKind.of(value), .array)
        XCTAssertEqual((value as? [Any])?.count, 0)
    }

    // MARK: - 3. The summary: what the menu says before you tap

    private func summary(_ json: String, at path: JSONPath = [.key("a")],
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try doc(json).arrayElementTemplate(forArrayAt: path).summary
    }

    func testSummaryNamesEveryPrimitiveElementType() throws {
        XCTAssertEqual(try summary(#"{"a":["x","y"]}"#), "string")
        XCTAssertEqual(try summary(#"{"a":[4,9]}"#), "number")
        XCTAssertEqual(try summary(#"{"a":[19.99,1.50]}"#), "number (decimal)")
        XCTAssertEqual(try summary(#"{"a":[true,false]}"#), "bool")
    }

    /// "object with 5 keys" is the example from the request: the count is the
    /// only way to tell, from a menu, that the shape was actually read.
    func testSummaryCountsTheKeysOfAnObjectElement() throws {
        XCTAssertEqual(try summary(#"{"a":[{"id":1,"t":"x"},{"id":2,"e":true}]}"#), "object with 3 keys")
        XCTAssertEqual(try summary(#"{"a":[{"id":1}]}"#), "object with 1 key")
        XCTAssertEqual(try summary(#"{"a":[{},{}]}"#), "empty object")
    }

    /// An array slot is added empty on purpose, so the summary has to say that
    /// as well as naming what the siblings hold.
    func testSummaryForAnArrayOfArraysNamesTheInnerTypeAndSaysItAddsAnEmptyOne() throws {
        XCTAssertEqual(try summary(#"{"a":[[1,2],[3]]}"#), "array of number · adds an empty array")
        XCTAssertEqual(try summary(#"{"a":[["x"],["y"]]}"#), "array of string · adds an empty array")
        XCTAssertEqual(try summary(#"{"a":[[],[]]}"#), "array · adds an empty array")
    }

    func testSummarySaysWhenSomeItemsAreNull() throws {
        let template = try doc(#"{"a":[1,null,2]}"#).arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.summary, "number · some items are null")
        XCTAssertEqual(template.kind, .number)
        XCTAssertTrue(template.isInferred, "one null among numbers is still an array of numbers")
    }

    func testSummaryForAnArrayOfNullsSaysSo() throws {
        let template = try doc(#"{"a":[null,null]}"#).arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.summary, "null · every item is null")
        XCTAssertEqual(template.kind, .null)
        XCTAssertTrue(template.isInferred)
    }

    // MARK: - 4. Mixed and empty arrays fall back, and SAY they fell back

    func testAMixedArrayNamesTheTypesItSawAndSaysWhatItChose() throws {
        let template = try doc(#"{"a":[1,"x",true]}"#).arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.summary,
                       "mixed items (bool, number, string) · adding a number, like the first one")
        XCTAssertEqual(template.kind, .number)
        XCTAssertEqual(template.value as? NSNumber, 0)
        XCTAssertFalse(template.isInferred, "a guess must not be reported as a reading")
    }

    func testAMixedArrayCountsNullsAmongTheTypesItSaw() throws {
        let template = try doc(#"{"a":["x",1,null]}"#).arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.summary,
                       "mixed items (null, number, string) · adding a string, like the first one")
        XCTAssertFalse(template.isInferred)
    }

    func testAnEmptyArrayWithNothingToLearnFromSaysWhatItAdded() throws {
        let template = try doc(#"{"a":[]}"#).arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.summary, "empty array · nothing to copy, adding an empty string")
        XCTAssertEqual(template.kind, .string)
        XCTAssertEqual(template.value as? String, "")
        XCTAssertFalse(template.isInferred)
    }

    /// An empty array is not always uninformative: the other rows of the same
    /// collection say what belongs in it, and matching them beats defaulting to
    /// a type nobody asked for.
    func testAnEmptyArrayIsReadFromTheSameKeyOnItsSiblingRows() throws {
        let d = try doc(#"{"rows":[{"tags":["beta","vip"]},{"tags":[]}]}"#)
        let template = d.arrayElementTemplate(forArrayAt: [.key("rows"), .index(1), .key("tags")])
        XCTAssertEqual(template.value as? String, "")
        XCTAssertEqual(template.kind, .string)
        XCTAssertEqual(template.summary,
                       "string · this array is empty — matching the other arrays alongside it")
        XCTAssertTrue(template.isInferred)
    }

    func testAnEmptyArrayInsideAnArrayOfArraysIsReadFromItsNeighbours() throws {
        let d = try doc(#"{"matrix":[[1,2],[]]}"#)
        let template = d.arrayElementTemplate(forArrayAt: [.key("matrix"), .index(1)])
        XCTAssertEqual(template.value as? NSNumber, 0)
        XCTAssertEqual(template.summary,
                       "number · this array is empty — matching the other arrays alongside it")
    }

    /// The neighbour lookup must not read the array it is standing in — an empty
    /// array next to empty arrays still has nothing to say.
    func testAnEmptyArrayWhoseNeighboursAreAlsoEmptyFallsBack() throws {
        let d = try doc(#"{"matrix":[[],[]]}"#)
        let template = d.arrayElementTemplate(forArrayAt: [.key("matrix"), .index(0)])
        XCTAssertFalse(template.isInferred)
        XCTAssertEqual(template.summary, "empty array · nothing to copy, adding an empty string")
    }

    /// A top-level empty array has no siblings at all, and must not walk off the
    /// end of the path looking for them.
    func testAnEmptyRootArrayFallsBackWithoutCrashing() throws {
        let d = try doc("[]")
        let template = d.arrayElementTemplate(forArrayAt: [])
        XCTAssertEqual(template.value as? String, "")
        XCTAssertFalse(template.isInferred)
    }

    /// Asking a node that is not an array is a caller mistake, not a crash.
    func testANonArrayPathFallsBackInsteadOfCrashing() throws {
        let d = try doc(#"{"a":{"b":1}}"#)
        XCTAssertEqual(d.arrayElementTemplate(forArrayAt: [.key("a")]).value as? String, "")
        XCTAssertEqual(d.arrayElementTemplate(forArrayAt: [.key("nope")]).value as? String, "")
    }

    // MARK: - 5. Bounded: a 10,000-row body costs what a 64-row one costs

    private func bigArray(_ element: String, count: Int, tail: String? = nil) -> String {
        var items = Array(repeating: element, count: count)
        if let tail { items.append(tail) }
        return #"{"a":["# + items.joined(separator: ",") + "]}"
    }

    /// The proof that it stops: element 5,000 is a number and every one of the
    /// first 64 is a string. A reader that scanned the whole array would call
    /// this mixed; a bounded one calls it a string array and says how far it
    /// looked.
    func testALargeArrayIsReadFromItsFirstItemsOnlyAndSaysSo() throws {
        let count = 5_000
        let d = try doc(bigArray(#""x""#, count: count, tail: "42"))
        let template = d.arrayElementTemplate(forArrayAt: [.key("a")])
        XCTAssertEqual(template.value as? String, "")
        XCTAssertTrue(template.isInferred)
        XCTAssertEqual(template.summary,
                       "string · read the first \(JSONArrayShapeReader.sampleLimit) of \(count + 1) items")
    }

    /// An array exactly at the limit was fully read, so it must NOT claim to
    /// have sampled.
    func testAnArrayAtTheSampleLimitDoesNotClaimToHaveSampled() throws {
        let d = try doc(bigArray("1", count: JSONArrayShapeReader.sampleLimit))
        XCTAssertEqual(d.arrayElementTemplate(forArrayAt: [.key("a")]).summary, "number")
    }

    /// Ten thousand rows of a real shape, timed. The bound is the only reason
    /// this is not a visible pause when the menu opens.
    func testTenThousandRowsAreShapedInWellUnderATenthOfASecond() throws {
        let row = #"{"id":1,"user":{"id":2,"name":"a"},"tags":["t"],"note":null}"#
        let d = try doc(bigArray(row, count: 10_000))
        let started = Date()
        let template = d.arrayElementTemplate(forArrayAt: [.key("a")])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual((template.value as? [String: Any])?.count, 4)
        XCTAssertLessThan(elapsed, 0.1, "shaping must not scale with the array: took \(elapsed)s")
    }

    /// Nesting is bounded too, or a pathological body recurses the stack away.
    /// Past the cap the slot is still the right *type*, it just stops being
    /// filled in.
    func testDeepNestingStopsAtTheDepthCapInsteadOfRecursingForever() throws {
        let depth = 60
        let text = #"{"a":["# + String(repeating: #"{"n":"#, count: depth) + "1"
            + String(repeating: "}", count: depth) + "]}"
        let d = try doc(text)
        var node = try XCTUnwrap(d.templateElement(forArrayAt: [.key("a")]) as? [String: Any])
        var levels = 1
        while let next = node["n"] as? [String: Any], !next.isEmpty {
            node = next
            levels += 1
        }
        XCTAssertEqual(levels, JSONArrayShapeReader.maxDepth,
                       "the template must stop copying at the depth cap")
        XCTAssertNotNil(node["n"], "the capped level still keeps the key, just not its shape")
    }

    // MARK: - 6. Appending the template into a source-indexed document

    /// The fidelity rule for every mutation in this file: adding an item must
    /// not reorder the keys of the items already there, and must not respell a
    /// single number it did not touch. Asserted on the WHOLE body, because "the
    /// new element is right" stayed true while the rest was being rewritten.
    private let orders = #"{"orders":[{"id":1001,"status":"shipped","total":19.99,"items":2},{"status":"pending","id":1002,"total":1.50,"items":1,"note":"gift"},{"total":250.00,"id":1003,"status":"paid","items":7}],"count":3}"#

    func testAppendingTheTemplateLeavesEveryExistingItemByteForByte() throws {
        let d = try doc(orders)
        XCTAssertTrue(d.preservesSourceFormatting)
        let template = d.templateElement(forArrayAt: [.key("orders")])
        XCTAssertTrue(d.appendElement(template, toArrayAt: [.key("orders")]))

        let appended = #"{"id":0,"items":0,"note":"","status":"","total":0}"#
        XCTAssertEqual(d.minifiedText(),
                       orders.replacingOccurrences(of: "]", with: "," + appended + "]"),
                       "1.50 and 250.00 must still be spelled the way the server spelled them")
    }

    func testAppendingTheTemplateIsOneUndoBackToTheServersBytes() throws {
        let d = try doc(orders)
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: [.key("orders")]),
                                      toArrayAt: [.key("orders")]))
        d.undo()
        XCTAssertEqual(d.minifiedText(), orders)
    }

    /// Appending into an array that was reordered first: the new element must
    /// not pick up the records of whatever used to sit at that index.
    func testAppendingTheTemplateAfterAReorderDoesNotBorrowAnyonesKeyOrder() throws {
        let d = try doc(orders)
        XCTAssertTrue(d.moveElement(inArrayAt: [.key("orders")], from: 0, to: 2))
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: [.key("orders")]),
                                      toArrayAt: [.key("orders")]))
        XCTAssertEqual(d.minifiedText(), #"{"orders":[{"status":"pending","id":1002,"total":1.50,"items":1,"note":"gift"},{"total":250.00,"id":1003,"status":"paid","items":7},{"id":1001,"status":"shipped","total":19.99,"items":2},{"id":0,"items":0,"note":"","status":"","total":0}],"count":3}"#)
    }

    /// A nested array inside a row: the rows around it must not notice.
    func testAppendingIntoANestedArrayLeavesTheSurroundingRowsAlone() throws {
        let groups = #"{"groups":[{"name":"north","rows":[{"sku":"a","qty":2},{"qty":5,"sku":"b"}]},{"name":"south","rows":[{"qty":9,"sku":"c"}]}]}"#
        let d = try doc(groups)
        let path: JSONPath = [.key("groups"), .index(0), .key("rows")]
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: path), toArrayAt: path))
        XCTAssertEqual(d.minifiedText(),
                       groups.replacingOccurrences(of: #"{"qty":5,"sku":"b"}]"#,
                                                   with: #"{"qty":5,"sku":"b"},{"qty":0,"sku":""}]"#))
    }

    /// The decimal zero has to reach the payload as a JSON number, not as
    /// `0.0` — no server writes that, and it is the writer's job, so prove the
    /// template does not undo it.
    func testADecimalTemplateStillSerialisesAsAPlainZero() throws {
        let d = try doc(#"{"prices":[19.99,1.50]}"#)
        XCTAssertTrue(d.appendElement(d.templateElement(forArrayAt: [.key("prices")]),
                                      toArrayAt: [.key("prices")]))
        XCTAssertEqual(d.minifiedText(), #"{"prices":[19.99,1.50,0]}"#)
    }
}
