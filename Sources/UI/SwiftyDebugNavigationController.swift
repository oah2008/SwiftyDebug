//
//  SwiftyDebugNavigationController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugNavigationController: UINavigationController {

    /// A back arrow that cannot mirror itself, whatever direction UIKit resolves
    /// where it draws it.
    ///
    /// UIKit's own back indicator is `chevron.backward`, and that glyph flips two
    /// independent ways: its image asset carries a right-to-left variant, and
    /// UIKit hands the button the image with `flipsForRightToLeftLayoutDirection`
    /// turned on, so `UIImageView` mirrors it as well. Both are decided at draw
    /// time from the resolved direction of UIKit's *private* image view — never
    /// from the bar's `semanticContentAttribute`, which is why forcing that moved
    /// the button to the left edge but left the arrow pointing right.
    ///
    /// Measured on a pushed bar: that private image view is created on push, long
    /// after `viewDidLoad`, with `semanticContentAttribute == .unspecified` and no
    /// trait override of its own — so it inherits its direction and nothing else.
    /// The chain it inherits through is the SDK window's `traitOverrides` pin,
    /// which does not exist before iOS 17 and is compiled out entirely on an
    /// iOS 15/16 host. One broken link and the arrow comes back mirrored.
    ///
    /// `chevron.left` is geometric rather than semantic: its asset resolves to the
    /// same left-pointing image under an RTL trait collection, and its
    /// `flipsForRightToLeftLayoutDirection` is false. Both mirroring paths are
    /// disarmed at the source, on every iOS version. It renders pixel-identically
    /// to the default indicator in LTR, so nothing about the bar looks different.
    private static let nonMirroringBackIndicator = UIImage(systemName: "chevron.left")

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
    }
}
