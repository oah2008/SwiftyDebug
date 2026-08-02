//
//  AppInfoRuleListFreshnessTests.swift
//  SwiftyDebugTests
//
//  The App tab renders the intercept rules from a snapshot taken when it
//  appeared, and it presents the rule editor itself. Nothing told it when a rule
//  changed, so:
//
//    * a rule edited in that editor kept showing its old title;
//    * a rule CREATED from the App tab produced no row at all, so people created
//      it a second time;
//    * worst of all, the enable switch wrote the row's cached copy back through
//      `InterceptRuleStore.update(_:)` — which writes the whole struct — so
//      flipping a switch silently reverted the name, mock, headers and scope the
//      developer had just edited.
//
//  These drive the real screen (row counts come from its data source) and the
//  real store.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class AppInfoRuleListFreshnessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRule(path: String, name: String) -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: path, matchMode: .exact)
        rule.name = name
        return rule
    }

    private func makeAppTab() -> AppInfoViewController {
        let vc = AppInfoViewController()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        // Make the table ask its data source now; off-screen it is lazy.
        _ = vc.tableView.numberOfSections
        return vc
    }

    /// The section index the INTERCEPT RULES header sits on, found by its header
    /// rather than hard-coded, so re-ordering the tab cannot make this test lie.
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

    /// Rules rows, excluding the trailing "Add Rule" row.
    private func ruleRowCount(_ vc: AppInfoViewController) -> Int {
        vc.tableView(vc.tableView, numberOfRowsInSection: ruleSection(of: vc)) - 1
    }

    private func titleOfRow(_ row: Int, in vc: AppInfoViewController) -> String {
        let indexPath = IndexPath(row: row, section: ruleSection(of: vc))
        let cell = vc.tableView(vc.tableView, cellForRowAt: indexPath)
        return allText(in: cell.contentView) + (cell.textLabel?.text ?? "")
            + (cell.textLabel?.attributedText?.string ?? "")
    }

    /// Spins the run loop until `condition` holds, so the
    /// `.interceptRulesDidChange` notification (posted async onto the main
    /// queue, then delivered on the main operation queue) can reach the screen.
    /// Returns either way — the assertion that follows is what reports.
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - The switch must never write a stale copy

    func testEnableToggleWritesTheStoresCopyNotTheRowsSnapshot() {
        var rule = makeRule(path: "/cart", name: "original name")
        InterceptRuleStore.shared.addOrUpdate(rule)

        // What the row captured when it was drawn.
        let staleSnapshot = rule

        // The rule is then edited somewhere else.
        rule.name = "renamed in the editor"
        rule.isBlocked = true
        InterceptRuleStore.shared.addOrUpdate(rule)

        let toWrite = AppInfoViewController.ruleForEnableToggle(
            id: staleSnapshot.id, enabled: false,
            storeRules: InterceptRuleStore.shared.allRules())

        XCTAssertEqual(toWrite?.name, "renamed in the editor",
                       "The switch wrote the row's stale copy back, reverting the edit.")
        XCTAssertEqual(toWrite?.isBlocked, true)
        XCTAssertEqual(toWrite?.isEnabled, false, "The switch still owns `isEnabled`.")
    }

    func testEnableToggleOnADeletedRuleWritesNothing() {
        let rule = makeRule(path: "/gone", name: "deleted")
        InterceptRuleStore.shared.addOrUpdate(rule)
        InterceptRuleStore.shared.remove(id: rule.id)

        XCTAssertNil(AppInfoViewController.ruleForEnableToggle(
            id: rule.id, enabled: true, storeRules: InterceptRuleStore.shared.allRules()),
            "Writing the cached copy here would resurrect a deleted rule.")
    }

    // MARK: - The row fingerprint decides when to redraw

    func testRenamingARuleChangesTheRowFingerprint() {
        var rule = makeRule(path: "/cart", name: "before")
        let before = AppInfoViewController.rowFingerprint([rule])
        rule.name = "after"
        XCTAssertNotEqual(AppInfoViewController.rowFingerprint([rule]), before,
                          "A renamed rule must force a redraw; otherwise the row keeps the old title.")
    }

    func testDisablingARuleChangesTheRowFingerprint() {
        var rule = makeRule(path: "/cart", name: "n")
        let before = AppInfoViewController.rowFingerprint([rule])
        rule.isEnabled = false
        XCTAssertNotEqual(AppInfoViewController.rowFingerprint([rule]), before)
    }

    func testAddingARuleChangesTheRowFingerprint() {
        let a = makeRule(path: "/a", name: "a")
        let b = makeRule(path: "/b", name: "b")
        XCTAssertNotEqual(AppInfoViewController.rowFingerprint([a, b]),
                          AppInfoViewController.rowFingerprint([a]))
    }

    func testChangingAScopePinChangesTheRowFingerprint() {
        var rule = makeRule(path: "/cart", name: "n")
        let before = AppInfoViewController.rowFingerprint([rule])
        rule.matchHost = "api.example.com"
        XCTAssertNotEqual(AppInfoViewController.rowFingerprint([rule]), before,
                          "Two rules differing only in host pin must not render identically.")
    }

    // MARK: - The screen actually observes the store

    func testRuleCreatedElsewhereAppearsWithoutLeavingTheTab() {
        let vc = makeAppTab()
        XCTAssertEqual(ruleRowCount(vc), 0)

        InterceptRuleStore.shared.addOrUpdate(makeRule(path: "/checkout", name: "new rule"))
        waitUntil { ruleRowCount(vc) == 1 }

        XCTAssertEqual(ruleRowCount(vc), 1,
                       "A rule created from this tab showed no row, so people created it twice.")
        XCTAssertTrue(titleOfRow(0, in: vc).contains("new rule"))
    }

    func testEditedRuleTitleRefreshesWithoutLeavingTheTab() {
        var rule = makeRule(path: "/cart", name: "before edit")
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeAppTab()
        XCTAssertTrue(titleOfRow(0, in: vc).contains("before edit"))

        rule.name = "after edit"
        InterceptRuleStore.shared.addOrUpdate(rule)
        waitUntil { titleOfRow(0, in: vc).contains("after edit") }

        let title = titleOfRow(0, in: vc)
        XCTAssertTrue(title.contains("after edit"), "Row still reads: \(title)")
        XCTAssertFalse(title.contains("before edit"))
    }

    func testRuleDeletedElsewhereDisappearsWithoutLeavingTheTab() {
        let rule = makeRule(path: "/cart", name: "doomed")
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeAppTab()
        XCTAssertEqual(ruleRowCount(vc), 1)

        InterceptRuleStore.shared.remove(id: rule.id)
        waitUntil { ruleRowCount(vc) == 0 }

        XCTAssertEqual(ruleRowCount(vc), 0)
    }
}
