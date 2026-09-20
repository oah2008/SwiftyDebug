//
//  AppinfoAuditFixTests.swift
//  SwiftyDebugTests
//
//  Three App-tab defects, each pinned to what the screen actually does:
//
//    * a completed request rebuilt the whole table, and the SETTINGS cells are
//      not dequeued — every pass throws away the `UISwitch` a finger is on, so
//      the touch is cancelled and the toggle springs back unwritten;
//    * the "Restart to Apply Everywhere" alert named a button that is compiled
//      out of a Release-configured SDK build;
//    * a MONITORED URLS cell reused from an untagged row activated its
//      below-tags top constraint while the card-top one was still installed,
//      handing Auto Layout a pair that cannot both hold.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class AppinfoAuditFixTests: XCTestCase {

    private var window: UIWindow!
    private var vc: AppInfoViewController!
    private var savedURLs: [String] = []

    override func setUp() {
        super.setUp()
        savedURLs = SwiftyDebug.urls
    }

    override func tearDown() {
        SwiftyDebug.urls = savedURLs
        window?.isHidden = true
        window = nil
        vc = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// Puts the real screen in a real window, because everything here is about
    /// cells that exist: an off-screen table builds none.
    private func makeAppTab(height: CGFloat = 900) {
        vc = AppInfoViewController()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.rootViewController = SwiftyDebugNavigationController(rootViewController: vc)
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        window.layoutIfNeeded()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func allText(in view: UIView) -> String {
        descendants(of: view).compactMap { ($0 as? UILabel)?.text }.joined(separator: " ")
    }

    /// Sections are found by their header, not by a hard-coded index, so
    /// re-ordering the tab cannot make these tests quietly test nothing.
    private func section(titled title: String) throws -> Int {
        for section in 0..<vc.tableView.numberOfSections {
            guard let header = vc.tableView(vc.tableView, viewForHeaderInSection: section) else { continue }
            if allText(in: header).contains(title) { return section }
        }
        throw NotFound(what: title)
    }

    private struct NotFound: Error { let what: String }

    // MARK: - A completed request must not rebuild the SETTINGS switches

    func testCompletedRequestLeavesTheSettingsSwitchesInPlace() throws {
        makeAppTab()
        let settings = try section(titled: "SETTINGS")
        let indexPath = IndexPath(row: 0, section: settings)

        let cellBefore = try XCTUnwrap(vc.tableView.cellForRow(at: indexPath),
                                       "the first SETTINGS row must be on screen for this to mean anything")
        let switchBefore = try XCTUnwrap(cellBefore.accessoryView as? UISwitch)

        // One completed request, exactly as `CustomHTTPProtocol` posts it.
        NotificationCenter.default.post(name: .networkRequestCompleted, object: nil)
        spin()
        window.layoutIfNeeded()

        let cellAfter = try XCTUnwrap(vc.tableView.cellForRow(at: indexPath))
        XCTAssertTrue(cellAfter === cellBefore,
                      "a completed request must not rebuild a SETTINGS row — these cells are not dequeued")
        XCTAssertTrue((cellAfter.accessoryView as? UISwitch) === switchBefore,
                      "the switch a finger is on may not be replaced; when it is, the touch is cancelled "
                      + "and the setting is never written")
    }

    /// The same guarantee under the traffic that actually provokes it: a burst,
    /// not a single notification.
    func testBurstOfCompletedRequestsLeavesEverySettingsSwitchInPlace() throws {
        makeAppTab()
        let settings = try section(titled: "SETTINGS")
        let rows = vc.tableView.numberOfRows(inSection: settings)
        XCTAssertGreaterThan(rows, 1)

        var switches: [Int: UISwitch] = [:]
        for row in 0..<rows {
            let indexPath = IndexPath(row: row, section: settings)
            if let sw = vc.tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch {
                switches[row] = sw
            }
        }
        XCTAssertFalse(switches.isEmpty, "no SETTINGS row was on screen")

        for _ in 0..<20 {
            NotificationCenter.default.post(name: .networkRequestCompleted, object: nil)
        }
        spin()
        window.layoutIfNeeded()

        for (row, sw) in switches {
            let indexPath = IndexPath(row: row, section: settings)
            let now = vc.tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch
            XCTAssertTrue(now === sw, "row \(row)'s switch was replaced by request traffic")
        }
    }

    /// The value a switch writes has to survive the traffic too — the reported
    /// symptom was "I turn it on and it doesn't turn on".
    func testSettingWrittenByASwitchSurvivesCompletedRequests() throws {
        makeAppTab()
        let settings = try section(titled: "SETTINGS")
        let indexPath = IndexPath(row: 0, section: settings)
        let cell = try XCTUnwrap(vc.tableView.cellForRow(at: indexPath))
        let sw = try XCTUnwrap(cell.accessoryView as? UISwitch)

        let original = sw.isOn
        defer {
            sw.setOn(original, animated: false)
            sw.sendActions(for: .valueChanged)
        }

        sw.setOn(!original, animated: false)
        sw.sendActions(for: .valueChanged)
        let written = sw.isOn

        NotificationCenter.default.post(name: .networkRequestCompleted, object: nil)
        spin()
        window.layoutIfNeeded()

        let sameCell = try XCTUnwrap(vc.tableView.cellForRow(at: indexPath))
        let sameSwitch = try XCTUnwrap(sameCell.accessoryView as? UISwitch)
        XCTAssertEqual(sameSwitch.isOn, written)
    }

    // MARK: - The restart alert may only name a button that exists

    func testRestartAdviceNamesTheQuitButtonOnlyWhenItShips() {
        XCTAssertEqual(AppInfoViewController.restartQuitAdvice().contains("Quit App Now"),
                       AppInfoViewController.offersQuitAction,
                       "the alert body may name \"Quit App Now\" only in a build that compiles that action in")
    }

    /// Either way the user is told how to make the change reach every session —
    /// an alert that says a restart is needed and then offers no route to one is
    /// the defect, not just a wrong button name.
    func testRestartAdviceAlwaysSaysHowToGetABrandNewProcess() {
        let advice = AppInfoViewController.restartQuitAdvice()
        XCTAssertTrue(advice.contains("iOS cannot relaunch an app"))
        XCTAssertTrue(advice.contains("Home screen"))
        if !AppInfoViewController.offersQuitAction {
            XCTAssertTrue(advice.contains("app switcher"),
                          "with no Quit button, the only route left is quitting by hand — say so")
        }
    }

    // MARK: - MONITORED URLS: one top constraint at a time

    /// A URL with no host resolves to no tag at all (`TagResolver` derives a tag
    /// from the host otherwise), so these are the rows that take the card-top
    /// constraint — and the rows whose recycled cells provoke the conflict.
    private func mixedURLs(count: Int) -> [String] {
        (0..<count).map { index in
            index.isMultiple(of: 2)
                ? "/local/only/path/\(index)"
                : "https://api.example.com/v1/items/\(index)"
        }
    }

    /// The direct form, and the one that can still see the defect: the engine is
    /// handed the pair the moment the second constraint is activated, and it
    /// resolves that by breaking one — so the pair is only visible BEFORE a
    /// layout pass, which is why this drives the data source itself rather than
    /// reading the table after it has laid out.
    func testCellRecycledAcrossTaggedAndUntaggedRowsHoldsOneTopConstraint() throws {
        SwiftyDebug.urls = mixedURLs(count: 60)
        makeAppTab(height: 600)

        let table = vc.tableView!
        let urlSection = try section(titled: "MONITORED URLS")
        scrollThrough(table)   // fills the reuse pool with configured cells

        // Alternating rows means every dequeue here is the reuse that matters:
        // a cell configured for a row of one shape, handed a row of the other.
        for row in 0..<8 {
            let cell = vc.tableView(table, cellForRowAt: IndexPath(row: row, section: urlSection))
            assertOneTopConstraint(in: cell, row: row)
        }
    }

    /// The same invariant over the table as a finger leaves it, so a cell that
    /// lost a constraint to Auto Layout's conflict recovery cannot go on
    /// rendering at the wrong offset unnoticed.
    func testScrollingTheURLSectionLeavesEveryCellPinnedCorrectly() throws {
        SwiftyDebug.urls = mixedURLs(count: 60)
        makeAppTab(height: 600)

        let table = vc.tableView!
        scrollThrough(table) {
            for cell in table.visibleCells where isURLCell(cell) {
                assertOneTopConstraint(in: cell, row: table.indexPath(for: cell)?.row ?? -1)
            }
        }
    }

    private func scrollThrough(_ table: UITableView, each: () -> Void = {}) {
        var offset: CGFloat = 0
        while offset < table.contentSize.height {
            table.contentOffset = CGPoint(x: 0, y: offset)
            table.layoutIfNeeded()
            each()
            offset += 120
        }
    }

    private func isURLCell(_ cell: UITableViewCell) -> Bool {
        String(describing: type(of: cell)).contains("AppURLCell")
    }

    private func assertOneTopConstraint(in cell: UITableViewCell, row: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        guard isURLCell(cell) else { return }
        let views = descendants(of: cell)
        guard let stack = views.compactMap({ $0 as? UIStackView }).first,
              let card = stack.superview,
              // The URL label is the multi-line one sitting directly on the card;
              // the tag pills are inside the stack.
              let urlLabel = views.first(where: { view in
                  guard let label = view as? UILabel else { return false }
                  return label.numberOfLines == 0 && label.superview === card
              })
        else {
            XCTFail("row \(row): could not find the URL cell's card, tags stack and URL label",
                    file: file, line: line)
            return
        }

        let tops = (card.constraints + cell.contentView.constraints).filter { constraint in
            constraint.isActive
                && constraint.firstItem === urlLabel
                && constraint.firstAttribute == .top
        }
        XCTAssertEqual(tops.count, 1,
                       "row \(row): the URL label must be pinned to exactly one anchor — the below-tags and "
                       + "card-top constraints are mutually exclusive, so holding both is unsatisfiable",
                       file: file, line: line)

        guard let top = tops.first else { return }
        if stack.isHidden {
            XCTAssertTrue(top.secondItem === card,
                          "row \(row): an untagged row pins the URL to the card top", file: file, line: line)
        } else {
            XCTAssertTrue(top.secondItem === stack,
                          "row \(row): a tagged row pins the URL below the tags", file: file, line: line)
        }
    }
}
