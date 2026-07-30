//
//  SwiftyDebugNavigationController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugNavigationController: UINavigationController {

    override func viewDidLoad() {
        super.viewDidLoad()

        overrideUserInterfaceStyle = .dark
        // The guarantee that this whole controller stays LTR in an RTL host comes
        // from SwiftyDebugHostingWindow (see UIView+ForceLTR.swift), which covers
        // views created after this point too. These two lines only settle the bar
        // one layout pass earlier: UINavigationBar propagates its own semantic
        // attribute to its internal subviews, so setting it before the bar builds
        // its button bar avoids a first frame with the back button on the right.
        view.semanticContentAttribute = .forceLeftToRight
        navigationBar.semanticContentAttribute = .forceLeftToRight
        navigationBar.tintColor = DebugTheme.accentColor

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 20),
            .foregroundColor: DebugTheme.accentColor
        ]
        navigationBar.titleTextAttributes = titleAttributes

        if #available(iOS 26, *) {
            // iOS 26+: system liquid glass nav bar
            navigationBar.isTranslucent = true
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = titleAttributes
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
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
        }
        view.forceLTR()
    }
}
