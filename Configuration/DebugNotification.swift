//
//  DebugNotification.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

extension Notification.Name {
    static let networkRequestCompleted = Notification.Name("networkRequestCompleted_SwiftyDebug")
    static let logEntriesUpdated = Notification.Name("logEntriesUpdated_SwiftyDebug")
    static let consoleOutputReceived = Notification.Name("consoleOutputReceived_SwiftyDebug")
    static let allLogsCleared = Notification.Name("allLogsCleared_SwiftyDebug")
    static let forceShowDebugger = Notification.Name("forceShowDebugger_SwiftyDebug")
}
