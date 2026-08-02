//
//  DetailCancelledPopRestoreTests.swift
//  SwiftyDebugTests
//
//  The request detail screen releases its big cached strings — every built
//  section and the whole response body — in `viewWillDisappear`, guarded by
//  `isMovingFromParent || isBeingDismissed`. Releasing them on a REAL
//  disappearance is deliberate and stays.
//
//  An interactive (swipe-back) pop sets `isMovingFromParent` the moment the
//  gesture starts, so the release runs THEN. If the user lets go before the
//  threshold, UIKit cancels the transition and brings the same screen back with
//  `viewWillAppear` / `viewDidAppear` — with nothing in it. The table renders no
//  sections, and Copy / "Share full details (text)" produce a header line with
//  no body: the request's own data, silently missing, on a screen that is still
//  in front of the user.
//
//  These tests drive the REAL controller in a REAL UINavigationController and
//  reproduce the cancelled pop the way UIKit does it — `willMove(toParent: nil)`
//  plus an appearance transition that is started and then reversed. The probe
//  that established this sequence produces exactly
//  `viewWillDisappear(isMovingFromParent: true)` → `viewWillAppear` →
//  `viewDidAppear`, with the controller still on the navigation stack.
//

import XCTest
@testable import SwiftyDebug

final class DetailCancelledPopRestoreTests: XCTestCase {

    private var window: UIWindow!
    private var navigation: UINavigationController!
    private var detail: NetworkDetailViewController!
    private var transaction: NetworkTransaction!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        navigation = nil
        detail = nil
        transaction = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTransaction() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com/v1/orders/42?expand=items")
        model.method = "POST"
        model.statusCode = "200"
        model.mineType = "application/json"
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = String(format: "%f", Date().timeIntervalSince1970 + 0.25)
        model.totalDuration = "0.250000 (s)"
        model.requestHeaderFields = ["Content-Type": "application/json",
                                     "X-Request-Id": "abc-123"] as NSDictionary
        model.responseHeaderFields = ["Content-Type": "application/json",
                                      "Cache-Control": "max-age=60"] as NSDictionary
        model.requestData = #"{"quantity":2,"sku":"WIDGET-1"}"#.data(using: .utf8)
        model.responseData = #"{"id":42,"status":"confirmed","total":19.99}"#.data(using: .utf8)
        model.responseDataSize = UInt(model.responseData?.count ?? 0)
        model.requestDataSize = UInt(model.requestData?.count ?? 0)

        // A rewritten response — the screen has to keep saying so.
        model.isResponseRewritten = true
        model.rewrittenValueCount = 1
        model.rewriteNotes = ["Confirm order\n  matched 1, changed 1"]
        return model
    }

    /// The detail screen, pushed onto a real navigation stack and laid out.
    private func presentDetail() -> NetworkDetailViewController {
        let model = makeTransaction()
        let vc = NetworkDetailViewController()
        vc.httpModel = model
        vc.httpModels = [model]

        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = nav
        win.isHidden = false
        win.layoutIfNeeded()

        nav.pushViewController(vc, animated: false)
        win.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        window = win
        navigation = nav
        detail = vc
        transaction = model
        return vc
    }

    /// The swipe-back gesture starting and then being ABANDONED, exactly as
    /// UIKit sequences it: the removal is announced, the disappearance
    /// transition begins (this is where `isMovingFromParent` is true), and then
    /// the transition is reversed instead of completed.
    private func beginAndCancelInteractivePop(_ vc: UIViewController) {
        vc.willMove(toParent: nil)
        vc.beginAppearanceTransition(false, animated: true)
        // User lifted the finger short of the threshold — UIKit reverses it.
        vc.beginAppearanceTransition(true, animated: true)
        vc.endAppearanceTransition()
    }

    private func tableRowCount(_ vc: NetworkDetailViewController) -> Int {
        vc.tableView.layoutIfNeeded()
        return vc.tableView.numberOfRows(inSection: 0)
    }

    // MARK: - The defect

    func testCancelledSwipeBackLeavesTheScreenWithItsSectionsIntact() {
        let vc = presentDetail()

        let titlesBefore = vc.detailModels.compactMap { $0.title }
        let rowsBefore = tableRowCount(vc)
        XCTAssertFalse(titlesBefore.isEmpty, "Setup failed: the detail screen built no sections.")

        beginAndCancelInteractivePop(vc)

        XCTAssertTrue(navigation.viewControllers.contains(vc),
                      "Setup failed: the cancelled pop actually popped the screen.")
        XCTAssertEqual(vc.detailModels.compactMap { $0.title }, titlesBefore,
                       "A CANCELLED swipe-back emptied the detail screen's model. The screen "
                       + "is still in front of the user with nothing in it.")
        XCTAssertEqual(tableRowCount(vc), rowsBefore,
                       "The detail table renders no rows after a cancelled swipe-back.")
    }

    func testCopyAndShareStillProduceTheFullDetailsAfterACancelledSwipeBack() {
        let vc = presentDetail()

        let bodyBefore = vc.messageBody
        XCTAssertTrue(bodyBefore.contains("RESPONSE"),
                      "Setup failed: the copied text has no RESPONSE section to lose.")

        beginAndCancelInteractivePop(vc)

        XCTAssertEqual(vc.messageBody, bodyBefore,
                       "Copy / \"Share full details (text)\" produce a header line with no "
                       + "sections after a cancelled swipe-back — the request's own data is "
                       + "silently missing from what the user pastes into a bug report.")
    }

    func testRewrittenBadgeSurvivesACancelledSwipeBack() {
        let vc = presentDetail()
        XCTAssertTrue(vc.detailModels.contains { $0.title?.contains("REWRITTEN") == true },
                      "Setup failed: the rewritten response was not badged to begin with.")

        beginAndCancelInteractivePop(vc)

        XCTAssertTrue(vc.detailModels.contains { $0.title?.contains("REWRITTEN") == true },
                      "The REWRITTEN badge is gone after a cancelled swipe-back, so a body no "
                      + "server ever sent is presented as if it were the server's.")
    }

    /// Export/Share still offers every action, and still finds a response and a
    /// request body to write out, after a cancelled swipe-back.
    func testExportSheetStillOffersEveryActionAfterACancelledSwipeBack() {
        let vc = presentDetail()
        beginAndCancelInteractivePop(vc)

        vc.exportResponseJSON(UIBarButtonItem())
        let shown = expectation(description: "export sheet presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shown.fulfill() }
        wait(for: [shown], timeout: 5)

        guard let sheet = vc.presentedViewController as? UIAlertController else {
            return XCTFail("The Export / Share sheet no longer opens.")
        }
        let titles = sheet.actions.compactMap { $0.title }
        XCTAssertTrue(titles.contains("Export Response as .json file"),
                      "Export lost the response body. Offered actions: \(titles)")
        XCTAssertTrue(titles.contains("Export Request as .json file"),
                      "Export lost the request body. Offered actions: \(titles)")
        XCTAssertTrue(titles.contains("Share full details (text)"))
        XCTAssertTrue(titles.contains("Copy cURL"))

        vc.dismiss(animated: false)
    }

    // MARK: - The release itself must be preserved

    /// A real pop still drops the big strings immediately. This is the whole
    /// point of the `viewWillDisappear` cleanup and must not be deleted.
    func testARealPopStillReleasesTheCachedContent() {
        let vc = presentDetail()
        XCTAssertFalse(vc.detailModels.isEmpty)

        navigation.popViewController(animated: false)
        window.layoutIfNeeded()

        XCTAssertFalse(navigation.viewControllers.contains(vc),
                       "Setup failed: the pop did not happen.")
        XCTAssertTrue(vc.detailModels.isEmpty,
                      "The deliberate release of the cached sections on a REAL disappearance "
                      + "was lost. The screen holds the whole response body until dealloc.")
    }

    /// Pushing a child (JSON viewer, replay editor, similar request) is not a
    /// disappearance the guard fires on, so nothing is released and nothing is
    /// rebuilt when the child is popped back off.
    func testPushingAChildScreenNeitherReleasesNorRebuilds() {
        let vc = presentDetail()
        let titlesBefore = vc.detailModels.compactMap { $0.title }

        // A push: the detail screen disappears, but is NOT moving from its parent.
        vc.beginAppearanceTransition(false, animated: true)
        vc.endAppearanceTransition()
        XCTAssertEqual(vc.detailModels.compactMap { $0.title }, titlesBefore,
                       "Pushing a child screen released the detail screen's sections.")

        vc.beginAppearanceTransition(true, animated: true)
        vc.endAppearanceTransition()
        XCTAssertEqual(vc.detailModels.compactMap { $0.title }, titlesBefore,
                       "Coming back from a child screen duplicated or dropped sections.")
    }

    /// Two cancelled gestures in a row have to leave exactly one copy of each
    /// section — a rebuild that appends instead of replacing would double the
    /// list, and `setupModels()` appends.
    func testRepeatedCancelledSwipeBacksDoNotDuplicateSections() {
        let vc = presentDetail()
        let titlesBefore = vc.detailModels.compactMap { $0.title }

        beginAndCancelInteractivePop(vc)
        beginAndCancelInteractivePop(vc)

        XCTAssertEqual(vc.detailModels.compactMap { $0.title }, titlesBefore,
                       "Cancelling the swipe-back twice changed the section list.")
    }

    /// The last section carries `isLast` (it draws the closing edge). A rebuild
    /// that skips the flag leaves the list visibly unfinished.
    func testRestoredSectionsKeepTheIsLastMarker() {
        let vc = presentDetail()
        XCTAssertEqual(vc.detailModels.last?.isLast, true,
                       "Setup failed: the last section was not marked.")

        beginAndCancelInteractivePop(vc)

        XCTAssertEqual(vc.detailModels.last?.isLast, true,
                       "The restored section list lost its `isLast` marker.")
        XCTAssertEqual(vc.detailModels.filter { $0.isLast }.count, 1,
                       "More than one section claims to be the last one.")
    }
}
