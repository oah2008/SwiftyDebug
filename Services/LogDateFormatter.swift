//
//  LogDateFormatter.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

/// Stateless date formatting utility for log entries.
enum LogDateFormatter {

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = NSTimeZone.system
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
