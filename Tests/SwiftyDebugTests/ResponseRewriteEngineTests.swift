//
//  ResponseRewriteEngineTests.swift
//  SwiftyDebugTests
//
//  Response rewrites edit a body the app then trusts — it parses the result and
//  navigates on it. So the bar is higher than "the happy path works":
//
//   * when a rewrite cannot be applied, the value is left EXACTLY as it was and
//     the reason is reported (a half-rewritten URL is worse than no rewrite),
//   * when nothing changes, the caller gets the original bytes back untouched,
//   * a rewrite that matches nothing SAYS it matched nothing, and
//   * "change the host" means the same thing here as it does for a redirect —
//     both go through InterceptRule.rewritingURL.
//

import XCTest
@testable import SwiftyDebug

final class ResponseRewriteEngineTests: XCTestCase {

    // MARK: - Helpers

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// Reads one value out of a body by pattern — reuses the matcher so the
    /// assertions cannot drift from the thing being tested.
    private func value(_ data: Data, _ pattern: String) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let path = JSONPathPattern(pattern)?.matches(in: root).first else { return nil }
        return JSONDocument(root: root).value(at: path)
    }

    private func string(_ data: Data, _ pattern: String) -> String? {
        value(data, pattern) as? String
    }

    private func rewrite(_ pattern: String, _ action: RewriteAction, enabled: Bool = true) -> ResponseRewrite {
        ResponseRewrite(pattern: pattern, action: action, isEnabled: enabled)
    }

    // MARK: - The example this feature was built for

    func testUsersExampleRewritesOnlyTheHost() {
        let body = data(#"{"data":{"url":"https://google.com/path/to/a"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)

        XCTAssertEqual(string(out.data, "data.url"), "https://salla.com/path/to/a")
        XCTAssertTrue(out.report.didChange)
        XCTAssertEqual(out.report.changedCount, 1)
        XCTAssertEqual(out.report.entries.count, 1)
        XCTAssertEqual(out.report.entries[0].matched, 1)
        XCTAssertEqual(out.report.entries[0].changed, 1)
        XCTAssertNil(out.report.entries[0].error)
        XCTAssertNil(out.report.skippedReason)
    }

    /// The same example, asserted on the BYTES the app would receive rather than
    /// on a re-parse — a re-parse would hide an escaped "\/" host or a changed
    /// document shape, and the app reads these bytes, not our parse of them.
    func testUsersExampleProducesExactlyTheExpectedBody() throws {
        let body = data(#"{"data":{"url":"https://google.com/path/to/a"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)

        let text = try XCTUnwrap(String(data: out.data, encoding: .utf8))
        XCTAssertEqual(text, #"{"data":{"url":"https://salla.com/path/to/a"}}"#)

        // Scheme kept, path kept, host swapped — spelled out so a regression
        // names which of the three broke.
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(string(out.data, "data.url"))))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "salla.com")
        XCTAssertEqual(url.path, "/path/to/a")
    }

    func testSchemelessURLKeepsItsSchemelessShape() {
        let body = data(#"{"data":{"url":"google.com/path/to/a?q=1"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(string(out.data, "data.url"), "salla.com/path/to/a?q=1")

        // Unless the target asks for a scheme, in which case the user wins.
        let withScheme = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("https://salla.com"))], to: body)
        XCTAssertEqual(string(withScheme.data, "data.url"), "https://salla.com/path/to/a?q=1")
    }

    func testProtocolRelativeURLStaysProtocolRelative() {
        let body = data(#"{"img":"//cdn.google.com/a.png"}"#)
        let out = ResponseRewriteEngine.apply([rewrite("img", .replaceHost("cdn.salla.com"))], to: body)
        XCTAssertEqual(string(out.data, "img"), "//cdn.salla.com/a.png")
    }

    // MARK: - Scope

    func testStarRewritesEveryElementOfAnArray() {
        let body = data("""
        {"data":{"items":[
          {"images":[{"url":"https://google.com/1.png"},{"url":"https://google.com/2.png"}]},
          {"images":[{"url":"https://google.com/3.png"}]}
        ]}}
        """)
        let out = ResponseRewriteEngine.apply(
            [rewrite("data.items[*].images[*].url", .replaceHost("cdn.salla.com"))], to: body)

        XCTAssertEqual(out.report.entries[0].matched, 3)
        XCTAssertEqual(out.report.entries[0].changed, 3)
        XCTAssertEqual(string(out.data, "data.items[0].images[0].url"), "https://cdn.salla.com/1.png")
        XCTAssertEqual(string(out.data, "data.items[0].images[1].url"), "https://cdn.salla.com/2.png")
        XCTAssertEqual(string(out.data, "data.items[1].images[0].url"), "https://cdn.salla.com/3.png")
    }

    func testDescendantWildcardRewritesAKeyAtEveryDepth() {
        let body = data("""
        {"url":"https://google.com/top",
         "data":{"url":"https://google.com/mid","deep":{"url":"https://google.com/bottom"}},
         "list":[{"url":"https://google.com/in-array"}],
         "name":"left alone"}
        """)
        let out = ResponseRewriteEngine.apply([rewrite("**.url", .replaceHost("salla.com"))], to: body)

        XCTAssertEqual(out.report.entries[0].matched, 4)
        XCTAssertEqual(out.report.entries[0].changed, 4)
        XCTAssertEqual(string(out.data, "url"), "https://salla.com/top")
        XCTAssertEqual(string(out.data, "data.url"), "https://salla.com/mid")
        XCTAssertEqual(string(out.data, "data.deep.url"), "https://salla.com/bottom")
        XCTAssertEqual(string(out.data, "list[0].url"), "https://salla.com/in-array")
        XCTAssertEqual(string(out.data, "name"), "left alone")
    }

    // MARK: - Nothing to do

    func testPatternThatMatchesNothingSaysSoAndReturnsTheSameBytes() {
        let body = data(#"{"data":{"url":"https://google.com/a"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.imageUrl", .replaceHost("salla.com"))], to: body)

        XCTAssertEqual(out.data, body, "The original bytes must come back untouched")
        XCTAssertFalse(out.report.didChange)
        XCTAssertEqual(out.report.changedCount, 0)
        XCTAssertEqual(out.report.entries.count, 1, "A rewrite that did nothing still reports")
        XCTAssertEqual(out.report.entries[0].matched, 0)
        XCTAssertTrue(out.report.hasEmptyMatch)
    }

    func testRewriteThatIsAlreadySatisfiedChangesNothing() {
        let body = data(#"{"data":{"url":"https://salla.com/a"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 1)
        XCTAssertEqual(out.report.entries[0].changed, 0)
        XCTAssertFalse(out.report.didChange)
    }

    func testDisabledRewritesAreNotApplied() {
        let body = data(#"{"data":{"url":"https://google.com/a"}}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("data.url", .replaceHost("salla.com"), enabled: false)], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertTrue(out.report.entries.isEmpty)
        XCTAssertNotNil(out.report.skippedReason, "The UI has to be able to say why nothing happened")
    }

    func testEmptyRewriteListIsAFreeNoOp() {
        let body = data(#"{"a":1}"#)
        let out = ResponseRewriteEngine.apply([], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertFalse(out.report.didChange)
        XCTAssertNil(out.report.skippedReason)
    }

    func testInvalidPatternIsReportedNotIgnored() {
        let body = data(#"{"data":{"url":"https://google.com/a"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data..url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 0)
        XCTAssertNotNil(out.report.entries[0].error)
        XCTAssertTrue(out.report.entries[0].error!.contains("not a valid path pattern"))
    }

    // MARK: - Values that are not URLs

    func testNonURLValueIsReportedAndLeftAlone() {
        let body = data(#"{"data":{"url":"this is not a url"},"n":5}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)

        XCTAssertEqual(out.data, body, "A value that cannot be rewritten must be byte-identical afterwards")
        XCTAssertEqual(out.report.entries[0].matched, 1)
        XCTAssertEqual(out.report.entries[0].changed, 0)
        XCTAssertEqual(out.report.entries[0].error, "value is not a URL")
    }

    func testNonStringValuesAndPathsAreReportedNotCoerced() {
        let body = data(#"{"a":{"url":42},"b":{"url":"/relative/path"},"c":{"url":"3.14"},"d":{"url":null}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("**.url", .replaceHost("salla.com"))], to: body)

        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 4)
        XCTAssertEqual(out.report.entries[0].changed, 0)
        // One message, with the count — not four repeated lines.
        XCTAssertEqual(out.report.entries[0].error, "value is not a URL (4 values)")
    }

    func testMissingTargetIsReportedOncePerRewrite() {
        let body = data(#"{"a":{"url":"https://google.com/1"},"b":{"url":"https://google.com/2"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("**.url", .replaceHost("   "))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 2)
        XCTAssertEqual(out.report.entries[0].error, "no replacement host set")
    }

    // MARK: - URL semantics match the redirect

    func testSchemePortAndQueryArePreserved() {
        let body = data(#"{"url":"https://google.com:8443/a/b?x=1&y=2#frag"}"#)
        let out = ResponseRewriteEngine.apply([rewrite("url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(string(out.data, "url"), "https://salla.com:8443/a/b?x=1&y=2#frag")
    }

    func testTargetCanCarrySchemeAndPort() {
        let body = data(#"{"url":"https://google.com/a?x=1"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("url", .replaceHost("http://localhost:8080"))], to: body)
        XCTAssertEqual(string(out.data, "url"), "http://localhost:8080/a?x=1")
    }

    func testHostAndPathKeepsTheOriginalQuery() {
        let body = data(#"{"url":"https://google.com/old/path?keep=1"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("url", .replaceHostAndPath("salla.com/v2/thing?ignored=1"))], to: body)
        XCTAssertEqual(string(out.data, "url"), "https://salla.com/v2/thing?keep=1")
    }

    func testRewriteAndRedirectAgreeOnWhatChangingTheHostMeans() {
        // Same input, same target: the body rewrite and the request redirect must
        // produce the same URL — they share InterceptRule.rewritingURL.
        let url = URL(string: "https://mahaly.com/checkout/abc?p=1")!
        var rule = InterceptRule(matchEndpoint: "/checkout/{id}")
        rule.redirectMode = .host
        rule.redirectTarget = "beta.mahaly.com"

        let viaRedirect = rule.redirectedURL(for: url)?.absoluteString
        let viaRewrite = ResponseRewriteEngine.rewrittenURLString(url.absoluteString,
                                                                 mode: .host, target: "beta.mahaly.com")
        XCTAssertEqual(viaRedirect, viaRewrite)
        XCTAssertEqual(viaRewrite, "https://beta.mahaly.com/checkout/abc?p=1")
    }

    // MARK: - find / replace

    func testLiteralFindReplace() {
        let body = data(#"{"msg":"hello world, world"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("msg", .findReplace(find: "world", replace: "there", isRegex: false))], to: body)
        XCTAssertEqual(string(out.data, "msg"), "hello there, there")
        XCTAssertEqual(out.report.entries[0].changed, 1)
    }

    func testRegexFindReplaceWithACaptureGroup() {
        let body = data(#"{"url":"https://google.com/v1/items"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("url", .findReplace(find: "/v([0-9]+)/", replace: "/v$1-beta/", isRegex: true))], to: body)
        XCTAssertEqual(string(out.data, "url"), "https://google.com/v1-beta/items")
    }

    func testInvalidRegexIsReportedAndNothingIsTouched() {
        let body = data(#"{"msg":"hello"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("msg", .findReplace(find: "[unclosed", replace: "x", isRegex: true))], to: body)

        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 1)
        XCTAssertEqual(out.report.entries[0].changed, 0)
        XCTAssertTrue(out.report.entries[0].error?.contains("not a valid regular expression") == true)
    }

    func testTemplateReferringToAMissingGroupIsReported() {
        let body = data(#"{"msg":"hello"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("msg", .findReplace(find: "hello", replace: "$3", isRegex: true))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertTrue(out.report.entries[0].error?.contains("$3") == true)
    }

    func testEmptyFindIsReported() {
        let body = data(#"{"msg":"hello"}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("msg", .findReplace(find: "", replace: "x", isRegex: false))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].error, "nothing to find")
    }

    func testFindReplaceOnANonStringIsReported() {
        let body = data(#"{"count":5}"#)
        let out = ResponseRewriteEngine.apply(
            [rewrite("count", .findReplace(find: "5", replace: "6", isRegex: false))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].error, "value is not text")
    }

    // MARK: - removeKey

    func testRemoveKeyDropsTheKeyEntirely() {
        let body = data(#"{"data":{"url":"https://google.com/a","token":"secret"}}"#)
        let out = ResponseRewriteEngine.apply([rewrite("data.token", .removeKey)], to: body)

        XCTAssertNil(value(out.data, "data.token"))
        XCTAssertEqual(string(out.data, "data.url"), "https://google.com/a")
        XCTAssertEqual(out.report.changedCount, 1)
    }

    func testRemovingArrayElementsRunsBackToFrontSoIndicesStayValid() {
        let body = data(#"{"items":[{"a":1},{"a":2},{"a":3}],"keep":true}"#)
        let out = ResponseRewriteEngine.apply([rewrite("items[*]", .removeKey)], to: body)

        XCTAssertEqual(out.report.entries[0].matched, 3)
        XCTAssertEqual(out.report.entries[0].changed, 3, "Forward removal would shift indices and lose one")
        XCTAssertEqual((value(out.data, "items") as? [Any])?.count, 0)
        XCTAssertEqual(value(out.data, "keep") as? Bool, true)
    }

    func testRemovingEveryTokenAnywhere() {
        let body = data(#"{"a":{"token":"x"},"b":[{"token":"y"},{"id":1}]}"#)
        let out = ResponseRewriteEngine.apply([rewrite("**.token", .removeKey)], to: body)
        XCTAssertEqual(out.report.changedCount, 2)
        XCTAssertNil(value(out.data, "a.token"))
        XCTAssertNil(value(out.data, "b[0].token"))
        XCTAssertEqual(value(out.data, "b[1].id") as? Int, 1)
    }

    // MARK: - setValue keeps the type

    func testSetValuePreservesTheExistingJSONType() {
        let body = data(#"{"n":42,"s":"text","b":true}"#)
        let rewrites = [rewrite("n", .setValue("7")),
                        rewrite("s", .setValue("7")),
                        rewrite("b", .setValue("false"))]
        let out = ResponseRewriteEngine.apply(rewrites, to: body)

        XCTAssertEqual(JSONValueKind.of(value(out.data, "n")!), .number)
        XCTAssertEqual(value(out.data, "n") as? Int, 7)
        XCTAssertEqual(JSONValueKind.of(value(out.data, "s")!), .string)
        XCTAssertEqual(value(out.data, "s") as? String, "7")
        XCTAssertEqual(JSONValueKind.of(value(out.data, "b")!), .bool)
        XCTAssertEqual(value(out.data, "b") as? Bool, false)
        // "7" written over the number 7 is not a change; over the string it is.
        XCTAssertEqual(out.report.changedCount, 3)
    }

    func testSetValueOnANumberThatIsNotANumberKeepsTheTextInsteadOfWritingZero() {
        let body = data(#"{"n":42}"#)
        let out = ResponseRewriteEngine.apply([rewrite("n", .setValue("N/A"))], to: body)
        XCTAssertEqual(value(out.data, "n") as? String, "N/A",
                       "Writing 0 here would be silent data corruption")
    }

    func testSetValueDoesNotCountANoOp() {
        let body = data(#"{"s":"same"}"#)
        let out = ResponseRewriteEngine.apply([rewrite("s", .setValue("same"))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertEqual(out.report.entries[0].matched, 1)
        XCTAssertEqual(out.report.entries[0].changed, 0)
    }

    func testSetValueOnAContainerNeedsJSON() {
        let body = data(#"{"obj":{"a":1}}"#)
        let bad = ResponseRewriteEngine.apply([rewrite("obj", .setValue("not json"))], to: body)
        XCTAssertEqual(bad.data, body)
        XCTAssertNotNil(bad.report.entries[0].error)

        let good = ResponseRewriteEngine.apply([rewrite("obj", .setValue(#"{"b":2}"#))], to: body)
        XCTAssertEqual(value(good.data, "obj.b") as? Int, 2)
        XCTAssertNil(value(good.data, "obj.a"))
    }

    // MARK: - Composition

    func testRewritesComposeInOrderAndTheOrderMatters() {
        let body = data(#"{"data":{"url":"https://google.com/a"}}"#)
        let first = rewrite("data.url", .replaceHost("b.com"))
        let second = rewrite("data.url", .findReplace(find: "b.com", replace: "c.com", isRegex: false))

        let forward = ResponseRewriteEngine.apply([first, second], to: body)
        XCTAssertEqual(string(forward.data, "data.url"), "https://c.com/a")
        XCTAssertEqual(forward.report.changedCount, 2)
        XCTAssertEqual(forward.report.entries.map { $0.rewriteId }, [first.id, second.id])

        // Reversed, the find has nothing to bite on yet and the host wins.
        let backward = ResponseRewriteEngine.apply([second, first], to: body)
        XCTAssertEqual(string(backward.data, "data.url"), "https://b.com/a")
        XCTAssertEqual(backward.report.changedCount, 1)
    }

    // MARK: - Bodies the engine refuses

    func testNonJSONBodyIsLeftAloneWithAReason() {
        let body = data("<html><body>nope</body></html>")
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertFalse(out.report.didChange)
        XCTAssertTrue(out.report.entries.isEmpty)
        XCTAssertEqual(out.report.skippedReason, "The response body is not JSON, so rewrites were skipped.")
    }

    func testEmptyBodyIsLeftAloneWithAReason() {
        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: Data())
        XCTAssertEqual(out.data, Data())
        XCTAssertNotNil(out.report.skippedReason)
    }

    func testOversizedBodyIsSkippedWithADiscoverableCap() {
        let filler = String(repeating: "x", count: ResponseRewriteEngine.maxBodyBytes)
        let body = data("{\"data\":{\"url\":\"https://google.com/a\"},\"pad\":\"\(filler)\"}")
        XCTAssertGreaterThan(body.count, ResponseRewriteEngine.maxBodyBytes)

        let out = ResponseRewriteEngine.apply([rewrite("data.url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(out.data, body)
        XCTAssertFalse(out.report.didChange)
        XCTAssertTrue(out.report.skippedReason?.contains("MB") == true)
    }

    func testTopLevelArrayBodyIsSupported() {
        let body = data(#"[{"url":"https://google.com/1"},{"url":"https://google.com/2"}]"#)
        let out = ResponseRewriteEngine.apply([rewrite("[*].url", .replaceHost("salla.com"))], to: body)
        XCTAssertEqual(out.report.changedCount, 2)
        XCTAssertEqual(string(out.data, "[0].url"), "https://salla.com/1")
    }

    // MARK: - Preview

    func testPreviewShowsBeforeAndAfterInDocumentOrder() {
        let body = data(#"{"items":[{"url":"https://google.com/1"},{"url":"https://google.com/2"}]}"#)
        let rows = ResponseRewriteEngine.preview(rewrite("items[*].url", .replaceHost("salla.com")),
                                                 on: body, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].path, "root.items[0].url")
        XCTAssertEqual(rows[0].before, "https://google.com/1")
        XCTAssertEqual(rows[0].after, "https://salla.com/1")
        XCTAssertEqual(rows[1].after, "https://salla.com/2")
    }

    func testPreviewIsCappedAndDoesNotMutate() {
        let body = data(#"{"items":[{"url":"https://google.com/1"},{"url":"https://google.com/2"}]}"#)
        let rows = ResponseRewriteEngine.preview(rewrite("items[*].url", .replaceHost("salla.com")),
                                                 on: body, limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(string(body, "items[0].url"), "https://google.com/1", "preview must not touch the body")
    }

    func testPreviewExplainsValuesItCannotRewrite() {
        let body = data(#"{"url":"not a url"}"#)
        let rows = ResponseRewriteEngine.preview(rewrite("url", .replaceHost("salla.com")), on: body, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].before, "not a url")
        XCTAssertTrue(rows[0].after.contains("value is not a URL"))
    }

    func testPreviewOfARemoveAndOfAnEmptyMatch() {
        let body = data(#"{"data":{"token":"secret"}}"#)
        XCTAssertEqual(ResponseRewriteEngine.preview(rewrite("data.token", .removeKey), on: body, limit: 5)[0].after,
                       "(removed)")
        XCTAssertTrue(ResponseRewriteEngine.preview(rewrite("data.nope", .removeKey), on: body, limit: 5).isEmpty,
                      "An empty preview is how the editor says 'this matches nothing'")
        XCTAssertTrue(ResponseRewriteEngine.preview(rewrite("data..token", .removeKey), on: body, limit: 5).isEmpty)
    }

    // MARK: - Model

    func testDisplayNameDescribesItselfWhenUnnamed() {
        XCTAssertEqual(ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com")).displayName,
                       "data.url -> salla.com")
        XCTAssertEqual(ResponseRewrite(pattern: "data.n", action: .setValue("7")).displayName, "data.n = 7")
        XCTAssertEqual(ResponseRewrite(pattern: "data.token", action: .removeKey).displayName,
                       "Remove data.token")
        XCTAssertEqual(ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"),
                                       name: "Point at staging").displayName, "Point at staging")
    }

    func testRewritesSurviveARuleRoundTrip() throws {
        var rule = InterceptRule(matchEndpoint: "/api/orders")
        rule.responseRewrites = [
            rewrite("data.url", .replaceHost("salla.com")),
            rewrite("data.items[*].price", .setValue("0")),
            rewrite("msg", .findReplace(find: "a", replace: "b", isRegex: true)),
            rewrite("data.token", .removeKey, enabled: false)
        ]
        let decoded = try JSONDecoder().decode(InterceptRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded.responseRewrites, rule.responseRewrites)
        XCTAssertTrue(decoded.hasActiveResponseRewrites)
    }

    func testARuleSavedBeforeThisFeatureStillDecodes() throws {
        let legacy = """
        {"id":"abc","matchEndpoint":"/api/orders","isBlocked":false,
         "headerOverrides":[],"queryParamOverrides":[],
         "removedHeaderKeys":[],"removedQueryParamKeys":[],
         "isEnabled":true,"createdAt":700000000}
        """
        let rule = try JSONDecoder().decode(InterceptRule.self, from: Data(legacy.utf8))
        XCTAssertEqual(rule.responseRewrites, [])
        XCTAssertFalse(rule.hasActiveResponseRewrites)
        XCTAssertEqual(rule.matchEndpoint, "/api/orders")
    }

    func testAnUnknownActionDropsOneRewriteNotTheWholeRule() throws {
        let json = """
        {"id":"abc","matchEndpoint":"/api/orders","isBlocked":false,
         "headerOverrides":[],"queryParamOverrides":[],
         "removedHeaderKeys":[],"removedQueryParamKeys":[],
         "isEnabled":true,"createdAt":700000000,
         "responseRewrites":[
           {"id":"1","isEnabled":true,"pattern":"data.url","action":{"type":"replaceHost","value":"salla.com"}},
           {"id":"2","isEnabled":true,"pattern":"data.x","action":{"type":"teleport","value":"???"}}
         ]}
        """
        let rule = try JSONDecoder().decode(InterceptRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.responseRewrites.count, 1, "The rule and its other rewrites survive")
        XCTAssertEqual(rule.responseRewrites.first?.id, "1")
        XCTAssertEqual(rule.responseRewrites.first?.action, .replaceHost("salla.com"))
    }
}
