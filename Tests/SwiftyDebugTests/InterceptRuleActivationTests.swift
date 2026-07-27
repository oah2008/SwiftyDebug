//
//  InterceptRuleActivationTests.swift
//  SwiftyDebugTests
//
//  Covers the guarantee that an intercept rule only ever carries header and
//  query-parameter changes the developer explicitly switched on. Rules that
//  quietly set headers nobody chose send modified requests with no visible trace
//  of why, which is the worst possible failure for a debugging tool.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleActivationTests: XCTestCase {

    private typealias Editor = InterceptRuleEditorViewController
    private typealias Item = InterceptRuleEditorViewController.EditItem

    // MARK: - Nothing applies unless it is checked

    func testInactiveItemsAreNeverSaved() {
        let items = [
            Item(key: "Authorization", value: "Bearer abc", isRemoving: false, isKeyEditable: false, isActive: true),
            Item(key: "X-Debug", value: "1", isRemoving: false, isKeyEditable: false, isActive: false),
            Item(key: "Accept", value: "application/json", isRemoving: false, isKeyEditable: false, isActive: false),
        ]
        let result = Editor.partition(items, lowercaseRemovals: true)

        XCTAssertEqual(result.overrides.count, 1)
        XCTAssertEqual(result.overrides.first?.key, "Authorization")
        XCTAssertTrue(result.removed.isEmpty)
    }

    func testInactiveRemovalsAreNeverSaved() {
        // An unchecked REMOVE row must not strip the header either — "inactive"
        // has to mean inert in both directions.
        let items = [
            Item(key: "Cookie", value: "", isRemoving: true, isKeyEditable: false, isActive: false),
            Item(key: "Referer", value: "", isRemoving: true, isKeyEditable: false, isActive: true),
        ]
        let result = Editor.partition(items, lowercaseRemovals: true)

        XCTAssertEqual(result.removed, ["referer"])
        XCTAssertTrue(result.overrides.isEmpty)
    }

    func testAllInactiveProducesAnEmptyRule() {
        let items = (0..<5).map {
            Item(key: "H\($0)", value: "v", isRemoving: false, isKeyEditable: false, isActive: false)
        }
        let result = Editor.partition(items, lowercaseRemovals: true)
        XCTAssertTrue(result.overrides.isEmpty)
        XCTAssertTrue(result.removed.isEmpty)
    }

    // MARK: - Shape of what does get saved

    func testEmptyKeysAreDroppedEvenWhenActive() {
        let items = [
            Item(key: "", value: "orphan", isRemoving: false, isKeyEditable: true, isActive: true),
            Item(key: "  ", value: "x", isRemoving: true, isKeyEditable: true, isActive: true),
            Item(key: "X-Real", value: "1", isRemoving: false, isKeyEditable: false, isActive: true),
        ]
        let result = Editor.partition(items, lowercaseRemovals: true)
        XCTAssertEqual(result.overrides.map { $0.key }, ["X-Real"])
        // A whitespace-only key is not empty, but it is also not a header name —
        // it survives as a removal, which is harmless and matches the old behavior.
        XCTAssertEqual(result.removed, ["  "])
    }

    func testHeaderRemovalsAreLowercasedButParamRemovalsAreNot() {
        let items = [Item(key: "Content-Type", value: "", isRemoving: true, isKeyEditable: false, isActive: true)]

        XCTAssertEqual(Editor.partition(items, lowercaseRemovals: true).removed, ["content-type"])
        XCTAssertEqual(Editor.partition(items, lowercaseRemovals: false).removed, ["Content-Type"])
    }

    func testOverridesPreserveOrderAndValues() {
        let items = [
            Item(key: "B", value: "2", isRemoving: false, isKeyEditable: false, isActive: true),
            Item(key: "A", value: "1", isRemoving: false, isKeyEditable: false, isActive: true),
        ]
        let result = Editor.partition(items, lowercaseRemovals: true)
        XCTAssertEqual(result.overrides.map { $0.key }, ["B", "A"])
        XCTAssertEqual(result.overrides.map { $0.value }, ["2", "1"])
    }

    // MARK: - A rule built from active items behaves as expected end to end

    func testRuleBuiltFromMixedActivationAppliesOnlyCheckedHeaders() {
        var rule = InterceptRule(matchEndpoint: "/api/orders", matchMode: .exact)
        let items = [
            Item(key: "Authorization", value: "Bearer live", isRemoving: false, isKeyEditable: false, isActive: true),
            Item(key: "X-Never", value: "nope", isRemoving: false, isKeyEditable: false, isActive: false),
        ]
        let headers = Editor.partition(items, lowercaseRemovals: true)
        rule.headerOverrides = headers.overrides
        rule.removedHeaderKeys = headers.removed
        rule.isEnabled = true

        InterceptRuleStore.shared.removeAll()
        defer { InterceptRuleStore.shared.removeAll() }
        InterceptRuleStore.shared.addOrUpdate(rule)

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://a.com/api/orders")!)
        XCTAssertEqual(resolved?.headerOverrides.count, 1)
        XCTAssertEqual(resolved?.headerOverrides.first?.key, "Authorization")
        XCTAssertFalse(resolved?.headerOverrides.contains { $0.key == "X-Never" } ?? true)
    }
}
