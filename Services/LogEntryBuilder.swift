//
//  LogEntryBuilder.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

/// Stateless utility for constructing log entries.
enum LogEntryBuilder {

    private static func parseFileInfo(file: String, function: String, line: Int) -> String {
        if file == "XXX" && function == "XXX" && line == 1 {
            return "XXX|XXX|1"
        }

        if line == 0 { // web
            let fileName = file.components(separatedBy: "/").last ?? ""
            return "\(fileName) \(function)\n"
        }

        let fileName = file.components(separatedBy: "/").last ?? ""
        return "\(fileName)[\(line)]\(function)\n"
    }

    static func handleLog(file: String, function: String, line: Int, message: String, color: UIColor, type: SwiftyDebugToolType) {
        let fileInfo = parseFileInfo(file: file, function: function, line: line)

        let newLog = LogRecord(content: message, color: color, fileInfo: fileInfo, isTag: false, type: type)

        // Set logSource, sourceName, and logTypeTag based on call context
        if file == "[WKWebView]" {
            newLog.logSource = .web
            newLog.sourceName = "console.\(function)"
            newLog.logTypeTag = .console
        } else if file == "XXX" && function == "XXX" && line == 1 {
            newLog.logSource = .app
            newLog.logTypeTag = .sdk
        } else {
            newLog.logSource = .app
            newLog.logTypeTag = .code
            let fileName = file.components(separatedBy: "/").last ?? ""
            if !fileName.isEmpty {
                newLog.sourceName = fileName
            }
        }

        LogStore.shared.addLog(newLog)

        // Send to Console tab for app-source entries
        if newLog.logSource == .app {
            let timeStr = LogCell.formatTime(newLog.date ?? Date())
            let text = "[\(timeStr)] \(message)\n"
            LogStore.shared.appendConsoleLineCache(text: text, color: newLog.color ?? .white)
        }

        LogStore.shared.scheduleRefreshNotification()
    }
}
