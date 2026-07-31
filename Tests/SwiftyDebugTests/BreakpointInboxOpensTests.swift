//
//  BreakpointInboxOpensTests.swift
//  SwiftyDebugTests
//
//  `BreakpointOverlay.openInbox()` is the banner's one job: a request is paused,
//  the host app looks hung, and one tap has to land on the editor that releases
//  it.
//
//  Only its *refusal* branches were pinned (`BreakpointOverlayTouchLockTests`
//  covers "cannot present" and "release the stuck flag"). Its happy path was
//  not: the body could be reduced to `return` and the suite stayed green while
//  the banner became a dead pixel — tap it, nothing happens, the request stays
//  held and the app stays hung.
//
//  These drive the real singleton with the debug window genuinely on screen.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class BreakpointInboxOpensTests: XCTestCase {

    private var savedRoot: UIViewController?
    private var savedHidden = true
    private var savedFlag = false
    private var savedDebugUIVisible = false

    override func setUp() {
        super.setUp()
        let presenter = DebugWindowPresenter.shared
        savedRoot = presenter.window.rootViewController
        savedHidden = presenter.window.isHidden
        savedFlag = presenter.displayedList
        savedDebugUIVisible = Settings.shared.debugUIVisible
        clearAnyPresentedDebugUI()
    }

    override func tearDown() {
        let presenter = DebugWindowPresenter.shared
        clearAnyPresentedDebugUI()
        presenter.window.rootViewController = savedRoot
        presenter.window.isHidden = savedHidden
        presenter.displayedList = savedFlag
        Settings.shared.debugUIVisible = savedDebugUIVisible
        BreakpointOverlay.shared.stop()
        super.tearDown()
    }

    /// The debug UI is presented on a process-wide singleton, and a modal
    /// presented into a scene-less test window never finishes its transition —
    /// so `dismiss` cannot finish either. Drop the whole host controller in that
    /// case: nothing outside this suite keeps a reference to it, and leaving a
    /// stuck modal on the singleton would break every later test that asks it to
    /// present.
    private func clearAnyPresentedDebugUI() {
        let presenter = DebugWindowPresenter.shared
        guard presenter.vc.presentedViewController != nil else { return }
        presenter.vc.dismiss(animated: false)
        spinRunLoop(timeout: 0.2) { presenter.vc.presentedViewController == nil }
        if presenter.vc.presentedViewController != nil {
            if presenter.window.rootViewController === presenter.vc {
                presenter.window.rootViewController = nil
            }
            presenter.vc = SwiftyDebugViewController()
        }
    }

    /// Tap the banner with the SDK's window genuinely on screen: the debug UI
    /// has to come up, and it has to come up aimed at the paused-requests inbox.
    func testTappingTheBannerOpensTheDebugUIOnTheInbox() {
        let presenter = makePresentableDebugWindow()
        presenter.displayedList = false

        BreakpointOverlay.shared.openInbox()

        let tabs = presenter.vc.presentedViewController as? SwiftyDebugTabBarController
        XCTAssertNotNil(tabs,
                        "The banner's only job is to open the editor for a request that is "
                        + "holding the host app hostage. Presenting nothing makes the banner a "
                        + "dead pixel: the app stays hung and there is no way to release it.")

        let landedOnTheInbox = tabs?.pendingInitialScreen == .breakpointInbox
            || (tabs?.viewControllers?.first as? UINavigationController)?
                .viewControllers.contains(where: { $0 is BreakpointInboxViewController }) == true
        XCTAssertTrue(landedOnTheInbox,
                      "One tap has to land ON the inbox — opening the debug UI on whatever tab "
                      + "was last used leaves the user hunting for the held request.")
    }

    /// The flag that opens the window to every touch is set here — legitimately,
    /// because a presentation really is under way. (Its mirror image, refusing
    /// to set it when nothing can be presented, is in
    /// `BreakpointOverlayTouchLockTests`.)
    func testOpeningTheInboxClaimsTouchesOnlyBecauseSomethingIsPresented() {
        let presenter = makePresentableDebugWindow()
        presenter.displayedList = false

        BreakpointOverlay.shared.openInbox()

        XCTAssertNotNil(presenter.vc.presentedViewController)
        XCTAssertTrue(presenter.displayedList,
                      "With the debug UI genuinely up, the window must claim touches — "
                      + "otherwise the UI it just opened cannot be tapped.")
    }

    /// Tapping the banner while the debug UI is already open must switch to the
    /// inbox instead of trying to present a second copy on top of the first.
    func testTappingTheBannerWhileTheDebugUIIsOpenSwitchesToTheInbox() throws {
        let presenter = makePresentableDebugWindow()

        BreakpointOverlay.shared.openInbox()
        let tabs = try XCTUnwrap(presenter.vc.presentedViewController as? SwiftyDebugTabBarController,
                                 "Precondition: the first tap opened the debug UI.")

        BreakpointOverlay.shared.openInbox()

        XCTAssertTrue(presenter.vc.presentedViewController === tabs,
                      "A second tap must not stack a second debug UI.")
        let nav = tabs.viewControllers?.first as? UINavigationController
        XCTAssertTrue(nav?.viewControllers.contains(where: { $0 is BreakpointInboxViewController }) == true,
                      "Tapping the banner with the tool already open has to take you to the "
                      + "held request, not leave you on whatever tab you were reading.")
    }

    // MARK: - Harness

    /// Puts the SDK's own window on screen, which is what `openInbox()` needs to
    /// find: `DebugWindowPresenter.vc` in a loaded, visible window.
    private func makePresentableDebugWindow() -> DebugWindowPresenter {
        let presenter = DebugWindowPresenter.shared
        presenter.window.rootViewController = presenter.vc
        presenter.window.isHidden = false
        presenter.vc.loadViewIfNeeded()
        presenter.window.layoutIfNeeded()
        XCTAssertTrue(BreakpointOverlay.canPresentInbox(from: presenter.vc),
                      "Precondition: the debug window is on screen and free to present.")
        return presenter
    }

    private func spinRunLoop(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
