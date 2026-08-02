//
//  RuleDuplicationBehaviourTests.swift
//  SwiftyDebugTests
//
//  What a duplicated rule IS, as opposed to where you can duplicate one from
//  (RuleDuplicationWiringTests).
//
//  Rules are bucketed by mode + host pin + endpoint, so a copy lands in the
//  SAME bucket as its original by definition — the one arrangement where a
//  half-copied identity does real damage:
//
//    * share the `id` and `addOrUpdate` treats the copy as an edit of the
//      original, and the original is gone;
//    * share `ResponseRewrite.id` and two rules matching the same request both
//      contribute a rewrite with that id to ONE composite;
//    * carry `isEnabled` across and the copy fires on exactly the request its
//      original already matched, the instant it exists — and rewrites
//      ACCUMULATE across matching rules, so the same edit runs twice.
//
//  Every one of those is pinned below, plus the plain requirement: a copy
//  carries everything.
//

import XCTest
@testable import SwiftyDebug

final class RuleDuplicationBehaviourTests: XCTestCase {

    private let path = "/product/10289032912/20920220"
    private let host = "api.example.com"

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A rule with something armed in every category the model has.
    private func fullRule(name: String = "Kill product tracking") -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: .exact, host: host)
        rule.name = name
        rule.isBlocked = false
        rule.headerOverrides = [KVPair(key: "Authorization", value: "Bearer abc"),
                                KVPair(key: "Accept", value: "application/json")]
        rule.queryParamOverrides = [KVPair(key: "page", value: "2")]
        rule.removedHeaderKeys = ["x-trace", "x-session"]
        rule.removedQueryParamKeys = ["utm_source"]
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "beta.example.com/checkout/xyz"
        rule.mock = MockResponse(isEnabled: true, statusCode: 404,
                                 body: "{\"error\":\"nope\"}",
                                 headers: [KVPair(key: "X-Mock", value: "1")], delay: 1.5)
        rule.breakpointMode = .afterResponse
        rule.responseRewrites = [
            ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"),
                            isEnabled: true, name: "point at salla"),
            ResponseRewrite(pattern: "data.token", action: .removeKey,
                            isEnabled: false, name: "drop token"),
        ]
        return rule
    }

    private func duplicate(of rule: InterceptRule, among others: [InterceptRule] = []) -> InterceptRule {
        InterceptRuleDuplicator.duplicate(rule, among: others.isEmpty ? [rule] : others)
    }

    // MARK: - 1. Its own identity

    func testTheCopyHasItsOwnIdAndCreationDate() {
        let original = fullRule()
        let copy = duplicate(of: original)

        XCTAssertNotEqual(copy.id, original.id,
                          "A shared id makes `addOrUpdate` treat the copy as an edit and the original disappears")
        XCTAssertFalse(copy.id.isEmpty)
        XCTAssertGreaterThanOrEqual(copy.createdAt, original.createdAt,
                                    "The copy is new; `createdAt` orders the lists that show it")
    }

    func testNestedIdentitiesAreFreshToo() {
        let original = fullRule()
        let copy = duplicate(of: original)

        let originalRewriteIds = Set(original.responseRewrites.map { $0.id })
        let copyRewriteIds = Set(copy.responseRewrites.map { $0.id })
        XCTAssertTrue(originalRewriteIds.isDisjoint(with: copyRewriteIds),
                      "Two rules matching the same request contribute their rewrites to one composite; "
                        + "duplicated rewrite ids make that composite ambiguous")

        let originalPairIds = Set((original.headerOverrides + original.queryParamOverrides
                                   + original.mock.headers).map { $0.id })
        let copyPairIds = Set((copy.headerOverrides + copy.queryParamOverrides
                               + copy.mock.headers).map { $0.id })
        XCTAssertTrue(originalPairIds.isDisjoint(with: copyPairIds),
                      "Header/param pairs must be re-minted, not shared")
    }

    // MARK: - 2. It carries everything

    func testTheCopyCarriesEverythingTheOriginalHad() {
        let original = fullRule()
        let copy = duplicate(of: original)

        // Scope + host pin.
        XCTAssertEqual(copy.matchMode, original.matchMode)
        XCTAssertEqual(copy.matchEndpoint, original.matchEndpoint)
        XCTAssertEqual(copy.matchHost, original.matchHost)
        XCTAssertEqual(copy.matchHosts, original.matchHosts)
        XCTAssertEqual(copy.storageKey, original.storageKey,
                       "A copy matches what its original matched — same scope, same bucket")

        // Headers / params, values AND removals (what "active" means once saved).
        XCTAssertEqual(copy.headerOverrides.map { [$0.key, $0.value] },
                       original.headerOverrides.map { [$0.key, $0.value] })
        XCTAssertEqual(copy.queryParamOverrides.map { [$0.key, $0.value] },
                       original.queryParamOverrides.map { [$0.key, $0.value] })
        XCTAssertEqual(copy.removedHeaderKeys, original.removedHeaderKeys)
        XCTAssertEqual(copy.removedQueryParamKeys, original.removedQueryParamKeys)

        // Everything else that changes the wire.
        XCTAssertEqual(copy.isBlocked, original.isBlocked)
        XCTAssertEqual(copy.redirectMode, original.redirectMode)
        XCTAssertEqual(copy.redirectTarget, original.redirectTarget)
        XCTAssertEqual(copy.breakpointMode, original.breakpointMode)

        XCTAssertEqual(copy.mock.isEnabled, original.mock.isEnabled)
        XCTAssertEqual(copy.mock.statusCode, original.mock.statusCode)
        XCTAssertEqual(copy.mock.body, original.mock.body)
        XCTAssertEqual(copy.mock.delay, original.mock.delay)
        XCTAssertEqual(copy.mock.headers.map { [$0.key, $0.value] },
                       original.mock.headers.map { [$0.key, $0.value] })

        XCTAssertEqual(copy.responseRewrites.count, original.responseRewrites.count)
        for (mine, theirs) in zip(copy.responseRewrites, original.responseRewrites) {
            XCTAssertEqual(mine.pattern, theirs.pattern)
            XCTAssertEqual(mine.action, theirs.action)
            XCTAssertEqual(mine.name, theirs.name)
            XCTAssertEqual(mine.isEnabled, theirs.isEnabled,
                           "A rewrite's own on/off flag is part of the rule and must survive the copy")
        }
    }

    func testABlockingRuleCopiesAsABlockingRule() {
        var original = InterceptRule.endpointRule(path: "/analytics", mode: .normalized, host: host)
        original.isBlocked = true
        let copy = duplicate(of: original)
        XCTAssertTrue(copy.isBlocked)
    }

    func testHostAndGlobalRulesCopyTheirScopeToo() {
        var hostRule = InterceptRule.hostRule(hosts: ["a.com", "b.com"])
        hostRule.isBlocked = true
        let hostCopy = duplicate(of: hostRule)
        XCTAssertEqual(hostCopy.matchMode, .host)
        XCTAssertEqual(hostCopy.matchHosts, ["a.com", "b.com"])
        XCTAssertEqual(hostCopy.storageKey, hostRule.storageKey)

        var global = InterceptRule.globalRule()
        global.isBlocked = true
        let globalCopy = duplicate(of: global)
        XCTAssertEqual(globalCopy.matchMode, .global)
        XCTAssertEqual(globalCopy.storageKey, global.storageKey)
    }

    // MARK: - 3. It arrives switched off

    func testTheCopyIsCreatedDisabled() {
        let original = fullRule()
        XCTAssertTrue(original.isEnabled, "Precondition: the original is armed")
        XCTAssertFalse(duplicate(of: original).isEnabled,
                       "A copy shares its original's scope, so an armed copy changes the wire the "
                         + "instant it exists — before anyone has edited the thing they duplicated")
    }

    /// The concrete reason. Two matching rules ACCUMULATE their rewrites into
    /// one composite, so an armed copy of a rewrite rule runs the same edit
    /// twice.
    func testAnArmedCopyWouldDoubleTheRewritesOnTheWire() throws {
        var original = InterceptRule.endpointRule(path: path, mode: .exact, host: host)
        original.responseRewrites = [ResponseRewrite(pattern: "data.url",
                                                     action: .replaceHost("salla.com"))]
        InterceptRuleStore.shared.addOrUpdate(original)

        let url = try XCTUnwrap(URL(string: "https://\(host)\(path)"))
        let before = try XCTUnwrap(InterceptRuleStore.shared.resolvedRule(forURL: url))
        XCTAssertEqual(before.responseRewrites.count, 1)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        let after = try XCTUnwrap(InterceptRuleStore.shared.resolvedRule(forURL: url))
        XCTAssertEqual(after.responseRewrites.count, 1,
                       "A freshly duplicated rule changed what reaches the wire")

        // Arm it deliberately and the second copy does show up — which is
        // exactly why it does not arm itself.
        var armed = copy
        armed.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(armed)
        XCTAssertEqual(try XCTUnwrap(InterceptRuleStore.shared.resolvedRule(forURL: url)).responseRewrites.count, 2)
    }

    // MARK: - 4. It is distinguishable in a list

    func testANamedRuleGetsACopySuffix() {
        let original = fullRule(name: "Kill product tracking")
        let copy = duplicate(of: original)
        XCTAssertEqual(copy.name, "Kill product tracking copy")
        XCTAssertNotEqual(InterceptRuleRowFormatter.title(for: copy),
                          InterceptRuleRowFormatter.title(for: original),
                          "Two rules with the same scope must not render as the same row")
    }

    /// An UNNAMED rule describes itself from what it does, so its copy would
    /// otherwise be a pixel-identical row on the same scope.
    func testAnUnnamedRuleGetsANameSoTheCopyIsTellableApart() {
        var original = InterceptRule.endpointRule(path: "/cart", mode: .exact, host: host)
        original.isBlocked = true
        XCTAssertEqual(original.name, "", "Precondition: it names itself")

        let copy = duplicate(of: original)
        XCTAssertFalse(copy.name.isEmpty, "The copy of an unnamed rule must be given a name of its own")
        XCTAssertTrue(copy.name.hasSuffix(" copy"), "got \(copy.name)")
        XCTAssertNotEqual(InterceptRuleRowFormatter.title(for: copy),
                          InterceptRuleRowFormatter.title(for: original),
                          "An unnamed rule and its copy rendered identically")
        XCTAssertEqual(InterceptRuleRowFormatter.scopeText(for: copy),
                       InterceptRuleRowFormatter.scopeText(for: original),
                       "…while still saying it applies to the same requests")
    }

    func testDuplicatingACopyDoesNotStackTheWordCopy() {
        let original = fullRule(name: "Kill product tracking")
        let first = duplicate(of: original, among: [original])
        XCTAssertEqual(first.name, "Kill product tracking copy")

        let second = duplicate(of: first, among: [original, first])
        XCTAssertEqual(second.name, "Kill product tracking copy 2",
                       "Duplicating a copy must not produce \u{201C}… copy copy\u{201D}")

        let third = duplicate(of: second, among: [original, first, second])
        XCTAssertEqual(third.name, "Kill product tracking copy 3")
    }

    func testBaseNameStripsOnlyARealCopySuffix() {
        XCTAssertEqual(InterceptRuleDuplicator.baseName("Kill tracking"), "Kill tracking")
        XCTAssertEqual(InterceptRuleDuplicator.baseName("Kill tracking copy"), "Kill tracking")
        XCTAssertEqual(InterceptRuleDuplicator.baseName("Kill tracking copy 7"), "Kill tracking")
        // Not a suffix we added — leave the user's words alone.
        XCTAssertEqual(InterceptRuleDuplicator.baseName("copy headers to staging"),
                       "copy headers to staging")
        XCTAssertEqual(InterceptRuleDuplicator.baseName("Xerox copy machine"), "Xerox copy machine")
    }

    // MARK: - 5. Both survive the store, and each is editable and deletable

    func testBothTwinsSurviveTheSameBucketAndStayIndependent() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertEqual(copy.storageKey, original.storageKey, "Precondition: same bucket")

        var stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2, "One of the twins was swallowed by the other")
        XCTAssertEqual(InterceptRuleStore.shared.rules(forStorageKey: original.storageKey).count, 2)

        // Edit the COPY. The original must not move.
        var editedCopy = try XCTUnwrap(stored.first { $0.id == copy.id })
        editedCopy.name = "edited copy"
        editedCopy.mock = MockResponse(isEnabled: true, statusCode: 500, body: "{}")
        editedCopy.matchHost = "other.example.com"
        InterceptRuleStore.shared.addOrUpdate(editedCopy)

        stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2)
        let originalNow = try XCTUnwrap(stored.first { $0.id == original.id })
        XCTAssertEqual(originalNow.name, original.name, "Editing the copy renamed the original")
        XCTAssertEqual(originalNow.mock.statusCode, 404, "Editing the copy overwrote the original's mock")
        XCTAssertEqual(originalNow.matchHost, host, "Editing the copy re-scoped the original")

        // Delete the ORIGINAL. The copy must survive, re-scoped and all.
        InterceptRuleStore.shared.remove(id: original.id)
        let left = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.id, copy.id)
        XCTAssertEqual(left.first?.name, "edited copy")
    }

    /// The other direction: editing the ORIGINAL must not touch the copy.
    func testEditingTheOriginalLeavesTheCopyAlone() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        var edited = original
        edited.name = "renamed original"
        edited.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(edited)

        let copyNow = try XCTUnwrap(InterceptRuleStore.shared.allRules().first { $0.id == copy.id })
        XCTAssertEqual(copyNow.name, copy.name)
        XCTAssertFalse(copyNow.isBlocked)
        XCTAssertFalse(copyNow.isEnabled, "The copy must still be the switched-off one it was created as")
    }

    func testDuplicateAndStoreReadsTheStoreNotAStaleSnapshot() throws {
        var rule = fullRule(name: "before")
        InterceptRuleStore.shared.addOrUpdate(rule)
        let staleSnapshot = rule

        rule.name = "after"
        rule.breakpointMode = .beforeSend
        InterceptRuleStore.shared.addOrUpdate(rule)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: staleSnapshot.id))
        XCTAssertEqual(copy.name, "after copy",
                       "The copy was made from a pre-edit snapshot, resurrecting old content")
        XCTAssertEqual(copy.breakpointMode, .beforeSend)
    }

    func testDuplicatingARuleThatIsAlreadyGoneDoesNothing() {
        let rule = fullRule()
        InterceptRuleStore.shared.addOrUpdate(rule)
        InterceptRuleStore.shared.remove(id: rule.id)

        XCTAssertNil(InterceptRuleDuplicator.duplicateAndStore(id: rule.id))
        XCTAssertTrue(InterceptRuleStore.shared.allRules().isEmpty,
                      "Duplicating a deleted rule put it back")
    }

    // MARK: - 6. The copy survives a round trip through disk

    func testTheCopyEncodesAndDecodesUnchanged() throws {
        let copy = duplicate(of: fullRule())
        let data = try JSONEncoder().encode([copy])
        let (decoded, total) = InterceptRuleStore.decodeRules(from: data)
        XCTAssertEqual(total, 1)
        let round = try XCTUnwrap(decoded.first)

        XCTAssertEqual(round.id, copy.id)
        XCTAssertEqual(round.name, copy.name)
        XCTAssertFalse(round.isEnabled, "A copy must still be switched off after a relaunch")
        XCTAssertEqual(round.mock.statusCode, copy.mock.statusCode)
        XCTAssertEqual(round.responseRewrites.map { $0.id }, copy.responseRewrites.map { $0.id })
        XCTAssertEqual(round.storageKey, copy.storageKey)
    }
}
