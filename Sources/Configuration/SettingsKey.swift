//
//  SettingsKey.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

enum SettingsKey: String {
    case shakeGestureEnabled = "shakeGestureEnabled_SwiftyDebug"
    case debugUIVisible = "debugUIVisible_SwiftyDebug"
    case bubbleVisible = "bubbleVisible_SwiftyDebug"

    case networkRequestsEnabled = "networkRequestsEnabled_SwiftyDebug"
    case webNetworkRequestsEnabled = "webNetworkRequestsEnabled_SwiftyDebug"
    case consoleLogsEnabled = "consoleLogsEnabled_SwiftyDebug"
    case webLogsEnabled = "webLogsEnabled_SwiftyDebug"
    case monitorAllRequests = "monitorAllRequests_SwiftyDebug"
    case monitorMedia = "monitorMedia_SwiftyDebug"

    /// Master kill-switch behavior selector.
    ///
    /// - `false` (default): shaking to "disable" only hides the overlay bubble
    ///   and its particles — capture keeps running (legacy behavior).
    /// - `true`: shaking to "disable" performs a *full stop* — all network
    ///   interception, logging, and swizzled work is gated off so the SDK has
    ///   ~zero CPU cost, as if it were never included.
    case fullStopOnDisable = "fullStopOnDisable_SwiftyDebug"

    /// Network-link-conditioner preset (raw value of `NetworkConditionerPreset`).
    /// Adds a fixed latency to every captured request. Off by default.
    case networkConditionerPreset = "networkConditionerPreset_SwiftyDebug"
}

extension SettingsKey {

    /// Suffix carried by every UserDefaults key SwiftyDebug writes.
    static let ownedKeySuffix = "_SwiftyDebug"

    /// `true` when a UserDefaults key belongs to **SwiftyDebug itself** rather
    /// than the host app.
    ///
    /// The SDK is embedded in the host app, so its own settings land in the
    /// host app's defaults domain. The UserDefaults inspector hides these so you
    /// only see your app's data — not the debugger's. Matching is by the shared
    /// suffix *and* the known cases, so a renamed case can't silently leak.
    static func isSDKOwned(_ key: String) -> Bool {
        if key.hasSuffix(ownedKeySuffix) { return true }
        return allKnownRawValues.contains(key)
    }

    private static let allKnownRawValues: Set<String> = {
        Set([
            SettingsKey.shakeGestureEnabled, .debugUIVisible, .bubbleVisible,
            .networkRequestsEnabled, .webNetworkRequestsEnabled, .consoleLogsEnabled,
            .webLogsEnabled, .monitorAllRequests, .monitorMedia,
            .fullStopOnDisable, .networkConditionerPreset,
        ].map { $0.rawValue })
    }()
}
