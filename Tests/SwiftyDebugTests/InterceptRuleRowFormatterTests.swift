//
//  InterceptRuleRowFormatterTests.swift
//  SwiftyDebugTests
//
//  Reported: "it should have names the rules ... note that mock, breakpoint and
//  rewrite does not have names that make it easier to know".
//
//  Every screen that lists rules built its own summary out of header and query
//  parameter COUNTS, so a rule that only mocked, only held a breakpoint, only
//  rewrote a response, only redirected or only blocked counted zero of both and
//  rendered as "Empty rule" — three different rules, three identical rows.
//
//  Since an endpoint rule can now also be pinned to a host, the second half of
//  these tests pins the other half of the complaint: "/cart on api.example.com"
//  and "/cart on any host" are two legal rules and must never render the same
//  string.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class InterceptRuleRowFormatterTests: XCTestCase {

    // The path from the report, kept verbatim: it is the one that came back
    // looking cut short.
    private let reportedPath = "/product/10289032912/20920220"

    // MARK: - Helpers

    private func endpointRule(path: String = "/cart",
                              mode: EndpointMatchMode = .exact,
                              host: String? = nil) -> InterceptRule {
        InterceptRule.endpointRule(path: path, mode: mode, host: host)
    }

    private func mockRule() -> InterceptRule {
        var rule = endpointRule()
        rule.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")
        return rule
    }

    private func breakpointRule() -> InterceptRule {
        var rule = endpointRule()
        rule.breakpointMode = .afterResponse
        return rule
    }

    private func rewriteRule() -> InterceptRule {
        var rule = endpointRule()
        rule.responseRewrites = [ResponseRewrite(pattern: "data.url",
                                                 action: .replaceHost("beta.example.com"))]
        return rule
    }

    private func redirectRule() -> InterceptRule {
        var rule = endpointRule()
        rule.redirectMode = .host
        rule.redirectTarget = "beta.example.com"
        return rule
    }

    private func blockRule() -> InterceptRule {
        var rule = endpointRule()
        rule.isBlocked = true
        return rule
    }

    // MARK: - A rule that does something is never called "empty"

    func testMockOnlyRuleIsNamedAfterItsMock() {
        let title = InterceptRuleRowFormatter.title(for: mockRule())
        XCTAssertTrue(title.contains("404"), "Expected the mock's status in the row title, got \(title)")
        XCTAssertFalse(InterceptRuleRowFormatter.isInert(mockRule()))
    }

    func testBreakpointOnlyRuleIsNamedAfterItsBreakpoint() {
        let title = InterceptRuleRowFormatter.title(for: breakpointRule())
        XCTAssertTrue(title.lowercased().contains("breakpoint"), title)
        XCTAssertFalse(InterceptRuleRowFormatter.isInert(breakpointRule()))
    }

    func testRewriteOnlyRuleIsNamedAfterItsRewrite() {
        let title = InterceptRuleRowFormatter.title(for: rewriteRule())
        XCTAssertTrue(title.lowercased().contains("rewrite"), title)
        XCTAssertTrue(title.contains("data.url"), title)
        XCTAssertFalse(InterceptRuleRowFormatter.isInert(rewriteRule()))
    }

    func testRedirectOnlyRuleIsNamedAfterItsTarget() {
        let title = InterceptRuleRowFormatter.title(for: redirectRule())
        XCTAssertTrue(title.contains("beta.example.com"), title)
        XCTAssertFalse(InterceptRuleRowFormatter.isInert(redirectRule()))
    }

    func testBlockOnlyRuleIsNamedAndTintedRed() {
        let rule = blockRule()
        XCTAssertTrue(InterceptRuleRowFormatter.title(for: rule).lowercased().contains("block"))
        XCTAssertEqual(InterceptRuleRowFormatter.titleColor(for: rule), .systemRed)
        XCTAssertFalse(InterceptRuleRowFormatter.isInert(rule))
    }

    /// The actual reported symptom: five rules on the SAME path, each doing a
    /// different thing, all previously rendering as one string.
    func testFiveDifferentlyArmedRulesOnTheSamePathAllRenderDifferently() {
        let titles = [mockRule(), breakpointRule(), rewriteRule(), redirectRule(), blockRule()]
            .map { InterceptRuleRowFormatter.title(for: $0) }

        XCTAssertEqual(Set(titles).count, titles.count,
                       "Rules doing different things must not share a row title: \(titles)")
        for title in titles {
            XCTAssertNotEqual(title, InterceptRuleRowFormatter.inertNote)
            XCTAssertFalse(title.lowercased().contains("empty"), title)
        }
    }

    /// Only a rule with genuinely nothing armed is allowed to say it does
    /// nothing — and it has to say it plainly rather than leave a blank row.
    func testOnlyAGenuinelyUnarmedRuleSaysItDoesNothing() {
        let empty = endpointRule()
        XCTAssertTrue(InterceptRuleRowFormatter.isInert(empty))
        XCTAssertTrue(InterceptRuleRowFormatter.detailText(for: empty)
            .contains(InterceptRuleRowFormatter.inertNote))

        for armed in [mockRule(), breakpointRule(), rewriteRule(), redirectRule(), blockRule()] {
            XCTAssertFalse(InterceptRuleRowFormatter.detailText(for: armed)
                .contains(InterceptRuleRowFormatter.inertNote),
                           "An armed rule claimed to do nothing: \(InterceptRuleRowFormatter.title(for: armed))")
        }
    }

    /// A rule carrying only header/param overrides kept working the way it did
    /// before — this is the one case the old code got right.
    func testHeaderOnlyRuleStillCountsItsHeaders() {
        var rule = endpointRule()
        rule.headerOverrides = [KVPair(key: "A", value: "1"), KVPair(key: "B", value: "2")]
        XCTAssertTrue(InterceptRuleRowFormatter.title(for: rule).contains("2 headers"))
    }

    // MARK: - The user's own name wins

    func testUserGivenNameReplacesTheDerivedOne() {
        var rule = mockRule()
        rule.name = "Sold out product"
        XCTAssertEqual(InterceptRuleRowFormatter.title(for: rule), "Sold out product")
    }

    func testWhitespaceOnlyNameFallsBackToWhatTheRuleDoes() {
        var rule = mockRule()
        rule.name = "   \n "
        XCTAssertEqual(InterceptRuleRowFormatter.title(for: rule),
                       InterceptRuleRowFormatter.title(for: mockRule()))
    }

    /// Naming a rule must not hide WHERE it applies: the scope lives on its own
    /// line precisely so a name can be anything the user likes.
    func testNamingARuleDoesNotHideItsScope() {
        var rule = endpointRule(path: "/cart", host: "api.example.com")
        rule.name = "Anything at all"
        let detail = InterceptRuleRowFormatter.detailText(for: rule)
        XCTAssertTrue(detail.contains("/cart"), detail)
        XCTAssertTrue(detail.contains("api.example.com"), detail)
    }

    // MARK: - Scope is unambiguous

    func testExactScopeShowsTheFullPathAndNeverTruncatesIt() {
        let rule = endpointRule(path: reportedPath, mode: .exact)
        XCTAssertTrue(InterceptRuleRowFormatter.scopeText(for: rule).contains(reportedPath),
                      InterceptRuleRowFormatter.scopeText(for: rule))
    }

    func testAnyHostEndpointRuleSaysSoOutLoud() {
        let rule = endpointRule(path: "/product/{id}", mode: .normalized, host: nil)
        XCTAssertEqual(InterceptRuleRowFormatter.scopeText(for: rule), "/product/{id} on any host")
    }

    func testHostPinnedEndpointRuleNamesItsHost() {
        let rule = endpointRule(path: "/product/{id}", mode: .normalized, host: "api.example.com")
        XCTAssertEqual(InterceptRuleRowFormatter.scopeText(for: rule),
                       "/product/{id} on api.example.com")
    }

    /// Three rules, one path, three scopes. Two of them are legal at the same
    /// time now, so if any two rendered alike the list would be lying.
    func testSamePathOnDifferentHostsNeverRendersTheSame() {
        let scopes = [
            InterceptRuleRowFormatter.scopeText(for: endpointRule(path: "/cart", host: nil)),
            InterceptRuleRowFormatter.scopeText(for: endpointRule(path: "/cart", host: "a.com")),
            InterceptRuleRowFormatter.scopeText(for: endpointRule(path: "/cart", host: "b.com")),
        ]
        XCTAssertEqual(Set(scopes).count, 3, "Scopes collided: \(scopes)")
    }

    func testHostPinIsShownCanonicalisedTheWayItIsMatched() {
        var rule = endpointRule(path: "/cart")
        rule.matchHost = "  API.Example.COM  "
        XCTAssertEqual(InterceptRuleRowFormatter.scopeText(for: rule), "/cart on api.example.com")
    }

    func testHostRuleListsItsHosts() {
        var rule = InterceptRule(matchEndpoint: "host:a.com,b.com", matchMode: .host)
        rule.matchHosts = ["b.com", "a.com"]
        let scope = InterceptRuleRowFormatter.scopeText(for: rule)
        XCTAssertTrue(scope.contains("a.com") && scope.contains("b.com"), scope)
    }

    /// A host rule with no hosts matches nothing at all. Saying nothing would
    /// read as "matches everything", which is the opposite.
    func testHostRuleWithNoHostsSaysItMatchesNothing() {
        let rule = InterceptRule(matchEndpoint: "host:", matchMode: .host)
        XCTAssertTrue(InterceptRuleRowFormatter.scopeText(for: rule).lowercased().contains("nothing"))
    }

    func testGlobalRuleSaysItAppliesEverywhere() {
        let rule = InterceptRule(matchEndpoint: "global", matchMode: .global)
        XCTAssertTrue(InterceptRuleRowFormatter.scopeText(for: rule).lowercased().contains("every request"))
    }

    func testEndpointRuleWithNoPathStillSaysSomething() {
        let rule = InterceptRule(matchEndpoint: "", matchMode: .exact)
        XCTAssertFalse(InterceptRuleRowFormatter.scopeText(for: rule).isEmpty)
        XCTAssertTrue(InterceptRuleRowFormatter.scopeText(for: rule).contains("any host"))
    }

    // MARK: - "Disabled" only where there is no switch

    func testDisabledIsMentionedOnlyWhenAskedFor() {
        var rule = mockRule()
        rule.isEnabled = false

        XCTAssertFalse(InterceptRuleRowFormatter.detailText(for: rule).contains("Disabled"),
                       "The rule list and App tab both show a switch — do not say it twice.")
        XCTAssertTrue(InterceptRuleRowFormatter.detailText(for: rule, includeEnabledState: true)
            .contains("Disabled"))

        var live = mockRule()
        live.isEnabled = true
        XCTAssertFalse(InterceptRuleRowFormatter.detailText(for: live, includeEnabledState: true)
            .contains("Disabled"))
    }

    // MARK: - Badges

    func testBadgePerMode() {
        XCTAssertEqual(InterceptRuleRowFormatter.badge(for: .exact), "EXACT")
        XCTAssertEqual(InterceptRuleRowFormatter.badge(for: .normalized), "PATTERN")
        XCTAssertEqual(InterceptRuleRowFormatter.badge(for: .host), "HOST")
        XCTAssertEqual(InterceptRuleRowFormatter.badge(for: .global), "GLOBAL")
    }

    func testAttributedTitleLeadsWithTheBadgeThenTheName() {
        var rule = mockRule()
        rule.name = "Sold out"
        let text = InterceptRuleRowFormatter.attributedTitle(for: rule).string
        XCTAssertTrue(text.hasPrefix("EXACT"), text)
        XCTAssertTrue(text.hasSuffix("Sold out"), text)
    }

    /// The transfer screens must not drift back into their own wording.
    func testTransferFormatterDelegatesToTheSharedOne() {
        var rule = mockRule()
        rule.isEnabled = false
        XCTAssertEqual(RuleTransferFormatter.attributedTitle(for: rule).string,
                       InterceptRuleRowFormatter.attributedTitle(for: rule).string)
        XCTAssertTrue(RuleTransferFormatter.subtitle(for: rule).contains("Disabled"),
                      "The export list has no switch, so it has to say a rule is off.")
        XCTAssertFalse(RuleTransferFormatter.subtitle(for: rule).lowercased().contains("empty rule"))
    }

    // MARK: - Purity

    /// Row formatting runs inside `cellForRowAt`. Same rule in, same strings out,
    /// with nothing read from the store or the disk.
    func testFormattingIsPure() {
        let rule = rewriteRule()
        XCTAssertEqual(InterceptRuleRowFormatter.title(for: rule),
                       InterceptRuleRowFormatter.title(for: rule))
        XCTAssertEqual(InterceptRuleRowFormatter.detailText(for: rule),
                       InterceptRuleRowFormatter.detailText(for: rule))
    }
}
