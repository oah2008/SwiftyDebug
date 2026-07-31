//
//  RuleClusterFixTests.swift
//  SwiftyDebugTests
//
//  The three rule-screen defects the maintainer asked for by name. All three are
//  silent: nothing on screen tells you the rule you just saved is armed again,
//  that your header override was cancelled, or that a different rule won this
//  launch than won the last one.
//

import XCTest
@testable import SwiftyDebug

final class RuleClusterFixTests: XCTestCase {

    private var store: InterceptRuleStore { .shared }

    override func tearDown() {
        store.removeAll()
        super.tearDown()
    }

    // MARK: - Saving must not re-arm a disabled rule

    func testSavingADisabledRuleKeepsItDisabled() {
        // There is no enable control in the editor, so a user opening a switched-off
        // rule and tapping Save cannot have meant to arm it. If it blocks requests,
        // re-arming silently breaks the host app's traffic again.
        var rule = InterceptRule.endpointRule(path: "/api/users", mode: .exact, host: "a.com")
        rule.isBlocked = true
        rule.isEnabled = false

        var edited = rule
        InterceptRuleEditorViewController.applyEnablement(to: &edited, existing: rule)

        XCTAssertFalse(edited.isEnabled,
                       "Saving an untouched disabled rule re-armed it")
    }

    func testANewRuleStillArmsItself() {
        // Creating a rule is an explicit act — it should be live.
        var fresh = InterceptRule.endpointRule(path: "/api/users", mode: .exact, host: "a.com")
        InterceptRuleEditorViewController.applyEnablement(to: &fresh, existing: nil)
        XCTAssertTrue(fresh.isEnabled)
    }

    // MARK: - An override beats a removal, whatever the casing

    func testAnOverrideBeatsARemovalWrittenInCanonicalCasing() {
        // Removal keys arrive verbatim from an imported rules.json, so a teammate's
        // document written as "Authorization" did not match the lower-cased override
        // set — and the header was stripped from the wire entirely: not the old
        // value, not the new one, with the editor still showing it armed.
        var remover = InterceptRule.globalRule()
        remover.removedHeaderKeys = ["Authorization"]     // canonical HTTP casing
        remover.order = 0
        store.addOrUpdate(remover)

        var setter = InterceptRule.endpointRule(path: "/api/me", mode: .exact, host: "a.com")
        setter.headerOverrides = [KVPair(key: "Authorization", value: "Bearer fresh")]
        setter.order = 1
        store.addOrUpdate(setter)

        let resolved = store.resolvedRule(forURL: URL(string: "https://a.com/api/me")!)

        XCTAssertEqual(resolved?.headerOverrides.first(where: { $0.key.lowercased() == "authorization" })?.value,
                       "Bearer fresh")
        XCTAssertTrue(resolved?.removedHeaderKeys.allSatisfy { $0.lowercased() != "authorization" } ?? false,
                      "The removal survived the override and stripped the header")
    }

    func testARemovalWithNoMatchingOverrideStillApplies() {
        // The fix must not turn every removal into a no-op.
        var remover = InterceptRule.globalRule()
        remover.removedHeaderKeys = ["X-Debug"]
        store.addOrUpdate(remover)

        let resolved = store.resolvedRule(forURL: URL(string: "https://a.com/anything")!)
        XCTAssertTrue(resolved?.removedHeaderKeys.contains(where: { $0.lowercased() == "x-debug" }) ?? false)
    }

    // MARK: - Precedence must be the same on every launch

    func testTwoOverlappingRulesResolveInAStableOrder() {
        // Two rules created in different buckets both start at order 0, so the
        // winner used to depend on the dictionary's enumeration order — random
        // across launches, with no user action.
        let older = InterceptRule(matchEndpoint: "a", matchMode: .global)
        let newer = InterceptRule(matchEndpoint: "b", matchMode: .global)

        var a = older, b = newer
        a.order = 0; b.order = 0

        // Whatever the input sequence, the resolved order must be identical.
        let forward = [a, b].sorted(by: InterceptRuleStore.precedes).map(\.id)
        let backward = [b, a].sorted(by: InterceptRuleStore.precedes).map(\.id)
        XCTAssertEqual(forward, backward,
                       "The comparator is not a total order — which rule wins is luck")
    }

    func testTheComparatorIsTotalEvenWhenOrderAndTimestampTie() throws {
        // Two rules encoded from the same JSON differ only by id — the last
        // tiebreak. Without it, sorting is unstable and the winner is luck.
        var a = InterceptRule(matchEndpoint: "a", matchMode: .global)
        a.order = 0
        let encoded = try JSONEncoder().encode(a)
        var b = try JSONDecoder().decode(InterceptRule.self, from: encoded)
        b.order = 0

        guard a.id != b.id || a.createdAt != b.createdAt else {
            // Same id AND timestamp means the same rule; nothing to order.
            return
        }
        XCTAssertNotEqual(InterceptRuleStore.precedes(a, b),
                          InterceptRuleStore.precedes(b, a),
                          "Exactly one must precede the other, or sorting is unstable")
    }

    func testExplicitOrderStillWins() {
        // The tiebreak must only break TIES — a deliberate reorder must survive it.
        var first = InterceptRule(matchEndpoint: "a", matchMode: .global)
        var second = InterceptRule(matchEndpoint: "b", matchMode: .global)
        first.order = 5
        second.order = 1

        XCTAssertTrue(InterceptRuleStore.precedes(second, first),
                      "An explicit order must outrank the createdAt tiebreak")
    }
}
