//
//  SwiftyDebugTabBarController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugTabBarController: UITabBarController {

    /// Remembers last selected tab bar index during app session (reset on app kill)
    static var savedTabIndex: Int = 0

    //MARK: - init
    override func viewDidLoad() {
        super.viewDidLoad()

        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.endEditing(true)

        overrideUserInterfaceStyle = .dark
        view.semanticContentAttribute = .forceLeftToRight
        tabBar.semanticContentAttribute = .forceLeftToRight
        view.forceLTR()
        self.delegate = self

        setChildControllers()

        self.selectedIndex = Self.savedTabIndex
        self.tabBar.tintColor = DebugTheme.accentColor
        
        self.tabBar.isTranslucent = true

        if #available(iOS 26, *) {
            // iOS 26+: system liquid glass tab bar
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.shadowColor = .clear
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
        } else {
            // Legacy: dark translucent tab bar
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.shadowColor = .clear
            appearance.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
            appearance.backgroundEffect = UIBlurEffect(style: .dark)
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        Settings.shared.debugUIVisible = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Settings.shared.debugUIVisible = false
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DebugWindowPresenter.shared.displayedList = false
    }
    
    //MARK: - private
    func setChildControllers() {
        let network = makeNav(root: NetworkViewController(),  tabTitle: "Network", systemImage: "arrow.up.arrow.down")
        let logs    = makeNav(root: LogViewController(),      tabTitle: "Logs",    systemImage: "doc.text")
        let app     = makeNav(root: AppInfoViewController(),  tabTitle: "App",     systemImage: "info.circle")

        let navs: [UINavigationController] = [network, logs, app]

        self.viewControllers = navs

        // Add close button to each tab's root VC
        let closeImage = UIImage(systemName: "xmark")
        for nav in navs {
            let btn = UIBarButtonItem(image: closeImage, style: .plain, target: self, action: #selector(dismissDebugger))
            btn.tintColor = DebugTheme.accentColor
            nav.topViewController?.navigationItem.leftBarButtonItem = btn
        }
    }

    @objc private func dismissDebugger() {
        dismiss(animated: true)
    }

    private func makeNav(root: UIViewController, tabTitle: String, systemImage: String) -> SwiftyDebugNavigationController {
        let nav = SwiftyDebugNavigationController(rootViewController: root)
        let image = UIImage(systemName: systemImage)
        nav.tabBarItem = UITabBarItem(title: tabTitle, image: image, selectedImage: image)
        return nav
    }
}

//MARK: - UITabBarControllerDelegate
extension SwiftyDebugTabBarController: UITabBarControllerDelegate {

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard viewController !== selectedViewController else { return true }
        if let index = viewControllers?.firstIndex(of: viewController) {
            Self.savedTabIndex = index
        }
        let transition = CATransition()
        transition.duration = 0.2
        transition.type = .fade
        view.layer.add(transition, forKey: nil)
        return true
    }
}
