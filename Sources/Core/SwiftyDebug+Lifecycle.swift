//
//  SwiftyDebug+Lifecycle.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

extension SwiftyDebug {

    static func initializationMethod() {
        // FIRST, before anything else reads the gate. `fullStop()` flips an
        // atomic kill-switch that every hot path consults, and `enable()` used
        // not to clear it — so calling `enable()` after a full stop produced a
        // fully navigable UI that captured nothing, polled no logs and hooked no
        // web views, with no public API able to undo it. Everything below
        // (`NSLogHook.enableIfNeeded()`, `CustomHTTPProtocol.canInit`, the
        // web-view push) short-circuits while the gate is closed, so this has to
        // be statement one.
        activateRuntimeForEnable()

        Settings.shared.bubbleVisible = true
        Settings.shared.debugUIVisible = false
        Settings.shared.shakeGestureEnabled = true

        _ = LogStore.shared

        // Sweep the previous session's captured bodies BEFORE anything can be
        // captured, then force the store into existence so nothing later can
        // trigger a lazy init that wipes live files. Order matters: this must
        // stay ahead of `NetworkMonitor.shared.enable()` below, which registers
        // the URLProtocol and opens the door to captures.
        sweepPreviousSessionBodiesIfNeeded()
        _ = NetworkRequestStore.shared

        // Reconcile the host app's pre-enable assignments with the persisted
        // App-tab toggles. See `applyMonitorFlags(from:)` — the host app wins.
        let settings = Settings.shared
        applyMonitorFlags(from: settings)
        PrintInterceptor.shared.enable = SwiftyDebug.enableConsoleLog && settings.consoleLogsEnabled

        NSLogHook.enableIfNeeded()
        WKWebViewSwizzling.enableIfNeeded()
        CustomHTTPProtocol.swizzleSessionConfiguration()

        NetworkMonitor.shared.enable()

        // Re-arm capture in web views that already exist. A no-op on a first
        // `enable()` (nothing is tracked yet); it matters after a `fullStop()`,
        // which told every live web view's injected JS to stop capturing.
        WKWebViewSwizzling.pushEnabledStateToWebViews(enabled: true)

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

    // MARK: - Runtime gate

    /// Clears a previous `fullStop()` so `enable()` genuinely re-enables the SDK.
    ///
    /// Must stay the first statement of `initializationMethod()`: every capture
    /// path in the SDK is gated on `SwiftyDebugRuntime.isActive` and silently
    /// does nothing while the gate is closed, including
    /// `NSLogHook.enableIfNeeded()` and `CustomHTTPProtocol.canInit(with:)`.
    ///
    /// Split out from `initializationMethod()` so the guarantee is testable
    /// without standing up a `UIWindow` or registering the URLProtocol.
    static func activateRuntimeForEnable() {
        SwiftyDebugRuntime.markActive()
    }

    // MARK: - Previous-session sweep

    /// `true` once this process has swept the previous session's captured bodies.
    ///
    /// Process-scoped on purpose — see `sweepPreviousSessionBodiesIfNeeded()`.
    private(set) static var didSweepPreviousSessionBodies = false

    /// Deletes the bodies left on disk by the *previous* run of the host app —
    /// exactly once per process, no matter how many times `enable()` is called.
    ///
    /// This used to run on every `enable()`. `enable()` is not rare-by-contract:
    /// a re-entrant setup path, a second scene connecting, or a host app that
    /// simply calls it again all reach it. The second call deleted every body
    /// captured since the first one straight off disk while the matching rows
    /// stayed in the in-memory list — so every request in the UI rendered with an
    /// empty body and no explanation. Sweeping stale bodies is a *startup*
    /// concern; it is not what "enable" means.
    ///
    /// - Parameter sweep: seam for tests. Defaults to the real disk sweep.
    /// - Note: Call on the main thread, like the rest of `enable()`. The one-shot
    ///   flag is deliberately unsynchronized because the lifecycle API is
    ///   documented main-thread-only.
    static func sweepPreviousSessionBodiesIfNeeded(
        sweep: () -> Void = NetworkTransaction.clearDiskCache
    ) {
        guard !didSweepPreviousSessionBodies else { return }
        didSweepPreviousSessionBodies = true
        sweep()
    }

    // MARK: - Monitor flags

    /// Reconciles `SwiftyDebug.monitorAllUrls` / `SwiftyDebug.monitorMedia` with
    /// the App-tab toggles persisted by the previous launch.
    ///
    /// The documented contract — the README quick start, the demo app, and the
    /// obvious shape of a `public static var` — is that assigning these *before*
    /// `enable()` works:
    ///
    ///     SwiftyDebug.monitorAllUrls = true
    ///     SwiftyDebug.enable()
    ///
    /// `enable()` used to overwrite both flags from `Settings` unconditionally,
    /// so from the second launch onward the host app's assignment was silently
    /// discarded and the quick start captured nothing.
    ///
    /// Resolution, per flag:
    ///
    /// * The host app asked for capture (`true`) → capture, and write that choice
    ///   back into `Settings` so the App-tab toggle reflects reality instead of
    ///   showing an OFF switch sitting over a live capture.
    /// * The host app left the flag at its `false` default → the persisted
    ///   App-tab toggle decides, so a toggle switched on last launch is still on.
    ///
    /// The App-tab toggles keep working at runtime in both cases: they write
    /// through to these flags immediately (see `Settings.monitorAllRequests`).
    ///
    /// - Important: **An explicit `= false` cannot be told apart from "never
    ///   assigned."** Both are plain `public static var`s with no setter hook, so
    ///   both leave the flag at its compile-time default of `false`. Writing
    ///   `SwiftyDebug.monitorMedia = false` therefore does *not* force off a
    ///   toggle the user switched on from the App tab — it only declines to force
    ///   it on. Switch it off from the App tab, or leave it off there. Removing
    ///   this caveat requires a `didSet` on the two properties in `SwiftyDebug`.
    static func applyMonitorFlags(from settings: Settings) {
        if SwiftyDebug.monitorAllUrls {
            settings.monitorAllRequests = true
        } else {
            SwiftyDebug.monitorAllUrls = settings.monitorAllRequests
        }

        if SwiftyDebug.monitorMedia {
            settings.monitorMediaEnabled = true
        } else {
            SwiftyDebug.monitorMedia = settings.monitorMediaEnabled
        }
    }

    // MARK: - Full stop / resume (kill-switch)

    /// Completely stops all SDK work at runtime: network interception, log
    /// capture, OSLog polling, and webview JS hooks all become no-ops. The
    /// swizzles remain installed (un-swizzling is unsafe) but every hot path
    /// consults `SwiftyDebugRuntime.isActive` and short-circuits, so the SDK
    /// costs ~zero CPU — as if it were never included. Reverses with
    /// `resumeFromFullStop()`, or with `SwiftyDebug.enable()`.
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
