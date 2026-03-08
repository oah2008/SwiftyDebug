//
//  SwiftyDebug.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

public class SwiftyDebug {

    /// URLs to monitor. When non-empty and `monitorAllUrls` is false, only requests
    /// matching these URLs are captured (case-insensitive substring match).
    public static var urls: [String] = []

    /// Tag map for the network list. Key = URL keyword (case-insensitive substring),
    /// value = label to display. e.g. `["algolia": "Algolia"]`
    public static var networkTagMap: [String: String]?

    /// Capture all network requests regardless of `urls`.
    public static var monitorAllUrls = false

    /// Capture media requests (images, video, audio, fonts).
    public static var monitorMedia = false

    /// Capture console logs.
    public static var enableConsoleLog = true

    public static func enable() {
        initializationMethod()
    }

    public static func disable() {
        deinitializationMethod()
    }
}

// MARK: - Override Swift `print`

public func print<T>(file: String = #file, function: String = #function, line: Int = #line, _ message: T, color: UIColor = .white) {
    Swift.print(message)
    PrintInterceptor.shared.handleLog(file: file, function: function, line: line, message: message, color: color)
}
