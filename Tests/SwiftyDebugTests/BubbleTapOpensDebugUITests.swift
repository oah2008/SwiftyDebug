//
//  BubbleTapOpensDebugUITests.swift
//  SwiftyDebugTests
//
//  Tapping the floating bubble is the ONLY way into the debug UI, and nothing
//  tested it: `didTapBubble()` could be replaced with `return` and the whole
//  suite stayed green while the SDK became unopenable.
//
//  It also has to open it *safely*. `DebugWindowPresenter.displayedList` is not
//  a display flag — it is what makes the SDK's window claim every point on
//  screen (`SwiftyDebugViewController.shouldReceive(point:)`). It used to be set
//  before `present`, so a tap that arrived before the SDK's window was live set
//  the flag, presented into nothing, and left the host app with every touch
//  swallowed and only a 25x25 bubble to aim at. Relaunching was the only way out.
//
//  So: one tap opens exactly one debug UI, a second tap cannot stack another,
//  and a tap that cannot present must change nothing at all.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class BubbleTapOpensDebugUITests: XCTestCase {

    private var savedFlag = false
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        savedFlag = DebugWindowPresenter.shared.displayedList
    }

    override func tearDown() {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        window = nil
        DebugWindowPresenter.shared.displayedList = savedFlag
        super.tearDown()
    }

    // MARK: - The tap opens the UI

    /// The whole feature: tap the bubble, get the debug UI. Driven through the
    /// bubble's own delegate hook, so the wiring done in `viewDidLoad`
    /// (`bubble.delegate = self`) is pinned too.
    func testTappingTheBubblePresentsTheDebugUI() {
        let host = makeHostInVisibleWindow()

        host.bubble.delegate?.didTapBubble()

        XCTAssertTrue(host.presentedViewController is SwiftyDebugTabBarController,
                      "Tapping the bubble is the only way into the debug UI. Presenting nothing "
                      + "here means the SDK cannot be opened at all.")
    }

    /// A second tap while the UI is already up must not stack a second copy —
    /// two debug UIs on top of each other, the lower one unreachable.
    func testASecondTapCannotStackASecondDebugUI() {
        let host = makeHostInVisibleWindow()

        host.bubble.delegate?.didTapBubble()
        let first = host.presentedViewController
        XCTAssertTrue(first is SwiftyDebugTabBarController, "Precondition: the first tap opened it.")

        host.bubble.delegate?.didTapBubble()

        XCTAssertTrue(host.presentedViewController === first,
                      "The second tap replaced or stacked a second tab bar controller.")
    }

    // MARK: - A tap that cannot present must change nothing

    /// The soft-lock. The bubble's controller has no window yet (the SDK's
    /// window has not been attached to a scene, which is exactly the state
    /// during app launch): `present` is dropped on the floor by UIKit, so the
    /// flag must not be set — it would leave the host app unusable.
    func testTappingWithNoWindowNeitherPresentsNorClaimsTouches() {
        let host = SwiftyDebugViewController()
        host.loadViewIfNeeded()
        XCTAssertNil(host.view.window, "Precondition: nothing to present onto.")
        DebugWindowPresenter.shared.displayedList = false

        host.bubble.delegate?.didTapBubble()

        XCTAssertNil(host.presentedViewController,
                     "UIKit drops a presentation from a controller with no window.")
        XCTAssertFalse(DebugWindowPresenter.shared.displayedList,
                       "This flag makes the SDK's window swallow every touch in the host app. "
                       + "Setting it for a presentation that never happened is the soft-lock: "
                       + "the host app is dead except for a 25x25 bubble until it is relaunched.")
    }

    // MARK: - Harness

    private func makeHostInVisibleWindow() -> SwiftyDebugViewController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let host = SwiftyDebugViewController()
        window.rootViewController = host
        window.isHidden = false
        host.loadViewIfNeeded()
        window.layoutIfNeeded()
        self.window = window
        XCTAssertNotNil(host.view.window, "Precondition: the host controller is in a live window.")
        return host
    }
}
