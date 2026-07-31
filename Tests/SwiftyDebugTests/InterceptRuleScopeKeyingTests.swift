//
//  InterceptRuleScopeKeyingTests.swift
//  SwiftyDebugTests
//
//  Two things reported as one bug:
//
//  * "when adding exact rules it override each others ... every exact rule
//    should apply to full path and should be unique"
//  * "when intrupt endpoint ask to intercept endpoint on this host or endpoint
//    with ignoring the host"
//
//  Both come down to what a rule is filed under. `matchEndpoint` alone was the
//  key, so an exact rule and a pattern rule for the same path shared a bucket,
//  an exact rule whose endpoint had been left holding a `{id}` pattern was
//  filed where no request would ever look, and the host was not part of matching
//  at all. `InterceptRule.storageKey` folds mode + host pin + endpoint into the
//  key, and the store probes the same function it stores under.
//
//  Rules already on developers' devices must survive all of it, so the legacy
//  payload at the bottom is pinned byte for byte.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleScopeKeyingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func blockingRule(path: String,
                              mode: EndpointMatchMode = .exact,
                              host: String? = nil,
                              marker: String) -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: mode, host: host)
        rule.headerOverrides = [KVPair(key: "X-Rule", value: marker)]
        rule.isEnabled = true
        return rule
    }

    private func marker(of rule: InterceptRule?) -> String? {
        rule?.headerOverrides.first(where: { $0.key == "X-Rule" })?.value
    }

    // MARK: - A. Exact rules are unique per FULL path

    /// The reported case, verbatim: two sibling paths under the same collection.
    func testTwoExactRulesForSiblingPathsCoexistAndDoNotOverrideEachOther() {
        let a = blockingRule(path: "/product/10289032912/20920220", marker: "a")
        let b = blockingRule(path: "/product/3/4", marker: "b")
        InterceptRuleStore.shared.addOrUpdate(a)
        InterceptRuleStore.shared.addOrUpdate(b)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)

        let first = InterceptRuleStore.shared.resolvedRule(
            forURL: url("https://s.com/product/10289032912/20920220"))
        let second = InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/product/3/4"))

        XCTAssertEqual(marker(of: first), "a")
        XCTAssertEqual(marker(of: second), "b")
        XCTAssertEqual(first?.headerOverrides.count, 1, "neither rule may leak into the other")
        XCTAssertEqual(second?.headerOverrides.count, 1)
    }

    func testAnExactRuleDoesNotFireOnASiblingPath() {
        InterceptRuleStore.shared.addOrUpdate(
            blockingRule(path: "/product/1/2", marker: "a"))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/product/1/3")))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/product/1")))
    }

    /// A path with no ids normalizes to itself, so exact and pattern rules for
    /// `/api/users` used to land on the same dictionary key.
    func testExactAndPatternRulesForTheSamePathAreDifferentRules() {
        let exact = blockingRule(path: "/api/users", mode: .exact, marker: "exact")
        let pattern = blockingRule(path: "/api/users", mode: .normalized, marker: "pattern")
        InterceptRuleStore.shared.addOrUpdate(exact)
        InterceptRuleStore.shared.addOrUpdate(pattern)

        XCTAssertNotEqual(exact.storageKey, pattern.storageKey)
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)

        let matches = InterceptRuleStore.shared.matchingRules(forURL: url("https://s.com/api/users"))
        XCTAssertEqual(Set(matches.compactMap { marker(of: $0) }), ["exact", "pattern"])
    }

    func testStorageKeySeparatesModeHostAndEndpoint() {
        XCTAssertNotEqual(
            InterceptRule.endpointKey(mode: .exact, host: "", endpoint: "/a"),
            InterceptRule.endpointKey(mode: .normalized, host: "", endpoint: "/a"))
        XCTAssertNotEqual(
            InterceptRule.endpointKey(mode: .exact, host: "a.com", endpoint: "/a"),
            InterceptRule.endpointKey(mode: .exact, host: "b.com", endpoint: "/a"))
        XCTAssertEqual(
            InterceptRule.endpointKey(mode: .exact, host: "  A.COM ", endpoint: "/a"),
            InterceptRule.endpointKey(mode: .exact, host: "a.com", endpoint: "/a"),
            "a host pin is compared case- and whitespace-insensitively")
    }

    // MARK: - C. This host vs any host

    func testARuleWithNoHostPinStillMatchesEveryHost() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", marker: "any"))

        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart"))), "any")
        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/cart"))), "any")
    }

    func testAHostPinnedRuleOnlyFiresOnThatHost() {
        InterceptRuleStore.shared.addOrUpdate(
            blockingRule(path: "/cart", host: "a.com", marker: "pinned"))

        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart"))), "pinned")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/cart")))
    }

    func testSamePathOnDifferentHostsAreTwoIndependentRules() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "a.com", marker: "a"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "b.com", marker: "b"))

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)
        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart"))), "a")
        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/cart"))), "b")
    }

    func testAnyHostAndPinnedRulesForTheSamePathBothApplyOnThatHost() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", marker: "any"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "a.com", marker: "pinned"))

        let onA = InterceptRuleStore.shared.matchingRules(forURL: url("https://a.com/cart"))
        XCTAssertEqual(Set(onA.compactMap { marker(of: $0) }), ["any", "pinned"])

        let onB = InterceptRuleStore.shared.matchingRules(forURL: url("https://b.com/cart"))
        XCTAssertEqual(onB.compactMap { marker(of: $0) }, ["any"])
    }

    func testHostPinIsCaseInsensitiveAgainstTheRequest() {
        InterceptRuleStore.shared.addOrUpdate(
            blockingRule(path: "/cart", host: "API.Example.COM", marker: "pinned"))
        XCTAssertEqual(
            marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://api.example.com/cart"))),
            "pinned")
    }

    func testPatternRulesTakeAHostPinToo() {
        InterceptRuleStore.shared.addOrUpdate(
            blockingRule(path: "/product/{id}", mode: .normalized, host: "a.com", marker: "pinned"))

        XCTAssertEqual(
            marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/product/77"))),
            "pinned")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/product/77")))
    }

    func testHostPinAllowsIsTheSameAnswerTheStoreGives() {
        let pinned = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: "a.com")
        XCTAssertTrue(pinned.hostPinAllows(url("https://a.com/cart")))
        XCTAssertFalse(pinned.hostPinAllows(url("https://b.com/cart")))

        let anyHost = InterceptRule.endpointRule(path: "/cart", mode: .exact)
        XCTAssertTrue(anyHost.appliesToAnyHost)
        XCTAssertTrue(anyHost.hostPinAllows(url("https://anything.com/cart")))

        // Host and global rules answer elsewhere and must never be gated by this.
        XCTAssertTrue(InterceptRule.globalRule().hostPinAllows(url("https://x.com/y")))
        XCTAssertTrue(InterceptRule.hostRule(hosts: ["a.com"]).hostPinAllows(url("https://z.com/y")))
    }

    /// The path-only lookup cannot evaluate a pin, so it is deliberately
    /// over-inclusive rather than hiding a rule the user created.
    func testPathOnlyLookupStillSurfacesHostPinnedRules() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "a.com", marker: "pinned"))
        let found = InterceptRuleStore.shared.matchingRules(forPath: "/cart")
        XCTAssertEqual(found.compactMap { marker(of: $0) }, ["pinned"])
        XCTAssertTrue(InterceptRuleStore.shared.hasRule(forPath: "/cart"))
    }

    // MARK: - Editing a rule re-keys it instead of cloning it

    func testChangingAnExistingRulesPathMovesItInsteadOfLeavingACopyBehind() {
        var rule = blockingRule(path: "/old", marker: "a")
        InterceptRuleStore.shared.addOrUpdate(rule)

        rule.matchEndpoint = "/new"
        InterceptRuleStore.shared.addOrUpdate(rule)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1,
                       "the old copy must not survive under the old key")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/old")))
        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/new"))), "a")
    }

    func testSwitchingAnExistingRuleFromPatternToExactRepointsIt() {
        // Exactly what the editor does: a rule created as a pattern, then flipped
        // to Exact. Before this, `matchEndpoint` was `let` and kept the pattern,
        // so the rule was filed as exact under "/product/{id}" and matched nothing.
        var rule = blockingRule(path: "/product/{id}", mode: .normalized, marker: "a")
        InterceptRuleStore.shared.addOrUpdate(rule)

        rule.matchMode = .exact
        rule.matchEndpoint = "/product/99"
        InterceptRuleStore.shared.addOrUpdate(rule)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1)
        XCTAssertEqual(marker(of: InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/product/99"))), "a")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/product/100")))
    }

    func testAddingAHostPinToAnExistingRuleRepointsIt() {
        var rule = blockingRule(path: "/cart", marker: "a")
        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/cart")))

        rule.matchHost = "a.com"
        InterceptRuleStore.shared.addOrUpdate(rule)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart")))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://b.com/cart")),
                     "the any-host copy must not be left behind")
    }

    func testUpdatingARuleInPlaceDoesNotDuplicateIt() {
        var rule = blockingRule(path: "/cart", marker: "a")
        InterceptRuleStore.shared.addOrUpdate(rule)
        rule.isEnabled = false
        InterceptRuleStore.shared.addOrUpdate(rule)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1)
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://s.com/cart")))
    }

    func testRemoveByIdRemovesExactlyOneRule() {
        let a = blockingRule(path: "/cart", host: "a.com", marker: "a")
        let b = blockingRule(path: "/cart", host: "b.com", marker: "b")
        InterceptRuleStore.shared.addOrUpdate(a)
        InterceptRuleStore.shared.addOrUpdate(b)

        InterceptRuleStore.shared.remove(id: a.id)
        XCTAssertEqual(InterceptRuleStore.shared.allRules().map { $0.id }, [b.id])
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart")))
    }

    func testRemoveByMatchEndpointRemovesEveryVariantOfThatEndpoint() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", marker: "any"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "a.com", marker: "pinned"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/other", marker: "keep"))

        InterceptRuleStore.shared.remove(matchEndpoint: "/cart")

        XCTAssertEqual(InterceptRuleStore.shared.allRules().compactMap { marker(of: $0) }, ["keep"])
    }

    func testRulesForMatchEndpointReturnsEveryVariant() {
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", mode: .exact, marker: "exact"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", mode: .normalized, marker: "pattern"))
        InterceptRuleStore.shared.addOrUpdate(blockingRule(path: "/cart", host: "a.com", marker: "pinned"))

        let found = InterceptRuleStore.shared.rules(for: "/cart")
        XCTAssertEqual(Set(found.compactMap { marker(of: $0) }), ["exact", "pattern", "pinned"])

        let exactAnyHost = InterceptRule.endpointKey(mode: .exact, host: "", endpoint: "/cart")
        XCTAssertEqual(
            InterceptRuleStore.shared.rules(forStorageKey: exactAnyHost).compactMap { marker(of: $0) },
            ["exact"])
    }

    func testReorderSetsOrderOnRulesThatNowLiveInDifferentBuckets() {
        let exact = blockingRule(path: "/cart", mode: .exact, marker: "exact")
        let pattern = blockingRule(path: "/cart", mode: .normalized, marker: "pattern")
        InterceptRuleStore.shared.addOrUpdate(exact)
        InterceptRuleStore.shared.addOrUpdate(pattern)

        InterceptRuleStore.shared.reorder(ids: [pattern.id, exact.id], for: "/cart")

        let applied = InterceptRuleStore.shared.matchingRules(forURL: url("https://s.com/cart"))
        XCTAssertEqual(applied.compactMap { marker(of: $0) }, ["pattern", "exact"])
    }

    // MARK: - The composite still carries everything

    func testResolvedRuleCarriesMockBreakpointAndRewritesFromAHostPinnedRule() {
        var rule = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: "a.com")
        rule.mock = MockResponse(isEnabled: true, statusCode: 418, body: "{}")
        rule.breakpointMode = .afterResponse
        rule.responseRewrites = [ResponseRewrite(pattern: "data.url", action: .setValue("x"))]
        rule.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(rule)

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart"))
        XCTAssertEqual(resolved?.mock.statusCode, 418)
        XCTAssertTrue(resolved?.mock.isEnabled ?? false)
        XCTAssertEqual(resolved?.breakpointMode, .afterResponse)
        XCTAssertEqual(resolved?.responseRewrites.count, 1)
        XCTAssertEqual(resolved?.matchHost, "a.com", "the composite must describe the request it resolved")
    }

    func testResolvedRuleNamesTheRulesThatContributed() {
        var blocked = InterceptRule.endpointRule(path: "/cart", mode: .exact)
        blocked.isBlocked = true
        var mocked = InterceptRule.globalRule()
        mocked.mock = MockResponse(isEnabled: true, statusCode: 500)
        mocked.name = "Server on fire"
        InterceptRuleStore.shared.addOrUpdate(blocked)
        InterceptRuleStore.shared.addOrUpdate(mocked)

        // Both contributors are named, so a request that came back mocked can be
        // traced to the rules that did it. (The two rules sit in different
        // buckets and both take order 0, so their relative order is not pinned.)
        let name = try? XCTUnwrap(InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.com/cart"))?.name)
        XCTAssertEqual(name?.contains("Blocked · /cart"), true)
        XCTAssertEqual(name?.contains("Server on fire"), true)
    }

    // MARK: - Canonicalization

    func testCanonicalizedRepairsAHostRuleThatOnlyKeptItsKey() {
        var rule = InterceptRule(matchEndpoint: "host:B.com,a.com", matchMode: .host)
        rule.matchHosts = []
        let fixed = rule.canonicalized()
        XCTAssertEqual(fixed.matchHosts, ["a.com", "b.com"])
        XCTAssertEqual(fixed.matchEndpoint, "host:a.com,b.com")
        XCTAssertEqual(fixed.storageKey, "host:a.com,b.com")
    }

    func testCanonicalizedForcesTheGlobalKey() {
        var rule = InterceptRule(matchEndpoint: "/whatever", matchMode: .global)
        rule.matchHost = "a.com"
        let fixed = rule.canonicalized()
        XCTAssertEqual(fixed.matchEndpoint, "global")
        XCTAssertEqual(fixed.storageKey, "global")
        XCTAssertTrue(fixed.matchHost.isEmpty, "a host pin must never alter a global rule's key")
    }

    func testCanonicalizedClearsAHostPinOnAHostRule() {
        var rule = InterceptRule.hostRule(hosts: ["a.com"])
        rule.matchHost = "b.com"
        XCTAssertEqual(rule.canonicalized().storageKey, "host:a.com")
    }

    /// The dead rule the old editor produced: mode flipped to exact, endpoint
    /// left holding the pattern. No real `url.path` contains "{id}", so it could
    /// never fire; re-filing it as a pattern is the only reading that works.
    func testAnExactRuleHoldingAPatternIsMigratedToAPatternRule() {
        var stranded = InterceptRule(matchEndpoint: "/product/{id}/{id}", matchMode: .exact)
        stranded.headerOverrides = [KVPair(key: "X-Rule", value: "stranded")]
        stranded.isEnabled = true

        let fixed = stranded.canonicalized()
        XCTAssertEqual(fixed.matchMode, .normalized)

        InterceptRuleStore.shared.addOrUpdate(stranded)
        XCTAssertEqual(
            marker(of: InterceptRuleStore.shared.resolvedRule(
                forURL: url("https://s.com/product/10289032912/20920220"))),
            "stranded")
    }

    func testARealPathIsNeverMistakenForAPattern() {
        let rule = InterceptRule(matchEndpoint: "/product/10289032912/20920220", matchMode: .exact)
        XCTAssertEqual(rule.canonicalized().matchMode, .exact)
        XCTAssertFalse(InterceptRule.looksLikeNormalizerOutput("/product/10289032912/20920220"))
        XCTAssertTrue(InterceptRule.looksLikeNormalizerOutput("/product/{id}/{id}"))
    }

    // MARK: - MIGRATION: files already on developers' devices

    /// The OLD on-disk shape: no `matchHost`, no `name`, and one rule still using
    /// the pre-rename `normalizedEndpoint` key. Every rule must load, keep its
    /// settings, and keep matching every host the way it always has.
    func testALegacyRulesFileLoadsCompletelyAndKeepsAnyHostBehaviour() {
        let legacy = Data("""
        [
          {
            "id": "legacy-normalized",
            "normalizedEndpoint": "/product/{id}",
            "matchMode": "normalized",
            "isBlocked": false,
            "headerOverrides": [{ "id": "h1", "key": "X-Rule", "value": "legacy-normalized" }],
            "queryParamOverrides": [],
            "removedHeaderKeys": [], "removedQueryParamKeys": [],
            "isEnabled": true, "createdAt": 0, "order": 0
          },
          {
            "id": "legacy-exact",
            "matchEndpoint": "/product/1/2",
            "matchMode": "exact",
            "isBlocked": true,
            "headerOverrides": [], "queryParamOverrides": [],
            "removedHeaderKeys": [], "removedQueryParamKeys": [],
            "isEnabled": true, "createdAt": 1, "order": 0
          },
          {
            "id": "legacy-host",
            "matchEndpoint": "host:stale",
            "matchMode": "host",
            "matchHosts": ["B.example.com", "a.example.com"],
            "isBlocked": false,
            "headerOverrides": [], "queryParamOverrides": [],
            "removedHeaderKeys": [], "removedQueryParamKeys": [],
            "isEnabled": true, "createdAt": 2, "order": 0
          },
          {
            "id": "legacy-global",
            "matchEndpoint": "global",
            "matchMode": "global",
            "isBlocked": false,
            "headerOverrides": [], "queryParamOverrides": [],
            "removedHeaderKeys": [], "removedQueryParamKeys": [],
            "isEnabled": true, "createdAt": 3, "order": 0
          }
        ]
        """.utf8)

        let (loaded, total) = InterceptRuleStore.decodeRules(from: legacy)
        XCTAssertEqual(total, 4)
        XCTAssertEqual(loaded.count, 4, "no rule may be dropped by the new fields")

        for rule in loaded { InterceptRuleStore.shared.addOrUpdate(rule) }
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 4)

        // The pattern rule still matches on ANY host — it was never pinned.
        for host in ["a.example.com", "somewhere-else.com"] {
            let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url("https://\(host)/product/77"))
            XCTAssertTrue(
                resolved?.headerOverrides.contains { $0.value == "legacy-normalized" } ?? false,
                "a rule with no recorded host must keep matching every host (\(host))")
        }

        // The exact rule still matches its own full path and nothing else.
        XCTAssertTrue(
            InterceptRuleStore.shared.resolvedRule(forURL: url("https://a.example.com/product/1/2"))?.isBlocked ?? false)

        // The host rule's stale key is repaired rather than orphaning it.
        let hostRule = InterceptRuleStore.shared.allRules().first { $0.id == "legacy-host" }
        XCTAssertEqual(hostRule?.matchEndpoint, "host:a.example.com,b.example.com")
        XCTAssertTrue(
            InterceptRuleStore.shared.hostRules(forURL: url("https://b.example.com/anything"))
                .contains { $0.id == "legacy-host" })

        // And the global rule still matches everything.
        XCTAssertTrue(
            InterceptRuleStore.shared.matchingRules(forURL: url("https://nowhere.com/zzz"))
                .contains { $0.id == "legacy-global" })
    }

    func testLegacyRulesGetEmptyNameAndAnyHostAfterDecoding() {
        let legacy = Data("""
        [{ "id": "x", "matchEndpoint": "/api/x", "matchMode": "exact",
           "isBlocked": false, "headerOverrides": [], "queryParamOverrides": [],
           "removedHeaderKeys": [], "removedQueryParamKeys": [],
           "isEnabled": true, "createdAt": 0, "order": 0 }]
        """.utf8)
        let (loaded, _) = InterceptRuleStore.decodeRules(from: legacy)
        XCTAssertEqual(loaded.first?.matchHost, "")
        XCTAssertEqual(loaded.first?.name, "")
        XCTAssertTrue(loaded.first?.appliesToAnyHost ?? false)
    }

    func testHostPinAndNameRoundTripThroughTheOnDiskFormat() throws {
        var rule = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: "a.com")
        rule.name = "Empty cart"
        let data = try JSONEncoder().encode([rule])
        let (back, total) = InterceptRuleStore.decodeRules(from: data)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(back.first?.matchHost, "a.com")
        XCTAssertEqual(back.first?.name, "Empty cart")
        XCTAssertEqual(back.first?.storageKey, rule.storageKey)
    }

    /// The store's own guarantee, restated for the new fields: one rule this
    /// build cannot read must not take the file with it.
    func testOneUnreadableRuleStillDoesNotWipeTheRest() {
        let data = Data("""
        [
          { "id": "good", "matchEndpoint": "/a", "matchMode": "exact", "matchHost": "a.com" },
          { "matchEndpoint": "/b" },
          { "id": "also-good", "matchEndpoint": "/c", "name": "keep me" }
        ]
        """.utf8)
        let (loaded, total) = InterceptRuleStore.decodeRules(from: data)
        XCTAssertEqual(total, 3)
        XCTAssertEqual(loaded.map { $0.id }, ["good", "also-good"])
        XCTAssertEqual(loaded.last?.name, "keep me")
    }

    /// The JS bridge matches rules by hand inside a WKWebView, so the fields it
    /// needs have to be in the payload before it can honour them.
    func testWebViewPayloadCarriesTheHostPinAndTheName() throws {
        var rule = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: "a.com")
        rule.isBlocked = true
        rule.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(rule)

        let json = InterceptRuleStore.shared.rulesAsJSONString()
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        let entry = try XCTUnwrap(parsed?.first)
        XCTAssertEqual(entry["matchHost"] as? String, "a.com")
        XCTAssertEqual(entry["name"] as? String, "Blocked · a.com/cart")
        XCTAssertEqual(entry["matchEndpoint"] as? String, "/cart")
    }
}
