//
//  ConsoleInsertGuardTests.swift
//  SwiftyDebugTests
//
//  The console table is virtual: its row count comes from a SQLite count that
//  arrives by notification, not from an array the screen owns. So the screen's
//  idea of the row count and the table's own cached row count can drift apart —
//  a count that lands while the Logs tab is showing a different source updates
//  the former and never touches the latter.
//
//  `insertRows` is checked by UIKit against the table's cached count, not
//  against the data source, and a mismatch is an immediate
//  NSInternalInconsistencyException:
//
//      Invalid update: invalid number of rows in section 0…
//
//  That is why every partial update states the row count it BELIEVES the table
//  is holding (`expectedExistingRows`) and falls back to `reloadData()` when the
//  belief is wrong.
//
//  `ConsoleBatchUpdateTests` covers the *shrink* half of this (`newRows < 0`).
//  It does not cover the guard inside `insertConsoleRows` itself: delete the
//  `numberOfRows(inSection:) == expectedExistingRows` check and the whole suite
//  stays green while the next line of output crashes the host app.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class ConsoleInsertGuardTests: XCTestCase {

    private var window: UIWindow!
    private var vc: LogViewController!
    private var consoleLogsWereEnabled = false
    private var consoleCaptureWasOn = true
    private var storeCallback: ((Int, Int) -> Void)?

    override func setUp() {
        super.setUp()
        consoleLogsWereEnabled = Settings.shared.consoleLogsEnabled
        consoleCaptureWasOn = SwiftyDebug.enableConsoleLog
        // The counts here are scripted; keep the real capture (stdout pipe +
        // OSLog poll) off so nothing else writes to the console store, and so
        // the test process keeps its own stdout.
        SwiftyDebug.enableConsoleLog = false
        Settings.shared.consoleLogsEnabled = true
        storeCallback = ConsoleLogDB.shared.onCountChanged
        ConsoleLogDB.shared.onCountChanged = nil

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        vc = LogViewController()
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        selectSegment(0)
        window.layoutIfNeeded()
    }

    override func tearDown() {
        selectSegment(0)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        vc = nil
        Settings.shared.consoleLogsEnabled = consoleLogsWereEnabled
        SwiftyDebug.enableConsoleLog = consoleCaptureWasOn
        ConsoleLogDB.shared.onCountChanged = storeCallback
        super.tearDown()
    }

    // MARK: - Tests

    /// The table is holding more rows than the screen thinks it is, and then the
    /// app prints another line. Without the guard that is an invalid batch
    /// update — the exception aborts the HOST app, not just the debug UI.
    func testAnInsertOntoATableHoldingMoreRowsThanExpectedResyncsInstead() {
        let table = consoleTable()

        post(totalCount: 6)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 6,
                       "Precondition: output is inserted while the console tab is up.")

        // The Logs tab moves to another source. Console counts keep arriving —
        // they update the screen's count and leave the table alone, because the
        // console table is not the one on screen.
        setSegmentWithoutNotifying(1)
        post(totalCount: 2)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 6,
                       "Precondition: the table still holds the rows it was given; only the "
                       + "screen's count moved. This drift is what the guard exists for.")

        // Back on the console tab, one more line of output arrives: a growth of
        // 2 rows onto a table the screen believes is holding 2, and is not.
        setSegmentWithoutNotifying(0)
        post(totalCount: 4)

        XCTAssertEqual(table.numberOfRows(inSection: 0), 4,
                       "The insert had to be abandoned for a reload. Taking it would raise "
                       + "\"invalid number of rows in section 0\" and abort the host app.")
    }

    /// The same drift, the other way round: the table is holding FEWER rows than
    /// the screen believes, so the insert would address rows past the end.
    func testAnInsertOntoATableHoldingFewerRowsThanExpectedResyncsInstead() {
        let table = consoleTable()

        post(totalCount: 2)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)

        setSegmentWithoutNotifying(1)
        post(totalCount: 30)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2,
                       "Precondition: the screen's count ran ahead of the table.")

        setSegmentWithoutNotifying(0)
        post(totalCount: 33)

        XCTAssertEqual(table.numberOfRows(inSection: 0), 33,
                       "Inserting rows 30…32 into a table holding 2 is \"attempt to insert row "
                       + "30 into a section with only 2 rows\" — the guard must reload instead.")
    }

    /// And the drift must never survive a sequence of them: after every count
    /// the table and the data source have to agree, because the next partial
    /// update is validated against exactly that.
    func testTheTableAndTheDataSourceAgreeAfterEveryDriftedInsert() {
        let table = consoleTable()

        for (offTab, backOn) in [(3, 9), (40, 41), (1, 600), (12, 13)] {
            setSegmentWithoutNotifying(1)
            post(totalCount: offTab)
            setSegmentWithoutNotifying(0)
            post(totalCount: backOn)

            XCTAssertEqual(table.numberOfRows(inSection: 0), backOn,
                           "table disagreed with the data source after \(offTab) -> \(backOn)")
            XCTAssertEqual(table.numberOfRows(inSection: 0),
                           vc.tableView(table, numberOfRowsInSection: 0))
        }
    }

    // MARK: - Harness

    /// Exactly what `LogStore` posts when `ConsoleLogDB`'s count changes.
    private func post(totalCount: Int) {
        NotificationCenter.default.post(name: .consoleOutputReceived, object: nil,
                                        userInfo: ["totalCount": totalCount, "insertedCount": 0])
        drainMainQueue()
        window.layoutIfNeeded()
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Moves the source selector without running the tab-switch handler — the
    /// same thing `setupUI` does when it restores the last used segment, and the
    /// cheapest way to reproduce a table whose cached row count no longer
    /// matches what the screen believes.
    private func setSegmentWithoutNotifying(_ index: Int) {
        segment()?.selectedSegmentIndex = index
    }

    /// A full tab switch, handler and all.
    private func selectSegment(_ index: Int) {
        guard let segment = segment() else { return }
        segment.selectedSegmentIndex = index
        vc?.segmentChanged(segment)
    }

    private func segment() -> UISegmentedControl? {
        guard let vc else { return nil }
        let controls = Self.segmentedControls(in: vc.view)
        if controls.isEmpty { XCTFail("No segmented control in the Logs screen") }
        return controls.first
    }

    private func consoleTable() -> UITableView {
        let tables = Self.tableViews(in: vc.view).filter { $0.dataSource === vc }
        XCTAssertEqual(tables.count, 2, "Expected the console and the card table.")
        guard let console = tables.first(where: { !$0.isHidden }) else {
            XCTFail("No visible table on the console tab")
            return UITableView()
        }
        return console
    }

    private static func tableViews(in view: UIView) -> [UITableView] {
        var out: [UITableView] = []
        if let table = view as? UITableView { out.append(table) }
        for subview in view.subviews { out += tableViews(in: subview) }
        return out
    }

    private static func segmentedControls(in view: UIView) -> [UISegmentedControl] {
        var out: [UISegmentedControl] = []
        if let segment = view as? UISegmentedControl { out.append(segment) }
        for subview in view.subviews { out += segmentedControls(in: subview) }
        return out
    }
}
