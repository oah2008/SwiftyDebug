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
}
