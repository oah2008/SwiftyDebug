//
//  AdversarialRuleDuplicationTests.swift
//  SwiftyDebugTests
//
//  Duplication, driven the way a user drives it and then attacked.
//
//  `RuleDuplicationBehaviourTests` establishes what a copy IS. This file goes
//  after the arrangement the maintainer called out as the risky one — a copy
//  lands in the SAME storage bucket as its original — and at the sequences a
//  bucket makes fragile:
//
//    * duplicate, then move the copy to a DIFFERENT bucket (edit its scope) and
//      check the original did not move, change, or lose a single field;
//    * duplicate a duplicate a duplicate — three rules, one bucket, three
//      identities, three names;
//    * duplicate, delete the ORIGINAL, arm the copy, and check the copy is what
//      `resolvedRule(forURL:)` actually hands the networking layer;
//    * duplicate twice and delete the MIDDLE one, which is where `order`
//      re-packing lives;
//    * the shapes nobody types on purpose: no host pin, an empty endpoint, a
//      2 000-character path, a name in Arabic with an emoji, and a copy of a
//      rule that is already switched off.
//
//  Every field comparison goes through `fingerprint`, which reads EVERY stored
//  property of `InterceptRule`. A field added to the model and forgotten in
//  `InterceptRuleDuplicator.duplicate` fails here rather than shipping.
//

import XCTest
@testable import SwiftyDebug

final class AdversarialRuleDuplicationTests: XCTestCase {

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

    // MARK: - Helpers

    /// Every stored property of a rule, flattened, EXCEPT the three that a copy
    /// is supposed to differ in (`id`, `createdAt`, `isEnabled`) and `order`,
    /// which is a position in a bucket and is re-packed by the store on purpose.
    ///
    /// Built from `Mirror` so a new field on the model shows up here without
    /// anyone remembering to add it — the failure mode this guards is exactly
    /// "someone added a field and `duplicate` did not copy it".
    private func fingerprint(_ rule: InterceptRule) -> String {
        let skipped: Set<String> = ["id", "createdAt", "isEnabled", "order", "name"]
        return Mirror(reflecting: rule).children
            .compactMap { child -> String? in
                guard let label = child.label, !skipped.contains(label) else { return nil }
                return "\(label)=\(describe(child.value))"
            }
            .sorted()
            .joined(separator: "\n")
    }

    /// Stable text for a field value. `Set` and `KVPair`/`ResponseRewrite` ids
    /// would otherwise make two equal rules read as different.
    private func describe(_ value: Any) -> String {
        switch value {
        case let pairs as [KVPair]:
            return pairs.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        case let set as Set<String>:
            return set.sorted().joined(separator: ",")
        case let rewrites as [ResponseRewrite]:
            return rewrites.map { "\($0.pattern)|\($0.action)|\($0.isEnabled)|\($0.name)" }
                .joined(separator: ",")
        case let mock as MockResponse:
            return "\(mock.isEnabled)|\(mock.statusCode)|\(mock.body)|"
                + mock.headers.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                + "|\(mock.delay)"
        default:
            return String(describing: value)
        }
    }

    /// A rule with something armed in every single category the model has.
    private func kitchenSink(name: String = "Kill product tracking",
                             mode: EndpointMatchMode = .exact,
                             pinnedTo pin: String? = nil) -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: mode, host: pin ?? host)
        rule.name = name
        rule.isBlocked = true
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

    private func stored(_ id: String) -> InterceptRule? {
        InterceptRuleStore.shared.allRules().first { $0.id == id }
    }

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    // MARK: - 1. Edit the copy's scope, name and headers; the original must not move

    /// The headline attack. A copy starts life in its original's bucket; editing
    /// its scope re-keys it, and `addOrUpdate` drops every copy of an id from
    /// every bucket before re-filing. If the two rules shared anything — an id,
    /// a bucket entry, a KVPair — this is where the original disappears or picks
    /// up the copy's edits.
    func testRescopingTheCopyLeavesTheOriginalIdenticalInEveryField() throws {
        let original = kitchenSink()
        InterceptRuleStore.shared.addOrUpdate(original)
        let before = fingerprint(try XCTUnwrap(stored(original.id)))

        var copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        // Move the copy to a different host, rename it, and change its headers —
        // three edits, three different fields, all in the shared bucket.
        copy.matchHost = "staging.example.com"
        copy.name = "staging twin"
        copy.headerOverrides = [KVPair(key: "Authorization", value: "Bearer CHANGED"),
                                KVPair(key: "X-New", value: "1")]
        copy.removedHeaderKeys = ["x-only-on-the-copy"]
        copy.mock.statusCode = 500
        copy.responseRewrites[0] = ResponseRewrite(pattern: "data.url",
                                                   action: .replaceHost("changed.com"),
                                                   isEnabled: true, name: "changed")
        InterceptRuleStore.shared.addOrUpdate(copy)

        let after = try XCTUnwrap(stored(original.id), "the original vanished when the copy was re-scoped")
        XCTAssertEqual(fingerprint(after), before, "editing the copy changed the original")
        XCTAssertEqual(after.name, original.name)

        // And the copy really did move.
        let storedCopy = try XCTUnwrap(stored(copy.id))
        XCTAssertEqual(InterceptRule.canonicalHost(storedCopy.matchHost), "staging.example.com")
        XCTAssertNotEqual(storedCopy.storageKey, after.storageKey)
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)
    }

    /// The same edit in the other direction: touching the ORIGINAL must not
    /// reach into the copy that is sitting next to it.
    func testEditingTheOriginalLeavesTheCopyIdenticalInEveryField() throws {
        var original = kitchenSink()
        InterceptRuleStore.shared.addOrUpdate(original)
        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        let copyBefore = fingerprint(copy)

        original.isBlocked = false
        original.matchHost = "other.example.com"
        original.headerOverrides = []
        original.responseRewrites = []
        original.mock = MockResponse()
        InterceptRuleStore.shared.addOrUpdate(original)

        let copyAfter = try XCTUnwrap(stored(copy.id), "the copy vanished when the original was edited")
        XCTAssertEqual(fingerprint(copyAfter), copyBefore)
    }

    // MARK: - 2. A copy of a copy of a copy

    func testThreeGenerationsStayThreeIndependentRulesInOneBucket() throws {
        let original = kitchenSink(name: "Base")
        InterceptRuleStore.shared.addOrUpdate(original)

        let gen1 = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        let gen2 = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: gen1.id))
        let gen3 = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: gen2.id))

        let all = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.id)).count, 4, "two generations share an id")

        let names = all.map { InterceptRuleRowFormatter.title(for: $0) }
        XCTAssertEqual(Set(names).count, 4, "two rows read identically: \(names)")
        XCTAssertFalse(names.contains { $0.contains("copy copy") },
                       "\"copy\" stacked up: \(names)")

        // Same bucket, and it holds exactly four rules with packed orders.
        let bucket = InterceptRuleStore.shared.rules(forStorageKey: original.storageKey)
        XCTAssertEqual(bucket.count, 4)
        XCTAssertEqual(bucket.map(\.order), [0, 1, 2, 3])

        // Every nested identity is distinct across all four.
        let rewriteIds = all.flatMap { $0.responseRewrites.map(\.id) }
        XCTAssertEqual(Set(rewriteIds).count, rewriteIds.count, "a rewrite id is shared between rules")
        let pairIds = all.flatMap { $0.headerOverrides.map(\.id) + $0.queryParamOverrides.map(\.id)
            + $0.mock.headers.map(\.id) }
        XCTAssertEqual(Set(pairIds).count, pairIds.count, "a KVPair id is shared between rules")

        // The great-grandchild still carries everything.
        XCTAssertEqual(fingerprint(gen3), fingerprint(original))
    }

    // MARK: - 3. Delete the original; the copy still works on the wire

    func testDeletingTheOriginalLeavesTheCopyWorkingOnTheWire() throws {
        let original = kitchenSink()
        InterceptRuleStore.shared.addOrUpdate(original)
        var copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        InterceptRuleStore.shared.remove(id: original.id)
        XCTAssertNil(stored(original.id))
        XCTAssertNotNil(stored(copy.id), "deleting the original took its copy with it")

        // A copy is created switched OFF; arming it is the user's next move.
        let target = try url("https://\(host)\(path)")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: target),
                     "a switched-off copy fired on the wire")

        copy.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(copy)

        let resolved = try XCTUnwrap(InterceptRuleStore.shared.resolvedRule(forURL: target),
                                     "the copy does not resolve once armed")
        XCTAssertTrue(resolved.isBlocked)
        XCTAssertEqual(resolved.mock.statusCode, 404)
        XCTAssertEqual(resolved.breakpointMode, .afterResponse)
        XCTAssertEqual(resolved.redirectTarget, "beta.example.com/checkout/xyz")
        XCTAssertEqual(resolved.responseRewrites.count, 2)
        XCTAssertEqual(resolved.headerOverrides.first { $0.key == "Authorization" }?.value, "Bearer abc")

        // And it still only fires on the host it is pinned to.
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: try url("https://other.example.com\(path)")))
    }

    // MARK: - 4. Duplicate twice, delete the middle one

    func testDeletingTheMiddleOfThreeRepacksOrderAndLosesNothing() throws {
        let original = kitchenSink(name: "Base")
        InterceptRuleStore.shared.addOrUpdate(original)
        let first = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        let second = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        let key = original.storageKey
        XCTAssertEqual(InterceptRuleStore.shared.rules(forStorageKey: key).map(\.id),
                       [original.id, first.id, second.id])

        InterceptRuleStore.shared.remove(id: first.id)

        let survivors = InterceptRuleStore.shared.rules(forStorageKey: key)
        XCTAssertEqual(survivors.map(\.id), [original.id, second.id])
        XCTAssertEqual(survivors.map(\.order), [0, 1], "order was not re-packed after the middle delete")
        XCTAssertEqual(fingerprint(try XCTUnwrap(stored(original.id))), fingerprint(original))
        XCTAssertEqual(fingerprint(try XCTUnwrap(stored(second.id))), fingerprint(original))

        // Arming both survivors: `resolvedRule` accumulates rewrites across
        // matching rules, so two armed twins must contribute four, not two.
        for var rule in survivors {
            rule.isEnabled = true
            InterceptRuleStore.shared.addOrUpdate(rule)
        }
        let resolved = try XCTUnwrap(
            InterceptRuleStore.shared.resolvedRule(forURL: try url("https://\(host)\(path)")))
        XCTAssertEqual(resolved.responseRewrites.count, 4)
        XCTAssertEqual(Set(resolved.responseRewrites.map(\.id)).count, 4,
                       "two rules contributed rewrites with the SAME id to one composite")
    }

    // MARK: - 5. Shapes nobody types on purpose

    /// A rule with no host pin matches every host. Its copy must too — losing
    /// the pin state in either direction silently changes what the rule catches.
    func testACopyOfAnAnyHostRuleIsStillAnyHost() throws {
        var original = InterceptRule.endpointRule(path: "/api/users", mode: .normalized, host: nil)
        original.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(original)

        var copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertTrue(copy.appliesToAnyHost)
        copy.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(copy)

        for hostName in ["a.example.com", "b.example.com", "totally.unrelated.dev"] {
            XCTAssertNotNil(
                InterceptRuleStore.shared.resolvedRule(forURL: try url("https://\(hostName)/api/users")),
                "the copy of an any-host rule stopped matching \(hostName)")
        }
    }

    /// An endpoint rule with an EMPTY path is reachable through import and
    /// through an older build. Copying one must not crash and must not silently
    /// land it in some other rule's bucket.
    func testACopyOfAnEmptyEndpointRuleStaysInItsOwnBucket() throws {
        var original = InterceptRule.endpointRule(path: "", mode: .normalized, host: nil)
        original.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(original)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertEqual(copy.matchEndpoint, "")
        XCTAssertEqual(copy.storageKey, original.storageKey)
        XCTAssertEqual(InterceptRuleStore.shared.rules(forStorageKey: original.storageKey).count, 2)
        XCTAssertNotEqual(copy.id, original.id)
    }

    func testACopyOfAVeryLongPathKeepsThePathWhole() throws {
        let longPath = "/" + String(repeating: "segment/", count: 250) + "leaf"
        XCTAssertGreaterThan(longPath.count, 2000)
        var original = InterceptRule.endpointRule(path: longPath, mode: .exact, host: host)
        original.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(original)

        var copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertEqual(copy.matchEndpoint, longPath)
        copy.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(copy)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: try url("https://\(host)\(longPath)")))
    }

    /// A name in a non-Latin script with an emoji. The copy suffix is appended
    /// with string arithmetic (`baseName` searches backwards for " copy"), which
    /// is where a grapheme-cluster bug would show up.
    func testUnicodeNamesSurviveDuplicationAndStayUnique() throws {
        var original = kitchenSink(name: "قاعدة الحظر 🚫 للمنتجات")
        InterceptRuleStore.shared.addOrUpdate(original)

        let first = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        let second = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        XCTAssertTrue(first.name.hasPrefix("قاعدة الحظر 🚫 للمنتجات"),
                      "the original name was mangled: \(first.name)")
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertNotEqual(first.name, original.name)

        // Round-trips through the rules file unchanged.
        let data = try JSONEncoder().encode([first, second])
        let back = try JSONDecoder().decode([InterceptRule].self, from: data)
        XCTAssertEqual(back.map(\.name), [first.name, second.name])

        // And a whitespace-only name is not a name: the copy must still get one
        // of its own, or two rows render identically.
        original.name = "   "
        InterceptRuleStore.shared.removeAll()
        InterceptRuleStore.shared.addOrUpdate(original)
        let blankCopy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertFalse(InterceptRuleRowFormatter.title(for: blankCopy)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(InterceptRuleRowFormatter.title(for: blankCopy),
                          InterceptRuleRowFormatter.title(for: original))
    }

    /// Duplicating a rule that is already switched off must not switch anything
    /// on — not the copy, and certainly not the original.
    func testDuplicatingADisabledRuleArmsNothing() throws {
        var original = kitchenSink()
        original.isEnabled = false
        InterceptRuleStore.shared.addOrUpdate(original)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(try XCTUnwrap(stored(original.id)).isEnabled,
                       "duplicating re-armed the original")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: try url("https://\(host)\(path)")))
    }

    // MARK: - 6. Host and global scopes

    func testDuplicatingAHostRuleAndThenNarrowingTheCopy() throws {
        var original = InterceptRule.hostRule(hosts: ["a.example.com", "b.example.com"])
        original.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(original)
        let before = fingerprint(try XCTUnwrap(stored(original.id)))

        var copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertEqual(copy.matchHosts, original.matchHosts)

        copy.matchHosts = ["c.example.com"]
        copy.matchEndpoint = InterceptRule.hostKey(for: ["c.example.com"])
        copy.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(copy)

        XCTAssertEqual(fingerprint(try XCTUnwrap(stored(original.id))), before,
                       "narrowing the copy's hosts changed the original's")

        // The copy now fires on its own host and only its own host…
        let onCopysHost = try XCTUnwrap(
            InterceptRuleStore.shared.resolvedRule(forURL: try url("https://c.example.com/x")))
        XCTAssertEqual(onCopysHost.name, copy.displayName,
                       "something other than the copy answered for c.example.com")
        // …and the original — still armed — answers for its own two, alone.
        let onOriginalsHost = try XCTUnwrap(
            InterceptRuleStore.shared.resolvedRule(forURL: try url("https://a.example.com/x")))
        XCTAssertEqual(onOriginalsHost.name, original.displayName,
                       "the re-scoped copy is still firing on the original's hosts")
    }

    func testDuplicatingAGlobalRuleKeepsBothInTheGlobalBucket() throws {
        var original = InterceptRule.globalRule()
        original.isBlocked = true
        original.name = "Kill everything"
        InterceptRuleStore.shared.addOrUpdate(original)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertEqual(copy.matchMode, .global)
        XCTAssertEqual(InterceptRuleStore.shared.rules(forStorageKey: "global").count, 2)
        XCTAssertNotEqual(copy.name, original.name)

        // Only the armed one fires.
        let resolved = try XCTUnwrap(
            InterceptRuleStore.shared.resolvedRule(forURL: try url("https://anything.dev/any/path")))
        XCTAssertEqual(resolved.name, original.displayName)
    }

    // MARK: - 7. Twenty copies, then a round-trip through the rules file

    /// The naming loop walks every existing title on every duplication. Twenty
    /// copies is enough to catch a name that repeats and a bucket that loses one.
    func testTwentyCopiesStayTwentyDistinctRulesAcrossASaveAndLoad() throws {
        let original = kitchenSink(name: "Base")
        InterceptRuleStore.shared.addOrUpdate(original)

        var ids: [String] = [original.id]
        for _ in 0..<20 {
            ids.append(try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id)).id)
        }

        let all = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(all.count, 21)
        XCTAssertEqual(Set(all.map(\.id)), Set(ids))
        let titles = all.map { InterceptRuleRowFormatter.title(for: $0) }
        XCTAssertEqual(Set(titles).count, 21, "duplicate row titles: \(titles.sorted())")

        // Whatever the store writes, it must read back the same.
        let data = try JSONEncoder().encode(all)
        let reloaded = try JSONDecoder().decode([InterceptRule].self, from: data)
        XCTAssertEqual(Set(reloaded.map(\.id)), Set(ids))
        XCTAssertEqual(Set(reloaded.map(\.name)), Set(all.map(\.name)))
        XCTAssertTrue(reloaded.dropFirst().allSatisfy { !$0.isEnabled },
                      "a copy came back armed after a save/load")
    }

    // MARK: - 8. The rule the caller hands over is never the one that is copied

    /// `duplicateAndStore` re-reads the store, so a row drawn before an edit
    /// cannot resurrect the pre-edit rule — and a rule deleted in between is not
    /// re-created.
    func testACopyIsMadeFromTheStoreNotFromAStaleRow() throws {
        var original = kitchenSink(name: "Base")
        InterceptRuleStore.shared.addOrUpdate(original)
        let staleSnapshot = original

        original.mock.statusCode = 503
        original.name = "Edited elsewhere"
        InterceptRuleStore.shared.addOrUpdate(original)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: staleSnapshot.id))
        XCTAssertEqual(copy.mock.statusCode, 503, "the copy resurrected the pre-edit rule")
        XCTAssertTrue(copy.name.hasPrefix("Edited elsewhere"))

        InterceptRuleStore.shared.remove(id: original.id)
        XCTAssertNil(InterceptRuleDuplicator.duplicateAndStore(id: staleSnapshot.id),
                     "duplicating a deleted rule re-created it")
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1)
    }
}
