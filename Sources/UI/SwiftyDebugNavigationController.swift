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
    }
}
