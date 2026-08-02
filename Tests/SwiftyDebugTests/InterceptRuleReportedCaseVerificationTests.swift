//
//  InterceptRuleReportedCaseVerificationTests.swift
//  SwiftyDebugTests
//
//  INDEPENDENT verification of the three reported defects, written without
//  reusing the helpers of the tests that shipped with the fix:
//
//    A. "when adding exact rules it override each others ... every exact rule
//        should apply to full path and should be unique"
//    B. "it should have names the rules ... mock, breakpoint and rewrite does
//        not have names"
//    C. "ask to intercept endpoint on this host or endpoint with ignoring
//        the host"
//
//  Where the shipped tests assert with header markers, these assert on the
//  MOCK BODY — i.e. the bytes a request would actually come back with — so a
//  rule that is filed correctly but resolves to the wrong payload still fails.
//
//  Plus the compatibility floor: a `rules.json` in the OLD on-disk format
//  (no `name`, no `matchHost`, legacy `normalizedEndpoint` key) must load with
//  every rule intact and matching what it used to, and one unreadable rule must
//  not take the file down.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleReportedCaseVerificationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A rule whose only armed behaviour is a mock with an identifiable body.
    private func mockRule(path: String,
                          mode: EndpointMatchMode = .exact,
                          host: String? = nil,
                          body: String,
                          status: Int = 200) -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: mode, host: host)
        rule.mock = MockResponse(isEnabled: true, statusCode: status, body: body)
        rule.isEnabled = true
        return rule
    }

    /// What a request to `string` would actually be answered with.
    private func resolvedMockBody(_ string: String) -> String? {
        let url = URL(string: string)!
        guard let rule = InterceptRuleStore.shared.resolvedRule(forURL: url) else { return nil }
        return rule.mock.isEnabled ? rule.mock.body : nil
    }

    // MARK: - A. The reported case, verbatim

    /// Two Exact rules under the same collection, each with a DIFFERENT mock.
    /// Before the fix both were filed under one key and one clobbered the other.
    func testTheTwoReportedExactRulesEachResolveToTheirOwnMock() {
        let store = InterceptRuleStore.shared
        store.addOrUpdate(mockRule(path: "/product/10289032912/20920220", body: "FIRST"))
        store.addOrUpdate(mockRule(path: "/product/10289032912/33333333", body: "SECOND"))

        XCTAssertEqual(store.allRules().count, 2,
                       "One exact rule overwrote the other in the store")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/20920220"),
                       "FIRST",
                       "The first exact path resolved to the wrong mock")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/33333333"),
                       "SECOND",
                       "The second exact path resolved to the wrong mock")
    }

    /// The order the rules are saved in must not decide who wins.
    func testTheReportedCaseHoldsWhenTheRulesAreSavedInTheOtherOrder() {
        let store = InterceptRuleStore.shared
        store.addOrUpdate(mockRule(path: "/product/10289032912/33333333", body: "SECOND"))
        store.addOrUpdate(mockRule(path: "/product/10289032912/20920220", body: "FIRST"))

        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/20920220"), "FIRST")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/33333333"), "SECOND")
    }

    /// A sibling path with no rule must stay untouched — the exact rules must
    /// not have widened into a pattern.
    func testASiblingPathWithNoRuleIsNotIntercepted() {
        InterceptRuleStore.shared.addOrUpdate(mockRule(path: "/product/10289032912/20920220", body: "FIRST"))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://api.example.com/product/10289032912/99999999")!),
                     "An exact rule leaked onto a sibling path")
    }

    /// The full path is what is matched — a prefix of it must not match.
    /// This is the matching half of the reported "only /product/10289032912".
    func testThePrefixOfTheReportedPathDoesNotMatch() {
        InterceptRuleStore.shared.addOrUpdate(mockRule(path: "/product/10289032912/20920220", body: "FIRST"))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://api.example.com/product/10289032912")!),
                     "A truncated prefix of the exact path matched the rule")
    }

    // MARK: - A/C. Same path, different host

    /// The third rule the brief asks for: same full path, different host.
    func testTheSamePathOnADifferentHostIsAThirdIndependentRule() {
        let store = InterceptRuleStore.shared
        store.addOrUpdate(mockRule(path: "/product/10289032912/20920220", body: "FIRST"))
        store.addOrUpdate(mockRule(path: "/product/10289032912/33333333", body: "SECOND"))
        store.addOrUpdate(mockRule(path: "/product/10289032912/20920220",
                                   host: "staging.example.com", body: "THIRD"))

        XCTAssertEqual(store.allRules().count, 3, "The host-pinned rule collided with an existing one")
        XCTAssertEqual(resolvedMockBody("https://staging.example.com/product/10289032912/20920220"),
                       "THIRD", "The host-pinned rule did not win on its own host")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/33333333"),
                       "SECOND")
    }

    /// A rule pinned to one host must NOT fire on another host. This is the
    /// behaviour item C exists to create.
    func testAHostPinnedRuleDoesNotFireOnAnotherHost() {
        InterceptRuleStore.shared.addOrUpdate(
            mockRule(path: "/cart", host: "api.example.com", body: "PINNED"))

        XCTAssertEqual(resolvedMockBody("https://api.example.com/cart"), "PINNED")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://other.com/cart")!),
                     "A host-pinned rule fired on a host it was not pinned to")
    }

    /// The other arm of the question: "ignore the host" must still match
    /// everywhere, which is also what every pre-existing rule does.
    func testAnAnyHostRuleStillFiresOnEveryHost() {
        InterceptRuleStore.shared.addOrUpdate(mockRule(path: "/cart", host: nil, body: "ANY"))
        XCTAssertEqual(resolvedMockBody("https://api.example.com/cart"), "ANY")
        XCTAssertEqual(resolvedMockBody("https://other.com/cart"), "ANY")
    }

    /// The host pin must be case- and whitespace-insensitive, or the same host
    /// typed two ways becomes two buckets.
    func testTheHostPinIsCanonicalized() {
        InterceptRuleStore.shared.addOrUpdate(
            mockRule(path: "/cart", host: "  API.Example.COM ", body: "PINNED"))
        XCTAssertEqual(resolvedMockBody("https://api.example.com/cart"), "PINNED")
    }

    // MARK: - A. Editing a rule's scope re-keys it

    /// The dead-guard bug: editing an existing rule and switching Pattern →
    /// Exact left the old copy in place and ran BOTH.
    func testRescopingAnExistingRuleLeavesExactlyOneCopy() {
        let store = InterceptRuleStore.shared
        var rule = mockRule(path: "/product/{id}/{id}", mode: .normalized, body: "PATTERN")
        store.addOrUpdate(rule)

        rule.matchMode = .exact
        rule.matchEndpoint = "/product/10289032912/20920220"
        rule.mock.body = "EXACT"
        store.addOrUpdate(rule)

        XCTAssertEqual(store.allRules().count, 1, "Re-scoping left a stale copy in the old bucket")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/product/10289032912/20920220"), "EXACT")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://api.example.com/product/1/2")!),
                     "The old pattern bucket still matched after re-scoping")
    }

    /// Pinning an existing any-host rule to a host must move it, not clone it.
    func testPinningAnExistingRuleToAHostMovesIt() {
        let store = InterceptRuleStore.shared
        var rule = mockRule(path: "/cart", body: "CART")
        store.addOrUpdate(rule)

        rule.matchHost = "api.example.com"
        store.addOrUpdate(rule)

        XCTAssertEqual(store.allRules().count, 1, "Pinning a rule to a host duplicated it")
        XCTAssertEqual(resolvedMockBody("https://api.example.com/cart"), "CART")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://other.com/cart")!),
                     "The any-host copy survived the pin")
    }

    // MARK: - B. Names

    /// Each single-purpose rule must name itself. "Empty rule" for any of these
    /// is the reported defect.
    func testEverySinglePurposeRuleProducesAMeaningfulName() {
        var mockOnly = InterceptRule.endpointRule(path: "/product/{id}", host: "api.example.com")
        mockOnly.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")

        var breakpointOnly = InterceptRule.endpointRule(path: "/cart", host: "api.example.com")
        breakpointOnly.breakpointMode = .afterResponse

        var rewriteOnly = InterceptRule.endpointRule(path: "/feed", host: "api.example.com")
        rewriteOnly.responseRewrites = [
            ResponseRewrite(pattern: "data.url", action: .setValue("x"))
        ]

        var redirectOnly = InterceptRule.endpointRule(path: "/checkout", host: "api.example.com")
        redirectOnly.redirectMode = .host
        redirectOnly.redirectTarget = "beta.example.com"

        for (label, rule) in [("mock", mockOnly), ("breakpoint", breakpointOnly),
                              ("rewrite", rewriteOnly), ("redirect", redirectOnly)] {
            XCTAssertNotEqual(rule.displayName, "Empty rule", "\(label)-only rule read as Empty rule")
            XCTAssertFalse(rule.displayName.contains("Empty rule"), "\(label)-only rule mentioned Empty rule")
            XCTAssertFalse(rule.displayName.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(label)-only rule produced a blank name")
        }

        XCTAssertEqual(mockOnly.displayName, "Mock 404 · api.example.com/product/{id}")
        XCTAssertEqual(breakpointOnly.displayName, "Breakpoint after response · api.example.com/cart")
        XCTAssertEqual(redirectOnly.displayName, "Redirect \u{2192} beta.example.com · api.example.com/checkout")
        XCTAssertTrue(rewriteOnly.displayName.hasPrefix("Rewrite data.url"), rewriteOnly.displayName)
    }

    /// A typed name wins over the derived one, and survives a store round trip.
    func testAUserTypedNameWinsAndSurvivesTheStore() {
        var rule = mockRule(path: "/cart", body: "X")
        rule.name = "Checkout 500"
        InterceptRuleStore.shared.addOrUpdate(rule)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().first?.displayName, "Checkout 500")
    }

    /// An untouched name keeps tracking the configuration rather than freezing.
    func testAnUnnamedRuleTracksItsConfiguration() {
        var rule = InterceptRule.endpointRule(path: "/cart", host: "api.example.com")
        rule.mock = MockResponse(isEnabled: true, statusCode: 200, body: "{}")
        let before = rule.displayName
        rule.mock.statusCode = 503
        XCTAssertNotEqual(rule.displayName, before, "The derived name did not follow the configuration")
    }

    /// The name must reach the composite the network layer actually holds, or
    /// nothing downstream can say which rule acted.
    func testTheResolvedCompositeCarriesTheName() {
        var rule = mockRule(path: "/cart", body: "X")
        rule.name = "Checkout 500"
        InterceptRuleStore.shared.addOrUpdate(rule)

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://api.example.com/cart")!)
        XCTAssertEqual(resolved?.name, "Checkout 500")
    }

    // MARK: - Migration: the OLD on-disk format

    /// Byte-for-byte an old `rules.json`: no `name`, no `matchHost`, and the
    /// first rule still using the legacy `normalizedEndpoint` key.
    private let legacyRulesJSON = """
    [
      {
        "id": "legacy-1",
        "normalizedEndpoint": "/product/{id}",
        "matchMode": "normalized",
        "matchHosts": [],
        "isBlocked": false,
        "headerOverrides": [{"key": "X-Legacy", "value": "1"}],
        "queryParamOverrides": [],
        "removedHeaderKeys": [],
        "removedQueryParamKeys": [],
        "isEnabled": true,
        "createdAt": 700000000,
        "order": 0
      },
      {
        "id": "legacy-2",
        "matchEndpoint": "/cart",
        "matchMode": "exact",
        "matchHosts": [],
        "isBlocked": true,
        "headerOverrides": [],
        "queryParamOverrides": [],
        "removedHeaderKeys": [],
        "removedQueryParamKeys": [],
        "isEnabled": true,
        "createdAt": 700000001,
        "order": 1
      },
      {
        "id": "legacy-3",
        "matchEndpoint": "host:a.com,b.com",
        "matchMode": "host",
        "matchHosts": ["a.com", "b.com"],
        "isBlocked": false,
        "headerOverrides": [{"key": "X-Host", "value": "1"}],
        "queryParamOverrides": [],
        "removedHeaderKeys": [],
        "removedQueryParamKeys": [],
        "isEnabled": true,
        "createdAt": 700000002,
        "order": 2
      },
      {
        "id": "legacy-4",
        "matchEndpoint": "global",
        "matchMode": "global",
        "matchHosts": [],
        "isBlocked": false,
        "headerOverrides": [{"key": "X-Global", "value": "1"}],
        "queryParamOverrides": [],
        "removedHeaderKeys": [],
        "removedQueryParamKeys": [],
        "isEnabled": true,
        "createdAt": 700000003,
        "order": 3
      }
    ]
    """

    /// Every rule in the old file must decode, and the two new fields must
    /// arrive absent without discarding anything.
    func testEveryRuleInAnOldFileSurvivesDecoding() {
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data(legacyRulesJSON.utf8))
        XCTAssertEqual(total, 4)
        XCTAssertEqual(rules.count, 4, "An old-format rule was discarded")
        XCTAssertEqual(Set(rules.map { $0.id }), ["legacy-1", "legacy-2", "legacy-3", "legacy-4"])
        for rule in rules {
            XCTAssertEqual(rule.name, "", "A rule with no name key decoded to something other than empty")
            XCTAssertEqual(rule.matchHost, "", "A rule with no matchHost decoded to a host pin")
        }
        // The legacy key is still honoured.
        XCTAssertEqual(rules.first(where: { $0.id == "legacy-1" })?.matchEndpoint, "/product/{id}")
    }

    /// Loaded through the real load path (decode → canonicalize → key → probe),
    /// each old rule must still match exactly what it used to, on ANY host.
    func testOldRulesStillMatchWhatTheyUsedToAfterMigration() {
        let (rules, _) = InterceptRuleStore.decodeRules(from: Data(legacyRulesJSON.utf8))
        for rule in rules { InterceptRuleStore.shared.addOrUpdate(rule) }

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 4, "Migration lost a rule")

        // Pattern rule: any host, still matches an instance of the pattern.
        let a = InterceptRuleStore.shared.matchingRules(forURL: URL(string: "https://anything.com/product/55")!)
        XCTAssertTrue(a.contains { $0.id == "legacy-1" }, "The legacy pattern rule stopped matching")

        // Exact rule: any host, still matches its literal path.
        let b = InterceptRuleStore.shared.matchingRules(forURL: URL(string: "https://whoever.com/cart")!)
        XCTAssertTrue(b.contains { $0.id == "legacy-2" }, "The legacy exact rule stopped matching")

        // Host rule and global rule.
        let c = InterceptRuleStore.shared.matchingRules(forURL: URL(string: "https://a.com/whatever")!)
        XCTAssertTrue(c.contains { $0.id == "legacy-3" }, "The legacy host rule stopped matching")
        XCTAssertTrue(c.contains { $0.id == "legacy-4" }, "The legacy global rule stopped matching")
    }

    /// The regression this repo already shipped once: ONE bad rule must not
    /// wipe the others.
    func testOneUndecodableRuleDoesNotWipeTheFile() {
        let mixed = """
        [
          {"id": "good-1", "matchEndpoint": "/a", "matchMode": "exact", "matchHosts": [],
           "isBlocked": false, "headerOverrides": [], "queryParamOverrides": [],
           "removedHeaderKeys": [], "removedQueryParamKeys": [], "isEnabled": true,
           "createdAt": 700000000, "order": 0},
          {"matchEndpoint": "/broken-no-id", "matchMode": "exact"},
          {"id": "good-2", "matchEndpoint": "/b", "matchMode": "exact", "matchHosts": [],
           "isBlocked": false, "headerOverrides": [], "queryParamOverrides": [],
           "removedHeaderKeys": [], "removedQueryParamKeys": [], "isEnabled": true,
           "createdAt": 700000001, "order": 1}
        ]
        """
        let (rules, total) = InterceptRuleStore.decodeRules(from: Data(mixed.utf8))
        XCTAssertEqual(total, 3, "The element count was lost, so the UI cannot report the skip")
        XCTAssertEqual(rules.count, 2, "One bad rule took the good ones with it")
        XCTAssertEqual(Set(rules.map { $0.id }), ["good-1", "good-2"])
    }

    /// A rule written by a NEWER build — unknown enum raw values, unknown
    /// fields — must degrade, not vanish.
    func testARuleFromANewerBuildDegradesInsteadOfVanishing() {
        let future = """
        [
          {"id": "future-1", "matchEndpoint": "/a", "matchMode": "exact", "matchHosts": [],
           "matchHost": "api.example.com", "name": "From the future",
           "isBlocked": false, "headerOverrides": [], "queryParamOverrides": [],
           "removedHeaderKeys": [], "removedQueryParamKeys": [], "isEnabled": true,
           "createdAt": 700000000, "order": 0,
           "breakpointMode": "someModeThatDoesNotExistYet",
           "redirectMode": "quantumTunnel",
           "unknownFutureField": {"nested": true}}
        ]
        """
        let (rules, _) = InterceptRuleStore.decodeRules(from: Data(future.utf8))
        XCTAssertEqual(rules.count, 1, "An unknown enum value discarded the whole rule")
        XCTAssertEqual(rules.first?.name, "From the future")
        XCTAssertEqual(rules.first?.matchHost, "api.example.com")
        XCTAssertEqual(rules.first?.breakpointMode, .off)
    }

    /// Encode → decode must be lossless for the two new fields, or a rule loses
    /// its pin the next time the app launches.
    func testTheNewFieldsSurviveAFullEncodeDecodeRoundTrip() throws {
        var rule = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: "api.example.com")
        rule.name = "Checkout 500"
        rule.mock = MockResponse(isEnabled: true, statusCode: 500, body: "{}")

        let data = try JSONEncoder().encode([rule])
        let (decoded, _) = InterceptRuleStore.decodeRules(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.matchHost, "api.example.com")
        XCTAssertEqual(decoded.first?.name, "Checkout 500")
        XCTAssertEqual(decoded.first?.storageKey, rule.storageKey,
                       "A round-tripped rule lands in a different bucket than it was saved from")
    }
}
