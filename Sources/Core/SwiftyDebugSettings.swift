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

    private override init() {
        shakeGestureEnabled = UserDefaults.standard.bool(forKey: SettingsKey.shakeGestureEnabled.rawValue)
        debugUIVisible = UserDefaults.standard.bool(forKey: SettingsKey.debugUIVisible.rawValue)
        bubbleVisible = UserDefaults.standard.object(forKey: SettingsKey.bubbleVisible.rawValue) == nil
            ? true
            : UserDefaults.standard.bool(forKey: SettingsKey.bubbleVisible.rawValue)
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
