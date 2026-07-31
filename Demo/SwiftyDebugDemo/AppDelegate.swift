//
//  AppDelegate.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
#if DEBUG
import SwiftyDebug
#endif

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // SwiftyDebug is a debug-only tool. The Podfile already limits the pod to
        // the Debug configuration (`:configurations => ['Debug']`); this guard is
        // the second half of that — it keeps the demo compiling in Release, where
        // the pod is not linked at all.
        #if DEBUG
        // Configure BEFORE enable(). Everything assigned here is read by
        // enable() and wins over the App-tab toggles persisted by the previous
        // launch, so this block behaves identically on every launch.
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.monitorMedia = true
        SwiftyDebug.enableConsoleLog = true

        SwiftyDebug.addTag(keyword: "jsonplaceholder", label: "Posts API")
        SwiftyDebug.addTag(keyword: "pokeapi", label: "PokeAPI")
        SwiftyDebug.addTag(keyword: "PokeAPI/sprites", label: "Sprites")

        SwiftyDebug.enable()
        #endif

        Logger.debug("SwiftyDebug Demo launched")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
