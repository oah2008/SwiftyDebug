//
//  AppInfoEnableSwitchTests.swift
//  SwiftyDebugTests
//
//  Flipping a rule's enable switch on the App tab used to silently revert the
//  rule. `InterceptRuleStore.update(_:)` writes the WHOLE struct, and the switch
//  handed it the copy the row had been drawn from — so a rule that had been
//  edited elsewhere since (renamed, given a mock body, re-scoped, blocked) had
//  every one of those fields overwritten with the row's stale snapshot, by an
//  action that looked like it only moved a switch.
//
//  The pure helper (`ruleForEnableToggle(id:enabled:storeRules:)`) is already
//  pinned. What was NOT pinned is *which array the controller feeds it*: point
//  `storeRules:` back at the controller's cached `interceptRules` and the whole
//  suite stays green while the shipped switch reverts edits again.
//
//  These drive the real switch, in a real cell, on the real screen.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class AppInfoEnableSwitchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - The switch writes the store's copy

    /// Draw the row, edit the rule somewhere else, then flip the switch. Only
    /// `isEnabled` may move.
    func testFlippingTheSwitchKeepsAnEditMadeAfterTheRowWasDrawn() throws {
        var rule = InterceptRule(matchEndpoint: "/cart", matchMode: .exact)
        rule.name = "original name"
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeAppTab()
        let toggle = try switchInFirstRuleRow(of: vc)
        XCTAssertTrue(toggle.isOn, "Precondition: the rule is enabled and the row shows it.")

        // The rule is edited in the rule editor while this row is on screen.
        // The refresh notification is posted asynchronously, so at the moment the
        // switch is tapped the row's cached copy is still the old one — exactly
        // the race the fix exists for.
        rule.name = "renamed in the editor"
        rule.isBlocked = true
        rule.matchHost = "api.example.com"
        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertEqual(cachedRuleNames(of: vc), ["original name"],
                       "Precondition: the screen has not refreshed yet, so its row copy is stale. "
                       + "If it had refreshed, this test could not tell the two arrays apart.")

        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)

        let stored = try XCTUnwrap(InterceptRuleStore.shared.allRules().first(where: { $0.id == rule.id }))
        XCTAssertEqual(stored.isEnabled, false, "The switch owns isEnabled and must write it.")
        XCTAssertEqual(stored.name, "renamed in the editor",
                       "Flipping the switch reverted the rule's name to the row's stale copy — "
                       + "a switch tap silently undoing an edit made in the editor.")
        XCTAssertEqual(stored.isBlocked, true, "…and it reverted `isBlocked` too.")
        XCTAssertEqual(stored.matchHost, "api.example.com",
                       "…and the scope, which decides which requests the rule fires on.")
    }

    /// The other direction: switching a disabled rule back on must not resurrect
    /// the old body/headers either.
    func testFlippingTheSwitchBackOnAlsoWritesTheStoresCopy() throws {
        var rule = InterceptRule(matchEndpoint: "/cart", matchMode: .exact)
        rule.name = "before"
        rule.isEnabled = false
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeAppTab()
        let toggle = try switchInFirstRuleRow(of: vc)
        XCTAssertFalse(toggle.isOn, "Precondition: the row is drawn from a disabled rule.")

        rule.name = "after"
        InterceptRuleStore.shared.addOrUpdate(rule)

        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)

        let stored = try XCTUnwrap(InterceptRuleStore.shared.allRules().first(where: { $0.id == rule.id }))
        XCTAssertEqual(stored.isEnabled, true)
        XCTAssertEqual(stored.name, "after",
                       "Arming a rule must not roll back the edit that came after the row was drawn.")
    }

    /// And a rule deleted between the row being drawn and the switch being
    /// tapped must stay deleted — writing the row's cached copy would put it
    /// back, arming a rule the developer had removed.
    func testFlippingTheSwitchOnARuleDeletedElsewhereDoesNotResurrectIt() throws {
        var rule = InterceptRule(matchEndpoint: "/cart", matchMode: .exact)
        rule.name = "doomed"
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeAppTab()
        let toggle = try switchInFirstRuleRow(of: vc)

        InterceptRuleStore.shared.remove(id: rule.id)
        XCTAssertEqual(cachedRuleNames(of: vc), ["doomed"],
                       "Precondition: the row still remembers the deleted rule.")

        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)

        XCTAssertTrue(InterceptRuleStore.shared.allRules().isEmpty,
                      "The switch re-added a rule that had been deleted — it would start "
                      + "intercepting again on a rule nobody can see any more.")
    }

    // MARK: - Harness

    private func makeAppTab() -> AppInfoViewController {
        let vc = AppInfoViewController()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        _ = vc.tableView.numberOfSections
        return vc
    }

    /// The rules the screen currently believes in, read straight off the
    /// controller: the array whose staleness is the whole point.
    private func cachedRuleNames(of vc: AppInfoViewController) -> [String] {
        let rules = Mirror(reflecting: vc).children
            .compactMap { $0.value as? [InterceptRule] }
            .first ?? []
        return rules.map { $0.name }
    }

    /// The real switch out of the real cell — the one wired to `setRule(id:enabled:)`.
    private func switchInFirstRuleRow(of vc: AppInfoViewController) throws -> UISwitch {
        let indexPath = IndexPath(row: 0, section: ruleSection(of: vc))
        let cell = vc.tableView(vc.tableView, cellForRowAt: indexPath)
        return try XCTUnwrap(cell.accessoryView as? UISwitch,
                             "The rule row no longer carries an enable switch.")
    }

    /// Found by its header rather than hard-coded, so re-ordering the tab cannot
    /// make this test lie.
    private func ruleSection(of vc: AppInfoViewController) -> Int {
        for section in 0..<vc.tableView.numberOfSections {
            guard let header = vc.tableView(vc.tableView, viewForHeaderInSection: section) else { continue }
            if allText(in: header).contains("INTERCEPT RULES") { return section }
        }
        XCTFail("The App tab no longer has an INTERCEPT RULES section.")
        return 0
    }

    private func allText(in view: UIView) -> String {
        var out = (view as? UILabel)?.text ?? ""
        for sub in view.subviews { out += allText(in: sub) }
        return out
    }
}
