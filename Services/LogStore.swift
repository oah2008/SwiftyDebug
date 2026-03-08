//
//  LogStore.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit


class LogStore: NSObject {

    static let shared = LogStore()

    // MARK: - Console (SQLite-backed, no in-memory array)

    /// Database-backed console store
    let consoleDB = ConsoleLogDB.shared

    // MARK: - Third Party & Web (SQLite-backed)

    /// Database-backed store for Third Party + Web log models
    let logModelDB = LogModelDB.shared

    /// Store console entries in SQLite. Call from main thread.
    func appendConsoleLineCache(text: String, color: UIColor = .white) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return }
        let colorCode = (color == .systemRed) ? 1 : 0
        consoleDB.batchInsert(lines: lines.map { (text: $0, colorCode: colorCode) })
    }

    func clearConsole() {
        consoleDB.deleteAll()
    }

    // MARK: - Coalesced refresh notification

    private var refreshScheduled = false

    /// Post logEntriesUpdated_SwiftyDebug at most once per run loop cycle.
    func scheduleRefreshNotification() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            NotificationCenter.default.post(name: .logEntriesUpdated, object: nil)
        }
    }

    // MARK: -

    private override init() {
        super.init()

        // Wire up count-changed callback to post notifications
        consoleDB.onCountChanged = { [weak self] totalCount, insertedCount in
            guard self != nil else { return }
            NotificationCenter.default.post(
                name: .consoleOutputReceived,
                object: nil,
                userInfo: [
                    "totalCount": totalCount,
                    "insertedCount": insertedCount
                ]
            )
        }

        // LogModelDB callback: coalesce refresh notification for Third Party / Web
        logModelDB.onCountChanged = { [weak self] _, _ in
            self?.scheduleRefreshNotification()
        }
    }

    func addLog(_ log: LogRecord) {
        guard log.content is String else { return }

        // Route Third Party and Web logs to SQLite
        if log.logSource == .thirdParty || log.logSource == .web {
            logModelDB.insert(model: log)
        }
        // App-source logs are handled separately via ConsoleLogDB
    }

    func resetWebLogs() {
        logModelDB.deleteAll(source: SwiftyDebugLogSource.web.rawValue)
    }

    /// Remove all logs matching a specific source
    func removeLogsBySource(_ source: SwiftyDebugLogSource) {
        logModelDB.deleteAll(source: source.rawValue)
    }
}
