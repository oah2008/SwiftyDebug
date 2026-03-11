//
//  AppDelegate.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyDebug

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.monitorMedia = true
        SwiftyDebug.enableConsoleLog = true

        SwiftyDebug.addTag(keyword: "jsonplaceholder", label: "Posts API")
        SwiftyDebug.addTag(keyword: "pokeapi", label: "PokeAPI")
        SwiftyDebug.addTag(keyword: "PokeAPI/sprites", label: "Sprites")

        SwiftyDebug.enable()

        Logger.debug("SwiftyDebug Demo launched")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
