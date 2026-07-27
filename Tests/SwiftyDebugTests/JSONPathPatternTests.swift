//
//  JSONPathPatternTests.swift
//  SwiftyDebugTests
//
//  A pattern is the addressing half of an automated response rewrite: it decides
//  WHICH values get overwritten in a body the app then trusts. Two failure modes
//  matter equally here —
//
//    * matching too little (the rewrite silently does nothing), and
//    * matching too much  (a "*" quietly rewrites half the document).
//
//  so both directions are pinned, along with the parser refusing input it cannot
//  honour instead of degrading into "matches nothing".
//

import XCTest
@testable import SwiftyDebug

final class JSONPathPatternTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func matchDisplays(_ pattern: String, _ text: String) -> [String] {
        guard let p = JSONPathPattern(pattern) else { return ["<unparseable>"] }
        return p.matches(in: json(text)).map { $0.display }
    }

    // MARK: - Parsing

    func testParsesTheShapesTheContractPromises() {
        for text in ["data.url", "data.items[*].url", "**.url", "data.items[0].url",
                     "data.*.url", "url", "data.items[*].images[*].url", "[0].name"] {
            XCTAssertNotNil(JSONPathPattern(text), "\(text) must parse")
        }
    }

    func testRefusesInputItCannotHonourRatherThanMatchingNothing() {
        for text in ["", "   ", ".", ".data", "data.", "data..url", "data[", "data[]",
                     "data[a]", "data[-1]", "us*r", "root", "$"] {
            XCTAssertNil(JSONPathPattern(text), "\(text) must NOT parse")
        }
    }

    func testAcceptsThePrefixesTheUIShows() {
        // The tree editor's breadcrumb is "root.data.url"; JSONPath tools write "$.data.url".
        XCTAssertEqual(JSONPathPattern("root.data.url")?.text, "data.url")
        XCTAssertEqual(JSONPathPattern("$.data.url")?.text, "data.url")
        XCTAssertEqual(JSONPathPattern("  data.url  ")?.text, "data.url")
        XCTAssertEqual(matchDisplays("root.data.url", #"{"data":{"url":"a"}}"#), ["root.data.url"])
    }

    func testCollapsesRepeatedDescendantWildcards() {
        // "**.**.url" would otherwise reach the same node twice.
        XCTAssertEqual(matchDisplays("**.**.url", #"{"a":{"url":"x"}}"#), ["root.a.url"])
    }

    // MARK: - Matching

    func testExactPath() {
        XCTAssertEqual(matchDisplays("data.url", #"{"data":{"url":"https://google.com/a"},"other":1}"#),
                       ["root.data.url"])
        XCTAssertEqual(matchDisplays("data.missing", #"{"data":{"url":"x"}}"#), [])
        XCTAssertEqual(matchDisplays("data.url", #"{"data":[1,2]}"#), [],
                       "A key pattern must not match into an array")
    }

    func testStarOverAnArrayOfObjects() {
        let body = #"{"data":{"items":[{"url":"a"},{"url":"b"},{"nope":1},{"url":"c"}]}}"#
        XCTAssertEqual(matchDisplays("data.items[*].url", body),
                       ["root.data.items[0].url", "root.data.items[1].url", "root.data.items[3].url"])
    }

    func testNestedArraysOfObjects() {
        let body = """
        {"data":{"items":[
          {"images":[{"url":"a1"},{"url":"a2"}]},
          {"images":[{"url":"b1"}]}
        ]}}
        """
        XCTAssertEqual(matchDisplays("data.items[*].images[*].url", body),
                       ["root.data.items[0].images[0].url",
                        "root.data.items[0].images[1].url",
                        "root.data.items[1].images[0].url"])
    }

    func testSpecificIndex() {
        let body = #"{"items":[{"url":"a"},{"url":"b"}]}"#
        XCTAssertEqual(matchDisplays("items[1].url", body), ["root.items[1].url"])
        XCTAssertEqual(matchDisplays("items[7].url", body), [], "Out of range matches nothing, never crashes")
        XCTAssertEqual(matchDisplays("items[0]", #"{"items":[]}"#), [])
    }

    func testDescendantWildcardFindsAKeyAtEveryDepth() {
        let body = """
        {"url":"top",
         "data":{"url":"mid","deep":{"nested":{"url":"bottom"}}},
         "list":[{"url":"in-array"}],
         "other":{"name":"no"}}
        """
        // Shallow before deep, arrays by index, object keys sorted — deterministic.
        XCTAssertEqual(matchDisplays("**.url", body),
                       ["root.url", "root.data.url", "root.data.deep.nested.url", "root.list[0].url"])
    }

    func testDescendantWildcardCanBeAnchored() {
        let body = #"{"a":{"url":"x","deep":{"url":"y"}},"b":{"url":"z"}}"#
        XCTAssertEqual(matchDisplays("a.**.url", body), ["root.a.url", "root.a.deep.url"])
    }

    func testAnyKeyMatchesOneLevelOnly() {
        let body = #"{"data":{"a":{"url":"1"},"b":{"url":"2"},"c":{"deep":{"url":"3"}}}}"#
        XCTAssertEqual(matchDisplays("data.*.url", body), ["root.data.a.url", "root.data.b.url"])
    }

    func testKeysContainingDotsAddressableWithBrackets() {
        let body = #"{"data":{"a.b":{"url":"x"}}}"#
        XCTAssertEqual(matchDisplays("data.a.b.url", body), [], "A dotted key is not two keys")
        XCTAssertEqual(matchDisplays(#"data["a.b"].url"#, body), ["root.data.a.b.url"])
    }

    func testMatchingIsDeterministicAcrossRuns() {
        let body = #"{"z":{"url":"1"},"a":{"url":"2"},"m":{"url":"3"},"k":{"url":"4"}}"#
        let first = matchDisplays("**.url", body)
        for _ in 0..<20 {
            XCTAssertEqual(matchDisplays("**.url", body), first,
                           "Object key order must not depend on hashing")
        }
        XCTAssertEqual(first, ["root.a.url", "root.k.url", "root.m.url", "root.z.url"])
    }

    func testNonContainerRootMatchesNothingInsteadOfCrashing() {
        XCTAssertEqual(matchDisplays("data.url", "42"), [])
        XCTAssertEqual(matchDisplays("**.url", #""just a string""#), [])
    }

    // MARK: - Limits

    func testWideDocumentIsCappedRatherThanHanging() {
        var items: [String] = []
        for i in 0..<5_000 { items.append(#"{"url":"u\#(i)"}"#) }
        let body = "{\"items\":[" + items.joined(separator: ",") + "]}"
        let pattern = JSONPathPattern("items[*].url")!

        let started = Date()
        let matches = pattern.matches(in: json(body))
        XCTAssertLessThanOrEqual(matches.count, JSONPathPattern.maxMatches)
        XCTAssertEqual(matches.count, JSONPathPattern.maxMatches, "Capped, not truncated to zero")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Must not hang the caller")

        // And an explicit smaller limit is honoured, for previews.
        XCTAssertEqual(pattern.matches(in: json(body), limit: 3).count, 3)
        XCTAssertEqual(pattern.matches(in: json(body), limit: 0).count, 0)
    }

    func testDeepDocumentUnderDescendantWildcardStopsAtTheNodeBudget() {
        // 400 levels of nesting, each with a decoy key: ** would otherwise walk forever.
        var body = #"{"url":"leaf"}"#
        for _ in 0..<400 { body = "{\"child\":\(body),\"noise\":\"x\"}" }
        let started = Date()
        let matches = JSONPathPattern("**.url")!.matches(in: json(body))
        XCTAssertGreaterThanOrEqual(matches.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testBroadPatternsAreFlaggedForTheUI() {
        XCTAssertFalse(JSONPathPattern("data.url")!.isBroad)
        XCTAssertFalse(JSONPathPattern("data.items[0].url")!.isBroad)
        XCTAssertTrue(JSONPathPattern("data.items[*].url")!.isBroad)
        XCTAssertTrue(JSONPathPattern("**.url")!.isBroad)
        XCTAssertTrue(JSONPathPattern("data.*.url")!.isBroad)
    }

    // MARK: - Scope options

    func testScopeOptionsForAnIndexedPath() {
        let path: JSONPath = [.key("data"), .key("items"), .index(0), .key("url")]
        let options = JSONPathPattern.scopeOptions(for: path)
        XCTAssertEqual(options.map { $0.pattern },
                       ["data.items[0].url", "data.items[*].url", "**.url"])
        XCTAssertEqual(options.map { $0.label },
                       ["Just this one", "Every item like it", "Every \"url\" anywhere"])
        for option in options {
            XCTAssertNotNil(JSONPathPattern(option.pattern), "\(option.pattern) must parse back")
        }
    }

    func testScopeOptionsWithoutAnIndexOmitTheArrayChoice() {
        let options = JSONPathPattern.scopeOptions(for: [.key("data"), .key("url")])
        XCTAssertEqual(options.map { $0.pattern }, ["data.url", "**.url"])
    }

    func testScopeOptionsForAnArrayElementOfferNoAnywhereChoice() {
        let options = JSONPathPattern.scopeOptions(for: [.key("items"), .index(2)])
        XCTAssertEqual(options.map { $0.pattern }, ["items[2]", "items[*]"])
    }

    func testScopeOptionsForTheRootAreEmpty() {
        XCTAssertTrue(JSONPathPattern.scopeOptions(for: []).isEmpty)
    }

    func testScopeOptionsNeverRepeatAPattern() {
        // A single key: "url" and "**.url" are different scopes, but nothing is duplicated.
        let options = JSONPathPattern.scopeOptions(for: [.key("url")])
        XCTAssertEqual(Set(options.map { $0.pattern }).count, options.count)
    }

    func testConcretePathTextRoundTripsThroughTheParser() {
        let body = #"{"data":{"a.b":[{"url":"x"}]}}"#
        let path: JSONPath = [.key("data"), .key("a.b"), .index(0), .key("url")]
        let text = JSONPathPattern.text(for: path)
        XCTAssertEqual(matchDisplays(text, body), [path.display])
    }
}
