//
//  LogTypeTag.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Display tag for the type of log entry in the UI.
enum LogTypeTag: String {
    case unknown = ""
    case nslog = "NSLog"
    case oslog = "os_log"
    case printLog = "print"
    case console = "console"
    case sdk = "SDK"
    case code = "Code"
}
