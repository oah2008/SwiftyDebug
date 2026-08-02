//
//  ForcedLayoutDirectionTests.swift
//  SwiftyDebugTests
//
//  SwiftyDebug must render left-to-right inside a host app that runs
//  right-to-left, and must not change the host app in return.
//
//  The bug these cover: the SDK forced `semanticContentAttribute` on the views it
//  knew about, in `viewDidLoad`. A host that forces RTL does it with
//  `UIView.appearance().semanticContentAttribute = .forceRightToLeft`, and UIKit
//  applies that proxy to every view as it enters a window — so every view born
//  after the sweep (cells, headers, anything added later) came back RTL, and no
//  amount of extra `forceLTR()` calls could close the hole. Separately, the
//  `layoutDirection` *trait* — which is what the navigation bar's back chevron
//  image is resolved from — is not moved by `semanticContentAttribute` at all.
//
//  A mirrored debug UI produces no crash and no failing assertion, so these
//  assert the resolved direction directly.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class ForcedLayoutDirectionTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 390, height: 780)

    /// Stands in for a host app that forces RTL app-wide, which is what
    /// `UIView.appearance()` is for.
    private func makeHostAppRightToLeft() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
    }

    override func tearDown() {
        UIView.appearance().semanticContentAttribute = .unspecified
        super.tearDown()
    }

    private func onScreen(_ window: UIWindow, root: UIViewController) {
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
    }

    // MARK: - The core guarantee

    func testDeeplyNestedViewIsLeftToRightWhileTheHostAppIsRightToLeft() {
        makeHostAppRightToLeft()

        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        let container = UIView()
        let leaf = UILabel()
        container.addSubview(leaf)
        root.view.addSubview(container)
        onScreen(window, root: root)

        XCTAssertEqual(root.view.effectiveUserInterfaceLayoutDirection, .leftToRight,
                       "The SDK window's root view must be LTR in an RTL host")
        XCTAssertEqual(container.effectiveUserInterfaceLayoutDirection, .leftToRight)
        XCTAssertEqual(leaf.effectiveUserInterfaceLayoutDirection, .leftToRight,
                       "Depth must not matter — the host proxy stamps every view individually")
    }

    /// The hole the old `forceLTR()` sweep could never cover: table cells and any
    /// other view built after `viewDidLoad` has already run.
    func testViewCreatedAfterTheWindowIsOnScreenIsStillLeftToRight() {
        makeHostAppRightToLeft()

        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        onScreen(window, root: root)

        let late = UIView()
        let lateLeaf = UIButton(type: .system)
        late.addSubview(lateLeaf)
        root.view.addSubview(late)
        window.layoutIfNeeded()

        XCTAssertEqual(late.effectiveUserInterfaceLayoutDirection, .leftToRight,
                       "A view added after the sweep must still come up LTR")
        XCTAssertEqual(lateLeaf.effectiveUserInterfaceLayoutDirection, .leftToRight)
    }

    /// A host may target a specific class rather than plain `UIView`. Containment
    /// scoping has to out-rank that, or the SDK loses on every label.
    func testScopedProxyOutranksAHostProxyOnASpecificClass() {
        makeHostAppRightToLeft()
        UILabel.appearance().semanticContentAttribute = .forceRightToLeft
        defer { UILabel.appearance().semanticContentAttribute = .unspecified }

        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        let label = UILabel()
        root.view.addSubview(label)
        onScreen(window, root: root)

        XCTAssertEqual(label.effectiveUserInterfaceLayoutDirection, .leftToRight)
    }

    // MARK: - The layoutDirection trait (the back chevron)

    /// `semanticContentAttribute` does not move the trait, and direction-aware
    /// images — `chevron.backward` in the nav bar's back button, anything using
    /// `imageFlippedForRightToLeftLayoutDirection` — are resolved from the trait.
    /// Forcing only the semantic attribute is what produced a back button on the
    /// correct side with the arrow pointing the wrong way.
    func testLayoutDirectionTraitIsPinnedLeftToRightThroughoutTheWindow() {
        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        let deep = UIView()
        root.view.addSubview(deep)
        onScreen(window, root: root)

        XCTAssertNotEqual(window.traitCollection.layoutDirection, .rightToLeft)
        XCTAssertEqual(root.traitCollection.layoutDirection, .leftToRight,
                       "The hosted view controller must inherit the pinned trait")
        XCTAssertEqual(deep.traitCollection.layoutDirection, .leftToRight)

        // Assert the OVERRIDE, not just the resolved value. The test host is already
        // LTR, so the resolved value reads .leftToRight whether or not the pin exists
        // — which is how this half of the fix shipped with no coverage at all.
        if #available(iOS 17.0, *) {
            XCTAssertTrue(window.traitOverrides.contains(UITraitLayoutDirection.self),
                          "The layout-direction pin is what turns the back chevron the right way")
            XCTAssertEqual(window.traitOverrides.layoutDirection, .leftToRight)
        }
    }

    /// The pre-iOS-17 path never runs on a modern simulator, so exercise its pure
    /// composition directly — starting from an explicitly RTL base.
    func testLegacyTraitCompositionForcesLeftToRightFromAnRTLBase() {
        let rtl = UITraitCollection(layoutDirection: .rightToLeft)
        XCTAssertEqual(rtl.layoutDirection, .rightToLeft, "precondition")

        let composed = SwiftyDebugHostingWindow.legacyLayoutDirectionTraits(base: rtl)
        XCTAssertEqual(composed.layoutDirection, .leftToRight,
                       "The legacy override must win over an RTL environment")
    }

    /// Control for the test above: prove a window's layout-direction override is
    /// actually load-bearing — i.e. that without the SDK's `.leftToRight` pin, an
    /// RTL environment really would reach every descendant.
    func testWindowLevelLayoutDirectionOverrideReachesEveryDescendant() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("traitOverrides is the iOS 17+ mechanism")
        }
        let window = UIWindow(frame: screen)
        window.traitOverrides.layoutDirection = .rightToLeft
        let root = UIViewController()
        let deep = UIView()
        root.view.addSubview(deep)
        onScreen(window, root: root)

        XCTAssertEqual(deep.traitCollection.layoutDirection, .rightToLeft,
                       "If this stops propagating, the SDK's LTR pin has stopped working too")
    }

    // MARK: - Navigation bar / back button

    func testPushedScreenKeepsTheBackButtonOnTheLeftInAnRTLHost() {
        makeHostAppRightToLeft()

        let window = SwiftyDebugWindow(frame: screen)
        let first = UIViewController()
        first.title = "First"
        let nav = SwiftyDebugNavigationController(rootViewController: first)
        onScreen(window, root: nav)

        let second = UIViewController()
        second.title = "Second"
        nav.pushViewController(second, animated: false)
        window.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()

        XCTAssertEqual(nav.navigationBar.effectiveUserInterfaceLayoutDirection, .leftToRight)
        XCTAssertEqual(nav.navigationBar.traitCollection.layoutDirection, .leftToRight,
                       "The back chevron image is resolved from this trait, not from the semantic attribute")

        // Nothing in the bar may resolve RTL — UIKit builds the button bar itself,
        // long after any viewDidLoad sweep.
        let mirrored = Self.descendants(of: nav.navigationBar)
            .filter { $0.effectiveUserInterfaceLayoutDirection == .rightToLeft }
        XCTAssertTrue(mirrored.isEmpty,
                      "Mirrored nav bar subviews: \(mirrored.map { String(describing: type(of: $0)) })")

        // And the back control really is on the left half of the bar.
        let bar = nav.navigationBar
        let backControls = Self.descendants(of: bar)
            .filter { $0 is UIControl && $0.bounds.width > 20 && $0.bounds.height > 20 }
        let leftmost = backControls
            .map { bar.convert($0.bounds, from: $0).minX }
            .min()
        if let leftmost {
            XCTAssertLessThan(leftmost, bar.bounds.midX,
                              "The back control must sit in the leading (left) half of the bar")
        }
    }

    // MARK: - The overlay window

    /// The paused-request banner lives in its own window, which used to be a plain
    /// UIWindow and so missed every fix applied to the main one.
    func testBreakpointOverlayWindowForcesLeftToRight() {
        makeHostAppRightToLeft()

        let window = PassthroughWindow(frame: screen)
        let root = UIViewController()
        let banner = UIView()
        let chevron = UIImageView()
        banner.addSubview(chevron)
        root.view.addSubview(banner)
        onScreen(window, root: root)

        XCTAssertEqual(banner.effectiveUserInterfaceLayoutDirection, .leftToRight)
        XCTAssertEqual(chevron.effectiveUserInterfaceLayoutDirection, .leftToRight)
        XCTAssertEqual(chevron.traitCollection.layoutDirection, .leftToRight)
    }

    // MARK: - The host app must not change

    func testHostAppWindowKeepsItsOwnRightToLeftLayout() {
        makeHostAppRightToLeft()
        // Make sure the SDK's proxy is registered before the host window is built.
        _ = SwiftyDebugWindow(frame: screen)

        let hostWindow = UIWindow(frame: screen)
        let root = UIViewController()
        let child = UILabel()
        root.view.addSubview(child)
        onScreen(hostWindow, root: root)

        XCTAssertEqual(root.view.effectiveUserInterfaceLayoutDirection, .rightToLeft,
                       "SwiftyDebug must not flip the app it is debugging")
        XCTAssertEqual(child.effectiveUserInterfaceLayoutDirection, .rightToLeft)
    }

    // MARK: - The manual sweep still works where it is used

    func testForceLTRPinsBothTheSemanticAttributeAndTheTrait() {
        makeHostAppRightToLeft()

        let cell = UITableViewCell()
        let inner = UILabel()
        cell.contentView.addSubview(inner)
        cell.forceLTR()

        XCTAssertEqual(cell.semanticContentAttribute, .forceLeftToRight)
        XCTAssertEqual(inner.semanticContentAttribute, .forceLeftToRight)
        if #available(iOS 17.0, *) {
            // Reading `.layoutDirection` without an override in place throws, so
            // the presence of the override is the thing to assert first.
            XCTAssertTrue(cell.traitOverrides.contains(UITraitLayoutDirection.self),
                          "forceLTR() must move the trait too, or direction-aware images stay flipped")
            XCTAssertEqual(cell.traitOverrides.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Helpers

    private static func descendants(of view: UIView) -> [UIView] {
        var out: [UIView] = []
        for sub in view.subviews {
            out.append(sub)
            out.append(contentsOf: descendants(of: sub))
        }
        return out
    }
}
