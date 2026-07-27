//
//  SwiftyDebug+Lifecycle.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

extension SwiftyDebug {

    static func initializationMethod() {
        Settings.shared.bubbleVisible = true
        Settings.shared.debugUIVisible = false
        Settings.shared.shakeGestureEnabled = true

        _ = LogStore.shared

        // Sweep the previous session's captured bodies BEFORE anything can be
        // captured, then force the store into existence so nothing later can
        // trigger a lazy init that wipes live files. Order matters: this must
        // stay ahead of `NetworkMonitor.shared.enable()` below, which registers
        // the URLProtocol and opens the door to captures.
        NetworkTransaction.clearDiskCache()
        _ = NetworkRequestStore.shared

        // Apply persisted toggle states
        let settings = Settings.shared
        SwiftyDebug.monitorAllUrls = settings.monitorAllRequests
        SwiftyDebug.monitorMedia = settings.monitorMediaEnabled
        PrintInterceptor.shared.enable = SwiftyDebug.enableConsoleLog && settings.consoleLogsEnabled

        NSLogHook.enableIfNeeded()
        WKWebViewSwizzling.enableIfNeeded()
        CustomHTTPProtocol.swizzleSessionConfiguration()

        NetworkMonitor.shared.enable()

        // Surface paused requests over the host app — a held request otherwise
        // looks like the app has hung. (See BREAKPOINTS.)
        BreakpointOverlay.shared.start()
    }

    static func deinitializationMethod() {
        DebugWindowPresenter.shared.disable()
        NetworkMonitor.shared.disable()
        PrintInterceptor.shared.enable = false
        Settings.shared.shakeGestureEnabled = false
    }

    // MARK: - Full stop / resume (kill-switch)

    /// Completely stops all SDK work at runtime: network interception, log
    /// capture, OSLog polling, and webview JS hooks all become no-ops. The
    /// swizzles remain installed (un-swizzling is unsafe) but every hot path
    /// consults `SwiftyDebugRuntime.isActive` and short-circuits, so the SDK
    /// costs ~zero CPU — as if it were never included. Reverses with
    /// `resumeFromFullStop()`.
    static func fullStop() {
        // Flip the global gate first so in-flight hot paths stop doing work
        // immediately.
        SwiftyDebugRuntime.markStopped()

        // Release anything paused at a breakpoint FIRST — a stopped SDK must
        // never leave the host app with permanently stuck requests.
        BreakpointCenter.shared.resumeAll()
        BreakpointOverlay.shared.stop()

        // Stop native network interception (unregisters the URLProtocol; the
        // runtime gate in canInit is the real backstop for already-created
        // sessions).
        NetworkMonitor.shared.disable()

        // Tear down log capture: restore stdout, cancel the OSLog poll timer,
        // drop the pipe handler, and mute the print interceptor.
        NSLogHook.disable()
        PrintInterceptor.shared.enable = false

        // Tell every live WKWebView's injected JS to stop capturing/intercepting.
        WKWebViewSwizzling.pushEnabledStateToWebViews(enabled: false)

        // Hide the overlay (bubble + particles). Visibility is also set by the
        // shake handler, but do it here too so programmatic callers get the full
        // effect.
        Settings.shared.bubbleVisible = false
    }

    /// Reverses `fullStop()` — re-enables all capture via the runtime gates
    /// (nothing is re-swizzled).
    static func resumeFromFullStop() {
        SwiftyDebugRuntime.markActive()

        NetworkMonitor.shared.enable()

        // Restore log capture, honoring the user's per-source toggles.
        NSLogHook.enableIfNeeded()
        PrintInterceptor.shared.enable = SwiftyDebug.enableConsoleLog && Settings.shared.consoleLogsEnabled

        WKWebViewSwizzling.pushEnabledStateToWebViews(enabled: true)
        BreakpointOverlay.shared.start()

        Settings.shared.bubbleVisible = true
    }
}
