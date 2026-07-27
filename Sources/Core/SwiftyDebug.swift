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

    /// Whether SwiftyDebug raises the host app's request timeouts while it is
    /// enabled (default `true`).
    ///
    /// A request paused at a breakpoint delivers no bytes, so the app's own
    /// `timeoutIntervalForRequest` — an *idle* timer — would kill it long before
    /// anyone could read it. To prevent that, the SDK raises request timeouts to
    /// cover the hold budget (10 minutes) app-wide, for every request, whether or
    /// not breakpoints are in use.
    ///
    /// That is a real change to the host app's networking behaviour, so it is
    /// switchable. Set it to `false` if your app depends on its own timeouts —
    /// breakpoints then only survive as long as the app is willing to wait.
    public static var extendTimeoutsForBreakpoints: Bool {
        get { Settings.shared.extendTimeoutsForBreakpoints }
        set { Settings.shared.extendTimeoutsForBreakpoints = newValue }
    }

    public static func enable() {
        initializationMethod()
    }

    public static func disable() {
        deinitializationMethod()
    }
}

// MARK: - Override Swift `print`

public func print<T>(file: String = #file, function: String = #function, line: Int = #line, _ message: T, color: UIColor = .white) {
    // Host stdout always passes through, unchanged.
    Swift.print(message)

    // Skip all SwiftyDebug work (string building, DB writes) when capture is off
    // or the SDK is fully stopped — this is the hot path for a disabled SDK.
    guard SwiftyDebugRuntime.isActive, PrintInterceptor.shared.enable else { return }
    PrintInterceptor.shared.handleLog(file: file, function: function, line: line, message: message, color: color)
}
