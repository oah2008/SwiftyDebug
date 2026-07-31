//
//  InterceptRuleNamingTests.swift
//  SwiftyDebugTests
//
//  A rule that only mocks, only holds a breakpoint, only rewrites a response or
//  only redirects used to display as "Empty rule" everywhere it was listed —
//  the row summary counted headers and query parameters and nothing else. Three
//  such rules in a list were indistinguishable, which is why rules needed names.
//
//  `displayName` is the answer, so it is pinned here for every combination of
//  armed features, including the ones that are switched on but would silently do
//  nothing.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleNamingTests: XCTestCase {

    // MARK: - Builders

    private func endpointRule(_ path: String,
                              mode: EndpointMatchMode = .normalized,
                              host: String? = nil) -> InterceptRule {
        InterceptRule.endpointRule(path: path, mode: mode, host: host)
    }

    private func rewrite(_ pattern: String,
                         name: String = "",
                         isEnabled: Bool = true) -> ResponseRewrite {
        ResponseRewrite(pattern: pattern,
                        action: .setValue("x"),
                        isEnabled: isEnabled,
                        name: name)
    }

    private func pair(_ key: String) -> KVPair { KVPair(key: key, value: "v") }

    // MARK: - The examples the feature was specified with

    func testMockOnlyRuleIsNamedAfterItsStatusCode() {
        var rule = endpointRule("/product/{id}")
        rule.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")
        XCTAssertEqual(rule.displayName, "Mock 404 · /product/{id}")
    }

    func testBreakpointOnlyHostRuleIsNamedAfterItsStage() {
        var rule = InterceptRule.hostRule(hosts: ["api.example.com"])
        rule.breakpointMode = .afterResponse
        XCTAssertEqual(rule.displayName, "Breakpoint after response · api.example.com")
    }

    func testBeforeSendBreakpointNamesItsOwnStage() {
        var rule = endpointRule("/checkout")
        rule.breakpointMode = .beforeSend
        XCTAssertEqual(rule.displayName, "Breakpoint before send · /checkout")
    }

    func testSingleRewriteRuleIsNamedAfterItsPattern() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("data.url")]
        XCTAssertEqual(rule.displayName, "Rewrite data.url · /cart")
    }

    func testBlockedRuleSaysBlocked() {
        var rule = endpointRule("/analytics")
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked · /analytics")
    }

    func testHeaderOnlyRuleCountsItsHeaders() {
        var rule = endpointRule("/product/{id}")
        rule.headerOverrides = [pair("A"), pair("B")]
        rule.removedHeaderKeys = ["c"]
        XCTAssertEqual(rule.displayName, "3 headers · /product/{id}")
    }

    // MARK: - Every armed feature on its own

    func testRedirectOnlyRuleNamesItsTarget() {
        var rule = endpointRule("/v1/thing")
        rule.redirectMode = .host
        rule.redirectTarget = "beta.example.com"
        XCTAssertEqual(rule.displayName, "Redirect \u{2192} beta.example.com · /v1/thing")
    }

    func testSingleHeaderIsSingular() {
        var rule = endpointRule("/x")
        rule.headerOverrides = [pair("A")]
        XCTAssertEqual(rule.displayName, "1 header · /x")
    }

    func testQueryParamsAreCountedSeparatelyFromHeaders() {
        var rule = endpointRule("/x")
        rule.queryParamOverrides = [pair("page")]
        rule.removedQueryParamKeys = ["debug"]
        XCTAssertEqual(rule.displayName, "2 params · /x")
    }

    func testHeadersAndParamsAreBothNamed() {
        var rule = endpointRule("/x")
        rule.headerOverrides = [pair("A")]
        rule.queryParamOverrides = [pair("page")]
        XCTAssertEqual(rule.displayName, "1 header + 1 param · /x")
    }

    // MARK: - Nothing armed

    func testEmptyRuleSaysSo() {
        XCTAssertEqual(endpointRule("/x").displayName, "Empty rule · /x")
    }

    func testDisabledMockIsNotNamed() {
        var rule = endpointRule("/x")
        rule.mock = MockResponse(isEnabled: false, statusCode: 500)
        XCTAssertEqual(rule.displayName, "Empty rule · /x")
    }

    func testBreakpointOffIsNotNamed() {
        var rule = endpointRule("/x")
        rule.breakpointMode = .off
        XCTAssertEqual(rule.displayName, "Empty rule · /x")
    }

    /// A redirect mode with no target does nothing on the wire, so naming the
    /// rule after it would be a lie of exactly the kind this file exists to stop.
    func testRedirectWithNoTargetIsNotNamed() {
        var rule = endpointRule("/x")
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "   "
        XCTAssertEqual(rule.displayName, "Empty rule · /x")
    }

    func testRedirectTargetIsTrimmed() {
        var rule = endpointRule("/x")
        rule.redirectMode = .host
        rule.redirectTarget = "  beta.com  "
        XCTAssertEqual(rule.displayName, "Redirect \u{2192} beta.com · /x")
    }

    // MARK: - Rewrites

    func testSeveralLiveRewritesAreCounted() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("a.b"), rewrite("c.d"), rewrite("e.f")]
        XCTAssertEqual(rule.displayName, "3 rewrites · /cart")
    }

    func testDisabledRewritesDoNotCountTowardsTheLiveOne() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("a.b", isEnabled: false), rewrite("c.d")]
        XCTAssertEqual(rule.displayName, "Rewrite c.d · /cart")
    }

    /// A rule that visibly carries rewrites must never read "Empty rule" — but it
    /// must also not claim to be doing something it is not.
    func testRewritesThatAreAllSwitchedOffSayThatOutLoud() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("a.b", isEnabled: false)]
        XCTAssertEqual(rule.displayName, "1 rewrite (off) · /cart")

        rule.responseRewrites = [rewrite("a.b", isEnabled: false), rewrite("c.d", isEnabled: false)]
        XCTAssertEqual(rule.displayName, "2 rewrites (off) · /cart")
    }

    func testARewriteWithItsOwnNameUsesIt() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("data.url", name: "Point images at staging")]
        XCTAssertEqual(rule.displayName, "Rewrite Point images at staging · /cart")
    }

    func testARewriteWithNoPatternAndNoNameStillCounts() {
        var rule = endpointRule("/cart")
        rule.responseRewrites = [rewrite("  ")]
        XCTAssertEqual(rule.displayName, "1 rewrite · /cart")
    }

    // MARK: - Combinations

    func testEverythingArmedAtOnceIsCombined() {
        var rule = endpointRule("/x")
        rule.isBlocked = true
        rule.mock = MockResponse(isEnabled: true, statusCode: 500)
        rule.breakpointMode = .beforeSend
        rule.redirectMode = .host
        rule.redirectTarget = "beta.com"
        rule.responseRewrites = [rewrite("a.b")]
        rule.headerOverrides = [pair("A")]
        rule.queryParamOverrides = [pair("p")]

        XCTAssertEqual(rule.displayName,
                       "Blocked + Mock 500 + Breakpoint before send + Redirect \u{2192} beta.com"
                       + " + Rewrite a.b + 1 header + 1 param · /x")
    }

    func testMockAndBreakpointTogether() {
        var rule = endpointRule("/x", mode: .exact)
        rule.mock = MockResponse(isEnabled: true, statusCode: 201)
        rule.breakpointMode = .afterResponse
        XCTAssertEqual(rule.displayName, "Mock 201 + Breakpoint after response · /x")
    }

    // MARK: - Scope half of the name

    func testGlobalRuleNamesItsScope() {
        var rule = InterceptRule.globalRule()
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked · All requests")
    }

    func testHostRuleListsEveryHost() {
        var rule = InterceptRule.hostRule(hosts: ["b.com", "A.com"])
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked · a.com, b.com")
    }

    func testHostPinnedEndpointRuleReadsAsOneAddress() {
        var rule = endpointRule("/cart", mode: .exact, host: "API.Example.com")
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked · api.example.com/cart")
    }

    func testAnyHostEndpointRuleShowsOnlyThePath() {
        var rule = endpointRule("/cart", mode: .exact)
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked · /cart")
    }

    /// A host rule with no hosts has nothing to say about scope; the name must
    /// not trail a lonely separator.
    func testHostRuleWithNoHostsDropsTheSeparator() {
        var rule = InterceptRule(matchEndpoint: "host:", matchMode: .host)
        rule.matchHosts = []
        rule.isBlocked = true
        XCTAssertEqual(rule.displayName, "Blocked")
    }

    // MARK: - The user's own name wins

    func testAUserGivenNameReplacesTheDerivedOne() {
        var rule = endpointRule("/product/{id}")
        rule.mock = MockResponse(isEnabled: true, statusCode: 404)
        rule.name = "Sold out product"
        XCTAssertEqual(rule.displayName, "Sold out product")
        XCTAssertEqual(rule.derivedName, "Mock 404 · /product/{id}",
                       "the derived name stays available so an editor can offer it back")
    }

    func testAUserGivenNameIsTrimmed() {
        var rule = endpointRule("/x")
        rule.isBlocked = true
        rule.name = "  Kill analytics \n"
        XCTAssertEqual(rule.displayName, "Kill analytics")
    }

    func testAWhitespaceOnlyNameFallsBackToTheDerivedOne() {
        var rule = endpointRule("/x")
        rule.isBlocked = true
        rule.name = "   "
        XCTAssertEqual(rule.displayName, "Blocked · /x")
    }

    // MARK: - Purity

    func testDisplayNameIsPureAndDoesNotMutateTheRule() {
        var rule = endpointRule("/product/{id}")
        rule.mock = MockResponse(isEnabled: true, statusCode: 404)
        rule.responseRewrites = [rewrite("a.b")]

        let first = rule.displayName
        let second = rule.displayName
        XCTAssertEqual(first, second)
        XCTAssertEqual(rule.matchEndpoint, "/product/{id}")
        XCTAssertEqual(rule.responseRewrites.count, 1)
        XCTAssertTrue(rule.name.isEmpty)
    }

    func testTwoIdenticallyConfiguredRulesDeriveTheSameName() {
        var a = endpointRule("/x", mode: .exact, host: "a.com")
        var b = endpointRule("/x", mode: .exact, host: "a.com")
        a.breakpointMode = .afterResponse
        b.breakpointMode = .afterResponse
        XCTAssertEqual(a.derivedName, b.derivedName)
        XCTAssertNotEqual(a.id, b.id, "different rules, same description")
    }

    // MARK: - Names survive a round trip, and their absence is not fatal

    func testNameRoundTripsThroughCodable() throws {
        var rule = endpointRule("/x")
        rule.isBlocked = true
        rule.name = "Kill analytics"
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(InterceptRule.self, from: data)
        XCTAssertEqual(back.name, "Kill analytics")
        XCTAssertEqual(back.displayName, "Kill analytics")
    }

    func testARuleWrittenBeforeNamesExistedStillDecodesAndIsIdentifiable() {
        let legacy = Data("""
        [{
          "id": "old-1",
          "matchEndpoint": "/product/{id}",
          "matchMode": "normalized",
          "isBlocked": false,
          "headerOverrides": [], "queryParamOverrides": [],
          "removedHeaderKeys": [], "removedQueryParamKeys": [],
          "isEnabled": true, "createdAt": 0, "order": 0,
          "mock": { "isEnabled": true, "statusCode": 404, "body": "{}", "headers": [], "delay": 0 }
        }]
        """.utf8)

        let (rules, total) = InterceptRuleStore.decodeRules(from: legacy)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(rules.count, 1, "a missing name must never cost a rule")
        XCTAssertEqual(rules.first?.name, "")
        XCTAssertEqual(rules.first?.displayName, "Mock 404 · /product/{id}")
    }
}
