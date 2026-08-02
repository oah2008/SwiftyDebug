//
//  LogScreenObserverLifetimeTests.swift
//  SwiftyDebugTests
//
//  The Logs tab had the same leak `NetworkViewController` was fixed for, and
//  nothing was pinning it: `NotificationCenter.addObserver(forName:…)` registers
//  the token it RETURNS, so dropping that token leaves the block registered for
//  the life of the process. `removeObserver(self)` in `deinit` cannot undo it.
//
//  In an SDK embedded in someone else's app that is one permanent observer per
//  open of the Logs tab, each one hopping onto the main queue for every single
//  line the app logs, forever, on behalf of a screen that no longer exists.
//
//  `DebugUIObserverLifetimeTests` pins the bag itself and the NETWORK screen.
//  These pin the LOGS screen: that it registers through the bag, and that every
//  token it took out is handed back to the same centre when it is released.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class LogScreenObserverLifetimeTests: XCTestCase {

    /// A notification centre that keeps a ledger of the block registrations made
    /// against it and of the tokens handed back. Nothing else can see either —
    /// `NotificationCenter` exposes no observer list — and an unregistration
    /// that never happens has no other visible symptom, which is precisely why
    /// this leak survived so long.
    private final class LedgerCenter: NotificationCenter {
        private(set) var issued: [ObjectIdentifier] = []
        private(set) var returned: Set<ObjectIdentifier> = []

        override func addObserver(forName name: NSNotification.Name?,
                                  object obj: Any?,
                                  queue: OperationQueue?,
                                  using block: @escaping (Notification) -> Void) -> NSObjectProtocol {
            let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
            issued.append(ObjectIdentifier(token))
            return token
        }

        override func removeObserver(_ observer: Any) {
            if let object = observer as? NSObject {
                returned.insert(ObjectIdentifier(object))
            }
            super.removeObserver(observer)
        }

        var leaked: [ObjectIdentifier] { issued.filter { !returned.contains($0) } }
    }

    private var consoleLogsWereEnabled = false
    private var consoleCaptureWasOn = true
    private var storeCallback: ((Int, Int) -> Void)?

    override func setUp() {
        super.setUp()
        consoleLogsWereEnabled = Settings.shared.consoleLogsEnabled
        consoleCaptureWasOn = SwiftyDebug.enableConsoleLog
        // Keep the real stdout pipe and OSLog poll out of this: the screen is
        // driven by hand here, and the test process keeps its own stdout.
        SwiftyDebug.enableConsoleLog = false
        Settings.shared.consoleLogsEnabled = true
        storeCallback = ConsoleLogDB.shared.onCountChanged
        ConsoleLogDB.shared.onCountChanged = nil
    }

    override func tearDown() {
        Settings.shared.consoleLogsEnabled = consoleLogsWereEnabled
        SwiftyDebug.enableConsoleLog = consoleCaptureWasOn
        ConsoleLogDB.shared.onCountChanged = storeCallback
        super.tearDown()
    }

    // MARK: - Every token is handed back

    /// The leak itself. Open the Logs tab, close it, and every block observer it
    /// registered must be gone from the centre it registered on.
    func testEveryObserverTheLogsScreenRegistersIsUnregisteredWhenItGoesAway() {
        let center = LedgerCenter()

        weak var weakController: LogViewController?
        autoreleasepool {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
            let controller = LogViewController()
            controller.notificationCenter = center
            window.rootViewController = controller
            window.isHidden = false
            controller.loadViewIfNeeded()
            window.layoutIfNeeded()
            weakController = controller

            XCTAssertGreaterThanOrEqual(center.issued.count, 2,
                                        "The Logs screen registers block observers for console output "
                                        + "and for log updates; if it registers none this test proves nothing.")
            XCTAssertEqual(center.leaked.count, center.issued.count,
                           "Precondition: nothing is unregistered while the screen is alive.")

            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertNil(weakController,
                     "The Logs screen must be deallocatable — a strongly captured self in one of "
                     + "its observer blocks would keep the whole screen alive behind the leak.")
        XCTAssertEqual(center.leaked, [],
                       "\(center.leaked.count) of \(center.issued.count) observers outlived the Logs "
                       + "screen. Each one is a permanent main-thread hop for every line the host "
                       + "app logs, for a screen that no longer exists — one more per Logs-tab open.")
    }

    /// Opening the tab repeatedly must not accumulate registrations — this is
    /// the shape the leak actually took in a session (open, close, open, close).
    func testOpeningTheLogsTabRepeatedlyLeavesNothingBehind() {
        let center = LedgerCenter()

        for _ in 0..<3 {
            autoreleasepool {
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
                let controller = LogViewController()
                controller.notificationCenter = center
                window.rootViewController = controller
                window.isHidden = false
                controller.loadViewIfNeeded()
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        XCTAssertGreaterThanOrEqual(center.issued.count, 6)
        XCTAssertEqual(center.leaked, [],
                       "Every open of the Logs tab left its observers registered forever.")
    }

    // MARK: - …and the observers were doing real work

    /// Guards the test above from becoming a tautology: if the Logs screen ever
    /// stopped registering (or stopped reacting), "nothing leaked" would be
    /// trivially true. This proves the registrations that must be cleaned up are
    /// the ones the screen actually runs on.
    func testTheRegisteredObserverIsTheOneThatDrivesTheConsoleTable() {
        let center = LedgerCenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let controller = LogViewController()
        controller.notificationCenter = center
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        selectConsoleTab(of: controller)
        window.layoutIfNeeded()

        let table = consoleTable(of: controller)
        center.post(name: .consoleOutputReceived, object: nil,
                    userInfo: ["totalCount": 7, "insertedCount": 7])
        drainMainQueue()
        window.layoutIfNeeded()

        XCTAssertEqual(table.numberOfRows(inSection: 0), 7,
                       "The console table is driven by the observer registered in viewDidLoad — "
                       + "if this stops holding, the leak test above is measuring nothing.")

        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: - Harness

    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func selectConsoleTab(of controller: LogViewController) {
        guard let segment = Self.segmentedControls(in: controller.view).first else {
            return XCTFail("No segmented control in the Logs screen")
        }
        segment.selectedSegmentIndex = 0
        controller.segmentChanged(segment)
    }

    private func consoleTable(of controller: LogViewController) -> UITableView {
        let tables = Self.tableViews(in: controller.view).filter { $0.dataSource === controller }
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
