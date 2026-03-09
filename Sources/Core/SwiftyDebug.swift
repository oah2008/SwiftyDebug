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

    // MARK: - Network Tags

    /// Internal tag storage populated by `addTag(keyword:label:)`.
    static var _tags: [String: String] = [:]

    /// Tag map for the network list. Key = URL keyword (case-insensitive substring),
    /// value = label to display.
    ///
    /// - Note: Prefer using `addTag(keyword:label:)` instead.
    @available(*, deprecated, message: "Use SwiftyDebug.addTag(keyword:label:) instead")
    public static var networkTagMap: [String: String]? {
        get { _tags.isEmpty ? nil : _tags }
        set { _tags = newValue ?? [:] }
    }

    /// Assign a tag label to network requests whose URL contains the given keyword.
    ///
    ///     SwiftyDebug.addTag(keyword: "algolia", label: "Algolia")
    ///     SwiftyDebug.addTag(keyword: "stripe", label: "Payments")
    ///
    /// - Parameters:
    ///   - keyword: A case-insensitive substring to match against request URLs.
    ///   - label: The short label displayed as a pill tag in the network list.
    public static func addTag(keyword: String, label: String) {
        _tags[keyword] = label
    }

    /// Remove a previously added tag by its keyword.
    public static func removeTag(keyword: String) {
        _tags.removeValue(forKey: keyword)
    }

    /// Remove all custom network tags.
    public static func removeAllTags() {
        _tags.removeAll()
    }

    // MARK: - Configuration

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
