//
//  SwiftyDebugNavigationController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugNavigationController: UINavigationController {

    /// UIKit's back indicator, kept only so the bar reserves the same metrics and
    /// so a screen that somehow escapes the custom button below still shows a
    /// left-pointing glyph in LTR.
    ///
    /// It is NOT the guarantee, and the comment that used to stand here claiming
    /// it was is wrong: handing UIKit a glyph whose
    /// `flipsForRightToLeftLayoutDirection` is false does not stop the mirroring,
    /// because UIKit installs a copy made with
    /// `imageFlippedForRightToLeftLayoutDirection()` regardless — measured on a
    /// pushed bar, the bar's image view reports `flips == true` either way. The
    /// arrow's direction then rests entirely on a private image view created on
    /// push, which is exactly the link that breaks. `SwiftyDebugBackButton` owns
    /// the control instead.
    private static let nonMirroringBackIndicator = UIImage(systemName: "chevron.left")

    /// Installs SwiftyDebug's own back button on every pushed screen, so no screen
    /// depends on UIKit's indicator. The root has no back button, and gets the
    /// close control from `SwiftyDebugTabBarController`.
    ///
    /// The button is ADDED to `leftBarButtonItems` rather than assigned over
    /// `leftBarButtonItem`. Several SDK screens set their own left item in
    /// `viewDidLoad` — which runs after a push-time assignment — and an assignment
    /// here would be overwritten while `hidesBackButton` stayed true, leaving a
    /// screen with no way back at all. Installing from `willShow` (after
    /// `viewDidLoad`) and inserting at the front makes both survive.
    private func installBackButton(on controller: UIViewController) {
        guard !viewControllers.isEmpty else { return }
        guard controller !== viewControllers.first else { return }   // the root has no back

        var items = controller.navigationItem.leftBarButtonItems ?? []
        if items.contains(where: { $0.customView is SwiftyDebugBackButton }) { return }

        let button = SwiftyDebugBackButton(title: "Back", target: self, action: #selector(popFromBackButton))
        items.insert(UIBarButtonItem(customView: button), at: 0)
        controller.navigationItem.leftBarButtonItems = items
        controller.navigationItem.hidesBackButton = true
    }

    @objc private func popFromBackButton() {
        popViewController(animated: true)
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        applyForcedLTR(to: viewController)
        super.pushViewController(viewController, animated: animated)
        installBackButton(on: viewController)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        viewControllers.forEach { applyForcedLTR(to: $0) }
        super.setViewControllers(viewControllers, animated: animated)
        viewControllers.dropFirst().forEach { installBackButton(on: $0) }
    }

    /// Pre-iOS-17 there is no `traitOverrides`, and the window's `traitCollection`
    /// override is not a supported propagation mechanism. `setOverrideTraitCollection`
    /// IS, and it is the only way a child controller on iOS 15/16 inherits the
    /// pinned direction — which is what direction-aware images resolve from.
    ///
    /// Deliberately does NOT touch `controller.view`: that would force `loadView`
    /// and run `viewDidLoad` while `navigationController` is still nil, which at
    /// least one SDK screen (`AppContainerBrowserViewController`, which installs a
    /// `navigationItem.searchController` there) does not survive. The window's
    /// sweep covers the view once it is on screen.
    private func applyForcedLTR(to controller: UIViewController) {
        if #unavailable(iOS 17.0) {
            setOverrideTraitCollection(UITraitCollection(layoutDirection: .leftToRight),
                                       forChild: controller)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The bar's internals are rebuilt on every push and pop; re-assert rather
        // than relying on a one-time stamp.
        navigationBar.pinLeftToRight()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        overrideUserInterfaceStyle = .dark
        // The window (SwiftyDebugHostingWindow, see UIView+ForceLTR.swift) covers
        // views created after this point, but only by inheritance and only from
        // iOS 17. Pin the bar itself as well: `view.forceLTR()` at the bottom of
        // this method cannot reach it — UIKit has not attached the bar to `view`
        // yet while `viewDidLoad` runs, which is why the bar was carrying no
        // layout-direction override at all. Its own override propagates to every
        // button view UIKit builds inside it later.
        view.semanticContentAttribute = .forceLeftToRight
        navigationBar.forceLTR()
        navigationBar.tintColor = DebugTheme.accentColor

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 20),
            .foregroundColor: DebugTheme.accentColor
        ]
        navigationBar.titleTextAttributes = titleAttributes

        let backIndicator = Self.nonMirroringBackIndicator

        if #available(iOS 26, *) {
            // iOS 26+: system liquid glass nav bar
            navigationBar.isTranslucent = true
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = titleAttributes
            appearance.setBackIndicatorImage(backIndicator, transitionMaskImage: backIndicator)
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
        } else {
            // Legacy: opaque black nav bar
            navigationBar.isTranslucent = false
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .black
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = titleAttributes
            appearance.setBackIndicatorImage(backIndicator, transitionMaskImage: backIndicator)
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
        }

        // The appearance objects drive the modern rendering path; these two drive
        // the legacy one. A host on an older iOS takes the second, so both have to
        // carry the non-mirroring glyph.
        navigationBar.backIndicatorImage = backIndicator
        navigationBar.backIndicatorTransitionMaskImage = backIndicator

        view.forceLTR()

        // `willShow` runs after the pushed screen's `viewDidLoad`, which is the
        // only point at which the back button cannot be overwritten by a screen
        // that sets its own left item.
        if delegate == nil { delegate = self }

        // Hiding UIKit's back button disables the interactive pop gesture, and a
        // swipe-back that silently stops working is a worse regression than a
        // mirrored arrow. Own the recognizer too.
        interactivePopGestureRecognizer?.delegate = self
    }
}

// MARK: - Keeping swipe-back alive

extension SwiftyDebugNavigationController: UINavigationControllerDelegate, UIGestureRecognizerDelegate {

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController,
                              animated: Bool) {
        installBackButton(on: viewController)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        // UIKit disables its own pop gesture once `hidesBackButton` is set, and
        // replacing the delegate to re-arm it also replaces the checks UIKit's own
        // delegate performed. Two of those matter:
        //  • there has to be somewhere to go back to, or the gesture wedges the
        //    navigation controller on its root, and
        //  • no push or pop may already be running, or an interactive pop starts
        //    on top of a transition and corrupts the stack.
        guard viewControllers.count > 1 else { return false }
        return transitionCoordinator == nil
    }
}
