//
//  LifecycleUiAuditFixTests.swift
//  SwiftyDebugTests
//
//  The floating bubble and the windows it lives in. Every rule pinned here is
//  one where the failure takes the SDK away from the user entirely — a bubble
//  parked outside the app's window cannot be tapped, a presenter that refuses to
//  re-attach cannot be reopened, a banner that cannot revive its window leaves a
//  paused request held for ever — or destroys their data: one long press used to
//  wipe the captured log more than once, with no confirmation and no undo.
//

import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import SwiftyDebug

final class LifecycleUiAuditFixTests: XCTestCase {

    // MARK: - Rotation (a right dock must survive portrait -> landscape)

    /// The reported failure: a bubble docked on the right edge in portrait is
    /// thrown to the LEFT edge by a rotation to landscape, back on top of the
    /// content it was dragged away from.
    func testRightDockedBubbleStaysOnTheRightThroughPortraitToLandscape() {
        let portrait = CGSize(width: 393, height: 852)
        let landscape = CGSize(width: 852, height: 393)
        let (bubble, _) = makeBubble(in: portrait)
        bubble.center = CGPoint(x: portrait.width - edgeInset, y: 400)

        bubble.updateOrientation(newSize: landscape)

        XCTAssertEqual(bubble.center.x, landscape.width - edgeInset, accuracy: 0.01,
                       "A right-docked bubble jumped across the screen on rotation. The x it is "
                       + "tested against is a coordinate in the pre-rotation WIDTH; comparing it "
                       + "with half the pre-rotation HEIGHT puts every possible x on a portrait "
                       + "phone below the threshold, so the right edge can never survive.")
    }

    func testLeftDockedBubbleStaysOnTheLeftThroughPortraitToLandscape() {
        let (bubble, _) = makeBubble(in: CGSize(width: 393, height: 852))
        bubble.center = CGPoint(x: edgeInset, y: 400)

        bubble.updateOrientation(newSize: CGSize(width: 852, height: 393))

        XCTAssertEqual(bubble.center.x, edgeInset, accuracy: 0.01)
    }

    func testRotationKeepsTheBubbleAtTheSameHeightProportionally() {
        let portrait = CGSize(width: 393, height: 852)
        let (bubble, _) = makeBubble(in: portrait)
        bubble.center = CGPoint(x: edgeInset, y: portrait.height * 0.25)

        bubble.updateOrientation(newSize: CGSize(width: 852, height: 393))

        XCTAssertEqual(bubble.center.y, 393 * 0.25, accuracy: 0.01,
                       "Vertical position is kept as a fraction of the old height.")
    }

    /// With no superview there is no real pre-rotation size to read, so the
    /// plain 90-degree swap stands in — it must still dock on the same side.
    func testRotationWithoutASuperviewKeepsTheSideItWasDockedOn() {
        let bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))
        bubble.center = CGPoint(x: 393 - edgeInset, y: 400)

        bubble.updateOrientation(newSize: CGSize(width: 852, height: 393))

        XCTAssertEqual(bubble.center.x, 852 - edgeInset, accuracy: 0.01)
    }

    // MARK: - Docking (measured in the window, never the display)

    /// iPad Split View: the app owns a 507pt column of a 1024pt display. A snap
    /// target taken from the display lands ~500pt outside the window, where
    /// `SwiftyDebugViewController.shouldReceive(point:)` can never hit-test the
    /// bubble again — the debug UI is gone for the rest of the session.
    func testDockingInASplitViewColumnStaysInsideTheWindow() {
        let column = CGRect(x: 0, y: 0, width: 507, height: 1024)

        let dock = Bubble.dockTarget(
            location: CGPoint(x: 400, y: 500),
            velocity: .zero,
            containerBounds: column,
            safeArea: .zero
        )

        XCTAssertEqual(dock.center.x, column.width - edgeInset, accuracy: 0.01,
                       "The right dock is the right edge of the app's window, not of the display.")
        XCTAssertTrue(column.contains(dock.center),
                      "A bubble docked outside the SDK window is untappable for ever: hit-testing "
                      + "answers with `bubble.frame.contains(point)`, and no point the window is "
                      + "asked about can be inside a frame that sits outside it.")
    }

    func testDockingSnapsToTheNearerEdgeOfTheWindow() {
        let column = CGRect(x: 0, y: 0, width: 507, height: 1024)

        let left = Bubble.dockTarget(location: CGPoint(x: 100, y: 500), velocity: .zero,
                                     containerBounds: column, safeArea: .zero)
        let right = Bubble.dockTarget(location: CGPoint(x: 400, y: 500), velocity: .zero,
                                      containerBounds: column, safeArea: .zero)

        XCTAssertEqual(left.center.x, edgeInset, accuracy: 0.01)
        XCTAssertEqual(right.center.x, column.width - edgeInset, accuracy: 0.01)
    }

    /// Slide Over: a short window, where a display-height clamp leaves the
    /// bubble below everything the user can see.
    func testDockingClampsVerticallyToTheWindowAndItsSafeArea() {
        let slideOver = CGRect(x: 0, y: 0, width: 320, height: 600)
        let safeArea = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)

        let low = Bubble.dockTarget(location: CGPoint(x: 300, y: 5_000), velocity: .zero,
                                    containerBounds: slideOver, safeArea: safeArea)
        let high = Bubble.dockTarget(location: CGPoint(x: 10, y: -200), velocity: .zero,
                                     containerBounds: slideOver, safeArea: safeArea)

        XCTAssertEqual(low.center.y, slideOver.height - safeArea.bottom - edgeInset, accuracy: 0.01)
        XCTAssertEqual(high.center.y, safeArea.top + edgeInset, accuracy: 0.01)
        XCTAssertTrue(slideOver.contains(low.center) && slideOver.contains(high.center))
    }

    func testADragWithoutAFlingUsesTheStandardDuration() {
        let dock = Bubble.dockTarget(location: CGPoint(x: 100, y: 300), velocity: .zero,
                                     containerBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
                                     safeArea: .zero)

        XCTAssertEqual(dock.duration, 0.3, accuracy: 0.0001)
    }

    // MARK: - Long press clears the log exactly once

    /// A long press sends its action on `.began`, on every `.changed` and again
    /// on `.ended`. Every one of those used to run `reset()`, which drops every
    /// non-pinned transaction and takes its two body files off disk with it.
    func testLongPressClearsTheLogOnceAndOnlyOnBegan() throws {
        let bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))
        let selector = Selector(("handleLongPress:"))
        XCTAssertTrue(bubble.responds(to: selector),
                      "The long-press action must stay `handleLongPress(_:)`: taking the "
                      + "recogniser is the only way to know which state it is in.")

        var clears = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .allLogsCleared, object: nil, queue: nil
        ) { _ in clears += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = bubble.perform(selector, with: StubLongPress(stubbedState: .began))
        XCTAssertEqual(clears, 1, "The press has to clear the log — that is the feature.")

        _ = bubble.perform(selector, with: StubLongPress(stubbedState: .changed))
        _ = bubble.perform(selector, with: StubLongPress(stubbedState: .ended))
        XCTAssertEqual(clears, 1,
                       "One press wiped the captured log two or three times. There is no "
                       + "confirmation and no undo, so it may happen once per press at most.")
    }

    /// The press and the drag share one 25x25 view. Without a policy UIKit
    /// cancels the pan as soon as the press recognises, so pressing the bubble,
    /// aiming for half a second and then dragging moved nothing at all — and
    /// cleared the log instead.
    func testTheLongPressDoesNotCancelTheDrag() throws {
        let bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))
        let recognizers = try XCTUnwrap(bubble.gestureRecognizers)
        let longPress = try XCTUnwrap(recognizers.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        let pan = try XCTUnwrap(recognizers.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let tap = try XCTUnwrap(recognizers.compactMap { $0 as? UITapGestureRecognizer }.first)

        XCTAssertTrue(longPress.delegate === bubble,
                      "Without a delegate there is no way to allow simultaneous recognition.")
        XCTAssertTrue(bubble.gestureRecognizer(longPress, shouldRecognizeSimultaneouslyWith: pan),
                      "The drag has to keep running after the press has recognised.")
        XCTAssertFalse(bubble.gestureRecognizer(longPress, shouldRecognizeSimultaneouslyWith: tap),
                       "Only the drag is exempt; nothing else should recognise alongside.")
    }

    // MARK: - The presenter re-attaches instead of no-opping

    /// When the scene the overlay window was attached to disconnects, UIKit nils
    /// `windowScene` but leaves `vc` as the root. `enable()` returned on the root
    /// alone, so `SwiftyDebug.enable()` and every `bubbleVisible = true` became a
    /// silent no-op and the debug UI was unreachable until relaunch.
    func testEnableReAttachesAWindowThatLostItsScene() {
        let presenter = DebugWindowPresenter.shared
        let savedRoot = presenter.window.rootViewController
        let savedHidden = presenter.window.isHidden
        let savedScene = presenter.window.windowScene
        defer {
            presenter.window.windowScene = savedScene
            presenter.window.rootViewController = savedRoot
            presenter.window.isHidden = savedHidden
        }

        presenter.window.rootViewController = presenter.vc
        presenter.window.isHidden = true
        // The presenter is a process-wide singleton, so whether it currently has
        // a scene depends on what ran before this test. Detach it explicitly —
        // that IS the state being reproduced (the scene disconnected), not an
        // assumption about it.
        presenter.window.windowScene = nil
        XCTAssertNil(presenter.window.windowScene, "Precondition: the window has no scene.")

        presenter.enable()

        XCTAssertFalse(presenter.window.isHidden,
                       "A detached window must be able to re-enter `enable()`: it is the whole "
                       + "recovery path after the scene it was attached to went away.")
    }

    // MARK: - The banner revives the window it needs to present on

    /// Shake-to-hide tears the presenter's window down, but the banner stays up
    /// for a request that is holding the host app hostage — and tapping it is
    /// the only offered way to release that request. With nothing to present
    /// onto, the tap did nothing at all: no UI, no release, the app hung until
    /// its own timeout.
    func testTappingTheBannerWithNoWindowRevivesThePresenterAndRetriesOnce() {
        let presenter = DebugWindowPresenter.shared
        let savedRoot = presenter.window.rootViewController
        let savedHidden = presenter.window.isHidden
        let savedFlag = presenter.displayedList
        let savedBubbleVisible = Settings.shared.bubbleVisible
        let savedDebugUIVisible = Settings.shared.debugUIVisible
        defer {
            presenter.window.rootViewController = savedRoot
            presenter.window.isHidden = savedHidden
            presenter.displayedList = savedFlag
            Settings.shared.bubbleVisible = savedBubbleVisible
            Settings.shared.debugUIVisible = savedDebugUIVisible
        }

        // The debug UI is presented on a process-wide singleton and a modal in a
        // scene-less test window never finishes its transition, so a stuck one
        // left by an earlier test would send `openInbox()` down its
        // already-open branch instead of the branch under test.
        clearAnyPresentedDebugUI()

        // Exactly the shake-to-hide state: the bubble is off, so `disable()` has
        // cleared the root and hidden the window.
        Settings.shared.bubbleVisible = false
        presenter.displayedList = false
        XCTAssertNil(presenter.window.rootViewController, "Precondition: nothing to present onto.")

        BreakpointOverlay.shared.openInbox()

        XCTAssertTrue(Settings.shared.bubbleVisible,
                      "The tap must bring the overlay window back — it is the only affordance "
                      + "offered for releasing a paused request.")
        XCTAssertTrue(presenter.window.rootViewController === presenter.vc)
        XCTAssertFalse(presenter.window.isHidden)
        XCTAssertFalse(presenter.displayedList,
                       "Nothing is presented yet, so the window may not claim every touch.")

        // Take the window away again before the retry lands: the retry has to
        // give up rather than revive a second time, or a tap with a window that
        // can never present would flip the bubble back on for ever.
        Settings.shared.bubbleVisible = false
        spinRunLoop(0.6)

        XCTAssertFalse(Settings.shared.bubbleVisible,
                       "One revive per tap: the retry must not start another.")
        XCTAssertNil(presenter.vc.presentedViewController,
                     "Nothing may be presented onto a window that is not on screen.")
        XCTAssertFalse(presenter.displayedList)
    }

    // MARK: - Harness

    /// The dock inset, read off the behaviour itself rather than hard-coded, so
    /// these tests pin which EDGE the bubble lands on and not a constant.
    private lazy var edgeInset: CGFloat = {
        let (bubble, _) = makeBubble(in: CGSize(width: 393, height: 852))
        bubble.center = CGPoint(x: 10, y: 400)
        bubble.updateOrientation(newSize: CGSize(width: 852, height: 393))
        return bubble.center.x
    }()

    /// Returns the container too: it owns the bubble, and `updateOrientation`
    /// reads the pre-rotation size from it.
    private func makeBubble(in size: CGSize) -> (Bubble, UIView) {
        let container = UIView(frame: CGRect(origin: .zero, size: size))
        let bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))
        container.addSubview(bubble)
        return (bubble, container)
    }

    private func clearAnyPresentedDebugUI() {
        let presenter = DebugWindowPresenter.shared
        guard presenter.vc.presentedViewController != nil else { return }
        presenter.vc.dismiss(animated: false)
        spinRunLoop(0.2)
        if presenter.vc.presentedViewController != nil {
            if presenter.window.rootViewController === presenter.vc {
                presenter.window.rootViewController = nil
            }
            presenter.vc = SwiftyDebugViewController()
        }
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `state` is read-only on a recogniser nobody is touching, and driving a
    /// real press needs a live window. Overriding it is the only way to ask the
    /// handler what it does in each of the three states one press reports.
    private final class StubLongPress: UILongPressGestureRecognizer {
        private var stubbed: UIGestureRecognizer.State

        override var state: UIGestureRecognizer.State {
            get { stubbed }
            set { stubbed = newValue }
        }

        init(stubbedState: UIGestureRecognizer.State) {
            stubbed = stubbedState
            super.init(target: nil, action: nil)
        }
    }
}
