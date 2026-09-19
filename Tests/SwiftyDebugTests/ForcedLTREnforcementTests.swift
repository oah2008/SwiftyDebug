//
//  ForcedLTREnforcementTests.swift
//  SwiftyDebugTests
//
//  The forced-LTR guarantee stopped being a one-time stamp and became a sweep
//  that re-asserts on every layout pass. That buys coverage of views UIKit
//  builds later (a nav bar's private back-button image view, an alert's
//  hierarchy, a dequeued cell) and it buys two new risks, both covered here:
//  a layout feedback loop, and reaching into things that are not ours.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class ForcedLTREnforcementTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 390, height: 780)

    override func tearDown() {
        UIView.appearance().semanticContentAttribute = .unspecified
        super.tearDown()
    }

    private func rtlHost() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
    }

    // MARK: - The sweep must settle

    /// Writing `semanticContentAttribute` or `textAlignment` inside a layout pass
    /// invalidates layout, and the sweep runs FROM `layoutSubviews`. If it wrote
    /// unconditionally it would schedule another pass forever and burn the CPU
    /// for as long as the debug UI was open. `pinLeftToRight()` only writes when
    /// the value differs, so the second pass must be a no-op.
    func testTheSweepReachesAFixedPointAndStopsWriting() {
        rtlHost()

        final class CountingWindow: SwiftyDebugWindow {
            var layoutCount = 0
            override func layoutSubviews() {
                layoutCount += 1
                super.layoutSubviews()
            }
        }

        let window = CountingWindow(frame: screen)
        let root = UIViewController()
        let stack = UIStackView(arrangedSubviews: (0..<20).map { index -> UIView in
            let label = UILabel()
            label.text = "row \(index)"
            return label
        })
        stack.axis = .vertical
        root.view.addSubview(stack)
        window.rootViewController = root
        window.isHidden = false

        window.layoutIfNeeded()
        let afterFirst = window.layoutCount

        // A settled tree must not schedule further layout of its own accord.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(window.layoutCount, afterFirst,
                       "The forced-LTR sweep re-triggered layout — it is looping, not settling.")

        // And an explicit pass must still not dirty anything.
        window.setNeedsLayout()
        window.layoutIfNeeded()
        let afterExplicit = window.layoutCount
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(window.layoutCount, afterExplicit)
    }

    /// The sweep is a full tree walk per layout pass. It has to stay cheap enough
    /// to run behind a scrolling list.
    func testTheSweepIsCheapEnoughToRunEveryLayoutPass() {
        rtlHost()
        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        for section in 0..<20 {
            let container = UIView()
            root.view.addSubview(container)
            for row in 0..<25 {
                let label = UILabel()
                label.text = "\(section)-\(row)"
                container.addSubview(label)
            }
        }
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()   // first pass does the writing

        // 500+ views, already settled: the steady state is one comparison each.
        let start = Date()
        for _ in 0..<50 {
            window.setNeedsLayout()
            window.layoutIfNeeded()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0,
                          "50 settled layout passes over ~500 views took \(elapsed)s — the sweep is too expensive")
    }

    // MARK: - Text alignment

    func testNaturalAlignmentBecomesLeftAndExplicitAlignmentSurvives() {
        rtlHost()
        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()

        let natural = UILabel()                      // never assigned: .natural
        let centred = UILabel(); centred.textAlignment = .center
        let right = UILabel();   right.textAlignment = .right
        let field = UITextField()
        let textView = UITextView()

        [natural, centred, right].forEach { root.view.addSubview($0) }
        root.view.addSubview(field)
        root.view.addSubview(textView)

        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()

        XCTAssertEqual(natural.textAlignment, .left,
                       ".natural resolves RIGHT in an RTL host — it must be pinned to .left")
        XCTAssertEqual(field.textAlignment, .left)
        XCTAssertEqual(textView.textAlignment, .left)
        XCTAssertEqual(centred.textAlignment, .center, "A deliberately centred label must stay centred")
        XCTAssertEqual(right.textAlignment, .right, "A deliberately right-aligned label must stay right-aligned")
    }

    /// A label created long after the window's first layout — a dequeued cell's
    /// label, in practice — must be covered too.
    func testALabelAddedAfterTheFirstLayoutIsStillPinned() {
        rtlHost()
        let window = SwiftyDebugWindow(frame: screen)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()

        let late = UILabel()
        late.text = "added later"
        root.view.addSubview(late)
        window.setNeedsLayout()
        window.layoutIfNeeded()

        XCTAssertEqual(late.textAlignment, .left)
        XCTAssertEqual(late.effectiveUserInterfaceLayoutDirection, .leftToRight)
    }

    // MARK: - The host app must be untouched

    /// The proxies are scoped by containment to SDK windows. A label in the HOST
    /// app's own window must keep the host's direction and the host's alignment —
    /// an SDK that reformats its host is worse than one that renders mirrored.
    func testTheHostAppsOwnLabelsAreNotTouched() {
        rtlHost()
        // Force the SDK's proxies to be installed before the host window is built.
        _ = SwiftyDebugWindow(frame: screen)

        let hostWindow = UIWindow(frame: screen)
        let hostRoot = UIViewController()
        let hostLabel = UILabel()
        hostLabel.text = "host"
        hostRoot.view.addSubview(hostLabel)
        hostWindow.rootViewController = hostRoot
        hostWindow.isHidden = false
        hostWindow.layoutIfNeeded()

        XCTAssertEqual(hostLabel.textAlignment, .natural,
                       "SwiftyDebug must not rewrite text alignment in the host app's own windows")
        XCTAssertEqual(hostRoot.view.effectiveUserInterfaceLayoutDirection, .rightToLeft,
                       "The host app keeps its own layout direction")
    }

    // MARK: - What the sweep must NOT reach

    /// A share sheet is rendered by another process. Forcing direction on it does
    /// nothing useful and is not the SDK's business.
    func testOutOfProcessControllersAreExcluded() {
        XCTAssertTrue(SwiftyDebugHostingWindow.isOutOfProcess(
            UIActivityViewController(activityItems: ["x"], applicationActivities: nil)))
        XCTAssertTrue(SwiftyDebugHostingWindow.isOutOfProcess(
            UIDocumentPickerViewController(forOpeningContentTypes: [])))
        XCTAssertFalse(SwiftyDebugHostingWindow.isOutOfProcess(UIViewController()))
        XCTAssertFalse(SwiftyDebugHostingWindow.isOutOfProcess(SwiftyDebugTabBarController()))
    }

    // MARK: - Navigation

    /// A pushed screen that installs its own left bar button must keep it AND
    /// still have a way back. Assigning over `leftBarButtonItem` (rather than
    /// inserting into `leftBarButtonItems`) left screens with `hidesBackButton`
    /// set and no back control at all.
    func testAScreenWithItsOwnLeftItemKeepsItAndStillHasABackButton() {
        final class OpinionatedScreen: UIViewController {
            override func viewDidLoad() {
                super.viewDidLoad()
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Mine", style: .plain,
                                                                  target: nil, action: nil)
            }
        }

        let window = SwiftyDebugWindow(frame: screen)
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        let pushed = OpinionatedScreen()
        nav.pushViewController(pushed, animated: false)
        window.layoutIfNeeded()

        let items = pushed.navigationItem.leftBarButtonItems ?? []
        XCTAssertTrue(items.contains { $0.customView is SwiftyDebugBackButton },
                      "A screen that sets its own left item must still get a back button")
        XCTAssertTrue(items.contains { $0.title == "Mine" },
                      "…and must keep its own item")
    }

    func testTheBackButtonIsNotDuplicatedAcrossPushAndWillShow() {
        let window = SwiftyDebugWindow(frame: screen)
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        let pushed = UIViewController()
        nav.pushViewController(pushed, animated: false)
        window.layoutIfNeeded()
        // `willShow` also installs; both paths must agree that one is enough.
        nav.navigationController(nav, willShow: pushed, animated: false)

        let count = (pushed.navigationItem.leftBarButtonItems ?? [])
            .filter { $0.customView is SwiftyDebugBackButton }.count
        XCTAssertEqual(count, 1, "Exactly one back button, however many install paths ran")
    }

    /// Hiding UIKit's back button disables its interactive pop gesture. The SDK
    /// re-arms it — but must not let it begin on the root, which wedges the stack.
    func testSwipeBackIsArmedOffTheRootAndDisarmedOnIt() throws {
        let window = SwiftyDebugWindow(frame: screen)
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        let recognizer = try XCTUnwrap(nav.interactivePopGestureRecognizer)
        XCTAssertTrue(recognizer.delegate === nav, "The SDK must own the pop recognizer's delegate")
        XCTAssertFalse(nav.gestureRecognizerShouldBegin(recognizer),
                       "Swipe-back on the root would wedge the navigation controller")

        nav.pushViewController(UIViewController(), animated: false)
        XCTAssertTrue(nav.gestureRecognizerShouldBegin(recognizer),
                      "Swipe-back must work once there is somewhere to go back to")
    }
}
