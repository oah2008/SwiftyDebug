//
//  BreakpointOverlayTouchLockTests.swift
//  SwiftyDebugTests
//
//  Tapping the paused-requests banner could soft-lock the entire host app.
//
//  `DebugWindowPresenter.displayedList` is not a display flag: it is what makes
//  the debug window claim every point on screen. `openInbox()` set it and then
//  presented onto a view controller that may have no window — a presentation
//  UIKit drops on the floor. The modal never appeared, the flag stayed true,
//  and from then on the SDK's window swallowed every touch in the host app.
//  The only thing left to tap was a 25x25 bubble.
//
//  So the rule these tests pin: the flag is never set unless a presentation is
//  genuinely under way, and it can never be left set with nothing presented.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class BreakpointOverlayTouchLockTests: XCTestCase {

    private var savedRoot: UIViewController?
    private var savedHidden = true
    private var savedFlag = false

    override func setUp() {
        super.setUp()
        let presenter = DebugWindowPresenter.shared
        savedRoot = presenter.window.rootViewController
        savedHidden = presenter.window.isHidden
        savedFlag = presenter.displayedList
    }

    override func tearDown() {
        let presenter = DebugWindowPresenter.shared
        presenter.window.rootViewController = savedRoot
        presenter.window.isHidden = savedHidden
        presenter.displayedList = savedFlag
        super.tearDown()
    }

    // MARK: - Is there anything to present onto?

    func testControllerWithNoWindowIsNotPresentable() {
        let vc = UIViewController()
        vc.loadViewIfNeeded()
        XCTAssertFalse(BreakpointOverlay.canPresentInbox(from: vc),
                       "A detached controller cannot present: UIKit logs and does nothing.")
    }

    func testControllerInAHiddenWindowIsNotPresentable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let vc = UIViewController()
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        window.isHidden = true
        XCTAssertFalse(BreakpointOverlay.canPresentInbox(from: vc))
    }

    func testControllerInAVisibleWindowIsPresentable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let vc = UIViewController()
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        XCTAssertTrue(BreakpointOverlay.canPresentInbox(from: vc))
        window.isHidden = true
    }

    func testControllerAlreadyPresentingIsNotPresentable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        // Stubbed rather than really presented: a UIWindow in a unit-test host
        // has no scene, so a real `present` never completes and the test would
        // be measuring the harness instead of the rule.
        let host = AlreadyPresentingController()
        window.rootViewController = host
        window.isHidden = false
        host.loadViewIfNeeded()

        XCTAssertNotNil(host.presentedViewController)
        XCTAssertFalse(BreakpointOverlay.canPresentInbox(from: host),
                       "Presenting on top of an existing modal is how you get two stacked debug UIs.")
        window.isHidden = true
    }

    private final class AlreadyPresentingController: UIViewController {
        private let modal = UIViewController()
        override var presentedViewController: UIViewController? { modal }
    }

    // MARK: - The flag

    /// The soft-lock itself: tap the banner while the debug window has nothing
    /// on screen. Nothing may be presented, and — critically — the window must
    /// not start claiming every touch.
    func testTappingTheBannerWithNoPresentableHostDoesNotClaimTouches() {
        let presenter = DebugWindowPresenter.shared
        presenter.window.rootViewController = nil
        presenter.window.isHidden = true
        presenter.displayedList = false

        BreakpointOverlay.shared.openInbox()

        XCTAssertNil(presenter.vc.presentedViewController,
                     "Nothing can be presented from a controller with no window.")
        XCTAssertFalse(presenter.displayedList,
                       "displayedList makes the debug window swallow every touch in the host app. "
                       + "Setting it for a presentation that never happened is the soft-lock.")
    }

    /// And it must be self-healing: a flag left set by anything else is taken
    /// back the moment we can see there is nothing presented.
    func testStuckFlagIsReleasedWhenNothingIsPresented() {
        let presenter = DebugWindowPresenter.shared
        presenter.window.rootViewController = nil
        presenter.window.isHidden = true
        presenter.displayedList = true   // stuck, e.g. by an earlier failed attempt

        BreakpointOverlay.shared.openInbox()

        XCTAssertFalse(presenter.displayedList,
                       "A stuck touch-claiming flag must be recoverable without relaunching the app.")
    }
}
