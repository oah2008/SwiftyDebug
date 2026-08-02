//
//  InterceptRuleRowRenderingTests.swift
//  SwiftyDebugTests
//
//  The formatter is unit-tested next door (InterceptRuleRowFormatterTests).
//  These drive the actual screens, because the reported bug was not that a
//  function returned the wrong string — it was that three screens each built
//  their own and never asked.
//
//  Also pinned here: the row-identity rule. This file group has already shipped
//  a switch that carried `tag = indexPath.row`, so after a swipe-delete the
//  toggle armed the WRONG rule. The delete-then-toggle test below fails on that
//  shape.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class InterceptRuleRowRenderingTests: XCTestCase {

    private let requestURL = URL(string: "https://api.example.com/product/10289032912/20920220")!

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = requestURL as NSURL
        return model
    }

    private func makeListVC() -> InterceptRuleListViewController {
        let vc = InterceptRuleListViewController()
        vc.httpModel = makeModel()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        // Force the table to ASK for its row count now. Off-screen it queries the
        // data source lazily, and `deleteRows` would otherwise compare against a
        // count it only fetched after the model had already changed.
        //
        // Deliberately WITHOUT a layout pass: laying out puts the table's own
        // cells through the reuse queue, which recycles the cell a test is
        // holding on to and calls `prepareForReuse` on it.
        _ = vc.tableView.numberOfRows(inSection: 0)
        return vc
    }

    /// Every piece of text a cell puts on screen, whatever nesting it uses.
    private func visibleText(of view: UIView) -> String {
        var out: [String] = []
        func walk(_ v: UIView) {
            if let label = v as? UILabel {
                if let attributed = label.attributedText, !attributed.string.isEmpty {
                    out.append(attributed.string)
                } else if let text = label.text {
                    out.append(text)
                }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out.joined(separator: " | ")
    }

    /// Sets a switch and runs whatever the cell wired to it.
    ///
    /// `sendActions(for:)` alone does not reach the target for a control that is
    /// not in a window, and none of these cells ever are — so the registered
    /// target/action pairs are invoked directly too. Writing the same value
    /// twice is what the real toggle does anyway: it assigns a state, it does
    /// not flip one.
    private func flipSwitch(_ sw: UISwitch, to newValue: Bool) {
        sw.isOn = newValue
        sw.sendActions(for: .valueChanged)
        for target in sw.allTargets {
            for action in sw.actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
                let selector = Selector(action)
                if action.hasSuffix(":") {
                    _ = (target as AnyObject).perform(selector, with: sw)
                } else {
                    _ = (target as AnyObject).perform(selector)
                }
            }
        }
    }

    private func firstSwitch(in view: UIView) -> UISwitch? {
        if let sw = view as? UISwitch { return sw }
        for sub in view.subviews {
            if let found = firstSwitch(in: sub) { return found }
        }
        return nil
    }

    private func mockRule(path: String, host: String?, name: String) -> InterceptRule {
        var rule = InterceptRule.endpointRule(path: path, mode: .exact, host: host)
        rule.name = name
        rule.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")
        return rule
    }

    // MARK: - The rule list

    /// A mock-only rule used to render as "Empty rule" — no name, no hint that a
    /// mock was armed at all.
    func testRuleListRowShowsWhatAMockOnlyRuleDoes() {
        var rule = InterceptRule.endpointRule(path: requestURL.path, mode: .exact)
        rule.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = makeListVC()
        let text = visibleText(of: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0)))

        XCTAssertFalse(text.lowercased().contains("empty rule"), text)
        XCTAssertTrue(text.contains("404"), text)
        XCTAssertTrue(text.contains(requestURL.path), "The full path must survive to the row: \(text)")
    }

    /// A breakpoint-only and a rewrite-only rule on the same path were two
    /// identical rows.
    func testRuleListDistinguishesBreakpointFromRewriteOnTheSamePath() {
        var breakpoint = InterceptRule.endpointRule(path: requestURL.path, mode: .exact)
        breakpoint.breakpointMode = .beforeSend
        var rewrite = InterceptRule.endpointRule(path: requestURL.path, mode: .exact)
        rewrite.responseRewrites = [ResponseRewrite(pattern: "data.url",
                                                   action: .replaceHost("beta.example.com"))]
        InterceptRuleStore.shared.addOrUpdate(breakpoint)
        InterceptRuleStore.shared.addOrUpdate(rewrite)

        let vc = makeListVC()
        let first = visibleText(of: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0)))
        let second = visibleText(of: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 1, section: 0)))

        XCTAssertNotEqual(first, second)
        XCTAssertTrue((first + second).lowercased().contains("breakpoint"))
        XCTAssertTrue((first + second).lowercased().contains("rewrite"))
    }

    /// Same name, same path, different host pin: legal now, and the rows have to
    /// say which is which.
    func testRuleListSeparatesHostPinnedFromAnyHost() {
        InterceptRuleStore.shared.addOrUpdate(
            mockRule(path: requestURL.path, host: nil, name: "Sold out"))
        InterceptRuleStore.shared.addOrUpdate(
            mockRule(path: requestURL.path, host: "api.example.com", name: "Sold out"))

        let vc = makeListVC()
        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 2)

        let rows = (0..<2).map {
            visibleText(of: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: $0, section: 0)))
        }
        XCTAssertNotEqual(rows[0], rows[1], "Two rules differing only in host rendered identically")
        XCTAssertTrue(rows.contains { $0.contains("on any host") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0.contains("on api.example.com") }, "\(rows)")
    }

    // MARK: - Row identity

    // Names that cannot be found anywhere else in a row: "A" would match the
    // "EXACT" badge and the test would grade itself against the wrong rule.
    private let names = ["alpha", "bravo", "charlie"]

    private func seedThreeNamedRules() {
        for name in names {
            InterceptRuleStore.shared.addOrUpdate(
                mockRule(path: requestURL.path, host: nil, name: name))
        }
    }

    private func name(in cell: UITableViewCell) -> String? {
        names.first { visibleText(of: cell).contains($0) }
    }

    /// Renders a cell, moves a DIFFERENT row on top of it, then flips that cell's
    /// switch. The rendered cell is not rebuilt by a move, so its toggle is
    /// pointing at a row number that now belongs to another rule.
    ///
    /// This is the confirmed "toggling a row enabled the WRONG rule" defect,
    /// which shipped here once already as `tag = indexPath.row`. Any row-numbered
    /// toggle disarms `charlie` instead of the rule the cell is showing.
    func testTogglingACellAfterTheRowsMoveHitsTheRuleTheCellShows() {
        seedThreeNamedRules()

        let vc = makeListVC()
        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 3)

        let topRow = vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        guard let shownName = name(in: topRow) else {
            return XCTFail("Row 0 showed none of \(names): \(visibleText(of: topRow))")
        }

        // Drag the last rule to the top: row 0 now belongs to somebody else.
        vc.tableView(vc.tableView,
                     moveRowAt: IndexPath(row: 2, section: 0),
                     to: IndexPath(row: 0, section: 0))

        guard let sw = firstSwitch(in: topRow) else {
            return XCTFail("No enable switch in the rule cell")
        }
        flipSwitch(sw, to: false)

        let stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first { $0.name == shownName }?.isEnabled, false,
                       "The switch disabled a different rule than the one its cell showed. "
                       + "Showing \(shownName), state: \(stored.map { "\($0.name)=\($0.isEnabled)" })")
        for rule in stored where rule.name != shownName {
            XCTAssertTrue(rule.isEnabled, "\(rule.name) was disarmed by a toggle on another row")
        }
    }

    /// Swipe-delete takes out the rule on THAT row and leaves the rest armed.
    func testSwipeDeleteRemovesTheRuleOnThatRowOnly() {
        seedThreeNamedRules()

        let vc = makeListVC()
        // A layout pass, so the table has committed to a row count before the
        // batch update checks it against the data source.
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.tableView.layoutIfNeeded()

        let doomed = name(in: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0)))
        XCTAssertNotNil(doomed)

        vc.tableView(vc.tableView, commit: .delete, forRowAt: IndexPath(row: 0, section: 0))

        let stored = InterceptRuleStore.shared.allRules()
        XCTAssertEqual(stored.count, 2)
        XCTAssertNil(stored.first { $0.name == doomed }, "The deleted rule is still stored")
        XCTAssertEqual(vc.tableView(vc.tableView, numberOfRowsInSection: 0), 2)
        for rule in stored { XCTAssertTrue(rule.isEnabled) }
    }

    // MARK: - The App tab

    func testAppTabRowShowsTheNameAndTheScope() {
        InterceptRuleStore.shared.addOrUpdate(
            mockRule(path: "/cart", host: "api.example.com", name: "Empty basket"))

        let vc = AppInfoViewController()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)

        // The section enum is private; scan for the row instead of hardcoding an
        // index, so this test does not break when a section is added.
        var found = ""
        for section in 0..<vc.numberOfSections(in: vc.tableView) {
            for row in 0..<vc.tableView(vc.tableView, numberOfRowsInSection: section) {
                let cell = vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: row, section: section))
                let text = visibleText(of: cell)
                if text.contains("Empty basket") { found = text }
            }
        }

        XCTAssertFalse(found.isEmpty, "The App tab never showed the rule's name")
        XCTAssertTrue(found.contains("/cart on api.example.com"), found)
        XCTAssertFalse(found.lowercased().contains("empty rule"), found)
    }

    // MARK: - Export / import list

    func testExportListShowsNameScopeAndDisabledState() {
        var rule = mockRule(path: "/cart", host: nil, name: "")
        rule.isEnabled = false
        InterceptRuleStore.shared.addOrUpdate(rule)

        let vc = RuleTransferViewController()
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)

        let text = visibleText(of: vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0)))
        XCTAssertFalse(text.lowercased().contains("empty rule"), text)
        XCTAssertTrue(text.contains("404"), text)
        XCTAssertTrue(text.contains("/cart on any host"), text)
        XCTAssertTrue(text.contains("Disabled"), "No switch on this screen — it has to say so: \(text)")
    }
}
