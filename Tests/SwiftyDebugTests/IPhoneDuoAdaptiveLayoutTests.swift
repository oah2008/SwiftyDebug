//
//  IPhoneDuoAdaptiveLayoutTests.swift
//  SwiftyDebugTests
//
//  iPhone Duo: the overlay window, the floating bubble, and the vertical bar.
//
//  The reported failures, all on iPhone Duo:
//   1. The debug UI opened at the OUTER display's size on the inner display and
//      never adapted — the overlay window was sized from `UIScreen.main`, which
//      on iPhone Duo is always the outer panel, and was never resized.
//   2. The SDK did not respect the vertical status bar — on iPhone Duo the status
//      bar, Dynamic Island and navigation controls run down one side of the
//      screen as an 84 pt bar, reported as a left OR right safe-area inset.
//   3. The bubble sat in the middle of the unfolded screen — it kept the x it had
//      on the 466 pt outer display, which is mid-screen on the 951 pt inner one.
//
//  Geometry below was measured on the iPhone Duo simulator (iOS 27.1).
//

import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import SwiftyDebug

final class IPhoneDuoAdaptiveLayoutTests: XCTestCase {

    private enum Duo {
        static let outerPortrait = CGRect(x: 0, y: 0, width: 466, height: 678)
        static let outerPortraitSafe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)

        /// Rotated to landscapeRight the vertical bar moves to the LEFT.
        static let outerLandscape = CGRect(x: 0, y: 0, width: 678, height: 466)
        static let outerLandscapeSafe = UIEdgeInsets(top: 0, left: 84, bottom: 34, right: 0)

        static let innerLandscape = CGRect(x: 0, y: 0, width: 951, height: 669)
        static let innerLandscapeSafe = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)

        /// Inner display in portrait: the bars go back to the top and bottom.
        static let innerPortrait = CGRect(x: 0, y: 0, width: 669, height: 951)
        static let innerPortraitSafe = UIEdgeInsets(top: 84, left: 0, bottom: 95, right: 0)
    }

    private var window: UIWindow?
    private let inset = Bubble.dockInset

    override func tearDown() {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        window = nil
        super.tearDown()
    }

    // MARK: - 1. The overlay window is the scene's size, not the outer panel's

    func testTheOverlayFrameCoversEveryDuoSceneButIsNeverExactlyFullScreen() {
        for scene in [Duo.outerPortrait, Duo.outerLandscape, Duo.innerLandscape, Duo.innerPortrait] {
            let frame = SwiftyDebugWindow.overlayFrame(forSceneBounds: scene)

            XCTAssertEqual(frame.origin, scene.origin)
            XCTAssertEqual(frame.width, scene.width,
                           "The overlay must span the scene it is in — on the inner display that "
                           + "is 951 pt, not the outer panel's 466 pt.")
            XCTAssertEqual(frame.height, scene.height, accuracy: 0.001)
            XCTAssertLessThan(frame.height, scene.height,
                              "A window that exactly covers its scene is full-screen to UIKit, and the "
                              + "topmost full-screen window takes the status bar, the supported "
                              + "orientations and the vertical bar away from the host app.")
        }
    }

    func testFitToSceneLeavesAWindowWithNoSceneAlone() {
        let window = SwiftyDebugWindow(frame: .zero)
        // Detach explicitly: in a host without a scene manifest UIKit attaches a
        // new window to the app's scene on its own (see the next test).
        window.windowScene = nil
        window.frame = .zero

        window.fitToScene()

        XCTAssertEqual(window.frame, .zero,
                       "With no scene there is no size to take — and no UIScreen.main fallback, "
                       + "which on iPhone Duo is always the wrong display.")
    }

    /// Measured in this test host: UIKit attaches a window to the app's scene
    /// inside `init(frame:)`, without the `windowScene` setter ever running. A
    /// window that only re-fits from the setter kept its zero size there.
    func testAWindowUIKitAttachesOnItsOwnStillTakesItsScenesSize() throws {
        let window = SwiftyDebugWindow(frame: .zero)
        defer { window.windowScene = nil }
        guard let scene = window.windowScene else {
            throw XCTSkip("UIKit did not attach this window to a scene in this host.")
        }

        let expected = SwiftyDebugWindow.overlayFrame(forSceneBounds: SceneGeometry.bounds(of: scene))
        XCTAssertTrue(SwiftyDebugWindow.isApproximatelyEqual(window.frame, expected),
                      "Implicitly attached window is \(window.frame), its scene needs \(expected).")
    }

    func testAttachingToASceneSizesTheWindowToThatScene() throws {
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            ?? UIWindow(frame: .zero).windowScene
        guard let scene else {
            throw XCTSkip("This test host has no window scene to attach to.")
        }
        let window = SwiftyDebugWindow(frame: .zero)
        window.windowScene = nil
        window.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        defer { window.windowScene = nil }

        window.windowScene = scene

        let expected = SwiftyDebugWindow.overlayFrame(forSceneBounds: SceneGeometry.bounds(of: scene))
        XCTAssertTrue(SwiftyDebugWindow.isApproximatelyEqual(window.frame, expected),
                      "Attached window is \(window.frame), its scene needs \(expected).")
    }

    func testFramesWithinHalfAPointAreTheSameFrame() {
        let a = CGRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertTrue(SwiftyDebugWindow.isApproximatelyEqual(a, SwiftyDebugWindow.overlayFrame(forSceneBounds: a)),
                      "The one-ulp height must not count as a different size, or the window "
                      + "would re-fit itself on every geometry callback.")
        XCTAssertFalse(SwiftyDebugWindow.isApproximatelyEqual(a, CGRect(x: 0, y: 0, width: 466, height: 678)))
    }

    // MARK: - 2. The vertical bar

    func testARightDockOnTheOuterDisplayStopsAtTheVerticalBar() {
        let center = Bubble.dockedCenter(side: .right, fraction: 0.5,
                                         containerBounds: Duo.outerPortrait,
                                         safeArea: Duo.outerPortraitSafe)

        XCTAssertEqual(center.x, 466 - 84 - inset, accuracy: 0.01)
        XCTAssertLessThanOrEqual(center.x + Bubble.size.width / 2, 466 - 84,
                                 "Docked to the raw right edge, the bubble sat underneath the "
                                 + "status bar and Dynamic Island.")
    }

    func testALeftDockInLandscapeStopsAtTheVerticalBarOnTheLeft() {
        let center = Bubble.dockedCenter(side: .left, fraction: 0.5,
                                         containerBounds: Duo.outerLandscape,
                                         safeArea: Duo.outerLandscapeSafe)

        XCTAssertEqual(center.x, 84 + inset, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(center.x - Bubble.size.width / 2, 84,
                                    "Rotating moves the vertical bar to the left edge; a left dock "
                                    + "has to move out from under it.")
    }

    func testTheDockStaysInsideTheTopAndBottomBarsOfTheInnerDisplayInPortrait() {
        let top = Bubble.dockedCenter(side: .left, fraction: 0, containerBounds: Duo.innerPortrait,
                                      safeArea: Duo.innerPortraitSafe)
        let bottom = Bubble.dockedCenter(side: .left, fraction: 1, containerBounds: Duo.innerPortrait,
                                         safeArea: Duo.innerPortraitSafe)

        XCTAssertEqual(top.y, 84 + inset, accuracy: 0.01)
        XCTAssertEqual(bottom.y, 951 - 95 - inset, accuracy: 0.01)
    }

    func testADragPicksItsSideByTheMiddleOfTheSafeArea() {
        // The usable width on the outer display is 0...382; its middle is ~191.
        // A release at x = 200 is right of it, though left of the raw middle (233).
        let dock = Bubble.dockTarget(location: CGPoint(x: 200, y: 300), velocity: .zero,
                                     containerBounds: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)

        XCTAssertEqual(dock.center.x, 466 - 84 - inset, accuracy: 0.01)
    }

    func testADragNeverDocksUnderTheVerticalBarOnEitherSide() {
        let right = Bubble.dockTarget(location: CGPoint(x: 460, y: 300), velocity: .zero,
                                      containerBounds: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        let left = Bubble.dockTarget(location: CGPoint(x: 5, y: 300), velocity: .zero,
                                     containerBounds: Duo.outerLandscape, safeArea: Duo.outerLandscapeSafe)

        XCTAssertEqual(right.center.x, 466 - 84 - inset, accuracy: 0.01)
        XCTAssertEqual(left.center.x, 84 + inset, accuracy: 0.01)
    }

    // MARK: - 3. Unfolding keeps the bubble on its edge

    /// The reported failure, end to end: dock the bubble on the right of the
    /// outer display by dragging it there, unfold, and it must be on the right
    /// edge of the inner display — not left at x = 369, which is the middle.
    func testUnfoldingKeepsARightDockedBubbleOnTheRightEdgeOfTheInnerDisplay() throws {
        let (window, host) = try makeOverlay(in: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        drag(host.bubble, releasingAt: CGPoint(x: 400, y: 300))
        XCTAssertEqual(host.bubble.center.x, 466 - 84 - inset, accuracy: 0.01, "Precondition: docked right.")

        try unfold(window, host, to: Duo.innerLandscape, safeArea: Duo.innerLandscapeSafe)

        XCTAssertEqual(host.bubble.center.x, 951 - 84 - inset, accuracy: 0.01,
                       "After unfolding the bubble must be on the inner display's right edge, beside "
                       + "the vertical bar. It used to keep the outer display's x, which is the middle "
                       + "of the unfolded screen.")
        XCTAssertEqual(host.bubble.center.y, 669 * (300.0 / 678.0), accuracy: 0.5,
                       "It keeps its height as a fraction of the screen.")
    }

    func testFoldingBackPutsTheBubbleBackOnTheOuterDisplaysEdge() throws {
        let (window, host) = try makeOverlay(in: Duo.innerLandscape, safeArea: Duo.innerLandscapeSafe)
        drag(host.bubble, releasingAt: CGPoint(x: 900, y: 500))

        try unfold(window, host, to: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)

        XCTAssertEqual(host.bubble.center.x, 466 - 84 - inset, accuracy: 0.01)
        XCTAssertTrue(Duo.outerPortrait.contains(host.bubble.frame),
                      "A bubble left outside the window can never be tapped again.")
    }

    func testALeftDockMovesOutFromUnderTheBarWhenItSwitchesToTheLeft() throws {
        let (window, host) = try makeOverlay(in: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        drag(host.bubble, releasingAt: CGPoint(x: 20, y: 300))
        XCTAssertEqual(host.bubble.center.x, inset, accuracy: 0.01, "Precondition: docked left.")

        // Rotating to landscapeRight moves the vertical bar to the left edge.
        try unfold(window, host, to: Duo.outerLandscape, safeArea: Duo.outerLandscapeSafe)

        XCTAssertEqual(host.bubble.center.x, 84 + inset, accuracy: 0.01)
    }

    func testTheFirstLayoutDocksTheBubbleOnTheLeftEdge() throws {
        let (_, host) = try makeOverlay(in: Duo.innerLandscape, safeArea: Duo.innerLandscapeSafe)

        XCTAssertEqual(host.bubble.center.x, inset, accuracy: 0.01)
        XCTAssertEqual(host.bubble.center.y, 669 * Bubble.initialDockFraction, accuracy: 0.5)
    }

    /// Before its first layout the bubble is parked off-screen. A rotation in
    /// that window must not read the parking spot as "docked top-left".
    func testARotationBeforeTheFirstLayoutKeepsTheInitialDock() {
        let container = UIView(frame: Duo.outerPortrait)
        let bubble = Bubble(frame: CGRect(origin: CGPoint(x: -50, y: -50), size: Bubble.size))
        container.addSubview(bubble)

        bubble.updateOrientation(newSize: Duo.outerLandscape.size)

        XCTAssertEqual(bubble.dockSide, .left)
        XCTAssertEqual(bubble.dockFraction, Bubble.initialDockFraction, accuracy: 0.0001)
        XCTAssertEqual(bubble.center.y, 466 * Bubble.initialDockFraction, accuracy: 0.5)
    }

    /// A dock near the top is clamped to the safe area, so the bubble's center
    /// is not `fraction * height`. Re-reading the dock from that clamped center
    /// on every rotation made it creep down a little each time.
    func testRotatingBackAndForthDoesNotDriftTheDock() throws {
        let (window, host) = try makeOverlay(in: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        drag(host.bubble, releasingAt: CGPoint(x: 400, y: 1))
        let fraction = host.bubble.dockFraction

        for _ in 0..<4 {
            host.bubble.updateOrientation(newSize: Duo.outerLandscape.size)
            try unfold(window, host, to: Duo.outerLandscape, safeArea: Duo.outerLandscapeSafe)
            host.bubble.updateOrientation(newSize: Duo.outerPortrait.size)
            try unfold(window, host, to: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        }

        XCTAssertEqual(host.bubble.dockSide, .right)
        XCTAssertEqual(host.bubble.dockFraction, fraction, accuracy: 0.0001)
    }

    /// A full-screen debug UI takes the overlay's root view out of the window,
    /// where its safe area reads zero, but UIKit still forwards rotations to it.
    /// A dock clamped by the safe area (here the inner display's 84 pt top bar
    /// in portrait) must not be re-read from those inputs: it used to be, and
    /// the bubble came back from the debug UI tens of points from where it was.
    func testARotationWithTheDebugUIOpenDoesNotRewriteTheDock() throws {
        let (window, host) = try makeOverlay(in: Duo.innerLandscape, safeArea: Duo.innerLandscapeSafe)
        drag(host.bubble, releasingAt: CGPoint(x: 900, y: 1))
        try unfold(window, host, to: Duo.innerPortrait, safeArea: Duo.innerPortraitSafe)
        let fraction = host.bubble.dockFraction
        XCTAssertNotEqual(host.bubble.center.y, 951 * fraction, accuracy: 1,
                          "Precondition: the top bar clamps the dock, so center and fraction disagree.")

        // What a full-screen presentation does to the root view.
        host.view.removeFromSuperview()
        host.additionalSafeAreaInsets = .zero
        XCTAssertEqual(host.view.safeAreaInsets, .zero, "Precondition: out of the window, no safe area.")

        host.bubble.updateOrientation(newSize: Duo.innerLandscape.size)

        XCTAssertEqual(host.bubble.dockSide, .right)
        XCTAssertEqual(host.bubble.dockFraction, fraction, accuracy: 0.0001,
                       "The dock is the bubble's position; a rotation seen from outside the window "
                       + "must not rewrite it.")
    }

    func testALayoutPassCannotMoveTheBubbleFromUnderTheFinger() throws {
        let (_, host) = try makeOverlay(in: Duo.outerPortrait, safeArea: Duo.outerPortraitSafe)
        let pan = StubPan()
        pan.stubbedState = .began
        _ = host.bubble.perform(Selector(("handlePan:")), with: pan)
        XCTAssertTrue(host.bubble.isBeingDragged)
        host.bubble.center = CGPoint(x: 200, y: 200)

        host.bubble.redock(in: Duo.innerLandscape, safeArea: Duo.innerLandscapeSafe)

        XCTAssertEqual(host.bubble.center, CGPoint(x: 200, y: 200),
                       "Mid-drag the finger owns the bubble.")

        pan.stubbedState = .ended
        pan.stubbedLocation = CGPoint(x: 200, y: 200)
        _ = host.bubble.perform(Selector(("handlePan:")), with: pan)
        XCTAssertFalse(host.bubble.isBeingDragged)
    }

    // MARK: - The fold

    func testTheBubbleMovesOffAHorizontalFold() {
        let usable = Bubble.safeRect(in: Duo.innerPortrait, safeArea: Duo.innerPortraitSafe)
        let fold = CGRect(x: 0, y: 460, width: 669, height: 30)

        let moved = Bubble.avoid([fold], from: CGPoint(x: inset, y: 470), within: usable)

        let bubbleRect = CGRect(x: moved.x - 12.5, y: moved.y - 12.5, width: 25, height: 25)
        XCTAssertFalse(bubbleRect.intersects(fold), "Nothing tappable may sit on the fold.")
        XCTAssertEqual(moved.x, inset, accuracy: 0.01, "It stays on its edge.")
        XCTAssertLessThan(moved.y, fold.minY, "It takes the nearer side of the fold.")
        XCTAssertTrue(usable.insetBy(dx: -0.5, dy: -0.5).contains(moved))
    }

    func testABubbleClearOfEveryReservedRegionDoesNotMove() {
        let usable = Bubble.safeRect(in: Duo.innerPortrait, safeArea: Duo.innerPortraitSafe)
        let point = CGPoint(x: inset, y: 200)

        XCTAssertEqual(Bubble.avoid([CGRect(x: 0, y: 460, width: 669, height: 30)], from: point, within: usable), point)
        XCTAssertEqual(Bubble.avoid([], from: point, within: usable), point)
    }

    func testTheRootViewTakesPartInConstraintUpdatesSoFoldChangesReachIt() {
        XCTAssertTrue(BubbleContainerView.requiresConstraintBasedLayout,
                      "UIKit re-calls updateConstraints() when the reserved regions read there "
                      + "change; a view that never gets updateConstraints() never hears the fold.")
    }

    func testTheSafeRectCollapsesRatherThanInvertsInATinyContainer() {
        let rect = Bubble.safeRect(in: CGRect(x: 0, y: 0, width: 20, height: 20),
                                   safeArea: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))

        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 0)
        XCTAssertEqual(rect.origin, CGPoint(x: 10, y: 10))
    }

    // MARK: - SceneGeometry

    func testAViewOutsideAnyWindowGetsTheCurrentScenesBounds() {
        XCTAssertEqual(SceneGeometry.bounds(for: UIView()), SceneGeometry.currentBounds)
        XCTAssertEqual(SceneGeometry.bounds(for: nil), SceneGeometry.currentBounds)
        XCTAssertGreaterThan(SceneGeometry.scale(), 0)
    }

    // MARK: - Harness

    /// The overlay's root controller in a visible window of `bounds`, with the
    /// safe area a real iPhone Duo window would report.
    ///
    /// The vertical bar is simulated with `additionalSafeAreaInsets`, which UIKit
    /// ADDS to the window's own insets — so this needs a test window with no
    /// side insets of its own. That holds on an ordinary simulator in portrait;
    /// on the iPhone Duo simulator a window covering the outer screen picks up
    /// the real 84 pt bar, which would count twice. Those runs skip here; the
    /// docking maths is pinned with explicit insets by the tests above.
    private func makeOverlay(in bounds: CGRect, safeArea: UIEdgeInsets) throws -> (UIWindow, SwiftyDebugViewController) {
        let window = UIWindow(frame: bounds)
        let host = SwiftyDebugViewController()
        host.additionalSafeAreaInsets = safeArea
        window.rootViewController = host
        window.isHidden = false
        host.loadViewIfNeeded()
        window.layoutIfNeeded()
        self.window = window
        try requireNoSideInsetsOfItsOwn(window)
        XCTAssertNotNil(host.view.window, "Precondition: the overlay is in a live window.")
        // Left/right only: a scene-less test window can carry top/bottom insets
        // of its own from the simulator's screen; the vertical bar is the sides.
        XCTAssertEqual(host.view.safeAreaInsets.left, safeArea.left, "Precondition: the simulated vertical bar applies.")
        XCTAssertEqual(host.view.safeAreaInsets.right, safeArea.right, "Precondition: the simulated vertical bar applies.")
        return (window, host)
    }

    /// What folding, unfolding or rotating does to the overlay window: a new
    /// size and a new safe area, with no rotation callback (the window is
    /// re-fitted by its scene-geometry observation, not by UIKit's rotation).
    private func unfold(_ window: UIWindow, _ host: SwiftyDebugViewController, to bounds: CGRect, safeArea: UIEdgeInsets) throws {
        window.frame = bounds
        host.additionalSafeAreaInsets = safeArea
        window.layoutIfNeeded()
        try requireNoSideInsetsOfItsOwn(window)
        host.view.layoutIfNeeded()
    }

    private func requireNoSideInsetsOfItsOwn(_ window: UIWindow) throws {
        let own = window.safeAreaInsets
        if own.left != 0 || own.right != 0 {
            throw XCTSkip("The test window has side insets of its own here (\(own)), so the simulated "
                          + "vertical bar would count twice. The docking maths is covered with explicit insets.")
        }
    }

    /// Drags the bubble and lets go at `location`, through its real pan handler.
    private func drag(_ bubble: Bubble, releasingAt location: CGPoint) {
        let pan = StubPan()
        pan.stubbedState = .began
        _ = bubble.perform(Selector(("handlePan:")), with: pan)
        pan.stubbedState = .ended
        pan.stubbedLocation = location
        _ = bubble.perform(Selector(("handlePan:")), with: pan)
    }

    /// A pan nobody is touching: state, location and velocity are stubbed, and it
    /// reports no movement, so the release point alone decides the dock.
    private final class StubPan: UIPanGestureRecognizer {
        var stubbedState: UIGestureRecognizer.State = .possible
        var stubbedLocation: CGPoint = .zero

        override var state: UIGestureRecognizer.State {
            get { stubbedState }
            set { stubbedState = newValue }
        }

        init() { super.init(target: nil, action: nil) }

        override func translation(in view: UIView?) -> CGPoint { .zero }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) {}
        override func location(in view: UIView?) -> CGPoint { stubbedLocation }
        override func velocity(in view: UIView?) -> CGPoint { .zero }
    }
}
