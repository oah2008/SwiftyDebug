//
//  KeychainAttributeNamingTests.swift
//  SwiftyDebugTests
//
//  The keychain detail screen used to trap 100% of the time, on the first tap.
//
//  `kSecAttrType` and `kSecAttrKeyType` are BOTH the literal string "type" —
//  two different Security constants, one short key. The readable-name table was
//  a dictionary *literal* listing both, and a Swift dictionary literal with a
//  repeated key does not merge, it traps: "Fatal error: Dictionary literal
//  contains duplicate keys". The table is a lazy static, so the trap fired the
//  first time anything asked for an attribute name — which is exactly what
//  opening a keychain item does.
//
//  These tests touch the lookup (a returned literal would abort the run here),
//  and pin the disambiguation that lets both attributes keep a human name.
//

import XCTest
import Security
@testable import SwiftyDebug

final class KeychainAttributeNamingTests: XCTestCase {

    // MARK: - The collision is real

    /// If this ever stops being true, the whole hazard is gone — but it is true
    /// on every SDK shipped so far, and the code must survive it.
    func testTypeAndKeyTypeAreLiterallyTheSameKey() {
        XCTAssertEqual(kSecAttrType as String, kSecAttrKeyType as String,
                       "The premise of this file: two constants, one short key.")
        XCTAssertTrue(KeychainInspector.collidingAttributeKeys.contains(kSecAttrType as String),
                      "The name table must acknowledge the collision it contains.")
    }

    /// The name table cannot be expressed as a dictionary literal — building it
    /// with `uniquingKeysWith:` is the fix, not a style choice.
    func testNameTableSurvivesBeingCollapsedIntoADictionary() {
        let pairs = KeychainInspector.knownAttributeNamePairs
        let collapsed = Dictionary(pairs.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        XCTAssertLessThan(collapsed.count, pairs.count,
                          "At least one key collides; that is why a literal traps.")
    }

    // MARK: - Reading a name never traps

    /// Merely *touching* the lazy static was the crash.
    func testAttributeNameLookupDoesNotTrap() {
        XCTAssertEqual(KeychainInspector.attributeName(kSecAttrAccount as String), "Account")
        XCTAssertEqual(KeychainInspector.attributeName(kSecAttrService as String), "Service")
        XCTAssertEqual(KeychainInspector.attributeName(kSecAttrPublicKeyHash as String), "Public Key Hash")
    }

    func testUnknownKeyFallsBackToTheRawKey() {
        XCTAssertEqual(KeychainInspector.attributeName("zzzz"), "zzzz")
    }

    // MARK: - Both colliding attributes still get a human name

    func testCollidingKeyIsNamedByItemClass() {
        let key = kSecAttrType as String
        XCTAssertEqual(KeychainInspector.attributeName(key, itemClass: .genericPassword), "Type")
        XCTAssertEqual(KeychainInspector.attributeName(key, itemClass: .internetPassword), "Type")
        XCTAssertEqual(KeychainInspector.attributeName(key, itemClass: .certificate), "Type")
        XCTAssertEqual(KeychainInspector.attributeName(key, itemClass: .key), "Key Type")
        XCTAssertEqual(KeychainInspector.attributeName(key, itemClass: .identity), "Key Type")
    }

    /// Deduplicating by silently dropping a name would leave that name
    /// unreachable for every class — this is what catches that shortcut.
    func testEveryReadableNameIsReachableForSomeItemClass() {
        for pair in KeychainInspector.knownAttributeNamePairs {
            let reachable = KeychainItemClass.allCases.map {
                KeychainInspector.attributeName(pair.key, itemClass: $0)
            }
            XCTAssertTrue(reachable.contains(pair.name),
                          "“\(pair.name)” (key “\(pair.key)”) is not reachable for any item class")
        }
    }

    // MARK: - The screen itself

    /// The user-visible repro: open a keychain item that carries the colliding
    /// attribute and read the captions off the rows.
    func testDetailScreenLabelsTheCollidingAttributeForAKey() {
        let item = KeychainItem(itemClass: .key,
                                attributes: [kSecAttrKeyType as String: "42",
                                             kSecAttrLabel as String: "signing key"])
        let captions = self.captions(forDetailScreenOf: item)
        XCTAssertTrue(captions.contains(Self.caption("Key Type", kSecAttrKeyType)),
                      "Expected a Key Type row, got: \(captions)")
        XCTAssertTrue(captions.contains(Self.caption("Label", kSecAttrLabel)),
                      "Expected a Label row, got: \(captions)")
    }

    func testDetailScreenLabelsTheCollidingAttributeForAPassword() {
        let item = KeychainItem(itemClass: .genericPassword,
                                attributes: [kSecAttrType as String: "42",
                                             kSecAttrAccount as String: "me"])
        let captions = self.captions(forDetailScreenOf: item)
        XCTAssertTrue(captions.contains(Self.caption("Type", kSecAttrType)),
                      "Expected a Type row, got: \(captions)")
        XCTAssertTrue(captions.contains(Self.caption("Account", kSecAttrAccount)),
                      "Expected an Account row, got: \(captions)")
    }

    // MARK: - Helpers

    /// The cell renders captions uppercased.
    private static func caption(_ name: String, _ key: CFString) -> String {
        "\(name)  ·  \(key as String)".uppercased()
    }

    /// Every caption the detail screen renders. Reaching this at all means the
    /// screen loaded without trapping.
    private func captions(forDetailScreenOf item: KeychainItem) -> [String] {
        let vc = KeychainItemDetailViewController(item: item)
        vc.loadViewIfNeeded()
        let table: UITableView = vc.tableView
        var texts: [String] = []
        for row in 0..<table.numberOfRows(inSection: 0) {
            let cell = vc.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
            texts += Self.labelTexts(in: cell.contentView)
        }
        return texts
    }

    private static func labelTexts(in view: UIView) -> [String] {
        var out: [String] = []
        if let label = view as? UILabel, let text = label.text { out.append(text) }
        for subview in view.subviews { out += labelTexts(in: subview) }
        return out
    }
}
