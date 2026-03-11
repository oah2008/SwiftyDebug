//
//  MainTabBarController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

final class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let feed    = makeNav(FeedViewController(),     title: "Posts",   icon: "doc.text.fill")
        let pokemon = makeNav(PokemonViewController(),  title: "Pokemon", icon: "star.circle.fill")
        let info    = makeNav(DemoInfoViewController(), title: "Setup",   icon: "info.circle.fill")

        viewControllers = [feed, pokemon, info]
        tabBar.tintColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        tabBar.backgroundColor = .systemBackground
    }

    private func makeNav(_ root:UIViewController, title:String, icon:String) -> UINavigationController {
        root.title = title
        root.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), tag: 0)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }
}
