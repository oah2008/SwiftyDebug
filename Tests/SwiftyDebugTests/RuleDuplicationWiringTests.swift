//
//  RuleDuplicationWiringTests.swift
//  SwiftyDebugTests
//
//  "I want to be able to duplicate current rule to be easier to edit."
//
//  These are the WIRING tests: they drive the three screens that list a rule —
//  the rule list, the App tab's INTERCEPT RULES section, and the editor — and
//  check that duplication is offered where delete already is, and that running
//  it puts a second, independent rule in the store.
//
//  They deliberately reach for the swipe action by TITLE, the way a finger
//  reaches for it: an action that exists but is never built into the
//  configuration is not a feature.
//
//  The pure behaviour of the copy itself (what it carries, what it is called,
//  whether it is armed) lives in RuleDuplicationBehaviourTests.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class RuleDuplicationWiringTests: XCTestCase {

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

    // MARK: - Harness

    private func model() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(host)\(path)")
        model.method = "GET"
        model.statusCode = "200"
        return model
    }

    /// A rule with something armed in every category, so "carries everything"
    /// has something to carry.
    private func fullRule(name: String = "Kill product tracking") -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: .exact, host: host)
        rule.name = name
        rule.headerOverrides = [KVPair(key: "Authorization", value: "Bearer abc")]
        rule.queryParamOverrides = [KVPair(key: "page", value: "2")]
        rule.removedHeaderKeys = ["x-trace"]
        rule.removedQueryParamKeys = ["utm_source"]
        rule.redirectMode = .host
        rule.redirectTarget = "beta.example.com"
        rule.mock = MockResponse(isEnabled: true, statusCode: 404,
                                 body: "{\"error\":\"nope\"}",
                                 headers: [KVPair(key: "X-Mock", value: "1")], delay: 1.5)
        rule.breakpointMode = .afterResponse
        rule.responseRewrites = [ResponseRewrite(pattern: "data.url",
                                                 action: .replaceHost("salla.com"),
                                                 isEnabled: true, name: "point at salla")]
        return rule
    }

    private func makeRuleList() -> InterceptRuleListViewController {
        let vc = InterceptRuleListViewController()
        vc.httpModel = model()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        // A layout pass, so the table has committed to a row count before a
        // batch update checks it against the data source.
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.tableView.layoutIfNeeded()
        return vc
    }

    private func makeAppTab() -> AppInfoViewController {
        let vc = AppInfoViewController()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.tableView.layoutIfNeeded()
        _ = vc.tableView.numberOfSections
        return vc
    }

    /// The rows the DATA SOURCE reports, which is what every screen here draws
    /// from — never the table's own cached count.
    private func rows(_ vc: UITableViewController, section: Int) -> Int {
        vc.tableView(vc.tableView, numberOfRowsInSection: section)
    }

    /// The swipe actions a finger would see on `indexPath`, by title.
    private func swipeActions(_ vc: UITableViewController, _ indexPath: IndexPath) -> [UIContextualAction] {
        vc.tableView(vc.tableView, trailingSwipeActionsConfigurationForRowAt: indexPath)?.actions ?? []
    }

    private func runAction(_ action: UIContextualAction) {
        action.handler(action, UIView()) { _ in }
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for sub in view.subviews { found.append(contentsOf: labels(in: sub)) }
        return found
    }

    // MARK: - 1. The rule list

    func testRuleListOffersDuplicateWhereItOffersDelete() throws {
        InterceptRuleStore.shared.addOrUpdate(fullRule())
        let vc = makeRuleList()
        XCTAssertEqual(rows(vc, section: 0), 1, "Precondition: one rule is listed")

        let titles = swipeActions(vc, IndexPath(row: 0, section: 0)).map { $0.title ?? "" }
        XCTAssertTrue(titles.contains("Delete"), "Delete must still be offered, got \(titles)")
        XCTAssertTrue(titles.contains("Duplicate"),
                      "The rule list offers no way to duplicate a rule, got \(titles)")
    }

    func testDuplicatingFromTheRuleListCreatesASecondIndependentRule() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let vc = makeRuleList()

        let duplicate = try XCTUnwrap(swipeActions(vc, IndexPath(row: 0, section: 0))
            .first { $0.title == "Duplicate" }, "No Duplicate action on the row")
        runAction(duplicate)

        let stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2, "Duplicating did not add a rule")
        let copy = try XCTUnwrap(stored.first { $0.id != original.id })
        XCTAssertNotEqual(copy.id, original.id, "The copy must have its own identity")
        XCTAssertEqual(rows(vc, section: 0), 2,
                       "The new rule must appear in the list it was duplicated from")
    }

    /// The row's cached copy of a rule goes stale the moment the rule is edited
    /// on another screen — that is the race `AppInfoViewController.setRule`
    /// exists for. Duplicating that snapshot would quietly resurrect the
    /// pre-edit rule as a brand-new one.
    func testDuplicatingUsesTheStoresCopyNotTheStaleRow() throws {
        var rule = fullRule(name: "before")
        InterceptRuleStore.shared.addOrUpdate(rule)
        let vc = makeRuleList()

        // Edited in the editor while this row is on screen. The refresh
        // notification is asynchronous, so the row is still holding the old one.
        rule.name = "after"
        rule.breakpointMode = .beforeSend
        InterceptRuleStore.shared.addOrUpdate(rule)

        runAction(try XCTUnwrap(swipeActions(vc, IndexPath(row: 0, section: 0))
            .first { $0.title == "Duplicate" }))

        let copy = try XCTUnwrap(InterceptRuleStore.shared.allRules().first { $0.id != rule.id })
        XCTAssertEqual(copy.name, "after copy",
                       "The copy was made from the row's pre-edit snapshot")
        XCTAssertEqual(copy.breakpointMode, .beforeSend,
                       "…and it lost the edit that had been made since")
    }

    /// Delete must still work — and must still delete exactly one rule.
    func testDeletingFromTheSwipeActionStillDeletesOneRule() throws {
        let first = fullRule(name: "first")
        var second = fullRule(name: "second")
        second.name = "second"
        InterceptRuleStore.shared.addOrUpdate(first)
        InterceptRuleStore.shared.addOrUpdate(second)
        let vc = makeRuleList()
        XCTAssertEqual(rows(vc, section: 0), 2)

        let delete = try XCTUnwrap(swipeActions(vc, IndexPath(row: 0, section: 0))
            .first { $0.title == "Delete" })
        runAction(delete)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1, "Delete removed the wrong number of rules")
        XCTAssertEqual(rows(vc, section: 0), 1)
    }

    // MARK: - 2. The App tab

    func testAppTabOffersDuplicateWhereItOffersDelete() throws {
        InterceptRuleStore.shared.addOrUpdate(fullRule())
        let vc = makeAppTab()
        let rulesSection = 2
        let ip = IndexPath(row: 0, section: rulesSection)
        XCTAssertTrue(vc.tableView(vc.tableView, canEditRowAt: ip),
                      "Precondition: the App tab's rule rows are swipeable")

        let titles = swipeActions(vc, ip).map { $0.title ?? "" }
        XCTAssertTrue(titles.contains("Delete"), "got \(titles)")
        XCTAssertTrue(titles.contains("Duplicate"),
                      "The App tab's INTERCEPT RULES section offers no way to duplicate, got \(titles)")
    }

    func testDuplicatingFromTheAppTabCreatesASecondIndependentRule() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let vc = makeAppTab()
        let ip = IndexPath(row: 0, section: 2)

        let duplicate = try XCTUnwrap(swipeActions(vc, ip).first { $0.title == "Duplicate" })
        runAction(duplicate)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)
        XCTAssertEqual(rows(vc, section: 2), 3,
                       "Two rules plus the Add Rule row — the App tab did not pick the copy up")
    }

    /// The "Add Rule" row is not a rule and must not be swipeable.
    func testTheAddRuleRowOffersNoSwipeActions() {
        InterceptRuleStore.shared.addOrUpdate(fullRule())
        let vc = makeAppTab()
        let addRow = IndexPath(row: 1, section: 2)
        XCTAssertFalse(vc.tableView(vc.tableView, canEditRowAt: addRow))
        XCTAssertNil(vc.tableView(vc.tableView, trailingSwipeActionsConfigurationForRowAt: addRow),
                     "The Add Rule row must not offer Delete or Duplicate")
    }

    // MARK: - 3. The editor

    func testTheEditorOffersDuplicateForAnExistingRuleOnly() throws {
        let rule = fullRule()
        InterceptRuleStore.shared.addOrUpdate(rule)

        let editing = InterceptRuleEditorViewController()
        editing.httpModel = model()
        editing.ruleToEdit = rule
        editing.loadViewIfNeeded()

        let actionRows = editing.tableView(editing.tableView, numberOfRowsInSection: 2)
        var editorText: [String] = []
        for row in 0..<actionRows {
            let cell = editing.tableView(editing.tableView, cellForRowAt: IndexPath(row: row, section: 2))
            editorText.append(contentsOf: labels(in: cell).compactMap { $0.text })
        }
        XCTAssertTrue(editorText.contains("Duplicate Rule"),
                      "The editor offers no way to duplicate the rule being edited, got \(editorText)")
        XCTAssertTrue(editorText.contains("Delete Rule"), "Delete must still be there, got \(editorText)")

        // A rule that does not exist yet has nothing to duplicate.
        let creating = InterceptRuleEditorViewController()
        creating.httpModel = model()
        creating.initialMatchMode = .exact
        creating.loadViewIfNeeded()
        var newText: [String] = []
        for row in 0..<creating.tableView(creating.tableView, numberOfRowsInSection: 2) {
            let cell = creating.tableView(creating.tableView, cellForRowAt: IndexPath(row: row, section: 2))
            newText.append(contentsOf: labels(in: cell).compactMap { $0.text })
        }
        XCTAssertFalse(newText.contains("Duplicate Rule"),
                       "There is nothing to duplicate before the rule exists, got \(newText)")
    }

    func testDuplicatingFromTheEditorStoresACopy() throws {
        let rule = fullRule()
        InterceptRuleStore.shared.addOrUpdate(rule)

        let editor = InterceptRuleEditorViewController()
        editor.httpModel = model()
        editor.ruleToEdit = rule
        editor.existingRuleId = rule.id
        editor.loadViewIfNeeded()

        // The row a finger taps.
        let rows = editor.tableView(editor.tableView, numberOfRowsInSection: 2)
        var duplicateRow: Int?
        for row in 0..<rows {
            let cell = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: row, section: 2))
            if labels(in: cell).compactMap({ $0.text }).contains("Duplicate Rule") { duplicateRow = row }
        }
        let row = try XCTUnwrap(duplicateRow, "No Duplicate Rule row in the ACTION section")
        editor.tableView(editor.tableView, didSelectRowAt: IndexPath(row: row, section: 2))

        let stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2, "Tapping Duplicate Rule stored no copy")
        XCTAssertNotNil(stored.first { $0.id != rule.id })
    }

    /// "Easier to edit" means the copy carries what is on SCREEN. Which in turn
    /// means the original has to be saved first, or the edit you can see would
    /// exist only on the copy.
    func testDuplicatingFromTheEditorCarriesTheUnsavedEditsIntoBoth() throws {
        let rule = fullRule(name: "original")
        InterceptRuleStore.shared.addOrUpdate(rule)

        let editor = InterceptRuleEditorViewController()
        editor.httpModel = model()
        editor.ruleToEdit = rule
        editor.existingRuleId = rule.id
        editor.loadViewIfNeeded()

        // An edit made in the editor and not yet saved.
        editor.setBlocked(true)
        XCTAssertEqual(InterceptRuleStore.shared.allRules().first { $0.id == rule.id }?.isBlocked, false,
                       "Precondition: the edit is on screen only")

        editor.tableView(editor.tableView, didSelectRowAt: IndexPath(row: 4, section: 2))

        let stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2)
        let original = try XCTUnwrap(stored.first { $0.id == rule.id })
        let copy = try XCTUnwrap(stored.first { $0.id != rule.id })
        XCTAssertTrue(original.isBlocked, "Duplicating discarded the edit that was on screen")
        XCTAssertTrue(copy.isBlocked, "The copy did not carry what was on screen")
        XCTAssertFalse(copy.isEnabled, "A copy is created switched off")
        XCTAssertEqual(copy.name, "original copy")
    }

    // MARK: - 4. A switched-off copy says so, everywhere it is shown

    func testTheCopysRowShowsItIsOff() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let vc = makeRuleList()
        runAction(try XCTUnwrap(swipeActions(vc, IndexPath(row: 0, section: 0))
            .first { $0.title == "Duplicate" }))

        let copy = try XCTUnwrap(InterceptRuleStore.shared.allRules().first { $0.id != original.id })
        var checked = false
        for row in 0..<rows(vc, section: 0) {
            let cell = vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: row, section: 0))
            let text = labels(in: cell).compactMap { $0.text }
            guard text.contains(copy.name) else { continue }
            checked = true
            let switches = allSwitches(in: cell)
            XCTAssertEqual(switches.first?.isOn, false,
                           "The copy's row must show it is switched off")
            XCTAssertLessThan(cell.contentView.alpha, 1.0,
                              "A disabled rule's row is dimmed — the copy's must be too")
        }
        XCTAssertTrue(checked, "The copy has no row showing \(copy.name)")
    }

    /// The editor has no enable control, so without this line a copy opened for
    /// editing looks exactly like an armed rule.
    func testTheEditorSaysWhenTheRuleItIsEditingIsSwitchedOff() throws {
        let original = fullRule()
        InterceptRuleStore.shared.addOrUpdate(original)
        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))

        let editor = InterceptRuleEditorViewController()
        editor.httpModel = model()
        editor.ruleToEdit = copy
        editor.existingRuleId = copy.id
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        var footerText: [String] = []
        for section in 0..<editor.numberOfSections(in: editor.tableView) {
            guard let footer = editor.tableView(editor.tableView, viewForFooterInSection: section) else { continue }
            footerText.append(contentsOf: labels(in: footer).compactMap { $0.text })
            XCTAssertGreaterThan(editor.tableView(editor.tableView, heightForFooterInSection: section), 0,
                                 "A footer with text needs height to be read")
        }
        XCTAssertTrue(footerText.contains { $0.lowercased().contains("switched off") },
                      "Nothing on the editor says the rule is disabled, got \(footerText)")

        // And an ARMED rule must not be told it is off.
        let armedEditor = InterceptRuleEditorViewController()
        armedEditor.httpModel = model()
        armedEditor.ruleToEdit = original
        armedEditor.existingRuleId = original.id
        armedEditor.loadViewIfNeeded()
        var armedFooters: [String] = []
        for section in 0..<armedEditor.numberOfSections(in: armedEditor.tableView) {
            guard let footer = armedEditor.tableView(armedEditor.tableView, viewForFooterInSection: section)
            else { continue }
            armedFooters.append(contentsOf: labels(in: footer).compactMap { $0.text })
        }
        XCTAssertFalse(armedFooters.contains { $0.lowercased().contains("switched off") },
                       "An armed rule was labelled as switched off, got \(armedFooters)")
    }

    private func allSwitches(in view: UIView) -> [UISwitch] {
        var found: [UISwitch] = []
        if let sw = view as? UISwitch { found.append(sw) }
        if let accessory = (view as? UITableViewCell)?.accessoryView {
            found.append(contentsOf: allSwitches(in: accessory))
        }
        for sub in view.subviews { found.append(contentsOf: allSwitches(in: sub)) }
        return found
    }
}
