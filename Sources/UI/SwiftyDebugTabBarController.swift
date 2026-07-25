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

    /// A screen to jump to as soon as the tab bar appears (used by the paused
    /// request overlay so one tap lands directly on the editor).
    enum InitialScreen { case breakpointInbox }
    var pendingInitialScreen: InitialScreen?

    /// Pushes the paused-requests inbox on the Network tab.
    func showBreakpointInbox() {
        // Network tab hosts the inbox.
        selectedIndex = 0
        guard let nav = viewControllers?.first as? UINavigationController else { return }
        // Don't stack duplicates.
        if nav.viewControllers.contains(where: { $0 is BreakpointInboxViewController }) { return }
        nav.pushViewController(BreakpointInboxViewController(), animated: true)
    }

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
        // The inbox is reachable from in here — no need for the banner on top.
        BreakpointOverlay.shared.refreshVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingInitialScreen == .breakpointInbox {
            pendingInitialScreen = nil
            showBreakpointInbox()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only mark the debug UI hidden when it's genuinely going away — not
        // when it's merely covered by a modal we presented ourselves.
        guard presentedViewController == nil else { return }
        Settings.shared.debugUIVisible = false
        // Back in the host app — re-show the banner if anything is still held.
        BreakpointOverlay.shared.refreshVisibility()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // CRITICAL: `displayedList` gates `SwiftyDebugWindow.point(inside:)` —
        // when false the overlay window only accepts touches inside the bubble.
        // Presenting a full-screen modal from inside the debug UI (e.g. the
        // media viewer) fires viewDidDisappear here; clearing the flag then made
        // the window swallow every touch in that modal, so its buttons appeared
        // dead. Keep the gate open while we still have something presented.
        guard presentedViewController == nil else { return }
        DebugWindowPresenter.shared.displayedList = false
    }
    
    //MARK: - private
    func setChildControllers() {
        let network = makeNav(root: NetworkViewController(),  tabTitle: "Network", systemImage: "arrow.up.arrow.down")
        let logs    = makeNav(root: LogViewController(),      tabTitle: "Logs",    systemImage: "doc.text")
        let media   = makeNav(root: MediaTabViewController(), tabTitle: "Media",   systemImage: "photo.on.rectangle")
        let app     = makeNav(root: AppInfoViewController(),  tabTitle: "App",     systemImage: "info.circle")

        let navs: [UINavigationController] = [network, logs, media, app]

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
