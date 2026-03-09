//
//  SwiftyDebug+Lifecycle.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

extension SwiftyDebug {

    static func initializationMethod() {
        Settings.shared.bubbleVisible = true
        Settings.shared.debugUIVisible = false
        Settings.shared.shakeGestureEnabled = true

        _ = LogStore.shared

        // Apply persisted toggle states
        let settings = Settings.shared
        SwiftyDebug.monitorAllUrls = settings.monitorAllRequests
        SwiftyDebug.monitorMedia = settings.monitorMediaEnabled
        PrintInterceptor.shared.enable = SwiftyDebug.enableConsoleLog && settings.consoleLogsEnabled

        NSLogHook.enableIfNeeded()
        WKWebViewSwizzling.enableIfNeeded()
        CustomHTTPProtocol.swizzleSessionConfiguration()

        NetworkMonitor.shared.enable()
    }

    static func deinitializationMethod() {
        DebugWindowPresenter.shared.disable()
        NetworkMonitor.shared.disable()
        PrintInterceptor.shared.enable = false
        Settings.shared.shakeGestureEnabled = false
    }
}
