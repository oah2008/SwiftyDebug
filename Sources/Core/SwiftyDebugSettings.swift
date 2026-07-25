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
            let on = consoleLogsEnabled && SwiftyDebug.enableConsoleLog
            PrintInterceptor.shared.enable = on
            // Start/stop the expensive OSLog poll timer + stdout pipe so turning
            // console logs off has (near) zero CPU cost. (See CONSOLE-COST.)
            if on {
                NSLogHook.enableIfNeeded()
            } else {
                NSLogHook.disable()
            }
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

    /// When `true`, shaking to "disable" performs a full stop (see
    /// `SettingsKey.fullStopOnDisable`). Default `false` — legacy behavior where
    /// shake only hides the overlay bubble.
    var fullStopOnDisable: Bool = false {
        didSet { save(.fullStopOnDisable, value: fullStopOnDisable) }
    }

    /// Fixed network-link-conditioner preset applied to every captured request.
    /// `.off` by default.
    var networkConditionerPreset: NetworkConditionerPreset = .off {
        didSet { saveString(.networkConditionerPreset, value: networkConditionerPreset.rawValue) }
    }

    /// Raises host-app request timeouts to `breakpointHoldSeconds` so a paused
    /// request survives long enough to be edited. ON by default — see
    /// `SettingsKey.extendTimeoutsForBreakpoints` for why a breakpoint is
    /// otherwise unusable in an app that sets a short timeout.
    var extendTimeoutsForBreakpoints: Bool = true {
        didSet { save(.extendTimeoutsForBreakpoints, value: extendTimeoutsForBreakpoints) }
    }

    /// Seconds a request may be held at a breakpoint. Default 10 minutes —
    /// long enough to reshape a payload by hand, short enough that a forgotten
    /// breakpoint doesn't wedge the app forever.
    var breakpointHoldSeconds: TimeInterval = 600 {
        didSet { saveDouble(.breakpointHoldSeconds, value: breakpointHoldSeconds) }
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
            ? false
            : ud.bool(forKey: SettingsKey.consoleLogsEnabled.rawValue)
        webLogsEnabled = ud.object(forKey: SettingsKey.webLogsEnabled.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.webLogsEnabled.rawValue)

        // Toggle defaults: OFF
        monitorAllRequests = ud.bool(forKey: SettingsKey.monitorAllRequests.rawValue)
        monitorMediaEnabled = ud.bool(forKey: SettingsKey.monitorMedia.rawValue)

        // Kill-switch behavior: OFF by default (shake only hides overlay)
        fullStopOnDisable = ud.bool(forKey: SettingsKey.fullStopOnDisable.rawValue)

        // Network conditioner: OFF by default
        let presetRaw = ud.string(forKey: SettingsKey.networkConditionerPreset.rawValue) ?? ""
        networkConditionerPreset = NetworkConditionerPreset(rawValue: presetRaw) ?? .off

        // Breakpoint hold: ON by default — a breakpoint that the host app times
        // out from is worse than no breakpoint at all.
        extendTimeoutsForBreakpoints = ud.object(forKey: SettingsKey.extendTimeoutsForBreakpoints.rawValue) == nil
            ? true
            : ud.bool(forKey: SettingsKey.extendTimeoutsForBreakpoints.rawValue)
        let hold = ud.double(forKey: SettingsKey.breakpointHoldSeconds.rawValue)
        breakpointHoldSeconds = hold > 0 ? hold : 600
    }

    // MARK: - Private

    private func save(_ key: SettingsKey, value: Bool) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private func saveString(_ key: SettingsKey, value: String) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private func saveDouble(_ key: SettingsKey, value: Double) {
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
