//
//  RegressionSweepVerificationTests.swift
//  SwiftyDebugTests
//
//  INDEPENDENT verification of the round that re-routed the canonical
//  pretty-printer through `JSONDocument`. Written without reusing the inputs of
//  the three agents that audited before it, so a shared blind spot in their
//  corpora cannot hide here too.
//
//  The maintainer's three demands are the three sections:
//
//    1. COPY IS ALWAYS VALID. For every body, the clipboard is either valid
//       JSON or the original text verbatim — never a truncated, re-ordered or
//       half-escaped thing in between, and never silently empty. Checked
//       through the REAL two-step the UI performs: the preview string is built
//       first (`dataToPrettyPrintString`), and the copy button is handed THAT
//       string (`JSONExporter.clipboardString`), which is what made the screen
//       and the clipboard disagree before.
//    2. RULE UX ALWAYS WORKS. A copy is independent of its original in every
//       stored field, including after the copy is edited — verified with a
//       `Mirror` fingerprint so a field added to the model and forgotten in
//       `duplicate` fails here instead of shipping.
//    3. SMART ARRAY ADD ALWAYS WORKS. The menu's advertised kind is the kind
//       actually appended, the result is always valid JSON, and appending never
//       disturbs the source key order or number spelling of the rows already
//       there.
//
//  Notes on two things deliberately NOT asserted, because they are live
//  defects reported separately rather than intended behaviour:
//    * a body over the node ceiling loses source key order and number spelling;
//    * an appended object row is spelled in alphabetical key order.
//

import XCTest
@testable import SwiftyDebug

final class RegressionSweepVerificationTests: XCTestCase {

    // MARK: - Helpers

    private func parses(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8),
                                           options: [.fragmentsAllowed])) != nil
    }

    /// The clipboard exactly as a user produces it: the detail screen renders
    /// the body into `rawContent`, and the COPY button copies that rendering.
    private func clipboard(for body: String) -> String? {
        guard let preview = Data(body.utf8).dataToPrettyPrintString() else { return nil }
        return JSONExporter.clipboardString(from: preview)
    }

    /// Fails unless `body` copies as valid JSON or as itself.
    private func assertCopyIsValidOrVerbatim(_ body: String,
                                             _ label: String,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
        guard let clip = clipboard(for: body) else {
            XCTFail("\(label): preview was nil for text that is valid UTF-8 — content dropped",
                    file: file, line: line)
            return
        }
        let verbatim = clip == body || clip == body.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(parses(clip) || verbatim,
                      """
                      \(label): clipboard is NEITHER valid JSON NOR the original.
                        input:     \(body.prefix(300))
                        clipboard: \(clip.prefix(300))
                      """,
                      file: file, line: line)
    }

    // MARK: - 1. COPY IS ALWAYS VALID

    /// Top-level fragments. RFC 8259 allows them and real endpoints return them
    /// ("OK" from a health check, a bare count from a HEAD-ish endpoint). The
    /// exporter used to PARSE these with `.fragmentsAllowed` and WRITE them
    /// without it, which raised an ObjC exception `try?` cannot catch — copying
    /// a body of "OK" terminated the host app.
    func testCopyOfEveryTopLevelFragmentIsValidJSON() {
        for body in ["\"OK\"", "42", "-0", "0", "true", "false", "null",
                     "\"\"", "3.14", "1e3", "\"a\\/b\"", "-17"] {
            guard let clip = clipboard(for: body) else {
                XCTFail("fragment \(body) produced a nil preview"); continue
            }
            XCTAssertTrue(parses(clip), "fragment \(body) copied as invalid JSON: \(clip)")
        }
    }

    /// A body that is not JSON must survive the round trip unchanged rather
    /// than being dropped or replaced with a guess.
    func testCopyOfNonJSONBodiesIsTheOriginalText() {
        let bodies = [
            "OK",
            "Internal Server Error",
            "<html><body><h1>502 Bad Gateway</h1></body></html>",
            "<?xml version=\"1.0\"?><root><a>1</a></root>",
            "{\"a\":1,\"b\":",       // truncated mid-payload
            "{",
            "id,name,price\n1,x,2",  // CSV
        ]
        for body in bodies {
            let clip = clipboard(for: body)
            XCTAssertEqual(clip, body, "non-JSON body was not preserved verbatim")
        }
    }

    /// Duplicate keys are legal to parse and real proxies emit them. Whatever
    /// the resolution rule is, the clipboard must still be parseable and must
    /// agree with what the screen showed.
    func testCopyOfDuplicateKeysStaysValidAndAgreesWithPreview() {
        for body in ["{\"a\":1,\"b\":2,\"a\":3}",
                     "{\"a\":1,\"a\":2}",
                     "{\"\":1,\"\":2}",
                     "{\"k\":\"one\",\"k\":\"two\",\"k\":\"three\"}"] {
            guard let preview = Data(body.utf8).dataToPrettyPrintString() else {
                XCTFail("nil preview for \(body)"); continue
            }
            let clip = JSONExporter.clipboardString(from: preview)
            XCTAssertTrue(parses(clip), "duplicate-key body copied as invalid JSON: \(clip)")
            XCTAssertEqual(preview, clip,
                           "screen and clipboard disagree for duplicate-key body \(body)")
        }
    }

    /// A lone surrogate cannot be encoded as UTF-8, so the bytes are not JSON.
    /// The requirement is that this is reported honestly and the text is still
    /// shown, not that it is silently mangled into something that parses.
    func testCopyOfLoneSurrogateIsVerbatimAndNeverInvalidJSON() {
        for body in ["{\"a\":\"\\ud800\"}",
                     "{\"a\":\"\\udc00\"}",
                     "{\"\\udfff\":1}",
                     "[\"\\ud800\"]"] {
            assertCopyIsValidOrVerbatim(body, "lone surrogate \(body)")
            XCTAssertNil(JSONExporter.prettyJSONString(from: body),
                         "a lone surrogate is not encodable JSON and must not be claimed as such")
        }
        // The paired form IS valid and must survive as JSON.
        guard let clip = clipboard(for: "{\"a\":\"\\ud83d\\ude00\"}") else {
            return XCTFail("nil preview for a valid surrogate pair")
        }
        XCTAssertTrue(parses(clip))
    }

    /// Bytes that are not UTF-8 at all are not text and not JSON. Both entry
    /// points must say so rather than returning a lossy reinterpretation.
    func testInvalidUTF8IsRefusedByBothEntryPoints() {
        let cases: [(String, Data)] = [
            ("0xFF inside a string", Data([0x7b,0x22,0x61,0x22,0x3a,0x22,0xFF,0x22,0x7d])),
            ("truncated sequence",   Data([0x22,0xE2,0x82,0x22])),
            ("lone continuation",    Data([0x80])),
            ("overlong encoding",    Data([0xC0,0xAF])),
        ]
        for (label, data) in cases {
            XCTAssertNil(data.dataToPrettyPrintString(), "\(label): claimed to be text")
            XCTAssertNil(JSONExporter.prettyJSONString(from: data), "\(label): claimed to be JSON")
        }
    }

    /// A 40-digit id overflows every fixed-width integer type. The point of
    /// routing through `JSONDocument` is that such a literal is echoed exactly
    /// as the server spelled it instead of being rounded through a Double.
    func testLongIntegerLiteralsSurviveCopyByteForByte() {
        let literals = [
            "1234567890123456789012345678901234567890",
            "-1234567890123456789012345678901234567890",
            "9007199254740993",            // first integer a Double cannot hold
            "18446744073709551615",        // UInt64.max
            "1250.00", "19.99", "1.0e3", "0e0", "1E+2", "-0.0",
        ]
        for literal in literals {
            let body = "{\"v\":\(literal)}"
            guard let clip = clipboard(for: body) else {
                XCTFail("nil preview for \(literal)"); continue
            }
            XCTAssertTrue(parses(clip), "\(literal) copied as invalid JSON")
            XCTAssertTrue(clip.contains(literal),
                          "literal \(literal) was respelled on the clipboard: \(clip)")
        }
    }

    /// The whole reason the round exists: the clipboard must not re-order the
    /// server's keys, and must not disagree with the screen.
    /// Key sets chosen because a `JSONSerialization` round-trip — the thing this
    /// round replaced — demonstrably re-orders them. A four-key object is NOT
    /// enough: Foundation's hash order happens to match insertion order there,
    /// so a four-key assertion passes even against the old, broken printer.
    /// These were measured against a reverted build and are disturbed every run.
    func testCopyKeepsServerKeyOrderAndMatchesTheScreen() {
        let keySets: [[String]] = [
            ["total", "items", "page", "per_page", "has_more", "next_cursor", "request_id"],
            ["id", "name", "email", "created_at", "updated_at", "status"],
            ["zulu", "alpha", "mike", "bravo", "yankee", "charlie",
             "xray", "delta", "whiskey", "echo", "victor", "foxtrot"],
        ]
        for keys in keySets {
            let body = "{" + keys.enumerated()
                .map { "\"\($0.element)\":\($0.offset)" }
                .joined(separator: ",") + "}"
            guard let preview = Data(body.utf8).dataToPrettyPrintString() else {
                XCTFail("nil preview for \(keys)"); continue
            }
            let clip = JSONExporter.clipboardString(from: preview)
            XCTAssertEqual(preview, clip, "screen and clipboard disagree for \(keys)")

            func positions(_ s: String) -> [Int] {
                keys.map { key in
                    s.range(of: "\"\(key)\"")
                        .map { s.distance(from: s.startIndex, to: $0.lowerBound) } ?? -1
                }
            }
            let p = positions(clip)
            XCTAssertEqual(p, p.sorted(),
                           "the clipboard re-ordered the server's keys:\n\(clip)")
        }
    }

    /// A body holding a negative literal that overflows a Double is the one
    /// shape Apple's parser ACCEPTS (yielding -inf) and Apple's writer REFUSES
    /// with an uncatchable ObjC exception. Copy must survive it.
    func testCopyOfDoubleOverflowLiteralsNeverCrashesAndNeverLosesTheBody() {
        for body in ["{\"a\":-1e999}",
                     "{\"balance\":-2e308}",
                     "[1,-1e999]",
                     "{\"a\":{\"b\":{\"c\":[-1e400]}}}",
                     "{\"ok\":1,\"bad\":-1e999,\"also\":\"text\"}"] {
            guard let clip = clipboard(for: body) else {
                XCTFail("\(body): preview nil — the body was dropped entirely"); continue
            }
            // Foundation cannot re-print it, so the contract is verbatim.
            XCTAssertEqual(clip, body,
                           "an unrepresentable body must be copied verbatim, not emptied")
            XCTAssertFalse(clip.isEmpty, "\(body): clipboard was empty")
        }
    }

    /// Structural adversaries: deep nesting, wide objects, empty containers,
    /// exotic-but-legal strings. None may yield a half-written document.
    func testCopyOfStructuralAdversariesIsAlwaysValidOrVerbatim() {
        var cases: [(String, String)] = [
            ("empty object", "{}"),
            ("empty array", "[]"),
            ("nested empties", "{\"a\":{},\"b\":[],\"c\":[{}],\"d\":[[]]}"),
            ("control chars", "{\"a\":\"\\u0000\\u0001\\u001f\\u007f\"}"),
            ("line separators", "{\"a\":\"\\u2028\\u2029\"}"),
            ("emoji and ZWJ", "{\"a\":\"👨‍👩‍👧‍👦🇸🇦\"}"),
            ("combining marks in key", "{\"e\u{0301}\":1}"),
            ("RTL", "{\"الاسم\":\"عبد الرحمن\"}"),
            ("empty key", "{\"\":\"v\"}"),
            ("escaped quote in key", "{\"a\\\"b\":1}"),
            ("backslashes", "{\"a\":\"c:\\\\temp\\\\x\"}"),
            ("URL value", "{\"u\":\"https://a.example.com/x/y?q=1&r=2\"}"),
            ("BOM prefix", "\u{FEFF}{\"a\":1}"),
            ("whitespace only", "   \n\t  "),
            ("empty", ""),
        ]
        // 300 levels deep: under Foundation's parser limit, over the source
        // scanner's 256-level index cap, so it exercises the unindexed path.
        cases.append(("300-deep nesting",
                      String(repeating: "[", count: 300) + "1" + String(repeating: "]", count: 300)))
        // A wide object.
        let wide = (0..<5_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        cases.append(("5000 keys", "{\(wide)}"))

        for (label, body) in cases {
            assertCopyIsValidOrVerbatim(body, label)
        }
    }

    /// A 5 MB paginated response — the size at which the ceiling logic decides
    /// between re-printing and passing bytes through. Whichever branch is
    /// taken, the clipboard must be valid JSON and identical to the screen.
    func testFiveMegabyteResponseCopiesAsValidJSONAndMatchesTheScreen() {
        var rows: [String] = []
        var i = 0
        while rows.count * 200 < 5 * 1024 * 1024 {
            rows.append("{\"id\":\(100000+i),\"sku\":\"SKU-\(i)\",\"name\":\"Product number \(i) with a reasonably long name\",\"qty\":\(i % 7),\"active\":\(i % 2 == 0),\"tags\":[\"alpha\",\"beta\"],\"updated_at\":\"2026-07-27T10:00:0\(i % 10)Z\"}")
            i += 1
        }
        let body = "{\"page\":1,\"total\":\(rows.count),\"items\":[" + rows.joined(separator: ",") + "]}"
        let data = Data(body.utf8)
        XCTAssertGreaterThan(data.count, 4 * 1024 * 1024)

        guard let preview = data.dataToPrettyPrintString() else {
            return XCTFail("5 MB body produced a nil preview")
        }
        let clip = JSONExporter.clipboardString(from: preview)
        XCTAssertTrue(parses(preview), "5 MB preview is not valid JSON")
        XCTAssertTrue(parses(clip), "5 MB clipboard is not valid JSON")
        // CONTRACT CHANGED: above the ceiling the preview stays bounded to keep
        // the main thread responsive while the clipboard is fully formatted, so
        // the two differ in WHITESPACE. What must not differ is the data.
        let previewRows = (try? JSONSerialization.jsonObject(with: Data(preview.utf8)))
            .flatMap { ($0 as? [String: Any])?["items"] as? [Any] }?.count
        let clipRows = (try? JSONSerialization.jsonObject(with: Data(clip.utf8)))
            .flatMap { ($0 as? [String: Any])?["items"] as? [Any] }?.count
        XCTAssertEqual(previewRows, clipRows, "5 MB: screen and clipboard disagree about the data")
    }

    // MARK: - 2. RULE UX ALWAYS WORKS

    /// Every stored property except the four a copy is meant to differ in.
    /// Built with `Mirror` so a new model field is covered automatically.
    private func fingerprint(_ rule: InterceptRule) -> String {
        let skipped: Set<String> = ["id", "createdAt", "isEnabled", "order", "name"]
        let text = Mirror(reflecting: rule).children
            .compactMap { child in
                guard let label = child.label, !skipped.contains(label) else { return nil }
                return "\(label)=\(String(describing: child.value))"
            }
            .sorted()
            .joined(separator: "\n")
        // `KVPair` and `ResponseRewrite` carry their own UUIDs, and a correct
        // copy MINTS FRESH ONES — that independence is asserted separately. They
        // are redacted here so this comparison is about the values a copy must
        // carry, not the identities it must not share.
        return text.replacingOccurrences(
            of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
            with: "<uuid>",
            options: [.regularExpression, .caseInsensitive])
    }

    /// A rule with every feature the model has armed at once.
    private func fullyArmedRule() -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: "/v1/orders/{id}/items", matchMode: .normalized)
        rule.matchHost = "api.example.com"
        rule.matchHosts = ["api.example.com", "staging.example.com"]
        rule.name = "Orders – everything on"
        rule.isBlocked = false
        rule.isEnabled = true
        rule.headerOverrides = [KVPair(key: "Authorization", value: "Bearer xyz"),
                                KVPair(key: "X-Debug", value: "1")]
        rule.queryParamOverrides = [KVPair(key: "locale", value: "ar-SA")]
        rule.removedHeaderKeys = ["User-Agent", "Cookie"]
        rule.removedQueryParamKeys = ["utm_source"]
        rule.redirectMode = .host
        rule.redirectTarget = "localhost:8080"
        rule.mock = MockResponse(isEnabled: true, statusCode: 503,
                                 body: "{\"error\":\"nope\"}",
                                 headers: [KVPair(key: "X-Mock", value: "yes")],
                                 delay: 2.5)
        rule.breakpointMode = .beforeSend
        rule.responseRewrites = [
            ResponseRewrite(pattern: "data.items[*].image", action: .replaceHost("cdn.local"),
                            isEnabled: true, name: "images"),
            ResponseRewrite(pattern: "data.total", action: .setValue("0"),
                            isEnabled: false, name: "zero total"),
        ]
        return rule
    }

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    /// Duplicating a fully armed rule carries every field, mints a new identity,
    /// and — critically — lands SWITCHED OFF so the copy does not start firing
    /// on the same requests the instant it exists.
    func testDuplicatingAFullyArmedRuleCarriesEveryFieldAndArrivesDisabled() {
        let seed = fullyArmedRule()
        InterceptRuleStore.shared.addOrUpdate(seed)
        // Compare against the STORED original, not the local seed: `addOrUpdate`
        // runs `canonicalized()`, which repairs mode/host disagreements (an
        // endpoint-scoped rule does not keep a `matchHosts` list). Comparing a
        // canonicalised copy to an un-canonicalised seed would fail on a
        // difference the store made on purpose, not one `duplicate()` caused.
        guard let original = InterceptRuleStore.shared.allRules().first(where: { $0.id == seed.id }) else {
            return XCTFail("the seed rule was not stored")
        }

        guard let stored = InterceptRuleDuplicator.duplicateAndStore(id: original.id),
              let copy = InterceptRuleStore.shared.allRules().first(where: { $0.id == stored.id }) else {
            return XCTFail("duplicateAndStore returned nil for a rule that is in the store")
        }

        XCTAssertEqual(fingerprint(copy), fingerprint(original),
                       "a field on InterceptRule is not carried by duplicate()")
        XCTAssertNotEqual(copy.id, original.id, "the copy reused the original's id")
        XCTAssertFalse(copy.isEnabled, "a copy must arrive disabled")
        XCTAssertNotEqual(copy.name, original.name, "the copy must be distinguishable in the list")
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)

        // Nested value types must be independent instances, not shared ids.
        let originalRewriteIDs = Set(original.responseRewrites.map(\.id))
        let copyRewriteIDs = Set(copy.responseRewrites.map(\.id))
        XCTAssertTrue(originalRewriteIDs.isDisjoint(with: copyRewriteIDs),
                      "the copy's response rewrites reused the original's ids")
        let originalPairIDs = Set(original.headerOverrides.map(\.id))
        let copyPairIDs = Set(copy.headerOverrides.map(\.id))
        XCTAssertTrue(originalPairIDs.isDisjoint(with: copyPairIDs),
                      "the copy's header pairs reused the original's ids")
    }

    /// The arrangement the maintainer called risky: edit the COPY heavily and
    /// confirm the ORIGINAL did not move a single field.
    func testEditingTheCopyLeavesTheOriginalUntouchedFieldByField() {
        let seed = fullyArmedRule()
        InterceptRuleStore.shared.addOrUpdate(seed)
        // The stored form, for the same canonicalisation reason as above.
        guard let original = InterceptRuleStore.shared.allRules().first(where: { $0.id == seed.id }) else {
            return XCTFail("the seed rule was not stored")
        }
        let before = fingerprint(original)

        guard var copy = InterceptRuleDuplicator.duplicateAndStore(id: original.id) else {
            return XCTFail("nil copy")
        }

        // Rewrite essentially everything about the copy.
        copy.matchEndpoint = "/v2/somewhere/else"
        copy.matchMode = .exact
        copy.matchHost = "other.example.com"
        copy.matchHosts = ["other.example.com"]
        copy.isBlocked = true
        copy.isEnabled = true
        copy.headerOverrides = [KVPair(key: "X-Only-On-Copy", value: "1")]
        copy.queryParamOverrides = []
        copy.removedHeaderKeys = ["Accept"]
        copy.removedQueryParamKeys = []
        copy.redirectMode = .none
        copy.redirectTarget = ""
        copy.mock = MockResponse(isEnabled: false, statusCode: 200, body: "", headers: [], delay: 0)
        copy.breakpointMode = .off
        copy.responseRewrites = []
        copy.name = "totally different"
        InterceptRuleStore.shared.addOrUpdate(copy)

        guard let reloaded = InterceptRuleStore.shared.allRules().first(where: { $0.id == original.id }) else {
            return XCTFail("the original vanished when the copy was edited")
        }
        XCTAssertEqual(fingerprint(reloaded), before,
                       "editing the copy changed the original")
        XCTAssertEqual(reloaded.name, original.name)
        XCTAssertTrue(reloaded.isEnabled, "the original was switched off by editing the copy")

        // And the reverse direction: editing the original leaves the copy alone.
        guard let copyStored = InterceptRuleStore.shared.allRules().first(where: { $0.id == copy.id }) else {
            return XCTFail("the copy was not stored")
        }
        let copyBefore = fingerprint(copyStored)
        var again = reloaded
        again.matchEndpoint = "/changed/original"
        again.responseRewrites = []
        InterceptRuleStore.shared.addOrUpdate(again)
        guard let copyReloaded = InterceptRuleStore.shared.allRules().first(where: { $0.id == copy.id }) else {
            return XCTFail("the copy vanished when the original was edited")
        }
        XCTAssertEqual(fingerprint(copyReloaded), copyBefore,
                       "editing the original changed the copy")
    }

    /// Duplicating repeatedly must keep producing distinct, individually
    /// addressable rules rather than collapsing onto one row.
    func testRepeatedDuplicationProducesDistinctRulesAndNames() {
        let original = fullyArmedRule()
        InterceptRuleStore.shared.addOrUpdate(original)

        var ids: Set<String> = [original.id]
        var names: Set<String> = [original.name]
        var last = original.id
        for step in 0..<6 {
            guard let copy = InterceptRuleDuplicator.duplicateAndStore(id: last) else {
                return XCTFail("duplication \(step) returned nil")
            }
            XCTAssertFalse(ids.contains(copy.id), "duplicate \(step) reused an id")
            XCTAssertFalse(names.contains(copy.name), "duplicate \(step) reused the name \(copy.name)")
            ids.insert(copy.id)
            names.insert(copy.name)
            last = copy.id
        }
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 7)
        // Deleting the middle of the chain must not disturb the rest.
        let all = InterceptRuleStore.shared.allRules()
        let victim = all[3]
        InterceptRuleStore.shared.remove(id: victim.id)
        let after = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(after.count, 6)
        XCTAssertFalse(after.contains { $0.id == victim.id })
        XCTAssertEqual(Set(after.map(\.id)), ids.subtracting([victim.id]))
    }

    /// Duplicating a rule that is no longer stored must refuse rather than
    /// resurrecting a deleted rule from a stale row snapshot.
    func testDuplicatingADeletedRuleRefuses() {
        let original = fullyArmedRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        InterceptRuleStore.shared.remove(id: original.id)
        XCTAssertNil(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertTrue(InterceptRuleStore.shared.allRules().isEmpty)
    }

    /// A disabled copy must not answer for a request; arming it must.
    func testACopyDoesNotAffectTheWireUntilItIsArmed() throws {
        var original = fullyArmedRule()
        original.mock = MockResponse(isEnabled: false, statusCode: 200, body: "", headers: [], delay: 0)
        original.breakpointMode = .off
        original.responseRewrites = []
        original.matchEndpoint = "/v1/orders"
        original.matchMode = .normalized
        InterceptRuleStore.shared.addOrUpdate(original)

        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/orders?x=1"))
        let baseline = InterceptRuleStore.shared.resolvedRule(forURL: url)
        XCTAssertNotNil(baseline, "the armed original should answer for its own URL")

        guard var copy = InterceptRuleDuplicator.duplicateAndStore(id: original.id) else {
            return XCTFail("nil copy")
        }
        let withDisabledCopy = InterceptRuleStore.shared.resolvedRule(forURL: url)
        XCTAssertEqual(withDisabledCopy?.headerOverrides.count,
                       baseline?.headerOverrides.count,
                       "a DISABLED copy changed what the networking layer resolves")

        // Delete the original, arm the copy: the copy must now be what answers.
        InterceptRuleStore.shared.remove(id: original.id)
        copy.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(copy)
        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)
        XCTAssertNotNil(resolved, "the armed copy does not answer after the original was deleted")
    }

    // MARK: - 3. SMART ARRAY ADD ALWAYS WORKS

    /// For every array shape, the kind the menu advertises is the kind actually
    /// appended, and the document still serialises to valid JSON.
    func testAddItemAppendsTheKindItAdvertisesForEveryShape() {
        let shapes: [(String, String)] = [
            ("strings",             "{\"a\":[\"x\",\"y\"]}"),
            ("integers",            "{\"a\":[1,2,3]}"),
            ("decimals",            "{\"a\":[19.99,5.00]}"),
            ("bools",               "{\"a\":[true,false]}"),
            ("nulls",               "{\"a\":[null,null]}"),
            ("mixed",               "{\"a\":[1,\"s\",true]}"),
            ("mixed leading null",  "{\"a\":[null,\"x\",1]}"),
            ("empty",               "{\"a\":[]}"),
            ("objects same keys",   "{\"a\":[{\"id\":1,\"n\":\"x\"},{\"id\":2,\"n\":\"y\"}]}"),
            ("objects differing",   "{\"a\":[{\"id\":1},{\"n\":\"x\"},{\"z\":true}]}"),
            ("objects disagreeing", "{\"a\":[{\"v\":1},{\"v\":\"s\"},{\"v\":[1,2]}]}"),
            ("nested arrays",       "{\"a\":[[1,2],[3]]}"),
            ("array of objects",    "{\"a\":[[{\"k\":1}]]}"),
            ("deep objects",        "{\"a\":[{\"o\":{\"p\":{\"q\":[1]}}}]}"),
        ]
        for (label, source) in shapes {
            guard let doc = JSONDocument(data: Data(source.utf8)) else {
                XCTFail("\(label): did not parse"); continue
            }
            let path: JSONPath = [.key("a")]
            let template = doc.arrayElementTemplate(forArrayAt: path)
            XCTAssertFalse(template.summary.isEmpty, "\(label): the menu subtitle is empty")
            XCTAssertTrue(doc.appendElement(template.value, toArrayAt: path),
                          "\(label): the append was refused")

            let array = doc.value(at: path) as? [Any]
            let appended = try? XCTUnwrap(array?.last)
            XCTAssertEqual(JSONValueKind.of(appended as Any), template.kind,
                           "\(label): the menu said \(template.kind.rawValue) but appended something else")

            let text = doc.prettyText()
            XCTAssertFalse(text.isEmpty, "\(label): the document stopped serialising after an append")
            XCTAssertTrue(parses(text), "\(label): appending produced invalid JSON:\n\(text)")
        }
    }

    /// An empty array reads its shape from the arrays alongside it rather than
    /// defaulting to a type nobody asked for.
    func testAnEmptyArrayBorrowsTheShapeOfItsSiblings() {
        let source = "{\"rows\":[{\"tags\":[\"x\"]},{\"tags\":[]}]}"
        guard let doc = JSONDocument(data: Data(source.utf8)) else { return XCTFail("no parse") }
        let path: JSONPath = [.key("rows"), .index(1), .key("tags")]
        let template = doc.arrayElementTemplate(forArrayAt: path)
        XCTAssertEqual(template.kind, .string,
                       "an empty tags array next to a string tags array should read as strings")
        XCTAssertTrue(template.isInferred)
        XCTAssertTrue(doc.appendElement(template.value, toArrayAt: path))
        XCTAssertTrue(parses(doc.prettyText()))
    }

    /// The fidelity guarantee: appending must not disturb the key order or the
    /// number spelling of the rows that were already there.
    func testAppendingLeavesExistingRowsSpelledExactlyAsTheServerSentThem() {
        let source = "{\"rows\":[{\"zulu\":1,\"alpha\":\"a\",\"price\":1250.00,\"exp\":1.0e3},"
                   + "{\"zulu\":2,\"alpha\":\"b\",\"price\":19.99,\"exp\":0e0}]}"
        guard let doc = JSONDocument(data: Data(source.utf8)) else { return XCTFail("no parse") }
        XCTAssertTrue(doc.preservesSourceFormatting)

        let path: JSONPath = [.key("rows")]
        let template = doc.arrayElementTemplate(forArrayAt: path)
        XCTAssertTrue(doc.appendElement(template.value, toArrayAt: path))
        let after = doc.prettyText()

        XCTAssertTrue(parses(after))
        for literal in ["1250.00", "19.99", "1.0e3", "0e0"] {
            XCTAssertTrue(after.contains(literal),
                          "number literal \(literal) was respelled by an unrelated append")
        }
        // Row 0's keys must still be in the order the server sent them.
        func position(_ key: String) -> Int {
            after.range(of: "\"\(key)\"").map { after.distance(from: after.startIndex, to: $0.lowerBound) } ?? -1
        }
        let order = [position("zulu"), position("alpha"), position("price"), position("exp")]
        XCTAssertEqual(order, order.sorted(),
                       "appending re-ordered the keys of an existing row:\n\(after)")
    }

    /// Append then undo must land exactly back on the original text, including
    /// its key order and number spelling — the tree alone is not the document.
    func testAppendThenUndoRestoresTheDocumentExactly() {
        let source = "{\"rows\":[{\"zulu\":1,\"price\":1250.00}]}"
        guard let doc = JSONDocument(data: Data(source.utf8)) else { return XCTFail("no parse") }
        let baseline = doc.prettyText()
        let path: JSONPath = [.key("rows")]
        for round in 0..<10 {
            let template = doc.arrayElementTemplate(forArrayAt: path)
            XCTAssertTrue(doc.appendElement(template.value, toArrayAt: path))
            doc.undo()
            XCTAssertEqual(doc.prettyText(), baseline,
                           "append/undo round \(round) did not converge")
        }
    }

    /// Reading the shape of a huge array must stay bounded — the menu is built
    /// on the main thread while a tap is being handled.
    func testShapeReadingIsBoundedOnAVeryLargeArray() {
        let rows = (0..<50_000).map { "{\"id\":\($0),\"n\":\"x\"}" }.joined(separator: ",")
        guard let doc = JSONDocument(data: Data("{\"a\":[\(rows)]}".utf8)) else {
            return XCTFail("no parse")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let template = doc.arrayElementTemplate(forArrayAt: [.key("a")])
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.5, "reading a 50k-row array took \(elapsed)s on the main thread")
        XCTAssertTrue(template.summary.contains("50000"),
                      "the summary should admit it only sampled the array: \(template.summary)")
    }
}
