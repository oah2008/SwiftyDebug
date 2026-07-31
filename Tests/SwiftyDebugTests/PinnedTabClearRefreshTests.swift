//
//  PinnedTabClearRefreshTests.swift
//  SwiftyDebugTests
//
//  "Clear Pinned Requests" (App tab → ACTIONS) calls
//  `NetworkRequestStore.shared.clearPinned()`, which deletes the pinned files
//  from disk, drops the models from the store, and posts `.allLogsCleared`.
//
//  The network screen listened to that notification only to throw away
//  body-search hits. It never re-read the store, so `cacheModels` still held the
//  deleted transactions and the Pinned tab kept rendering rows for requests that
//  no longer existed anywhere — tapping one opened a detail screen for a
//  transaction whose body had already been erased. Nothing corrected it until an
//  unrelated request completed and drove `reloadHttp()`.
//
//  These tests drive the REAL `NetworkViewController` in a window, through the
//  REAL store, and read what the table actually renders.
//

import XCTest
@testable import SwiftyDebug

final class PinnedTabClearRefreshTests: XCTestCase {

    private var window: UIWindow!
    private var controller: NetworkViewController!
    private var addedModels: [NetworkTransaction] = []
    private var addedURLs: Set<String> = []

    private var savedNetworkRequestsEnabled = true
    private var savedWebRequestsEnabled = true

    override func setUp() {
        super.setUp()
        savedNetworkRequestsEnabled = Settings.shared.networkRequestsEnabled
        savedWebRequestsEnabled = Settings.shared.webNetworkRequestsEnabled
        Settings.shared.networkRequestsEnabled = true
        Settings.shared.webNetworkRequestsEnabled = true
    }

    override func tearDown() {
        // Leave the shared tab state where a fresh launch leaves it, so the tab
        // this test switched to cannot decide another test's starting tab.
        if let controller = controller {
            switchTab(controller, to: 0)
        }
        window?.isHidden = true
        window = nil
        controller = nil

        for model in addedModels {
            model.removePinFromDisk()
            NetworkRequestStore.shared.remove(model)
        }
        // Anything this test put in the shared store under one of its own URLs,
        // including a copy the store restored from disk on first touch.
        for model in NetworkRequestStore.shared.snapshot()
        where addedURLs.contains(model.url?.absoluteString ?? "") {
            model.removePinFromDisk()
            NetworkRequestStore.shared.remove(model)
        }
        addedModels.removeAll()
        addedURLs.removeAll()

        Settings.shared.networkRequestsEnabled = savedNetworkRequestsEnabled
        Settings.shared.webNetworkRequestsEnabled = savedWebRequestsEnabled
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTransaction(_ urlString: String, pinned: Bool) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: urlString)
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "application/json"
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = model.startTime
        model.totalDuration = "0.010000 (s)"
        model.isPinned = pinned
        addedURLs.insert(urlString)
        return model
    }

    /// Adds to the real store, records it for teardown, and pins it to disk the
    /// same way the swipe action does. Order matters: the store is a lazy
    /// singleton whose init restores every pin on disk, so writing the pin first
    /// would make `addHttpRequset` see its own restored duplicate.
    @discardableResult
    private func addPinnedToStore(_ urlString: String) -> NetworkTransaction {
        let model = makeTransaction(urlString, pinned: true)
        XCTAssertTrue(NetworkRequestStore.shared.addHttpRequset(model))
        model.savePinToDisk()
        addedModels.append(model)
        return model
    }

    /// A loaded, on-screen controller. `viewDidLoad` reads the store.
    private func makeLoadedController() -> NetworkViewController {
        let vc = NetworkViewController()
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = SwiftyDebugNavigationController(rootViewController: vc)
        win.isHidden = false
        win.layoutIfNeeded()
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        window = win
        controller = vc
        return vc
    }

    /// Drives the real segmented-control action (0 = App, 1 = Web, 2 = Pinned).
    private func switchTab(_ vc: NetworkViewController, to index: Int) {
        let segment = UISegmentedControl(items: ["App", "Web", "Pinned"])
        segment.selectedSegmentIndex = index
        vc.perform(NSSelectorFromString("segmentChanged:"), with: segment)
    }

    /// The table the tab actually renders into, found in the live hierarchy.
    private func tableView(in vc: NetworkViewController) -> UITableView {
        func find(_ view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        guard let table = find(vc.view) else {
            XCTFail("The network screen has no table view")
            return UITableView()
        }
        return table
    }

    private func renderedRowCount(_ vc: NetworkViewController) -> Int {
        let table = tableView(in: vc)
        table.layoutIfNeeded()
        return table.numberOfRows(inSection: 0)
    }

    /// `.allLogsCleared` observers are registered on the main queue; let them run.
    private func pumpMainQueue() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - The defect

    func testPinnedTabStopsRenderingRequestsThatClearPinnedDeleted() {
        let urlString = "https://api.example.com/pinned-\(UUID().uuidString)"
        let model = addPinnedToStore(urlString)

        let vc = makeLoadedController()
        switchTab(vc, to: 2)

        // Precondition: the row is there before the clear, or the test proves
        // nothing about what the clear leaves behind.
        XCTAssertEqual(vc.models?.count, 1,
                       "Setup failed: the pinned request is not on the Pinned tab to begin with.")
        XCTAssertEqual(renderedRowCount(vc), 1,
                       "Setup failed: the Pinned tab rendered no row for the pinned request.")

        NetworkRequestStore.shared.clearPinned()
        pumpMainQueue()

        // The store really did delete it — this is what the screen is out of
        // step with.
        XCTAssertFalse(NetworkRequestStore.shared.snapshot().contains(where: { $0 === model }),
                       "Setup failed: clearPinned() left the transaction in the store.")

        XCTAssertEqual(vc.models?.count, 0,
                       "The Pinned tab's model still holds the requests that "
                       + "\"Clear Pinned Requests\" just deleted from the store and from disk.")
        XCTAssertEqual(renderedRowCount(vc), 0,
                       "The Pinned tab is still RENDERING rows for requests that were just "
                       + "deleted — tapping one opens a detail screen for a transaction "
                       + "whose body is already erased.")
    }

    /// The screen's cached list has to agree with the store, not merely look
    /// empty — a filtered-but-still-cached model comes back on the next tab
    /// switch.
    func testCachedListMatchesTheStoreAfterClearPinned() {
        let urlString = "https://api.example.com/pinned-\(UUID().uuidString)"
        addPinnedToStore(urlString)

        let vc = makeLoadedController()
        switchTab(vc, to: 2)
        XCTAssertEqual(vc.cacheModels?.count, NetworkRequestStore.shared.snapshot().count)

        NetworkRequestStore.shared.clearPinned()
        pumpMainQueue()

        XCTAssertEqual(vc.cacheModels?.count, NetworkRequestStore.shared.snapshot().count,
                       "The screen's cached transaction list did not re-read the store after "
                       + "the pinned requests were cleared.")
        XCTAssertFalse((vc.cacheModels ?? []).contains { $0.url?.absoluteString == urlString },
                       "A cleared pinned request is still in the screen's cache and will "
                       + "reappear on the next tab switch.")
    }

    // MARK: - Adjacent behaviour that must not move

    /// The trash button clears unpinned traffic and KEEPS pinned rows. A refresh
    /// bolted onto `.allLogsCleared` must not turn that into a full wipe.
    func testTrashButtonStillKeepsPinnedRequestsOnScreen() {
        let pinnedURL = "https://api.example.com/keep-\(UUID().uuidString)"
        addPinnedToStore(pinnedURL)

        let loose = makeTransaction("https://api.example.com/loose-\(UUID().uuidString)", pinned: false)
        XCTAssertTrue(NetworkRequestStore.shared.addHttpRequset(loose))
        addedModels.append(loose)

        let vc = makeLoadedController()
        switchTab(vc, to: 2)

        vc.perform(NSSelectorFromString("tapTrashButton:"), with: UIBarButtonItem())
        pumpMainQueue()

        XCTAssertEqual(vc.models?.count, 1,
                       "Clear (trash) must keep pinned requests visible on the Pinned tab.")
        XCTAssertEqual(vc.models?.first?.url?.absoluteString, pinnedURL)
        XCTAssertEqual(renderedRowCount(vc), 1,
                       "The Pinned tab stopped rendering the pinned request that survived Clear.")
    }

    /// Pin / unpin from the list still works, and still writes and removes the
    /// on-disk record that makes a pin survive relaunch.
    func testSwipeActionStillPinsAndUnpinsAndPersists() {
        let urlString = "https://api.example.com/swipe-\(UUID().uuidString)"
        let model = makeTransaction(urlString, pinned: false)
        XCTAssertTrue(NetworkRequestStore.shared.addHttpRequset(model))
        addedModels.append(model)

        let vc = makeLoadedController()
        switchTab(vc, to: 0)
        vc.reloadHttp()

        guard let row = vc.models?.firstIndex(where: { $0 === model }) else {
            return XCTFail("The unpinned request is not on the App tab")
        }
        let table = tableView(in: vc)
        let indexPath = IndexPath(row: row, section: 0)

        guard let pinAction = vc.tableView(table, leadingSwipeActionsConfigurationForRowAt: indexPath)?
            .actions.first else {
            return XCTFail("No leading swipe action on a captured request row")
        }
        XCTAssertEqual(pinAction.title, "Pin")
        pinAction.handler(pinAction, UIView()) { _ in }

        XCTAssertTrue(model.isPinned, "The swipe action stopped pinning.")
        XCTAssertTrue(
            NetworkTransaction.loadPinnedFromDisk().contains { $0.url?.absoluteString == urlString },
            "A pin made from the list no longer survives relaunch — it was not written to disk."
        )

        guard let unpinAction = vc.tableView(table, leadingSwipeActionsConfigurationForRowAt: indexPath)?
            .actions.first else {
            return XCTFail("No leading swipe action after pinning")
        }
        XCTAssertEqual(unpinAction.title, "Unpin")
        unpinAction.handler(unpinAction, UIView()) { _ in }

        XCTAssertFalse(model.isPinned, "The swipe action stopped unpinning.")
        XCTAssertFalse(
            NetworkTransaction.loadPinnedFromDisk().contains { $0.url?.absoluteString == urlString },
            "Unpinning no longer removes the on-disk record, so the request comes back "
            + "pinned after relaunch."
        )
    }

    /// A pinned request restored from disk is what the store loads at launch.
    /// Clearing pinned requests must leave nothing for the next launch to
    /// restore.
    func testClearPinnedLeavesNothingForTheNextLaunchToRestore() {
        let urlString = "https://api.example.com/relaunch-\(UUID().uuidString)"
        addPinnedToStore(urlString)

        XCTAssertTrue(
            NetworkTransaction.loadPinnedFromDisk().contains { $0.url?.absoluteString == urlString },
            "Setup failed: the pin was never written to disk."
        )

        NetworkRequestStore.shared.clearPinned()
        pumpMainQueue()

        XCTAssertFalse(
            NetworkTransaction.loadPinnedFromDisk().contains { $0.url?.absoluteString == urlString },
            "Clear Pinned Requests left the pin on disk, so it comes back next launch."
        )
    }
}
