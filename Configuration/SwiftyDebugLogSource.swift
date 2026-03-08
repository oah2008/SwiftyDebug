//
//  SwiftyDebugLogSource.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

enum SwiftyDebugLogSource: Int {
    case app = 0        // Host app logs (explicit SDK calls + app's own NSLog/print)
    case thirdParty     // Third-party SDK / system framework logs
    case web            // WKWebView console
}
