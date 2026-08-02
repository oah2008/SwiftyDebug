//
//  RTLBackIndicatorOrientationTests.swift
//  SwiftyDebugTests
//
//  The back chevron in SwiftyDebug's navigation bar must point LEFT inside a
//  host app that runs right-to-left. It did not, on a real RTL device, after a
//  previous round of forced-LTR work reported it fixed.
//
//  Why the earlier tests missed it: they asserted that an override *object*
//  existed, in a test host that is itself left-to-right, so the resolved value
//  read `.leftToRight` whether or not anything was pinned. These assert the
//  glyph's resolved orientation — by rendering it and looking at which way it
//  points — with the layout direction the bar actually sits in forced to RTL.
//
//  What was measured (see the fix in SwiftyDebugNavigationController):
//
//  * UIKit's default back indicator is `chevron.backward`, which HAS a
//    right-to-left variant in its image asset, and UIKit hands it to the button
//    with `flipsForRightToLeftLayoutDirection == true` on top of that. Both
//    mirroring paths are decided where the glyph is drawn, from the resolved
//    direction of UIKit's own private image view — never from the bar's
//    `semanticContentAttribute`.
//  * That private image view is built when a screen is PUSHED, long after
//    `viewDidLoad`, with `semanticContentAttribute == .unspecified` and no trait
//    override of its own. It inherits, and nothing else.
//  * `UINavigationBar` itself carried no layout-direction pin: `view.forceLTR()`
//    in `viewDidLoad` cannot reach it, because UIKit has not attached the bar to
//    `view` yet at that point.
//
//  So the glyph hung off an unbroken inheritance chain from the window — and
//  the window's pin is `traitOverrides`, which does not exist before iOS 17 and
//  is compiled out on an iOS 15/16 host entirely.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class RTLBackIndicatorOrientationTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 390, height: 780)

    override func tearDown() {
        UIView.appearance().semanticContentAttribute = .unspecified
        super.tearDown()
    }

    // MARK: - The reported defect

    /// The device case, end to end: a pushed screen in an environment whose
    /// layout direction is right-to-left, rendered, and the arrow inspected.
    func testBackChevronPointsLeftWhenTheAmbientLayoutDirectionIsRightToLeft() throws {
        let nav = try makePushedNavigation(ambientDirection: .rightToLeft)
        let chevron = try backChevronImageView(in: nav.navigationBar)

        XCTAssertEqual(try Self.pointing(ofView: chevron), .left,
                       "The back arrow must point left in an RTL host. It pointed right on a real device.")
    }

    /// Control: the same measurement, in a left-to-right environment. If this
    /// ever fails the renderer, not the SDK, has changed.
    func testBackChevronPointsLeftInALeftToRightEnvironment() throws {
        let nav = try makePushedNavigation(ambientDirection: .leftToRight)
        let chevron = try backChevronImageView(in: nav.navigationBar)

        XCTAssertEqual(try Self.pointing(ofView: chevron), .left)
    }

    // MARK: - Why it broke: the glyph itself must not be direction-aware

    /// The durable half of the fix. Whatever direction UIKit ends up resolving
    /// for its private image view — on any iOS version, through any inheritance
    /// chain the SDK does not control — the installed glyph has to look the same.
    func testInstalledBackIndicatorHasNoRightToLeftVariantAndNoFlipFlag() throws {
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()

        let installed = try XCTUnwrap(nav.navigationBar.backIndicatorImage,
                                      "SwiftyDebug must install its own back indicator instead of inheriting UIKit's mirroring one")

        XCTAssertFalse(installed.flipsForRightToLeftLayoutDirection,
                       "A flipping image is mirrored by UIImageView from the view's own resolved direction")

        let asset = try XCTUnwrap(installed.imageAsset)
        let resolvedRTL = asset.image(with: UITraitCollection(layoutDirection: .rightToLeft))
        XCTAssertEqual(try Self.pointing(ofImage: resolvedRTL), .left,
                       "Resolved against an RTL trait collection the back indicator must still point left")

        let resolvedLTR = asset.image(with: UITraitCollection(layoutDirection: .leftToRight))
        XCTAssertEqual(try Self.pointing(ofImage: resolvedLTR), .left)
    }

    /// Proves the measurement above discriminates: UIKit's default indicator —
    /// what the SDK used to inherit — fails it.
    func testUIKitDefaultBackIndicatorIsTheMirroringOneThisTestWouldCatch() throws {
        let mirroring = try XCTUnwrap(UIImage(systemName: "chevron.backward"))
        let asset = try XCTUnwrap(mirroring.imageAsset)

        XCTAssertEqual(try Self.pointing(ofImage: asset.image(with: UITraitCollection(layoutDirection: .leftToRight))), .left)
        XCTAssertEqual(try Self.pointing(ofImage: asset.image(with: UITraitCollection(layoutDirection: .rightToLeft))), .right,
                       "chevron.backward mirrors itself — if it ever stops, the test above proves nothing")
    }

    /// The appearance objects drive the modern rendering path; the bar property
    /// drives the legacy one. Both have to carry the non-mirroring glyph.
    func testBothNavigationBarAppearancesCarryTheNonMirroringIndicator() throws {
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()
        let installed = try XCTUnwrap(nav.navigationBar.backIndicatorImage)

        for (name, appearance) in [("standard", nav.navigationBar.standardAppearance),
                                   ("scrollEdge", nav.navigationBar.scrollEdgeAppearance)] {
            let image = try XCTUnwrap(appearance?.backIndicatorImage, "\(name)Appearance has no back indicator")
            XCTAssertFalse(image.flipsForRightToLeftLayoutDirection, "\(name)Appearance indicator flips")
            let asset = try XCTUnwrap(image.imageAsset)
            XCTAssertEqual(try Self.pointing(ofImage: asset.image(with: UITraitCollection(layoutDirection: .rightToLeft))), .left,
                           "\(name)Appearance indicator mirrors under RTL")
        }
        XCTAssertFalse(installed.flipsForRightToLeftLayoutDirection)
    }

    /// The other half: the bar is pinned itself, so every button view UIKit
    /// creates inside it later inherits left-to-right rather than the host's
    /// direction. `view.forceLTR()` in `viewDidLoad` never reached the bar.
    func testNavigationBarCarriesItsOwnLayoutDirectionPin() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("traitOverrides is the iOS 17+ mechanism") }

        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()

        // Reading `layoutDirection` with no override in place raises
        // NSInternalInconsistencyException, so the presence check has to gate it.
        guard nav.navigationBar.traitOverrides.contains(UITraitLayoutDirection.self) else {
            return XCTFail("The bar must not depend on inheriting the pin from the window")
        }
        XCTAssertEqual(nav.navigationBar.traitOverrides.layoutDirection, .leftToRight)
        XCTAssertEqual(nav.navigationBar.semanticContentAttribute, .forceLeftToRight)
    }

    /// Replacing the system indicator must not change how the bar looks in the
    /// LTR case every existing user is in.
    func testTheReplacementIsIndistinguishableFromUIKitsIndicatorInLTR() throws {
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()
        let installed = try XCTUnwrap(nav.navigationBar.backIndicatorImage)
        let system = try XCTUnwrap(UIImage(systemName: "chevron.backward"))

        XCTAssertEqual(installed.size, system.size, "The back arrow changed size")
        let ltr = UITraitCollection(layoutDirection: .leftToRight)
        XCTAssertEqual(try Self.pixels(of: try XCTUnwrap(installed.imageAsset).image(with: ltr)),
                       try Self.pixels(of: try XCTUnwrap(system.imageAsset).image(with: ltr)),
                       "The back arrow renders differently from the system one in LTR")
    }

    // MARK: - Adjacent behaviour that must not regress

    /// The previous round moved the back BUTTON to the left edge; only the glyph
    /// was wrong. Keep the position fixed while fixing the arrow.
    func testBackButtonStaysInTheLeadingHalfOfTheBarUnderRTL() throws {
        let nav = try makePushedNavigation(ambientDirection: .rightToLeft)
        let bar = nav.navigationBar
        let chevron = try backChevronImageView(in: bar)

        let x = bar.convert(chevron.bounds, from: chevron).midX
        XCTAssertLessThan(x, bar.bounds.midX,
                          "The back control belongs in the leading (left) half of the bar")
    }

    /// The interactive pop gesture watches a screen edge, and that edge is
    /// direction-derived too. It must stay on the left.
    func testInteractivePopGestureStaysOnTheLeftEdgeUnderRTL() throws {
        let nav = try makePushedNavigation(ambientDirection: .rightToLeft)
        let recognizer = try XCTUnwrap(nav.interactivePopGestureRecognizer)

        if let edgePan = recognizer as? UIScreenEdgePanGestureRecognizer {
            XCTAssertEqual(edgePan.edges, .left,
                           "A right-edge pop gesture is the mirrored one")
        } else {
            let edges = recognizer.value(forKey: "edges") as? UInt
            XCTAssertEqual(edges, UIRectEdge.left.rawValue,
                           "UINavigationController's pop recognizer must watch the left edge")
        }
    }

    /// The disclosure chevrons the SDK draws itself use the geometric
    /// `chevron.right`, which has no RTL variant — unlike `chevron.backward`.
    /// If that ever changes every list row in the SDK mirrors silently.
    func testSDKDisclosureChevronsDoNotMirror() throws {
        for name in ["chevron.right", "chevron.left", "chevron.down", "chevron.up"] {
            let image = try XCTUnwrap(UIImage(systemName: name), name)
            XCTAssertFalse(image.flipsForRightToLeftLayoutDirection, "\(name) flips")
            let asset = try XCTUnwrap(image.imageAsset, name)
            let ltr = asset.image(with: UITraitCollection(layoutDirection: .leftToRight))
            let rtl = asset.image(with: UITraitCollection(layoutDirection: .rightToLeft))
            XCTAssertEqual(try Self.pixels(of: ltr), try Self.pixels(of: rtl),
                           "\(name) renders differently under RTL — it has a mirrored variant")
        }
    }

    // MARK: - Building the RTL environment

    /// Builds a pushed SwiftyDebug navigation stack whose ambient layout
    /// direction — the direction the navigation bar and everything UIKit creates
    /// inside it inherits — is `direction`.
    ///
    /// The RTL pin goes on the navigation controller's own view, which is the
    /// bar's actual trait environment. That is what a real RTL host produces
    /// whenever the window-level pin does not reach: always on iOS 15 and 16,
    /// where `traitOverrides` does not exist and the whole pin is compiled out.
    private func makePushedNavigation(ambientDirection: UIUserInterfaceLayoutDirection) throws -> SwiftyDebugNavigationController {
        if ambientDirection == .rightToLeft {
            UIView.appearance().semanticContentAttribute = .forceRightToLeft
        }

        let window = SwiftyDebugWindow(frame: screen)
        let first = UIViewController()
        first.title = "First"
        let nav = SwiftyDebugNavigationController(rootViewController: first)
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        if ambientDirection == .rightToLeft {
            guard #available(iOS 17.0, *) else { throw XCTSkip("needs traitOverrides to force RTL") }
            // Only the trait. The two `semanticContentAttribute` lines the SDK
            // sets in `viewDidLoad` are deliberately left standing, because they
            // do hold on a device — over-forcing them here would manufacture
            // failures the host never sees.
            nav.view.traitOverrides.layoutDirection = .rightToLeft
        }

        let second = UIViewController()
        second.title = "Second"
        nav.pushViewController(second, animated: false)
        window.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()
        return nav
    }

    /// UIKit's private image view for the visible back arrow.
    ///
    /// The bar also holds a chevron in a transition *mask* view, which is not
    /// what the user sees — and which is a chevron symbol too once the SDK
    /// supplies the mask image, so it has to be excluded by position in the
    /// hierarchy rather than by what its image is.
    private func backChevronImageView(in bar: UINavigationBar) throws -> UIImageView {
        let chevrons = Self.descendants(of: bar)
            .compactMap { $0 as? UIImageView }
            .filter { ($0.image?.description ?? "").contains("symbol(system: chevron") }
            .filter { !Self.hasMaskAncestor($0, upTo: bar) }
        guard chevrons.count == 1 else {
            XCTFail("Expected exactly one visible chevron image view in the bar, found \(chevrons.count)")
            throw Failure.notFound
        }
        return chevrons[0]
    }

    private static func hasMaskAncestor(_ view: UIView, upTo bar: UINavigationBar) -> Bool {
        var next: UIView? = view
        while let current = next, current !== bar {
            if String(describing: type(of: current)).contains("Mask") { return true }
            next = current.superview
        }
        return false
    }

    private enum Failure: Error { case notFound, unreadable }

    // MARK: - Measuring which way an arrow points

    enum Pointing: CustomStringConvertible {
        case left, right
        var description: String { self == .left ? "left (<)" : "right (>)" }
    }

    /// A chevron's tip sits at the vertical middle and its arms open the other
    /// way, so the horizontal centre of the ink in the top band lies on the
    /// opposite side from the ink in the middle band. `<` opens right: top ink
    /// is to the RIGHT of middle ink.
    private static func pointing(ofView view: UIView) throws -> Pointing {
        let size = view.bounds.size
        guard size.width >= 4, size.height >= 4 else { throw Failure.unreadable }
        return try classify(render(size) { context in view.layer.render(in: context) }, size)
    }

    private static func pointing(ofImage image: UIImage) throws -> Pointing {
        let size = image.size
        guard size.width >= 4, size.height >= 4 else { throw Failure.unreadable }
        return try classify(render(size) { context in
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded())))
            UIGraphicsPopContext()
        }, size)
    }

    /// The rendered bitmap itself — position sensitive, so a mirrored variant
    /// cannot compare equal to its original the way a pixel count would.
    private static func pixels(of image: UIImage) throws -> [UInt8] {
        let size = image.size
        guard size.width >= 4, size.height >= 4 else { throw Failure.unreadable }
        return render(size) { context in
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded())))
            UIGraphicsPopContext()
        }
    }

    private static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> [UInt8] {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            draw(context)
        }
        return pixels
    }

    private static func classify(_ pixels: [UInt8], _ size: CGSize) throws -> Pointing {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        var topSum = 0.0, topCount = 0.0, middleSum = 0.0, middleCount = 0.0
        for y in 0..<height {
            let band = Double(y) / Double(height)
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                if band < 0.28 { topSum += Double(x); topCount += 1 }
                if band > 0.42, band < 0.58 { middleSum += Double(x); middleCount += 1 }
            }
        }
        guard topCount > 0, middleCount > 0 else { throw Failure.unreadable }
        let top = topSum / topCount, middle = middleSum / middleCount
        guard abs(top - middle) > 0.5 else { throw Failure.unreadable }
        return top > middle ? .left : .right
    }

    private static func descendants(of view: UIView) -> [UIView] {
        var out: [UIView] = []
        for subview in view.subviews {
            out.append(subview)
            out.append(contentsOf: descendants(of: subview))
        }
        return out
    }
}
