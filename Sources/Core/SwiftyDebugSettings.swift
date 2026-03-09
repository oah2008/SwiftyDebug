//
//  Settings.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

class Settings: NSObject {

    static let shared = Settings()

    var shakeGestureEnabled: Bool = false {
        didSet { save(.shakeGestureEnabled, value: shakeGestureEnabled) }
    }

    var debugUIVisible: Bool = false {
        didSet { save(.debugUIVisible, value: debugUIVisible) }
    }

    var bubbleVisible: Bool = false {
        didSet {
            save(.bubbleVisible, value: bubbleVisible)
            updateBubblePresentation()
        }
    }

    var networkRequestsEnabled: Bool = true {
        didSet { save(.networkRequestsEnabled, value: networkRequestsEnabled) }
    }

    var webNetworkRequestsEnabled: Bool = true {
        didSet { save(.webNetworkRequestsEnabled, value: webNetworkRequestsEnabled) }
    }

    var consoleLogsEnabled: Bool = true {
        didSet {
            save(.consoleLogsEnabled, value: consoleLogsEnabled)
            PrintInterceptor.shared.enable = consoleLogsEnabled && SwiftyDebug.enableConsoleLog
        }
    }

    var webLogsEnabled: Bool = true {
        didSet { save(.webLogsEnabled, value: webLogsEnabled) }
    }

    var monitorAllRequests: Bool = false {
        didSet {
            save(.monitorAllRequests, value: monitorAllRequests)
            SwiftyDebug.monitorAllUrls = monitorAllRequests
        }
    }

    var monitorMediaEnabled: Bool = false {
        didSet {
            save(.monitorMedia, value: monitorMediaEnabled)
            SwiftyDebug.monitorMedia = monitorMediaEnabled
        }
    }

    private override init() {
        let ud = UserDefaults.standard

        shakeGestureEnabled = ud.bool(forKey: SettingsKey.shakeGestureEnabled.rawValue)
        debugUIVisible = ud.bool(forKey: SettingsKey.debugUIVisible.rawValue)
        bubbleVisible = ud.object(forKey: SettingsKey.bubbleVisible.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.bubbleVisible.rawValue)

        // Toggle defaults: ON unless explicitly set to false
        networkRequestsEnabled = ud.object(forKey: SettingsKey.networkRequestsEnabled.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.networkRequestsEnabled.rawValue)
        webNetworkRequestsEnabled = ud.object(forKey: SettingsKey.webNetworkRequestsEnabled.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.webNetworkRequestsEnabled.rawValue)
        consoleLogsEnabled = ud.object(forKey: SettingsKey.consoleLogsEnabled.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.consoleLogsEnabled.rawValue)
        webLogsEnabled = ud.object(forKey: SettingsKey.webLogsEnabled.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.webLogsEnabled.rawValue)

        // Toggle defaults: OFF
        monitorAllRequests = ud.bool(forKey: SettingsKey.monitorAllRequests.rawValue)
        monitorMediaEnabled = ud.bool(forKey: SettingsKey.monitorMedia.rawValue)
    }

    // MARK: - Private

    private func save(_ key: SettingsKey, value: Bool) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private func updateBubblePresentation() {
        let presenter = DebugWindowPresenter.shared
        let bubble = presenter.vc.bubble
        let screenWidth = UIScreen.main.bounds.size.width
        let bubbleWidth = bubble.frame.size.width
        let isOnRightSide = bubble.frame.origin.x > screenWidth / 2
        let visibleOffset = bubbleWidth / 8 * 8.25

        if bubbleVisible {
            bubble.frame.origin.x = isOnRightSide
                ? screenWidth - visibleOffset
                : -bubbleWidth + visibleOffset
            presenter.enable()
        } else {
            bubble.frame.origin.x = isOnRightSide
                ? screenWidth
                : -bubbleWidth
            presenter.disable()
        }
    }
}
