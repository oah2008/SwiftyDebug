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
    /// enabled. **Default `false`** — enabling the SDK no longer changes your
    /// app's networking behaviour.
    ///
    /// While `false`, every `timeoutIntervalForRequest` your app sets is passed
    /// through untouched, and a request paused at a breakpoint survives only as
    /// long as your app is willing to wait for it.
    ///
    /// What turning it on costs: `timeoutIntervalForRequest` is an *idle* timer,
    /// and a paused request delivers no bytes, so a short app timeout kills the
    /// request before you can finish editing it. To prevent that, the SDK raises
    /// request timeouts app-wide to the breakpoint hold budget
    /// (`Settings.breakpointHoldSeconds`, 10 minutes by default) — **for every
    /// request, whether or not breakpoints are in use**. Any code of yours that
    /// depends on a request failing fast (retry ladders, "poor connection"
    /// banners, watchdogs) will stop firing. It is a debugging aid; leave it off
    /// unless you are actually pausing requests.
    ///
    /// Setting this does not retroactively change `URLSession`s that already
    /// exist — see `setExtendTimeoutsForBreakpoints(_:)` and
    /// `extendTimeoutsChangeEffect`.
    public static var extendTimeoutsForBreakpoints: Bool {
        get { Settings.shared.extendTimeoutsForBreakpoints }
        set { Settings.shared.extendTimeoutsForBreakpoints = newValue }
    }

    /// How far a change to `extendTimeoutsForBreakpoints` can reach right now.
    ///
    /// A `URLSession` copies its `URLSessionConfiguration` when it is created, so
    /// the request timeout is frozen into every session at *its* creation time.
    /// Flipping the setting therefore only governs sessions built afterwards.
    public enum TimeoutChangeEffect: Equatable {

        /// Nothing was built under the old value, so the next request already
        /// behaves the new way. No restart, no prompt.
        case appliesImmediately

        /// At least one `URLSessionConfiguration` already had its timeout decided
        /// under the old value. Sessions built from it — typically the app's
        /// long-lived API session, created at launch — keep that timeout until
        /// the process restarts. Sessions created from now on use the new value.
        case restartRequiredForExistingSessions

        /// `true` when the UI should offer a restart prompt.
        public var requiresRestart: Bool { self == .restartRequiredForExistingSessions }

        /// Ready-to-display explanation, so callers don't have to invent one.
        public var message: String {
            switch self {
            case .appliesImmediately:
                return "This takes effect right away."
            case .restartRequiredForExistingSessions:
                return "New network sessions use this immediately. Sessions your app "
                     + "already created keep the timeout they were built with — "
                     + "restart the app to apply it everywhere."
            }
        }
    }

    /// What would happen if `extendTimeoutsForBreakpoints` were changed right
    /// now, without changing it. Use this to decide whether to warn *before*
    /// showing a confirmation.
    public static var extendTimeoutsChangeEffect: TimeoutChangeEffect {
        return effect(from: CustomHTTPProtocol.timeoutSettingChangeEffect)
    }

    /// Sets `extendTimeoutsForBreakpoints` and reports how far the change
    /// reached, so a "restart the app?" prompt is only shown when a restart is
    /// genuinely required.
    ///
    /// Setting it to the value it already has is a no-op and always reports
    /// `.appliesImmediately`.
    @discardableResult
    public static func setExtendTimeoutsForBreakpoints(_ enabled: Bool) -> TimeoutChangeEffect {
        guard Settings.shared.extendTimeoutsForBreakpoints != enabled else {
            return .appliesImmediately
        }
        Settings.shared.extendTimeoutsForBreakpoints = enabled
        return extendTimeoutsChangeEffect
    }

    private static func effect(
        from internalEffect: CustomHTTPProtocol.TimeoutSettingChangeEffect
    ) -> TimeoutChangeEffect {
        switch internalEffect {
        case .appliesImmediately: return .appliesImmediately
        case .restartRequiredForExistingSessions: return .restartRequiredForExistingSessions
        }
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
