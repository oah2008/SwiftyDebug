//
//  InterceptRuleDecodingResilienceTests.swift
//  SwiftyDebug
//
//  Covers the "one bad rule must not delete every rule on the device" fix.
//
//  The bug: `decodeIfPresent` THROWS on an unknown enum raw value rather than
//  returning nil, several fields used a hard `try c.decode`, and
//  `loadFromDisk()` wrapped the WHOLE array in `try?`. One unreadable rule
//  therefore produced nil -> an empty in-memory store -> the next `addOrUpdate`
//  wrote that emptiness over rules.json. Everything, gone.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleDecodingResilienceTests: XCTestCase {

    // MARK: - Helpers

    /// Decodes the way `InterceptRuleStore` reads our own `rules.json`.
    private func decodeRule(_ json: String) -> InterceptRule? {
        let decoder = JSONDecoder()
        decoder.userInfo[.swiftyDebugLenientRuleDecoding] = true
        return try? decoder.decode(InterceptRule.self, from: Data(json.utf8))
    }

    /// Decodes the way `RuleTransfer` reads a teammate's exported file.
    private func decodeRuleStrictly(_ json: String) throws -> InterceptRule {
        try JSONDecoder().decode(InterceptRule.self, from: Data(json.utf8))
    }

    /// A valid rule document. `extra` adds fields — deliberately no key it
    /// already contains, so nothing here depends on duplicate-key behaviour.
    private func ruleJSON(id: String = "id-1", extra: String = "") -> String {
        """
        {
          "id": "\(id)",
          "matchEndpoint": "/api/users",
          "isBlocked": false,
          "isEnabled": true,
          "createdAt": 700000000
          \(extra.isEmpty ? "" : ",\(extra)")
        }
        """
    }

    // MARK: - Unknown enum raw values (the proved throw)

    func testUnknownMatchModeFallsBackInsteadOfKillingTheRule() {
        // This is the exact field that had no `try?` guard.
        let json = """
        {
          "id": "x", "matchEndpoint": "/api/thing",
          "matchMode": "regexFromTheFuture",
          "isBlocked": false, "isEnabled": true, "createdAt": 700000000
        }
        """
        let rule = decodeRule(json)
        XCTAssertNotNil(rule, "an unknown matchMode must not destroy the rule")
        XCTAssertEqual(rule?.matchMode, .normalized)
        XCTAssertEqual(rule?.matchEndpoint, "/api/thing")
    }

    func testUnknownRedirectAndBreakpointModesStillFallBack() {
        let rule = decodeRule(ruleJSON(extra: """
        "redirectMode": "quantumTunnel", "breakpointMode": "onTuesdays"
        """))
        XCTAssertEqual(rule?.redirectMode, RedirectMode.none)
        XCTAssertEqual(rule?.breakpointMode, .off)
    }

    // MARK: - Formerly-required fields

    func testMissingIsBlockedIsEnabledAndCreatedAtNoLongerThrow() {
        // All three were hard `try c.decode`.
        let json = """
        { "id": "y", "matchEndpoint": "/api/y" }
        """
        let rule = decodeRule(json)
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.isBlocked, false)
        XCTAssertEqual(rule?.isEnabled, true, "an absent flag means hand-written JSON, which means armed")
        XCTAssertNotNil(rule?.createdAt)
    }

    func testWrongTypedFieldsDegradeFieldByField() {
        let rule = decodeRule(ruleJSON(extra: """
        "order": "seventh", "redirectTarget": 42, "matchHosts": "not-an-array"
        """))
        XCTAssertNotNil(rule, "three unreadable fields must cost three fields, not the rule")
        XCTAssertEqual(rule?.order, 0)
        XCTAssertEqual(rule?.redirectTarget, "")
        XCTAssertEqual(rule?.matchHosts, [])
    }

    func testLegacyNormalizedEndpointKeyStillWorks() {
        let json = """
        { "id": "z", "normalizedEndpoint": "/api/legacy", "isBlocked": false,
          "isEnabled": true, "createdAt": 700000000 }
        """
        XCTAssertEqual(decodeRule(json)?.matchEndpoint, "/api/legacy")
    }

    func testImportStaysStrictSoItCanStillNameTheMissingField() {
        // The two callers want opposite things. An imported file is untrusted
        // input the user can go and fix, and the import preview's whole value is
        // saying WHICH field is missing — so leniency is opt-in, and the local
        // store is the only thing that opts in.
        let json = #"{ "id": "abc", "matchEndpoint": "/api/x" }"#
        XCTAssertThrowsError(try decodeRuleStrictly(json)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected a named missing key, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "isBlocked")
        }
        XCTAssertNotNil(decodeRule(json), "the same document must still load from our own file")
    }

    func testUnknownEnumsAreLenientEvenOnImport() {
        // Leniency for enum raw values is NOT opt-in: an unknown case is a
        // version skew, not a malformed document, and it is the exact throw
        // that used to take whole files down.
        let json = ruleJSON(extra: """
        "matchMode": "regexFromTheFuture", "headerOverrides": [], "queryParamOverrides": [],
        "removedHeaderKeys": [], "removedQueryParamKeys": []
        """)
        XCTAssertEqual(try decodeRuleStrictly(json).matchMode, .normalized)
    }

    func testRuleWithNoIdentityOrNoEndpointIsRejected() {
        // These two are allowed to fail: a rule with no id cannot be toggled or
        // deleted, and one with no endpoint can never match anything.
        XCTAssertNil(decodeRule(#"{ "matchEndpoint": "/api/x" }"#))
        XCTAssertNil(decodeRule(#"{ "id": "no-endpoint" }"#))
    }

    // MARK: - Per-element arrays

    func testKVPairWithNoIdIsGivenOneRatherThanKillingTheRule() {
        let rule = decodeRule(ruleJSON(extra: """
        "headerOverrides": [
          { "id": "a", "key": "X-Good", "value": "1" },
          { "key": "X-No-Id", "value": "2" },
          { "id": "c", "key": "X-Also-Good", "value": "3" }
        ]
        """))
        // The middle pair has no `id`; the synthesized decoder required one and
        // threw, which used to take the whole rule (and then the whole file).
        XCTAssertEqual(rule?.headerOverrides.map { $0.key },
                       ["X-Good", "X-No-Id", "X-Also-Good"])
        XCTAssertEqual(Set(rule?.headerOverrides.map { $0.id } ?? []).count, 3,
                       "the invented id must still be unique")
    }

    func testNonObjectElementIsDroppedWithoutLosingItsSiblings() {
        let rule = decodeRule(ruleJSON(extra: """
        "queryParamOverrides": [
          { "id": "a", "key": "page", "value": "1" },
          "garbage",
          { "id": "c", "key": "limit", "value": "20" }
        ]
        """))
        XCTAssertEqual(rule?.queryParamOverrides.map { $0.key }, ["page", "limit"])
    }

    // MARK: - The store's own array decode (the destructive path)

    func testOneUnreadableRuleDoesNotDiscardTheOthers() {
        let json = """
        [
          \(ruleJSON(id: "keep-1")),
          { "matchEndpoint": "/api/broken", "isBlocked": false },
          \(ruleJSON(id: "keep-2"))
        ]
        """
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data(json.utf8))
        XCTAssertEqual(total, 3, "all three elements must be seen")
        XCTAssertEqual(rules.map { $0.id }, ["keep-1", "keep-2"],
                       "the bad element is skipped; the good ones survive")
    }

    func testEveryRuleUnreadableStillReportsHowManyWerePresent() {
        let json = """
        [ { "nope": 1 }, { "also": 2 } ]
        """
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data(json.utf8))
        XCTAssertTrue(rules.isEmpty)
        XCTAssertEqual(total, 2, "knowing two rules were lost is what makes the backup worth taking")
    }

    func testPayloadThatIsNotAListReportsNilTotal() {
        // `total == nil` is what flips the store into "never write empty over
        // this file" mode.
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data("{\"rules\":[]}".utf8))
        XCTAssertTrue(rules.isEmpty)
        XCTAssertNil(total)
    }

    func testEmptyListIsACleanLoadNotALoss() {
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data("[]".utf8))
        XCTAssertTrue(rules.isEmpty)
        XCTAssertEqual(total, 0, "an empty file is readable — it must not look like corruption")
    }

    func testDecodeIsNotSilentlyLossyForAFullyValidFile() {
        let json = "[\(ruleJSON(id: "a")),\(ruleJSON(id: "b"))]"
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data(json.utf8))
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(total, 2)
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTripPreservesEverything() {
        var rule = InterceptRule.hostRule(hosts: ["api.example.com"])
        rule.isBlocked = true
        rule.isEnabled = false
        rule.order = 4
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "beta.example.com/v2"
        rule.breakpointMode = .afterResponse
        rule.headerOverrides = [KVPair(key: "X-Env", value: "beta")]
        rule.removedHeaderKeys = ["cookie"]
        rule.mock = MockResponse(isEnabled: true, statusCode: 503, body: "{}", headers: [], delay: 1)

        let data = try! JSONEncoder().encode([rule])
        let (back, total) = InterceptRuleStore.decodeRules(from: data)
        XCTAssertEqual(total, 1)
        let r = back.first
        XCTAssertEqual(r?.id, rule.id)
        XCTAssertEqual(r?.matchMode, .host)
        XCTAssertEqual(r?.matchHosts, ["api.example.com"])
        XCTAssertEqual(r?.isBlocked, true)
        XCTAssertEqual(r?.isEnabled, false)
        XCTAssertEqual(r?.order, 4)
        XCTAssertEqual(r?.redirectMode, .hostAndPath)
        XCTAssertEqual(r?.redirectTarget, "beta.example.com/v2")
        XCTAssertEqual(r?.breakpointMode, .afterResponse)
        XCTAssertEqual(r?.headerOverrides.first?.key, "X-Env")
        XCTAssertEqual(r?.removedHeaderKeys, ["cookie"])
        XCTAssertEqual(r?.mock.statusCode, 503)
        XCTAssertEqual(r?.mock.isEnabled, true)
    }

    // MARK: - LenientElement itself

    func testLenientElementNeverThrowsAndAlwaysAdvances() {
        // The wrapper exists because an UnkeyedDecodingContainer does not
        // reliably advance past an element whose decode threw — "try, catch,
        // continue" would spin forever.
        let data = Data("[1, \"two\", 3, null, 5]".utf8)
        let wrapped = try? JSONDecoder().decode([LenientElement<Int>].self, from: data)
        XCTAssertEqual(wrapped?.count, 5)
        XCTAssertEqual(wrapped?.compactMap { $0.value }, [1, 3, 5])
    }
}
