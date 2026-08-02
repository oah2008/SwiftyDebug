//
//  ConsoleBatchUpdateTests.swift
//  SwiftyDebugTests
//
//  Clearing the Console used to crash the host app on the next line of output.
//
//  The console table is virtual: its row count comes from a SQLite count that
//  arrives by notification, not from an array the view controller owns. The
//  handler applied growth with `insertRows`, but when the count *shrank* it
//  simply returned — the table kept its old, larger cached row count while the
//  data source reported the new smaller one. The next line of output then ran
//  `insertRows` against that stale table and UIKit threw:
//
//      Invalid update: invalid number of rows in section 0. The number of rows
//      contained in an existing section after the update (1) must be equal to
//      the number of rows contained in that section before the update (N),
//      plus or minus the number of rows inserted or deleted…
//
//  A shrink is not exotic: Clear posts a count of 0 from the store's write
//  queue, and a still-in-flight insert callback can land *after* the local
//  count was zeroed, putting rows back into the table first.
//
//  These tests assert the resync directly (a stale table fails cleanly here,
//  before the invalid update that would abort the whole run).
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class ConsoleBatchUpdateTests: XCTestCase {

    private var window: UIWindow!
    private var vc: LogViewController!
    private var consoleLogsWereEnabled = false
    private var consoleCaptureWasOn = true
    private var storeCallback: ((Int, Int) -> Void)?

    override func setUp() {
        super.setUp()
        consoleLogsWereEnabled = Settings.shared.consoleLogsEnabled
        consoleCaptureWasOn = SwiftyDebug.enableConsoleLog
        // These tests post the store's notification themselves. Keep the real
        // capture (stdout pipe + OSLog poll) switched off so nothing else
        // writes to the console store — and so the test process keeps its own
        // stdout.
        SwiftyDebug.enableConsoleLog = false
        Settings.shared.consoleLogsEnabled = true
        // Detach the live store from the notification for the duration: a write
        // still in flight from elsewhere in the suite would otherwise post a
        // real count into the middle of a scripted sequence.
        storeCallback = ConsoleLogDB.shared.onCountChanged
        ConsoleLogDB.shared.onCountChanged = nil

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        vc = LogViewController()
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        selectConsoleTab()
        window.layoutIfNeeded()
    }

    override func tearDown() {
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

    /// The exact sequence that crashed: a count that shrinks, then one more
    /// line of output.
    func testShrinkingCountResyncsTableSoTheNextLineDoesNotBreakTheBatchUpdate() {
        let table = consoleTable()
        let base = table.numberOfRows(inSection: 0)

        post(totalCount: base + 3)
        XCTAssertEqual(table.numberOfRows(inSection: 0), base + 3,
                       "New output should be inserted, not dropped.")

        // Clear: the store reports zero rows.
        post(totalCount: 0)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0,
                       "A shrink must resync the table. Leaving \(base + 3) stale rows in it "
                       + "makes the next insertRows an invalid batch update — the Clear-then-print crash.")

        // The next line of output. This is the call that used to abort.
        post(totalCount: 1)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
    }

    /// The real-world ordering: Clear runs, an insert callback that was already
    /// in flight lands afterwards and refills the table, then the delete
    /// callback arrives with 0, then the user's app prints one more line.
    func testClearFollowedByLateInsertCallbackThenOutput() {
        let table = consoleTable()
        let base = table.numberOfRows(inSection: 0)

        post(totalCount: base + 5)
        XCTAssertEqual(table.numberOfRows(inSection: 0), base + 5)

        // Late insert callback (queued before the delete was even issued).
        post(totalCount: base + 7)
        XCTAssertEqual(table.numberOfRows(inSection: 0), base + 7)

        // deleteAll's callback.
        post(totalCount: 0)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0)

        // print("…")
        post(totalCount: 2)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
    }

    /// A shrink that lands while the console tab is on screen must never leave
    /// the table and the data source disagreeing, whatever the sizes.
    func testTableAndDataSourceNeverDisagreeAcrossAnArbitrarySequence() {
        let table = consoleTable()
        for count in [12, 3, 40, 0, 1, 700, 699, 0, 5] {
            post(totalCount: count)
            XCTAssertEqual(table.numberOfRows(inSection: 0), count,
                           "table disagreed with the data source after a count of \(count)")
        }
    }

    /// Turning console capture off zeroes the count — same hazard, other door.
    func testDisablingConsoleLogsResyncsTheTable() {
        let table = consoleTable()
        post(totalCount: 25)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 25)

        Settings.shared.consoleLogsEnabled = false
        post(totalCount: 25)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0)

        Settings.shared.consoleLogsEnabled = true
        post(totalCount: 4)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 4)
    }

    // MARK: - Harness

    /// Exactly what `LogStore` posts when `ConsoleLogDB`'s count changes — and
    /// the invariant that must survive it: the row count the table is holding
    /// and the row count the data source reports are the same number. The
    /// moment they differ, the next partial update is an invalid batch update.
    private func post(totalCount: Int, file: StaticString = #filePath, line: UInt = #line) {
        NotificationCenter.default.post(name: .consoleOutputReceived, object: nil,
                                        userInfo: ["totalCount": totalCount, "insertedCount": 0])
        drainMainQueue()
        window.layoutIfNeeded()

        let table = consoleTable()
        XCTAssertEqual(table.numberOfRows(inSection: 0),
                       vc.tableView(table, numberOfRowsInSection: 0),
                       "Table and data source disagree after a count of \(totalCount): "
                       + "the next line of output would be an invalid batch update.",
                       file: file, line: line)
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// The console table is the one visible while segment 0 is selected.
    private func consoleTable() -> UITableView {
        let tables = Self.tableViews(in: vc.view).filter { $0.dataSource === vc }
        XCTAssertEqual(tables.count, 2, "Expected the console and the card table.")
        guard let console = tables.first(where: { !$0.isHidden }) else {
            XCTFail("No visible table on the console tab")
            return UITableView()
        }
        return console
    }

    private func selectConsoleTab() {
        guard let segment = Self.segmentedControls(in: vc.view).first else {
            XCTFail("No segmented control in the Logs screen")
            return
        }
        segment.selectedSegmentIndex = 0
        vc.segmentChanged(segment)
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
