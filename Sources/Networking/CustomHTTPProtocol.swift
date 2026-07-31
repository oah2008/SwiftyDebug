//
//  CustomHTTPProtocol.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

// MARK: - BlockBox

/// A simple wrapper so we can pass a closure through `perform(_:on:with:waitUntilDone:modes:)`,
/// which requires an `AnyObject` argument.
private class CPBlockBox: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

// MARK: - CPURLSessionChallengeSender

// https://stackoverflow.com/questions/27604052/nsurlsessiontask-authentication-challenge-completionhandler-and-nsurlauthenticat
@objc private class CPURLSessionChallengeSender: NSObject, URLAuthenticationChallengeSender {

    private let sessionCompletionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    init(sessionCompletionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.sessionCompletionHandler = sessionCompletionHandler
        super.init()
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.useCredential, credential)
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.useCredential, nil)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.cancelAuthenticationChallenge, nil)
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.performDefaultHandling, nil)
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.rejectProtectionSpace, nil)
    }
}

// MARK: - Session Configuration Swizzling

/// Store original IMP pointers for session configuration class methods.
private var orig_defaultSessionConfiguration: IMP?
private var orig_ephemeralSessionConfiguration: IMP?
/// Store original IMP for protocolClasses getter.
private var orig_protocolClassesGetter: IMP?
/// Store original IMP for the request-timeout setter.
private var orig_setTimeoutIntervalForRequest: IMP?

/// Type alias for the original session configuration constructor.
private typealias SessionConfigConstructor = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
/// Type alias for the protocolClasses getter.
private typealias ProtocolClassesGetterFunc = @convention(c) (AnyObject, Selector) -> NSArray?
/// Type alias for `-[NSURLSessionConfiguration setTimeoutIntervalForRequest:]`.
private typealias TimeoutSetterFunc = @convention(c) (AnyObject, Selector, TimeInterval) -> Void

// MARK: - CustomHTTPProtocolDelegate

@objc protocol CustomHTTPProtocolDelegate: NSObjectProtocol {

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           canAuthenticateAgainstProtectionSpace protectionSpace: URLProtectionSpace) -> Bool

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge)

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           didCancelAuthenticationChallenge challenge: URLAuthenticationChallenge)

}

// MARK: - CustomHTTPProtocol

@objc class CustomHTTPProtocol: URLProtocol {

    // MARK: Class-level delegate storage

    private static var sDelegate: CustomHTTPProtocolDelegate?

    @objc static func start() {
        URLProtocol.registerClass(self)
    }

    @objc static func stop() {
        URLProtocol.unregisterClass(self)
    }

    @objc static func getDelegate() -> CustomHTTPProtocolDelegate? {
        var result: CustomHTTPProtocolDelegate?
        objc_sync_enter(self)
        result = sDelegate
        objc_sync_exit(self)
        return result
    }

    @objc static func setDelegate(_ newValue: CustomHTTPProtocolDelegate?) {
        objc_sync_enter(self)
        sDelegate = newValue
        objc_sync_exit(self)
    }

    // MARK: Shared demux (lazily created once)

    private static var sharedDemuxInstance: QNSURLSessionDemux?
    /// True while SwiftyDebug builds its OWN session configuration. Timeout
    /// decisions taken during that window are not host-app decisions, so they must
    /// not count toward "does flipping the setting need a restart?" — otherwise the
    /// SDK's own 60-second demux config trips the check on the very first request
    /// and the answer is always "restart required".
    ///
    /// Stored per-thread, not in a shared static Bool. It is written on whichever
    /// thread happens to run `demuxOnce` (a CFNetwork thread, inside swift_once)
    /// and read by `recordTimeoutDecision` from host-app threads: a plain static
    /// is a data race Thread Sanitizer reports against the SDK, and it is also
    /// wrong — a host config built on another thread during that window would be
    /// misfiled as ours. The flag only ever means "the configuration being built
    /// on THIS thread, right now, is ours", so that is exactly what it stores.
    private static let buildingOwnConfigurationKey =
        "com.swiftydebug.CustomHTTPProtocol.buildingOwnConfiguration"

    private static var isBuildingOwnConfiguration: Bool {
        get { (Thread.current.threadDictionary[buildingOwnConfigurationKey] as? Bool) ?? false }
        set {
            if newValue {
                Thread.current.threadDictionary[buildingOwnConfigurationKey] = true
            } else {
                Thread.current.threadDictionary.removeObject(forKey: buildingOwnConfigurationKey)
            }
        }
    }

    /// The transport settings on the demux session that are, in effect, the
    /// HOST APP's settings — because every request the app makes is re-issued
    /// through this one session. Captured so tests can prove SwiftyDebug left
    /// them exactly as `URLSessionConfiguration.default` produced them.
    ///
    /// The same type also carries the settings read back off a HOST session's
    /// configuration (see `hostTransportSettings(for:)`), because the fix for
    /// "one shared session speaks for every app session" is to MIRROR the
    /// originating configuration rather than impose either SwiftyDebug's tuning
    /// or Foundation's defaults. Same fields, read from the other direction.
    struct DemuxTransportSettings: Equatable {
        var httpShouldSetCookies: Bool
        var httpMaximumConnectionsPerHost: Int
        var requestCachePolicy: URLRequest.CachePolicy
        var allowsCellularAccess: Bool
        var httpShouldUsePipelining: Bool
        var httpCookieAcceptPolicy: HTTPCookie.AcceptPolicy
        /// Reference, not value: two configurations pointing at the SAME jar are
        /// interchangeable, two pointing at different jars never are. `nil` means
        /// the app turned cookie storage off entirely.
        var httpCookieStorage: HTTPCookieStorage?
        var urlCredentialStorage: URLCredentialStorage?

        init(_ config: URLSessionConfiguration) {
            httpShouldSetCookies = config.httpShouldSetCookies
            httpMaximumConnectionsPerHost = config.httpMaximumConnectionsPerHost
            requestCachePolicy = config.requestCachePolicy
            allowsCellularAccess = config.allowsCellularAccess
            httpShouldUsePipelining = config.httpShouldUsePipelining
            httpCookieAcceptPolicy = config.httpCookieAcceptPolicy
            httpCookieStorage = config.httpCookieStorage
            urlCredentialStorage = config.urlCredentialStorage
        }

        static func == (lhs: DemuxTransportSettings, rhs: DemuxTransportSettings) -> Bool {
            lhs.httpShouldSetCookies == rhs.httpShouldSetCookies
                && lhs.httpMaximumConnectionsPerHost == rhs.httpMaximumConnectionsPerHost
                && lhs.requestCachePolicy == rhs.requestCachePolicy
                && lhs.allowsCellularAccess == rhs.allowsCellularAccess
                && lhs.httpShouldUsePipelining == rhs.httpShouldUsePipelining
                && lhs.httpCookieAcceptPolicy == rhs.httpCookieAcceptPolicy
                && lhs.httpCookieStorage === rhs.httpCookieStorage
                && lhs.urlCredentialStorage === rhs.urlCredentialStorage
        }

        /// The subset that CANNOT be expressed on a `URLRequest`, and therefore
        /// decides WHICH session a request has to be issued on. See
        /// `DemuxSessionSignature`.
        var sessionSignature: DemuxSessionSignature {
            DemuxSessionSignature(
                httpMaximumConnectionsPerHost: httpMaximumConnectionsPerHost,
                httpCookieAcceptPolicy: httpCookieAcceptPolicy,
                cookieStorage: httpCookieStorage.map(ObjectIdentifier.init),
                credentialStorage: urlCredentialStorage.map(ObjectIdentifier.init))
        }
    }

    /// Identity of a demux session.
    ///
    /// `URLRequest` can express a cache policy, a cookie opt-out, cellular access
    /// and pipelining, so those four ride along on each forwarded request. It
    /// **cannot** express a connection cap, a cookie jar, a credential store or a
    /// cookie accept policy — those are properties of the connection pool and of
    /// the session, so the only way to honour the host app's is to issue its
    /// requests on a session that was built with them. One session per distinct
    /// signature, created on demand and cached.
    struct DemuxSessionSignature: Hashable {
        var httpMaximumConnectionsPerHost: Int
        var httpCookieAcceptPolicy: HTTPCookie.AcceptPolicy
        var cookieStorage: ObjectIdentifier?
        var credentialStorage: ObjectIdentifier?
    }

    /// What `URLSessionConfiguration.default` handed us, before SwiftyDebug
    /// touched the configuration at all. nil until `demuxOnce` has run.
    private(set) static var systemDefaultTransportSettings: DemuxTransportSettings?
    /// What the demux session was actually built with. Must equal
    /// `systemDefaultTransportSettings` — see the comment in `demuxOnce`.
    private(set) static var demuxTransportSettings: DemuxTransportSettings?

    private static let demuxOnce: Void = {
        isBuildingOwnConfiguration = true
        defer { isBuildingOwnConfiguration = false }
        let config = URLSessionConfiguration.default
        systemDefaultTransportSettings = DemuxTransportSettings(config)

        // DO NOT TUNE THIS SESSION.
        //
        // Every request the host app makes is re-issued through this one shared
        // session, so a transport setting here is not SwiftyDebug's setting —
        // it silently becomes the host app's. Three used to be set here, and all
        // three were measured regressions in any app that merely LINKS the SDK:
        //
        //  • `httpShouldSetCookies = false` stripped Cookie from every request
        //    and left `HTTPCookieStorage.shared.cookies` empty, so cookie-session
        //    logins stopped working outright. Its only conceivable purpose was to
        //    avoid double-applying cookies, but nothing double-applies them: the
        //    request reaches `startLoading` BEFORE CFNetwork's HTTP protocol has
        //    attached any, so this session is the only place they can be added.
        //  • `httpMaximumConnectionsPerHost = 1` serialised all traffic to a host.
        //    Its comment claimed it "reduced connection overhead"; measured, six
        //    concurrent 300 ms GETs took 1.87 s instead of 0.31 s.
        //  • `requestCachePolicy = .reloadIgnoringLocalCacheData` overrode the
        //    policy the app chose per request, so URLCache was never consulted:
        //    3x the requests, 3x the data, and `.returnCacheDataDontLoad` (the
        //    offline read) could not succeed. The app's own policy travels on the
        //    forwarded request and is now left to govern; cache READS happen
        //    through `cachedResponseDisposition` before we ever come here.
        //
        // Their absence is the fix, so absence is what `SharedDemuxConfigurationTests`
        // pins — via the two snapshots above, which diverge the moment anyone
        // assigns one of them again.

        // `urlCache` IS still cleared, and unlike the three above it is
        // load-bearing rather than a tuning knob. The response is handed to the
        // host app's loading system through
        // `client?.urlProtocol(_:didReceive:cacheStoragePolicy:)`, which stores it
        // in the app's URLCache; a cache on this session would store a second
        // copy of every response. Clearing it costs no cache reads, because this
        // session never performs them — see `cachedResponseDisposition`.
        config.urlCache = nil

        // You have to explicitly configure the session to use your own protocol subclass here
        // otherwise you don't see redirects <rdar://problem/17384498>.
        config.protocolClasses = [CustomHTTPProtocol.self]
        demuxTransportSettings = DemuxTransportSettings(config)
        sharedDemuxInstance = QNSURLSessionDemux(configuration: config)
    }()

    @objc class func sharedDemux() -> QNSURLSessionDemux {
        _ = demuxOnce
        return sharedDemuxInstance!
    }

    // MARK: - Mirroring the ORIGINATING session (see HOST-TRANSPORT)

    /// Reads the transport settings off the session that actually issued this
    /// request.
    ///
    /// Why this is needed at all: `startLoading` re-issues the request on a
    /// SwiftyDebug session, so every session-level setting on the app's own
    /// session is dropped on the floor unless it is deliberately carried over.
    /// Measured on the simulator, NOTHING travels from a configuration onto the
    /// `URLRequest` a `URLProtocol` is handed — a session with
    /// `httpShouldSetCookies = false`, `allowsCellularAccess = false`,
    /// `httpMaximumConnectionsPerHost = 2` and
    /// `requestCachePolicy = .returnCacheDataElseLoad` produces a request that
    /// reports `httpShouldHandleCookies == true`, `allowsCellularAccess == true`
    /// and `cachePolicy == .useProtocolCachePolicy`. So the request cannot be
    /// asked; the session has to be.
    ///
    /// `URLProtocol.task` is public API and is the task the app created. Its
    /// `session` accessor is not in the headers, so it is called only after
    /// `responds(to:)` says it exists and only through KVC, and every caller
    /// treats `nil` as "unknown" and degrades safely (see
    /// `resolveDemux(for:)` and `upstreamRequest(_:hostSettings:...)`).
    /// Nothing here is required for correctness of the capture — it exists so
    /// the host app's own settings are not silently replaced by ours.
    private static let originatingSessionSelector = NSSelectorFromString("session")

    static func originatingSession(of task: URLSessionTask?) -> URLSession? {
        guard let task else { return nil }
        let object = task as AnyObject
        guard object.responds(to: originatingSessionSelector) else { return nil }
        return object.value(forKey: "session") as? URLSession
    }

    /// The originating configuration's transport settings, or nil when the
    /// session could not be reached (an `NSURLConnection`-era load, or an OS
    /// where the accessor is gone).
    static func hostTransportSettings(for task: URLSessionTask?) -> DemuxTransportSettings? {
        guard let session = originatingSession(of: task) else { return nil }
        return DemuxTransportSettings(session.configuration)
    }

    /// Demux sessions built to mirror a host configuration, one per distinct
    /// `DemuxSessionSignature`.
    ///
    /// The signature keys on the ADDRESS of the cookie/credential stores, which
    /// is only sound because the cached session's configuration holds a strong
    /// reference to them: a store that is still a key can never be deallocated,
    /// so its address can never be handed to a different store and collide.
    private static var dedicatedDemuxes: [DemuxSessionSignature: QNSURLSessionDemux] = [:]
    private static let dedicatedDemuxLock = NSLock()

    /// A ceiling on how many extra sessions the SDK will stand up. An app with a
    /// handful of networking stacks has a handful of signatures; a pathological
    /// one that builds a fresh cookie jar per request would otherwise leak a
    /// session per request. Past the cap we fall back to the shared session and
    /// the fallback is the SAFE direction (cookies are switched off rather than
    /// taken from the wrong jar).
    static let maxDedicatedDemuxSessions = 8

    /// Where a request carrying `settings` must be issued, and whether that
    /// session's cookie jar really is the host's.
    ///
    /// The `Bool` is not cosmetic: if we hand the request to the shared session
    /// while the app uses a private per-account jar, automatic cookie handling
    /// puts the SHARED jar's cookie on the wire — account A's credential on
    /// account B's session. In that case the caller must switch cookie handling
    /// off for the request instead.
    static func resolveDemux(for settings: DemuxTransportSettings?)
        -> (demux: QNSURLSessionDemux, sessionSharesHostCookieStorage: Bool) {
        let shared = sharedDemux()
        guard let settings else {
            // Unknown originating session: keep today's behaviour exactly.
            return (shared, true)
        }
        guard let sharedSettings = demuxTransportSettings else { return (shared, true) }
        if settings.sessionSignature == sharedSettings.sessionSignature {
            return (shared, true)
        }

        dedicatedDemuxLock.lock()
        defer { dedicatedDemuxLock.unlock() }
        let signature = settings.sessionSignature
        if let existing = dedicatedDemuxes[signature] {
            return (existing, true)
        }
        guard dedicatedDemuxes.count < maxDedicatedDemuxSessions else {
            return (shared, settings.httpCookieStorage === sharedSettings.httpCookieStorage)
        }
        let created = makeDedicatedDemux(mirroring: settings)
        dedicatedDemuxes[signature] = created
        return (created, true)
    }

    /// Builds a demux session that mirrors the host configuration's
    /// session-only settings. Everything a `URLRequest` can express is
    /// deliberately NOT set here — it travels per request, so one session can
    /// still serve many requests that differ only in those.
    private static func makeDedicatedDemux(mirroring settings: DemuxTransportSettings)
        -> QNSURLSessionDemux {
        isBuildingOwnConfiguration = true
        defer { isBuildingOwnConfiguration = false }
        let config = URLSessionConfiguration.default
        // Same two load-bearing lines as `demuxOnce`, for the same reasons.
        config.urlCache = nil
        config.protocolClasses = [CustomHTTPProtocol.self]
        // The host app's, not ours.
        config.httpMaximumConnectionsPerHost = settings.httpMaximumConnectionsPerHost
        config.httpCookieStorage = settings.httpCookieStorage
        config.httpCookieAcceptPolicy = settings.httpCookieAcceptPolicy
        config.urlCredentialStorage = settings.urlCredentialStorage
        return QNSURLSessionDemux(configuration: config)
    }

    /// Applies the originating configuration's transport settings to the request
    /// SwiftyDebug is about to issue.
    ///
    /// Pure, so the whole table is testable without CFNetwork. Each line answers
    /// a setting the host app chose and the demux session would otherwise
    /// silently replace:
    ///
    ///  • cookies — an app that sets `httpShouldSetCookies = false`, or that uses
    ///    a private per-account jar we could not give the request a session for,
    ///    must not have the SHARED jar's `Cookie` put on the wire. Both collapse
    ///    to "switch cookie handling off for this request".
    ///  • cellular — `allowsCellularAccess = false` is usually a user-visible
    ///    "Wi-Fi only" setting. AND-ed, so neither side can turn it back on.
    ///  • pipelining — OR-ed, matching CFNetwork's own rule that either the
    ///    session or the request can ask for it.
    ///  • cache policy — a request that inherits its policy from the session
    ///    reports `.useProtocolCachePolicy`, so the session's real policy has to
    ///    be written onto the request or the app's choice is lost. See
    ///    `effectiveCachePolicy(request:session:)`.
    static func upstreamRequest(_ request: URLRequest,
                                hostSettings: DemuxTransportSettings?,
                                sessionSharesHostCookieStorage: Bool) -> URLRequest {
        guard let hostSettings else { return request }
        var result = request
        let cookieJarIsUsable = sessionSharesHostCookieStorage && hostSettings.httpCookieStorage != nil
        result.httpShouldHandleCookies =
            request.httpShouldHandleCookies && hostSettings.httpShouldSetCookies && cookieJarIsUsable
        result.allowsCellularAccess = request.allowsCellularAccess && hostSettings.allowsCellularAccess
        result.httpShouldUsePipelining =
            request.httpShouldUsePipelining || hostSettings.httpShouldUsePipelining
        result.cachePolicy = effectiveCachePolicy(request: request.cachePolicy,
                                                  session: hostSettings.requestCachePolicy)
        return result
    }

    /// The cache policy that actually governs a request.
    ///
    /// `.useProtocolCachePolicy` on a `URLRequest` means "I did not choose one" —
    /// it is the value a request reports when its policy comes from the session.
    /// Reading only the request therefore misses `URLSessionConfiguration
    /// .requestCachePolicy` entirely, which is how most apps set it, and the
    /// `URLCache` read in `startLoading` never fired for them.
    static func effectiveCachePolicy(request: URLRequest.CachePolicy,
                                     session: URLRequest.CachePolicy?) -> URLRequest.CachePolicy {
        guard request == .useProtocolCachePolicy, let session else { return request }
        return session
    }

    /// Test hook: drops the per-signature sessions so one test's host
    /// configuration cannot decide another test's routing.
    static func resetDedicatedDemuxesForTesting() {
        dedicatedDemuxLock.lock()
        defer { dedicatedDemuxLock.unlock() }
        dedicatedDemuxes.removeAll()
    }

    static var dedicatedDemuxCountForTesting: Int {
        dedicatedDemuxLock.lock()
        defer { dedicatedDemuxLock.unlock() }
        return dedicatedDemuxes.count
    }

    // MARK: Session configuration swizzling

    private static var configSwizzled = false

    /// Replaces the original `+load` from ObjC. Must be called explicitly
    /// (e.g. from `Settings` or app delegate) because Swift
    /// does not support `+load`. Idempotent — safe to call multiple times.
    @objc class func swizzleSessionConfiguration() {
        guard !configSwizzled else { return }
        configSwizzled = true

        let defaultSel = Selector(("defaultSessionConfiguration"))
            let ephemeralSel = Selector(("ephemeralSessionConfiguration"))

            // Replacement block for +defaultSessionConfiguration.
            // imp_implementationWithBlock blocks receive (self, args...) -- no _cmd.
            let replacedDefault: @convention(block) (AnyObject) -> URLSessionConfiguration = { selfObj in
                let original = unsafeBitCast(orig_defaultSessionConfiguration!, to: SessionConfigConstructor.self)
                let config = original(selfObj, defaultSel)
                CustomHTTPProtocol.injectProtocol(into: config)
                return config
            }

            orig_defaultSessionConfiguration = replaceMethod(
                defaultSel,
                imp_implementationWithBlock(replacedDefault),
                URLSessionConfiguration.self,
                true
            )

            // Replacement block for +ephemeralSessionConfiguration.
            let replacedEphemeral: @convention(block) (AnyObject) -> URLSessionConfiguration = { selfObj in
                let original = unsafeBitCast(orig_ephemeralSessionConfiguration!, to: SessionConfigConstructor.self)
                let config = original(selfObj, ephemeralSel)
                CustomHTTPProtocol.injectProtocol(into: config)
                return config
            }

            orig_ephemeralSessionConfiguration = replaceMethod(
                ephemeralSel,
                imp_implementationWithBlock(replacedEphemeral),
                URLSessionConfiguration.self,
                true
            )

            // Also swizzle the protocolClasses GETTER on the actual runtime class
            // of URLSessionConfiguration. This is critical because in ObjC, +load
            // ran the class method swizzle before main(), so ALL configs were created
            // post-swizzle. In Swift there is no +load — the class method swizzle
            // happens later. Configs created before the swizzle (by third-party SDKs
            // or the system) won't have our protocol. By swizzling the getter, we
            // ensure that when URLSession reads a config's protocolClasses at session
            // creation time, our protocol is always included — regardless of when the
            // config was created.
            let protocolClassesSel = NSSelectorFromString("protocolClasses")
            // Use the actual runtime class of a config instance (class cluster).
            let sampleConfig = orig_defaultSessionConfiguration.flatMap { imp in
                unsafeBitCast(imp, to: SessionConfigConstructor.self)(
                    URLSessionConfiguration.self, defaultSel
                )
            }
            let configClass: AnyClass = sampleConfig.map { object_getClass($0)! } ?? URLSessionConfiguration.self
            if let getterMethod = class_getInstanceMethod(configClass, protocolClassesSel) {
                orig_protocolClassesGetter = method_getImplementation(getterMethod)

                let replacedGetter: @convention(block) (AnyObject) -> NSArray? = { configObj in
                    let original = unsafeBitCast(orig_protocolClassesGetter!, to: ProtocolClassesGetterFunc.self)
                    let result = original(configObj, protocolClassesSel)
                    let classes = (result as? [AnyClass]) ?? []
                    // Behind the host app's own protocols, ahead of the system's.
                    // See `protocolClassesInserting(_:into:)`.
                    guard let mutable = protocolClassesInserting(CustomHTTPProtocol.self, into: classes) else {
                        return result
                    }
                    return mutable as NSArray
                }

                method_setImplementation(getterMethod, imp_implementationWithBlock(replacedGetter))
            }

            swizzleRequestTimeoutSetter(on: configClass)
    }

    /// Raises any request timeout the host app sets below the breakpoint hold
    /// budget — **only while `Settings.extendTimeoutsForBreakpoints` is on, which
    /// it is not by default.**
    ///
    /// This is what makes breakpoints usable. `timeoutIntervalForRequest` is
    /// an **idle** timer: it resets only when real bytes reach the client. A
    /// request held at an `.afterResponse` breakpoint delivers nothing until you
    /// tap Deliver, so the timer runs uninterrupted and the app gives up with
    /// NSURLErrorTimedOut — the demo's own stack sets 10 seconds, which is gone
    /// before you have finished reading the payload, let alone editing it. The
    /// edited body is then delivered to a task that no longer exists, and the
    /// screen stays empty with no error.
    ///
    /// Swizzling the *setter* (rather than only the config constructors) is
    /// required because apps typically do `URLSessionConfiguration.default` and
    /// then assign their own timeout, which would overwrite anything we set at
    /// construction. (See BREAKPOINTS.)
    ///
    /// While the setting is off this hook is a pure pass-through: it forwards the
    /// app's value to the original setter byte-for-byte. It stays installed so
    /// that switching the setting on later needs no re-swizzle (which could not
    /// be done safely anyway).
    private class func swizzleRequestTimeoutSetter(on configClass: AnyClass) {
        let sel = NSSelectorFromString("setTimeoutIntervalForRequest:")
        guard let method = class_getInstanceMethod(configClass, sel) else { return }
        orig_setTimeoutIntervalForRequest = method_getImplementation(method)

        let replaced: @convention(block) (AnyObject, TimeInterval) -> Void = { configObj, value in
            let original = unsafeBitCast(orig_setTimeoutIntervalForRequest!, to: TimeoutSetterFunc.self)
            let applied = Self.effectiveRequestTimeout(value)
            Self.recordTimeoutDecision(requested: value)
            original(configObj, sel, applied)
        }
        method_setImplementation(method, imp_implementationWithBlock(replaced))
    }

    /// The timeout to actually apply, given what the host app asked for.
    /// Pure and `internal` so it can be unit-tested without CFNetwork.
    ///
    /// When `extendTimeoutsForBreakpoints` is off — the default — this returns
    /// `requested` unchanged, so the host app's own timeout is never touched.
    static func effectiveRequestTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard SwiftyDebugRuntime.isActive,
              Settings.shared.extendTimeoutsForBreakpoints else { return requested }
        let floor = Settings.shared.breakpointHoldSeconds
        // A host app asking for MORE than the hold budget keeps its own value.
        return max(requested, floor)
    }

    // MARK: - Does flipping the setting need an app restart?

    /// What a change to `extendTimeoutsForBreakpoints` can actually reach.
    enum TimeoutSettingChangeEffect {
        /// No `URLSessionConfiguration` seen this launch had a timeout that
        /// depended on the setting, so nothing stale can exist: the next request
        /// already behaves the new way.
        case appliesImmediately
        /// At least one configuration's timeout was decided under the *previous*
        /// value. `URLSession` copies its configuration at init, so those
        /// sessions keep the timeout they were built with for their whole life —
        /// only sessions created from here on pick up the new value.
        case restartRequiredForExistingSessions
    }

    private static let timeoutDecisionLock = NSLock()
    /// Count of timeout decisions whose outcome depended on the setting, i.e.
    /// where on/off would have produced different values. Only ever grows.
    private static var _timeoutDecisionsBoundToSetting = 0

    /// Records one `setTimeoutIntervalForRequest:` / config-creation decision.
    ///
    /// Only decisions that *depend* on the setting count: a config asking for
    /// more than the hold budget gets the same number either way, so it can
    /// never be stale.
    ///
    /// `internal` rather than `private` only so the rule can be unit-tested
    /// without standing up CFNetwork.
    static func recordTimeoutDecision(requested: TimeInterval) {
        guard !isBuildingOwnConfiguration else { return }
        guard requested < Settings.shared.breakpointHoldSeconds else { return }
        timeoutDecisionLock.lock()
        _timeoutDecisionsBoundToSetting += 1
        timeoutDecisionLock.unlock()
    }

    /// Whether flipping `extendTimeoutsForBreakpoints` right now would leave
    /// already-built `URLSession`s on the old timeout.
    ///
    /// Deliberately conservative: once any setting-dependent decision has been
    /// made this launch we cannot know which live sessions still hold it (a
    /// session's configuration is an immutable copy we do not retain), so we
    /// report that a restart is needed rather than let the UI promise something
    /// false.
    static var timeoutSettingChangeEffect: TimeoutSettingChangeEffect {
        timeoutDecisionLock.lock()
        let count = _timeoutDecisionsBoundToSetting
        timeoutDecisionLock.unlock()
        return count == 0 ? .appliesImmediately : .restartRequiredForExistingSessions
    }

    /// Test hook: forget every recorded decision, as a fresh launch would.
    static func resetTimeoutDecisionTrackingForTesting() {
        timeoutDecisionLock.lock()
        _timeoutDecisionsBoundToSetting = 0
        timeoutDecisionLock.unlock()
    }

    // MARK: - Where SwiftyDebug sits in `protocolClasses`

    /// True for a `URLProtocol` subclass that ships with the system — CFNetwork's
    /// `_NSURLHTTPProtocol` and friends — as opposed to one the host app
    /// registered itself.
    ///
    /// The test has to be made at runtime against the defining bundle: the class
    /// names are private and undocumented, but `com.apple.CFNetwork` is stable.
    /// A class defined in the main bundle is the app's own by definition, so it
    /// is checked first and never counts as the system's.
    static func isSystemProvidedProtocolClass(_ cls: AnyClass) -> Bool {
        let bundle = Bundle(for: cls)
        guard bundle != Bundle.main else { return false }
        return bundle.bundleIdentifier?.hasPrefix("com.apple.") == true
    }

    /// `classes` with SwiftyDebug inserted at the one position that is both
    /// correct and polite — or nil when it is already present, meaning "leave
    /// the array alone".
    ///
    /// NOT index 0, and NOT the end.
    ///
    /// **Index 0** — what this used to do — pre-empts the host app's OWN
    /// `URLProtocol`s. OHHTTPStubs, Mocker and hand-rolled offline layers all
    /// register at index 0 expecting to win, so jumping ahead of them meant
    /// their stubs never fired and a request the test believed was stubbed
    /// silently went to the live network, with no opt-out.
    ///
    /// **The end** is not the answer either, and this is the trap in "just
    /// append": a stock `URLSessionConfiguration.default` already lists
    /// CFNetwork's `_NSURLHTTPProtocol` FIRST, and it claims every http/https
    /// request. Appending parks SwiftyDebug behind it, where `canInit` is never
    /// called and the SDK captures nothing at all.
    ///
    /// So: after every protocol the host app registered, immediately before the
    /// first system-provided one.
    static func protocolClassesInserting(_ protoCls: AnyClass,
                                         into classes: [AnyClass]) -> [AnyClass]? {
        guard !classes.contains(where: { $0 == protoCls }) else { return nil }
        var result = classes
        let index = classes.firstIndex(where: { isSystemProvidedProtocolClass($0) }) ?? classes.count
        result.insert(protoCls, at: index)
        return result
    }

    /// Injects `CustomHTTPProtocol` into the given configuration's
    /// `protocolClasses`, behind the host app's own protocols and ahead of the
    /// system's — see `protocolClassesInserting(_:into:)`.
    ///
    /// `internal` rather than `private` only so the timeout bookkeeping below can
    /// be unit-tested without standing up CFNetwork.
    class func injectProtocol(into config: URLSessionConfiguration) {
        if config.responds(to: #selector(getter: URLSessionConfiguration.protocolClasses)),
           config.responds(to: #selector(setter: URLSessionConfiguration.protocolClasses)) {
            let current = config.protocolClasses ?? []
            // Written back even when SwiftyDebug is already listed: with the
            // `protocolClasses` getter swizzled, a read can include us while the
            // config's own storage does not, and URLSession copies the storage.
            // That unconditional write is pre-existing behaviour — only the
            // insertion POSITION changed here.
            config.protocolClasses = protocolClassesInserting(CustomHTTPProtocol.self, into: current) ?? current
        }
        // Covers configs the app never assigns a timeout to (the setter swizzle
        // covers the ones it does).
        let requested = config.timeoutIntervalForRequest
        let applied = effectiveRequestTimeout(requested)

        // Record HERE, against the value the host app actually asked for, and do
        // it on BOTH branches — including the one that modifies the config.
        // Delegating the record to the swizzled setter (as this used to) makes it
        // run with `requested: applied`, i.e. the 600 we just raised the config
        // to, which can never satisfy `recordTimeoutDecision`'s
        // `requested < breakpointHoldSeconds` check. The configs we modified —
        // the only ones that can be holding a stale timeout — were therefore the
        // only ones never counted, so turning the setting OFF reported
        // `.appliesImmediately` and the UI never prompted for a restart while
        // live sessions sat on 600 s.
        recordTimeoutDecision(requested: requested)

        // The write is skipped when nothing would change, so with the setting off
        // the config is left literally untouched rather than re-assigned its own
        // value.
        guard applied != requested else { return }
        config.timeoutIntervalForRequest = applied
    }

    // MARK: Instance properties

    private var clientThread: Thread?
    private var modes: [String]?
    private var startTime: TimeInterval = 0
    private var _dataTask: URLSessionDataTask?
    @objc var pendingChallenge: URLAuthenticationChallenge?
    private var pendingChallengeCompletionHandler: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
    private var response: URLResponse?
    /// The transport settings of the session the HOST APP issued this request on,
    /// read once in `startLoading` and mirrored onto the request SwiftyDebug
    /// re-issues. nil when the originating session could not be reached — every
    /// use degrades to today's behaviour. See `hostTransportSettings(for:)`.
    private var hostTransportSettings: DemuxTransportSettings?
    private var data: NSMutableData?
    private var error: Error?
    private var responseTruncated: Bool = false

    /// Cap on the response body SwiftyDebug keeps for the UI — and, while a
    /// response is being held, the cap on the hold itself. See
    /// `holdAbandonReason(bufferedBytes:incomingBytes:isHoldingForRewriteOnly:)`.
    static let maxCapturedResponseBytes = 10 * 1024 * 1024
    /// Request body captured from HTTPBodyStream in startLoading.
    /// self.request.HTTPBody is nil when the body was sent via a stream,
    /// so we must capture it from the recursiveRequest after reading the stream.
    private var capturedRequestBody: Data?
    /// The request after intercept rules have been applied (headers/query params modified).
    /// Used in stopLoading() so the UI reflects the actual request that was sent.
    private var interceptedRequest: URLRequest?
    /// The composite rule matched for this request (mock / breakpoint / redirect).
    private var resolvedRule: InterceptRule?
    /// True when the response was served from a mock rather than the network.
    private var isMocked = false
    /// While an `.afterResponse` breakpoint is armed — or the rule has armed
    /// response rewrites — we buffer the response instead of streaming it to the
    /// client, so the whole body can be edited before the app sees any of it.
    /// Set when `stopLoading()` cancels our own upstream task, so the
    /// cancellation error CFNetwork reports back can be told apart from one we
    /// did not cause. See `isClientInitiatedCancellation`.
    private var didCancelOwnTask = false
    private var isHoldingResponse = false
    /// True when the ONLY reason we are holding is response rewrites (no
    /// breakpoint). Such a hold is abandonable: if the body outgrows the rewrite
    /// engine's cap there is nothing left to rewrite, so we flush and stream the
    /// rest rather than buffer a payload we have no use for.
    private var isHoldingForRewriteOnly = false
    private var heldResponse: URLResponse?
    /// The cache policy computed for the held response, so a body we buffered
    /// but did not touch is delivered exactly as it would have been streamed.
    private var heldCacheStoragePolicy: URLCache.StoragePolicy = .notAllowed
    /// What `ResponseRewriteEngine` did (or why it never ran). Copied onto the
    /// transaction in `stopLoading` — a response the app sees but the server
    /// never sent has to be traceable.
    private var rewriteReport: RewriteReport?
    /// The breakpoint entry parked for this request, if any. Held so that if the
    /// app gives up first (timeout / cancellation) we can drop it from the inbox
    /// instead of leaving a row that can never be delivered.
    ///
    /// Strong on purpose: a weak reference could be nil by the time `stopLoading`
    /// runs, which would skip the expiry and leave a row whose Deliver button
    /// silently does nothing. No cycle — the parked entry's handlers capture this
    /// protocol weakly.
    private var parkedBreakpoint: BreakpointCenter.PausedRequest?

    // MARK: Recursive request flag

    private static let kOurRecursiveRequestFlagProperty = "com.apple.dts.CustomHTTPProtocol"

    /// Mark a request with this key (via `URLProtocol.setProperty`) to make
    /// `canInit` skip it entirely. Used by SwiftyDebug's own internal fetches
    /// (e.g. `ImageLoader` thumbnails) so they are never captured — otherwise
    /// loading a captured image would itself be captured, in an infinite loop.
    static var recursiveRequestFlagProperty: String { kOurRecursiveRequestFlagProperty }

    // MARK: Skipped file extensions

    private static let skippedExtensions: Set<String> = {
        return Set([
            "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "heic", "heif",
            "mp4", "mov", "avi", "m4v", "m4a", "mp3", "wav", "aac",
            "woff", "woff2", "ttf", "otf", "eot"
        ])
    }()

    // MARK: NSURLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Global kill-switch: when the SDK is fully stopped, do zero
        // interception — this is the real off-switch even though the swizzled
        // `protocolClasses` getter still lists us for already-created sessions.
        guard SwiftyDebugRuntime.isActive, NetworkMonitor.shared.isNetworkEnable else {
            return false
        }

        guard let scheme = request.url?.scheme, scheme == "http" || scheme == "https" else {
            return false
        }

        if URLProtocol.property(forKey: kOurRecursiveRequestFlagProperty, in: request) != nil {
            return false
        }

        // Skip media requests unless monitorMedia is enabled
        if !SwiftyDebug.monitorMedia {
            if let pathExtension = request.url?.pathExtension.lowercased(),
               !pathExtension.isEmpty,
               skippedExtensions.contains(pathExtension) {
                return false
            }
        }

        // If monitorAllUrls is set, capture everything
        if SwiftyDebug.monitorAllUrls {
            return true
        }

        // Filter by SwiftyDebug.urls
        let urls = SwiftyDebug.urls
        if !urls.isEmpty {
            let url = request.url?.absoluteString.lowercased() ?? ""
            for filterURL in urls {
                if url.contains(filterURL.lowercased()) {
                    return true
                }
            }
            return false
        }

        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return CanonicalRequestForRequest(request) as URLRequest
    }

    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    deinit {
        // We should have cleared task and pending challenge by now.
    }

    // MARK: - Query-parameter edits (pure, so it can be unit-tested)

    /// Characters SwiftyDebug leaves un-escaped in a query name or value it
    /// writes itself.
    ///
    /// Narrower than `.urlQueryAllowed`, which permits `&`, `=`, `+`, `/`, `?`
    /// and `#`. `&` and `=` would split one parameter into two; `+` decodes as a
    /// space on most servers; `/`, `?` and `#` change the byte string without
    /// changing the meaning, which is enough to invalidate a signature.
    private static let queryComponentAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+/?#")
        return set
    }()

    /// Percent-encodes one query name or value that SwiftyDebug is introducing.
    static func percentEncodedQueryComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed) ?? raw
    }

    /// Applies `rule`'s query-parameter edits to `url`.
    ///
    /// Returns **nil** — meaning "leave this URL completely alone" — whenever the
    /// rule edits no query parameters, and that no-op is the whole point of this
    /// function existing.
    ///
    /// Round-tripping a URL through `URLComponents.queryItems` RE-ENCODES the
    /// entire query with Foundation's own rules, so `%2B` comes back as `+` and
    /// `%2F` as `/`:
    ///
    ///     in : ...?X-Amz-Signature=ab%2Bcd%2Fef%3D%3D
    ///     out: ...?X-Amz-Signature=ab+cd/ef%3D%3D
    ///
    /// The URL still "works", but it is no longer the byte string the signature
    /// was computed over, so the server answers 403 SignatureDoesNotMatch. That
    /// used to happen for every request matched by ANY enabled rule — including a
    /// rule whose only edit was a header override — because the old code was
    /// guarded solely by "a rule matched".
    ///
    /// When there IS a query edit to make, the work happens in
    /// `percentEncodedQueryItems`, so every parameter the rule did not name keeps
    /// its original bytes exactly.
    static func urlApplyingQueryEdits(of rule: InterceptRule, to url: URL) -> URL? {
        guard !rule.queryParamOverrides.isEmpty || !rule.removedQueryParamKeys.isEmpty else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Names arrive percent-encoded here; the rule stores plain text, so
        // compare decoded. (`?a%20b=1` is matched by the key "a b".)
        func decodedName(_ item: URLQueryItem) -> String {
            item.name.removingPercentEncoding ?? item.name
        }

        var items = components.percentEncodedQueryItems ?? []
        items.removeAll { rule.removedQueryParamKeys.contains(decodedName($0)) }

        for pair in rule.queryParamOverrides {
            let encoded = URLQueryItem(name: percentEncodedQueryComponent(pair.key),
                                       value: percentEncodedQueryComponent(pair.value))
            if let idx = items.firstIndex(where: { decodedName($0) == pair.key }) {
                items[idx] = encoded
            } else {
                items.append(encoded)
            }
        }

        components.percentEncodedQueryItems = items.isEmpty ? nil : items
        return components.url
    }

    // MARK: - The host app's URLCache (see MAJOR 3)

    /// What to do with the cached entry the URL loading system handed this
    /// protocol.
    enum CachedResponseDisposition: Equatable {
        /// Go upstream, as always.
        case load
        /// Answer from `cachedResponse` without touching the network.
        case serveFromCache
        /// The app asked for cache-only and there is nothing cached. Fail,
        /// rather than quietly doing the one thing the policy forbids.
        case failCacheOnlyMiss
    }

    /// Decides whether a request can be answered from the host app's cache.
    /// Pure, so the policy table is testable without CFNetwork or a URLCache.
    ///
    /// Only the two policies that name the cache *explicitly* are honoured here.
    /// `.useProtocolCachePolicy` deliberately still loads: deciding whether a
    /// stored entry is fresh is HTTP revalidation, which CFNetwork does on the
    /// upstream leg and SwiftyDebug must not attempt to re-implement. Serving a
    /// stale body because the SDK guessed wrong would be a worse bug than the
    /// extra request.
    ///
    /// An armed breakpoint also forces `.load`. The developer asked to intervene
    /// in a network exchange; silently short-circuiting to cache would mean the
    /// pause they armed never fires and nothing anywhere says why.
    /// `ruleChangesTheRequest` covers every rule that alters WHAT would be
    /// fetched — a redirect, or a query-param edit. Serving the cache short-
    /// circuits the network, so an armed redirect silently never happens and the
    /// list still shows the redirect target as though it had. Only a rule that
    /// merely observes (or edits the response) can safely be served from cache.
    static func cachedResponseDisposition(policy: URLRequest.CachePolicy,
                                          hasCachedResponse: Bool,
                                          breakpointMode: BreakpointMode,
                                          ruleChangesTheRequest: Bool = false) -> CachedResponseDisposition {
        guard breakpointMode == .off, !ruleChangesTheRequest else { return .load }
        switch policy {
        case .returnCacheDataDontLoad:
            return hasCachedResponse ? .serveFromCache : .failCacheOnlyMiss
        case .returnCacheDataElseLoad:
            return hasCachedResponse ? .serveFromCache : .load
        default:
            return .load
        }
    }

    override func startLoading() {
        // At this point we kick off the process of loading the URL via NSURLSession.
        // The thread that calls this method becomes the client thread.

        // Calculate our effective run loop modes. In some circumstances (yes I'm looking at
        // you UIWebView!) we can be called from a non-standard thread which then runs a
        // non-standard run loop mode waiting for the request to finish. We detect this
        // non-standard mode and add it to the list of run loop modes we use when scheduling
        // our callbacks.
        var calculatedModes: [String] = [RunLoop.Mode.default.rawValue]
        if let currentMode = RunLoop.current.currentMode?.rawValue,
           currentMode != RunLoop.Mode.default.rawValue {
            calculatedModes.append(currentMode)
        }
        self.modes = calculatedModes

        // Stamp the clock and latch the client thread BEFORE anything that can
        // return early. A request blocked by an intercept rule used to return
        // before `startTime` was ever set, so `stopLoading` computed its duration
        // against the epoch and the list showed a ~56-year request.
        self.startTime = Date().timeIntervalSince1970
        self.data = NSMutableData()
        // Latch the thread we were called on, primarily for debugging purposes.
        self.clientThread = Thread.current

        // Read the ORIGINATING session's transport settings before anything else
        // touches the request. Everything downstream — the URLCache decision, the
        // session the request is re-issued on, the request itself — has to mirror
        // the app's own configuration rather than impose the demux session's.
        self.hostTransportSettings = Self.hostTransportSettings(for: self.task)

        // Create new request that's a clone of the request we were initialised with,
        // except that it has our 'recursive request flag' property set on it.
        let recursiveRequest = (self.request as NSURLRequest).mutableCopy() as! NSMutableURLRequest

        CustomHTTPProtocol.setProperty(true,
                                        forKey: CustomHTTPProtocol.kOurRecursiveRequestFlagProperty,
                                        in: recursiveRequest)

        // Convert body stream to body data to avoid needNewBodyStream overhead.
        // When a request with HTTPBodyStream is cloned, CFNetwork calls needNewBodyStream:
        // which bounces through the demux delegate on another thread - 11.4% of CPU in traces.
        // Reading the stream into HTTPBody eliminates this callback entirely.
        if recursiveRequest.httpBodyStream != nil && recursiveRequest.httpBody == nil {
            let stream = recursiveRequest.httpBodyStream!
            let bodyData = NSMutableData()
            var buffer = [UInt8](repeating: 0, count: 4096)
            stream.open()
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    bodyData.append(buffer, length: bytesRead)
                } else {
                    break
                }
            }
            stream.close()
            if bodyData.length > 0 {
                recursiveRequest.httpBody = bodyData as Data
            }
        }

        // Capture the request body for the debug model.
        // The original request's HTTPBody may be nil when the body was sent via
        // HTTPBodyStream. recursiveRequest now has the stream data converted to HTTPBody.
        self.capturedRequestBody = recursiveRequest.httpBody

        // --- Interception: check for matching intercept rules ---
        if let url = recursiveRequest.url {
            self.resolvedRule = InterceptRuleStore.shared.resolvedRule(forURL: url)
            if let rule = self.resolvedRule {
                if rule.isBlocked {
                    let error = NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "Blocked by SwiftyDebug intercept rule"]
                    )
                    self.client?.urlProtocol(self, didFailWithError: error)
                    return
                }
                // Apply header overrides
                for pair in rule.headerOverrides {
                    recursiveRequest.setValue(pair.value, forHTTPHeaderField: pair.key)
                }
                for key in rule.removedHeaderKeys {
                    recursiveRequest.setValue(nil, forHTTPHeaderField: key)
                }
                // Apply query param overrides.
                //
                // NO-OP BY DESIGN: a rule that edits no query parameters must not
                // reach the URL at all — see `urlApplyingQueryEdits(of:to:)` for
                // why touching it corrupts signed URLs.
                if let editedURL = Self.urlApplyingQueryEdits(of: rule, to: url) {
                    recursiveRequest.url = editedURL
                }
                // Apply redirect last, so it rewrites the URL that already has
                // the rule's query-param edits (the original query is preserved).
                if let current = recursiveRequest.url,
                   let redirected = rule.redirectedURL(for: current) {
                    recursiveRequest.url = redirected
                    // Keep Host consistent with the new destination unless the
                    // rule explicitly overrides it.
                    let overridesHost = rule.headerOverrides.contains { $0.key.lowercased() == "host" }
                    if !overridesHost, let newHost = redirected.host {
                        recursiveRequest.setValue(newHost, forHTTPHeaderField: "Host")
                    }
                }
                // Save the modified request so stopLoading() reflects what was actually sent.
                // Only set when a rule was applied; non-intercepted requests use self.request as before.
                self.interceptedRequest = recursiveRequest as URLRequest
            }
        }

        // Network Link Conditioner simulation (see NETWORK-SIM). Reads the fixed
        // preset chosen on the Info tab and either fails the request (100% loss)
        // or delays it by the preset's latency so loader/spinner states can be
        // observed. Off by default.
        let preset = Settings.shared.networkConditionerPreset
        if preset.dropsAllRequests {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Dropped by SwiftyDebug network simulation (100% Loss)"]
            )
            self.client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // --- Mock response: answer locally, never touch the network. ---
        // The active mock profile is consulted too, not just this rule. A rule's
        // own mock wins — the specific beats the general — which is what
        // `resolvedMock` encodes. Without this call an activated profile is
        // inert and the UI's "N mocks active" is a lie.
        // While the profiles feature is hidden, only the rule's own mock applies.
        //
        // ORDER vs. RESPONSE REWRITES: a mock REPLACES the response entirely and
        // never touches the network, so it returns here and the rewrite engine
        // never runs on a mocked body. That is deliberate — the mock body is
        // already exactly what the developer typed, and silently rewriting it
        // afterwards would mean the mock editor showed one thing and the app got
        // another. To change a mock, edit the mock.
        let profileMock = MockProfileStore.isFeatureEnabled
            ? (recursiveRequest as URLRequest).url.flatMap {
                MockProfileStore.shared.resolvedMock(forURL: $0, ruleMock: self.resolvedRule?.mock)
              }
            : MockProfileStore.resolveMock(ruleMock: self.resolvedRule?.mock, profileMock: nil)
        if let mock = profileMock {
            deliverMock(mock, for: recursiveRequest as URLRequest)
            return
        }

        // --- The host app's URLCache. ---
        // The loading system already looked the request up and handed us the
        // entry as `self.cachedResponse`; using it is the protocol's job, and
        // this protocol used to ignore it completely while ALSO forcing
        // `.reloadIgnoringLocalCacheData` on the demux session. Between them,
        // linking SwiftyDebug turned every cache hit into a network round trip
        // and made `.returnCacheDataDontLoad` — the offline read — impossible to
        // satisfy. The forced policy is gone (see `demuxOnce`); this restores
        // the read.
        let rule = self.resolvedRule
        let ruleChangesTheRequest = (rule?.redirectMode ?? .none) != .none
            || !(rule?.queryParamOverrides.isEmpty ?? true)
            || !(rule?.removedQueryParamKeys.isEmpty ?? true)
        //
        // The policy is read through `effectiveCachePolicy`, NOT straight off the
        // request: a request whose policy comes from the session reports
        // `.useProtocolCachePolicy`, so reading only the request meant the cache
        // was never consulted for the most common way of configuring one —
        // `URLSessionConfiguration.requestCachePolicy`.
        let effectivePolicy = Self.effectiveCachePolicy(
            request: (recursiveRequest as URLRequest).cachePolicy,
            session: self.hostTransportSettings?.requestCachePolicy)
        switch Self.cachedResponseDisposition(policy: effectivePolicy,
                                              hasCachedResponse: self.cachedResponse != nil,
                                              breakpointMode: rule?.breakpointMode ?? .off,
                                              ruleChangesTheRequest: ruleChangesTheRequest) {
        case .load:
            break
        case .serveFromCache:
            if let cached = self.cachedResponse {
                deliverCachedResponse(cached)
                return
            }
        case .failCacheOnlyMiss:
            // What CFNetwork itself returns for a `.returnCacheDataDontLoad`
            // miss. Going to the network instead would defeat the whole point
            // of the policy.
            self.client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorResourceUnavailable,
                userInfo: [NSLocalizedDescriptionKey:
                            "The request requires cached data, which is not available."]))
            return
        }

        // --- Breakpoint (before send): park the request for editing. ---
        if self.resolvedRule?.breakpointMode == .beforeSend {
            let paused = BreakpointCenter.PausedRequest(
                stage: .beforeSend,
                request: recursiveRequest as URLRequest,
                resume: { [weak self] edited in
                    // Continue with whatever the developer changed.
                    self?.performOnThread(self?.clientThread, modes: self?.modes) {
                        guard let self else { return }
                        // The captured transaction has to describe what actually
                        // went on the wire. Both of these were latched in
                        // `startLoading`, BEFORE the developer edited the parked
                        // request, so leaving them would show the Network list —
                        // and the cURL command copied from it — a method, URL,
                        // headers and body that were never sent.
                        self.interceptedRequest = edited.request
                        self.capturedRequestBody = edited.request.httpBody
                        self.sendUpstream(edited.request)
                    }
                },
                abort: { [weak self] in
                    guard let self else { return }
                    self.performOnThread(self.clientThread, modes: self.modes) {
                        self.client?.urlProtocol(self, didFailWithError: NSError(
                            domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSLocalizedDescriptionKey: "Aborted at breakpoint"]))
                    }
                }
            )
            self.parkedBreakpoint = paused
            BreakpointCenter.shared.park(paused)
            return
        }

        sendUpstream(recursiveRequest as URLRequest)
    }

    /// Actually issues the (possibly breakpoint-edited) request upstream,
    /// honoring the network-conditioner latency.
    private func sendUpstream(_ request: URLRequest) {
        // MIRROR, do not impose. The session below is SwiftyDebug's, but the
        // request is the host app's, so the app's transport settings have to be
        // carried across the hand-off: the ones a URLRequest can express travel
        // on the request, the ones only a session can express decide WHICH demux
        // session it goes to. See `resolveDemux(for:)`.
        let routing = Self.resolveDemux(for: self.hostTransportSettings)
        let outbound = Self.upstreamRequest(
            request,
            hostSettings: self.hostTransportSettings,
            sessionSharesHostCookieStorage: routing.sessionSharesHostCookieStorage)

        self._dataTask = routing.demux.dataTask(
            with: outbound,
            delegate: self,
            modes: self.modes
        )

        let latency = Settings.shared.networkConditionerPreset.addedLatency
        if latency > 0 {
            // Defer resume (non-blocking) so the whole request is delayed by the
            // preset's simulated latency. Never sleep the client thread.
            let task = self._dataTask
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + latency) {
                task?.resume()
            }
        } else {
            self._dataTask?.resume()
        }
    }

    /// Test hook: the task SwiftyDebug actually handed to a demux session.
    ///
    /// Tests assert against THIS rather than against the pure functions that
    /// build it, so that reverting the wiring in `sendUpstream` — not just the
    /// table in `upstreamRequest` — is what makes them fail. `originatingSession`
    /// turns it back into the session it was issued on, which is the only place
    /// the settings a `URLRequest` cannot express (the connection cap, the cookie
    /// jar) are observable.
    var upstreamTaskForTesting: URLSessionDataTask? { _dataTask }

    /// Synthesizes a response from a mock rule and hands it to the client without
    /// any network access. (See MOCK.)
    private func deliverMock(_ mock: MockResponse, for request: URLRequest) {
        let body = mock.body.data(using: .utf8) ?? Data()
        let url = request.url ?? URL(string: "https://swiftydebug.mock")!
        let response = mock.httpResponse(for: url)

        // Record it so the mock shows up in the request list like a real call.
        self.response = response
        self.data = NSMutableData(data: body)
        self.isMocked = true

        // A mock REPLACES the response, so rewrites never see it. Say so on the
        // transaction rather than leaving an armed rewrite that quietly did
        // nothing — that silent no-op is the exact failure this feature exists
        // to avoid, and the rule editor warns about the same conflict up front.
        if resolvedRule?.hasActiveResponseRewrites == true {
            self.rewriteReport = RewriteReport(
                skippedReason: "This response came from a mock, so response rewrites were skipped. "
                             + "Edit the mock body instead.")
        }

        // Same conflict, one step earlier: a mock answers without touching the
        // network, so an armed breakpoint on the same rule can never pause
        // anything — `startLoading` returns here before it parks, and the
        // `.afterResponse` stage has no server exchange to hold at all. That was
        // silent: the developer armed a breakpoint, triggered the request, and
        // the inbox stayed empty with nothing anywhere saying why. Say it in the
        // DIDN'T PAUSE section of the inbox they are staring at.
        if let mode = resolvedRule?.breakpointMode, mode != .off {
            BreakpointCenter.shared.note(Self.mockPreemptedBreakpointMessage(mode), for: request.url)
        }

        let deliver = { [weak self] in
            guard let self, let response else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { self.client?.urlProtocol(self, didLoad: body) }
            self.client?.urlProtocolDidFinishLoading(self)
        }

        let delay = max(mock.delay, Settings.shared.networkConditionerPreset.addedLatency)
        if delay > 0 {
            let thread = self.clientThread, modes = self.modes
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performOnThread(thread, modes: modes, block: deliver)
            }
        } else {
            deliver()
        }
    }

    /// Why an armed breakpoint never paused a request a mock answered. Pure and
    /// `static` so the wording is pinned by tests — this sentence IS the fix, so
    /// it has to survive refactoring.
    ///
    /// Worded for a mock from either source (the rule's own or an active mock
    /// profile), because both short-circuit the same way.
    static func mockPreemptedBreakpointMessage(_ mode: BreakpointMode) -> String {
        switch mode {
        case .off:
            return ""
        case .beforeSend:
            return "A mock answered this request without touching the network, so the "
                 + "\u{201C}before send\u{201D} breakpoint never paused it. "
                 + "Switch the mock off to pause the real request."
        case .afterResponse:
            return "A mock answered this request without touching the network, so there was no "
                 + "server response to pause and the \u{201C}after response\u{201D} breakpoint "
                 + "was skipped. Edit the mock body instead."
        }
    }

    /// Answers the request from the entry the URL loading system found in the
    /// host app's `URLCache`, with no network access.
    ///
    /// The cached response is replayed byte-for-byte, and `.notAllowed` is used
    /// for the storage policy because it is already stored — re-storing what we
    /// just read is how a cached entry gets its lifetime silently extended.
    private func deliverCachedResponse(_ cached: CachedURLResponse) {
        self.response = cached.response
        self.data = NSMutableData(data: cached.data)

        // A rewrite armed on a URL that answers from cache would otherwise do
        // nothing at all, with nothing to read anywhere — the same silent no-op
        // the mock path reports, for the same reason.
        if resolvedRule?.hasActiveResponseRewrites == true {
            self.rewriteReport = RewriteReport(
                skippedReason: "This response was served from the app's URLCache without a "
                             + "network request, so response rewrites were skipped.")
        }

        client?.urlProtocol(self, didReceive: cached.response, cacheStoragePolicy: .notAllowed)
        if !cached.data.isEmpty { client?.urlProtocol(self, didLoad: cached.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // The implementation just cancels the current load (if it's still running).

        cancelPendingChallenge()

        // The app gave up on this request (cancelled, or its own timeout elapsed
        // while it sat at a breakpoint). Delivering now would go nowhere, so drop
        // the row rather than leave a "Deliver" button that silently does nothing.
        if let parked = parkedBreakpoint, !parked.isSettled {
            BreakpointCenter.shared.expire(parked)
            parkedBreakpoint = nil
        }
        isHoldingResponse = false
        isHoldingForRewriteOnly = false

        if let task = self._dataTask {
            didCancelOwnTask = true
            task.cancel()
            self._dataTask = nil
            // The following ends up calling urlSession(_:task:didCompleteWithError:) with
            // NSURLErrorDomain / NSURLErrorCancelled, which specifically traps and ignores the error.
        }
        // Don't nil out self.modes; see property declaration comments for a discussion of this.

        if !NetworkMonitor.shared.isNetworkEnable {
            return
        }

        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        // Use the intercepted request (with rule modifications applied) if available,
        // so the UI, cURL command, and request info reflect what was actually sent.
        let effectiveRequest = self.interceptedRequest ?? self.request
        model.url = effectiveRequest.url as NSURL?
        model.method = effectiveRequest.httpMethod
        model.mineType = self.response?.mimeType

        // Use capturedRequestBody which includes stream-based bodies
        // (self.request.HTTPBody is nil when the body was sent via HTTPBodyStream)
        if let reqBody = self.capturedRequestBody, reqBody.count > 0 {
            let maxBodySize = UInt(512 * 1024)
            if reqBody.count <= maxBodySize {
                model.requestData = reqBody
            } else {
                model.requestData = reqBody.subdata(in: 0..<Int(maxBodySize))
                model.isRequestBodyTruncated = true
            }
        }
        // NOTE: Do NOT re-read HTTPBodyStream here - it's already consumed by the URL loading
        // system at this point. The body was already converted to HTTPBody in startLoading.

        if let httpResponse = self.response as? HTTPURLResponse {
            model.statusCode = "\(httpResponse.statusCode)"
        } else {
            model.statusCode = "0"
        }

        model.size = ByteCountFormatter().string(fromByteCount: Int64(self.data?.length ?? 0))
        model.responseData = self.data as Data?  // setter writes to disk, frees NSData
        model.isResponseTruncated = self.responseTruncated
        model.isImage = (self.response?.mimeType?.range(of: "image") != nil)

        // Time
        let startTimeDouble = self.startTime
        let endTimeDouble = Date().timeIntervalSince1970
        let durationDouble = abs(endTimeDouble - startTimeDouble)

        model.startTime = String(format: "%f", startTimeDouble)
        model.endTime = String(format: "%f", endTimeDouble)
        model.totalDuration = String(format: "%f (s)", durationDouble)

        model.errorDescription = (self.error as NSError?)?.description
        model.errorLocalizedDescription = self.error?.localizedDescription
        model.requestHeaderFields = effectiveRequest.allHTTPHeaderFields as NSDictionary?

        if let httpResponse = self.response as? HTTPURLResponse {
            model.responseHeaderFields = httpResponse.allHeaderFields as NSDictionary
        }

        if self.response?.mimeType == nil {
            model.isImage = false
        }

        if let absoluteString = model.url?.absoluteString, absoluteString.count > 4 {
            let suffix4 = String(absoluteString.suffix(4))
            if suffix4 == ".png" || suffix4 == ".PNG" ||
               suffix4 == ".jpg" || suffix4 == ".JPG" ||
               suffix4 == ".gif" || suffix4 == ".GIF" {
                model.isImage = true
            }
        }
        if let absoluteString = model.url?.absoluteString, absoluteString.count > 5 {
            let suffix5 = String(absoluteString.suffix(5))
            if suffix5 == ".jpeg" || suffix5 == ".JPEG" {
                model.isImage = true
            }
        }

        // Response rewrites: `self.data` above is the body the app actually
        // received, so record what produced it. Reports are attached even when
        // nothing changed — an armed rewrite that matched zero values has to say
        // so somewhere, and this is the only place that survives the request.
        if let report = self.rewriteReport {
            model.recordRewriteReport(report, rewrites: self.resolvedRule?.responseRewrites ?? [])
        }

        // Handling errors 404...
        handleError(self.error, model: model)

        // Build the searchable metadata index once, while the response body is
        // still in memory (self.data). Avoids per-keystroke disk reads later.
        model.buildSearchIndex(responseBody: self.data as Data?)

        if NetworkRequestStore.shared.addHttpRequset(model) {
            NotificationCenter.default.post(
                name: .networkRequestCompleted,
                object: nil,
                userInfo: ["statusCode": model.statusCode ?? "0"]
            )
        }

        // Release accumulated data immediately - don't wait for dealloc.
        // The model now owns the data; keeping a second reference wastes memory.
        self.data = nil
        self.response = nil
        self.error = nil
        self.interceptedRequest = nil
        self.rewriteReport = nil
    }

    // MARK: Authentication challenge handling

    /// Performs the block on the specified thread in one of specified modes.
    private func performOnThread(_ thread: Thread?, modes: [String]?, block: @escaping () -> Void) {
        let effectiveThread = thread ?? Thread.main
        let effectiveModes = (modes?.isEmpty ?? true) ? [RunLoop.Mode.default.rawValue] : modes!
        let box = CPBlockBox(block)
        perform(#selector(onThreadPerformBlock(_:)),
                on: effectiveThread,
                with: box,
                waitUntilDone: false,
                modes: effectiveModes)
    }

    @objc private func onThreadPerformBlock(_ box: CPBlockBox) {
        box.block()
    }

    /// Called by our NSURLSession delegate callback to pass the challenge to our delegate.
    /// This simply passes the challenge over to the main thread.
    private func didReceiveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        performOnThread(nil, modes: nil) {
            self.mainThreadDidReceiveAuthenticationChallenge(challenge, completionHandler: completionHandler)
        }
    }

    /// The main thread side of authentication challenge processing.
    private func mainThreadDidReceiveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if self.pendingChallenge != nil {
            // Our delegate is not expecting a second authentication challenge before resolving the
            // first. Cancel the new challenge.
            clientThreadCancelAuthenticationChallenge(challenge, completionHandler: completionHandler)
        } else {
            let strongDelegate = type(of: self).getDelegate()

            if !(strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:canAuthenticateAgainstProtectionSpace:))) ?? false) {
                clientThreadCancelAuthenticationChallenge(challenge, completionHandler: completionHandler)
            } else {
                // Remember that this challenge is in progress.
                self.pendingChallenge = challenge
                self.pendingChallengeCompletionHandler = completionHandler

                // Pass the challenge to the delegate.
                strongDelegate?.customHTTPProtocol?(self, didReceiveAuthenticationChallenge: self.pendingChallenge!)
            }
        }
    }

    /// Cancels an authentication challenge that hasn't made it to the pending challenge state.
    private func clientThreadCancelAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        performOnThread(self.clientThread, modes: self.modes) {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Cancels an authentication challenge that /has/ made it to the pending challenge state.
    private func cancelPendingChallenge() {
        performOnThread(nil, modes: nil) {
            if self.pendingChallenge == nil {
                // Not unusual - happens every time you shut down the connection.
            } else {
                let strongDelegate = type(of: self).getDelegate()
                let challenge = self.pendingChallenge!
                self.pendingChallenge = nil
                self.pendingChallengeCompletionHandler = nil

                if strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:didCancelAuthenticationChallenge:))) ?? false {
                    strongDelegate?.customHTTPProtocol?(self, didCancelAuthenticationChallenge: challenge)
                }
            }
        }
    }

    @objc func resolveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                              withCredential credential: URLCredential?) {
        if challenge !== self.pendingChallenge {
            // This should never happen.
            return
        }

        let completionHandler = self.pendingChallengeCompletionHandler!
        self.pendingChallenge = nil
        self.pendingChallengeCompletionHandler = nil

        performOnThread(self.clientThread, modes: self.modes) {
            if credential == nil {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.useCredential, credential)
            }
        }
    }

    // MARK: Error handling

    @discardableResult
    private func handleError(_ error: Error?, model: NetworkTransaction) -> NetworkTransaction {
        if error == nil {
            // https://httpcodes.co/status/
            switch (model.statusCode as NSString?)?.integerValue ?? 0 {
            case 100:
                model.errorDescription = "Informational :\nClient should continue with request"
                model.errorLocalizedDescription = "Continue"
            case 101:
                model.errorDescription = "Informational :\nServer is switching protocols"
                model.errorLocalizedDescription = "Switching Protocols"
            case 102:
                model.errorDescription = "Informational :\nServer has received and is processing the request"
                model.errorLocalizedDescription = "Processing"
            case 103:
                model.errorDescription = "Informational :\nresume aborted PUT or POST requests"
                model.errorLocalizedDescription = "Checkpoint"
            case 122:
                model.errorDescription = "Informational :\nURI is longer than a maximum of 2083 characters"
                model.errorLocalizedDescription = "Request-URI too long"
            case 300:
                model.errorDescription = "Redirection :\nMultiple options for the resource delivered"
                model.errorLocalizedDescription = "Multiple Choices"
            case 301:
                model.errorDescription = "Redirection :\nThis and all future requests directed to the given URI"
                model.errorLocalizedDescription = "Moved Permanently"
            case 302:
                model.errorDescription = "Redirection :\nTemporary response to request found via alternative URI"
                model.errorLocalizedDescription = "Found"
            case 303:
                model.errorDescription = "Redirection :\nPermanent response to request found via alternative URI"
                model.errorLocalizedDescription = "See Other"
            case 304:
                model.errorDescription = "Redirection :\nResource has not been modified since last requested"
                model.errorLocalizedDescription = "Not Modified"
            case 305:
                model.errorDescription = "Redirection :\nContent located elsewhere, retrieve from there"
                model.errorLocalizedDescription = "Use Proxy"
            case 306:
                model.errorDescription = "Redirection :\nSubsequent requests should use the specified proxy"
                model.errorLocalizedDescription = "Switch Proxy"
            case 307:
                model.errorDescription = "Redirection :\nConnect again to different URI as provided"
                model.errorLocalizedDescription = "Temporary Redirect"
            case 308:
                model.errorDescription = "Redirection :\nConnect again to a different URI using the same method"
                model.errorLocalizedDescription = "Permanent Redirect"
            case 400:
                model.errorDescription = "Client Error :\nRequest cannot be fulfilled due to bad syntax"
                model.errorLocalizedDescription = "Bad Request"
            case 401:
                model.errorDescription = "Client Error :\nAuthentication is possible but has failed"
                model.errorLocalizedDescription = "Unauthorized"
            case 402:
                model.errorDescription = "Client Error :\nPayment required, reserved for future use"
                model.errorLocalizedDescription = "Payment Required"
            case 403:
                model.errorDescription = "Client Error :\nServer refuses to respond to request"
                model.errorLocalizedDescription = "Forbidden"
            case 404:
                model.errorDescription = "Client Error :\nRequested resource could not be found"
                model.errorLocalizedDescription = "Not Found"
            case 405:
                model.errorDescription = "Client Error :\nRequest method not supported by that resource"
                model.errorLocalizedDescription = "Method Not Allowed"
            case 406:
                model.errorDescription = "Client Error :\nContent not acceptable according to the Accept headers"
                model.errorLocalizedDescription = "Not Acceptable"
            case 407:
                model.errorDescription = "Client Error :\nClient must first authenticate itself with the proxy"
                model.errorLocalizedDescription = "Proxy Authentication Required"
            case 408:
                model.errorDescription = "Client Error :\nServer timed out waiting for the request"
                model.errorLocalizedDescription = "Request Timeout"
            case 409:
                model.errorDescription = "Client Error :\nRequest could not be processed because of conflict"
                model.errorLocalizedDescription = "Conflict"
            case 410:
                model.errorDescription = "Client Error :\nResource is no longer available and will not be available again"
                model.errorLocalizedDescription = "Gone"
            case 411:
                model.errorDescription = "Client Error :\nRequest did not specify the length of its content"
                model.errorLocalizedDescription = "Length Required"
            case 412:
                model.errorDescription = "Client Error :\nServer does not meet request preconditions"
                model.errorLocalizedDescription = "Precondition Failed"
            case 413:
                model.errorDescription = "Client Error :\nRequest is larger than the server is willing or able to process"
                model.errorLocalizedDescription = "Request Entity Too Large"
            case 414:
                model.errorDescription = "Client Error :\nURI provided was too long for the server to process"
                model.errorLocalizedDescription = "Request-URI Too Long"
            case 415:
                model.errorDescription = "Client Error :\nServer does not support media type"
                model.errorLocalizedDescription = "Unsupported Media Type"
            case 416:
                model.errorDescription = "Client Error :\nClient has asked for unprovidable portion of the file"
                model.errorLocalizedDescription = "Requested Range Not Satisfiable"
            case 417:
                model.errorDescription = "Client Error :\nServer cannot meet requirements of Expect request-header field"
                model.errorLocalizedDescription = "Expectation Failed"
            case 418:
                model.errorDescription = "Client Error :\nI'm a teapot"
                model.errorLocalizedDescription = "I'm a Teapot"
            case 420:
                model.errorDescription = "Client Error :\nTwitter rate limiting"
                model.errorLocalizedDescription = "Enhance Your Calm"
            case 421:
                model.errorDescription = "Client Error :\nMisdirected Request"
                model.errorLocalizedDescription = "Misdirected Request"
            case 422:
                model.errorDescription = "Client Error :\nRequest unable to be followed due to semantic errors"
                model.errorLocalizedDescription = "Unprocessable Entity"
            case 423:
                model.errorDescription = "Client Error :\nResource that is being accessed is locked"
                model.errorLocalizedDescription = "Locked"
            case 424:
                model.errorDescription = "Client Error :\nRequest failed due to failure of a previous request"
                model.errorLocalizedDescription = "Failed Dependency"
            case 426:
                model.errorDescription = "Client Error :\nClient should switch to a different protocol"
                model.errorLocalizedDescription = "Upgrade Required"
            case 428:
                model.errorDescription = "Client Error :\nOrigin server requires the request to be conditional"
                model.errorLocalizedDescription = "Precondition Required"
            case 429:
                model.errorDescription = "Client Error :\nUser has sent too many requests in a given amount of time"
                model.errorLocalizedDescription = "Too Many Requests"
            case 431:
                model.errorDescription = "Client Error :\nServer is unwilling to process the request"
                model.errorLocalizedDescription = "Request Header Fields Too Large"
            case 444:
                model.errorDescription = "Client Error :\nServer returns no information and closes the connection"
                model.errorLocalizedDescription = "No Response"
            case 449:
                model.errorDescription = "Client Error :\nRequest should be retried after performing action"
                model.errorLocalizedDescription = "Retry With"
            case 450:
                model.errorDescription = "Client Error :\nWindows Parental Controls blocking access to webpage"
                model.errorLocalizedDescription = "Blocked by Windows Parental Controls"
            case 451:
                model.errorDescription = "Client Error :\nThe server cannot reach the client's mailbox"
                model.errorLocalizedDescription = "Wrong Exchange server"
            case 499:
                model.errorDescription = "Client Error :\nConnection closed by client while HTTP server is processing"
                model.errorLocalizedDescription = "Client Closed Request"
            case 500:
                model.errorDescription = "Server Error :\ngeneric error message"
                model.errorLocalizedDescription = "Internal Server Error"
            case 501:
                model.errorDescription = "Server Error :\nserver does not recognise method or lacks ability to fulfill"
                model.errorLocalizedDescription = "Not Implemented"
            case 502:
                model.errorDescription = "Server Error :\nserver received an invalid response from upstream server"
                model.errorLocalizedDescription = "Bad Gateway"
            case 503:
                model.errorDescription = "Server Error :\nserver is currently unavailable"
                model.errorLocalizedDescription = "Service Unavailable"
            case 504:
                model.errorDescription = "Server Error :\ngateway did not receive response from upstream server"
                model.errorLocalizedDescription = "Gateway Timeout"
            case 505:
                model.errorDescription = "Server Error :\nserver does not support the HTTP protocol version"
                model.errorLocalizedDescription = "HTTP Version Not Supported"
            case 506:
                model.errorDescription = "Server Error :\ncontent negotiation for the request results in a circular reference"
                model.errorLocalizedDescription = "Variant Also Negotiates"
            case 507:
                model.errorDescription = "Server Error :\nserver is unable to store the representation"
                model.errorLocalizedDescription = "Insufficient Storage"
            case 508:
                model.errorDescription = "Server Error :\nserver detected an infinite loop while processing the request"
                model.errorLocalizedDescription = "Loop Detected"
            case 509:
                model.errorDescription = "Server Error :\nbandwidth limit exceeded"
                model.errorLocalizedDescription = "Bandwidth Limit Exceeded"
            case 510:
                model.errorDescription = "Server Error :\nfurther extensions to the request are required"
                model.errorLocalizedDescription = "Not Extended"
            case 511:
                model.errorDescription = "Server Error :\nclient needs to authenticate to gain network access"
                model.errorLocalizedDescription = "Network Authentication Required"
            case 526:
                model.errorDescription = "Server Error :\nThe origin web server does not have a valid SSL certificate"
                model.errorLocalizedDescription = "Invalid SSL certificate"
            case 598:
                model.errorDescription = "Server Error :\nnetwork read timeout behind the proxy"
                model.errorLocalizedDescription = "Network Read Timeout Error"
            case 599:
                model.errorDescription = "Server Error :\nnetwork connect timeout behind the proxy"
                model.errorLocalizedDescription = "Network Connect Timeout Error"
            default:
                break
            }
        }
        return model
    }
}

// MARK: - URLSessionDataDelegate

extension CustomHTTPProtocol: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirect: code >= 300 && < 400
        var redirectedRequest: URLRequest? = request
        if response.statusCode >= 300 && response.statusCode < 400 {
            self.client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
            // Remember to set to nil, otherwise the normal request will be requested twice
            redirectedRequest = nil
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Ask our delegate whether it wants this challenge. We do this from this thread, not the
        // main thread, to avoid the overload of bouncing to the main thread for challenges that
        // aren't going to be customised anyway.
        let strongDelegate = type(of: self).getDelegate()

        var result = false
        if strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:canAuthenticateAgainstProtectionSpace:))) ?? false {
            result = strongDelegate!.customHTTPProtocol?(self, canAuthenticateAgainstProtectionSpace: challenge.protectionSpace) ?? false
        }

        // If the client wants the challenge, kick off that process. If not, resolve it by doing
        // the default thing.
        if result {
            didReceiveAuthenticationChallenge(challenge, completionHandler: completionHandler)
        } else {
            // Callback the original method
            let challengeWrapper = URLAuthenticationChallenge(
                authenticationChallenge: challenge,
                sender: CPURLSessionChallengeSender(sessionCompletionHandler: completionHandler)
            )
            self.client?.urlProtocol(self, didReceive: challengeWrapper)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Pass the call on to our client. The only tricky thing is that we have to decide on a
        // cache storage policy, which is based on the actual request we issued, not the request
        // we were given.
        let cacheStoragePolicy: URLCache.StoragePolicy
        if let httpResponse = response as? HTTPURLResponse {
            cacheStoragePolicy = CacheStoragePolicyForRequestAndResponse(
                self._dataTask?.originalRequest ?? self.request,
                httpResponse
            )
        } else {
            cacheStoragePolicy = .notAllowed
        }

        // Two things need the WHOLE body before the app sees any of it, and both
        // buffer here instead of streaming:
        //  • an `.afterResponse` breakpoint (the body has to be editable first —
        //    see BREAKPOINTS), and
        //  • armed response rewrites (a JSON document cannot be rewritten one
        //    chunk at a time — see RESPONSE-REWRITE).
        // Which runs first is decided in `didCompleteWithError`, not here.
        let holdForBreakpoint = (self.resolvedRule?.breakpointMode == .afterResponse)
        let holdForRewrites = shouldBufferForRewrites(response)
        if holdForBreakpoint || holdForRewrites {
            self.isHoldingResponse = true
            self.isHoldingForRewriteOnly = holdForRewrites && !holdForBreakpoint
            self.heldResponse = response
            self.heldCacheStoragePolicy = cacheStoragePolicy
            self.response = response
            completionHandler(.allow)
            return
        }

        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: cacheStoragePolicy)

        self.response = response

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        // WHILE A HOLD IS ON, `self.data` IS NOT JUST SWIFTYDEBUG'S CAPTURE — it
        // is the only copy of the body the app will ever get, because nothing has
        // been streamed to the client. Letting the capture cap below truncate it
        // means `deliverHeldResponse` hands the app a short body behind a
        // Content-Length that matches the short body: a well-formed response the
        // app cannot tell from a complete one.
        //
        // So a hold is bounded, and reaching the bound GIVES THE HOLD UP rather
        // than shortening the body: whatever was buffered is flushed, the rest
        // streams normally, and the reason is recorded on the transaction.
        if self.isHoldingResponse,
           let reason = Self.holdAbandonReason(bufferedBytes: self.data?.length ?? 0,
                                               incomingBytes: data.count,
                                               isHoldingForRewriteOnly: self.isHoldingForRewriteOnly) {
            abandonHold(reason)
        }

        // While holding for an `.afterResponse` breakpoint, accumulate only —
        // the client must not see any bytes until the developer releases it.
        if !self.isHoldingResponse {
            self.client?.urlProtocol(self, didLoad: data)
        }

        // Only accumulate for SwiftyDebug's capture if under the size cap.
        // The client always receives the full, unmodified data above — and the
        // block above guarantees we are no longer holding by the time this can
        // truncate anything.
        if !self.responseTruncated {
            let maxSize = Self.maxCapturedResponseBytes
            let currentLength = self.data?.length ?? 0
            if currentLength + data.count <= maxSize {
                self.data?.append(data)
            } else {
                let remaining = maxSize - currentLength
                if remaining > 0 {
                    self.data?.append(data.subdata(in: 0..<remaining))
                }
                self.responseTruncated = true
            }
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(proposedResponse)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            // A failure releases any hold — nothing to edit.
            self.isHoldingResponse = false
            self.isHoldingForRewriteOnly = false
            // `stopLoading()` cancels the task, and CFNetwork reports that back
            // here as NSURLErrorCancelled. The client already knows — it is the
            // one that asked — and calling didFailWithError after stopLoading is
            // not allowed, so this is swallowed. (The comment in `stopLoading`
            // has always promised this trap; it just was not here.) Redirects
            // report the same error for the same reason.
            guard !Self.isClientInitiatedCancellation(error, didCancel: self.didCancelOwnTask) else { return }
            self.client?.urlProtocol(self, didFailWithError: error)
            self.error = error
            return
        }

        guard self.isHoldingResponse else {
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }

        // ORDER OF THE THREE WAYS A BODY CAN BE CHANGED — deliberate:
        //
        //  1. A MOCK never reaches this method. It replaces the response
        //     entirely in `startLoading()` and never touches the network, so
        //     rewrites do not apply to mocked bodies (see the comment there).
        //  2. REWRITES run HERE, on the complete body, before anything else
        //     sees it — including SwiftyDebug's own capture.
        //  3. The `.afterResponse` BREAKPOINT parks the ALREADY-rewritten body,
        //     so the editor shows what the rules produced and any manual edit
        //     composes on top of them instead of fighting them.
        let deliverableBody = applyResponseRewrites(to: self.data as Data? ?? Data())
        let didRewrite = (self.rewriteReport?.didChange == true)
        if didRewrite {
            // Keep the captured transaction honest: what the UI shows is what
            // the app actually received.
            self.data = NSMutableData(data: deliverableBody)
        }

        // No breakpoint — the rewrite was the only reason we held. Deliver now.
        // Headers are only rebuilt when the bytes actually changed, so an
        // untouched body is delivered exactly as it would have been streamed.
        guard self.resolvedRule?.breakpointMode == .afterResponse else {
            deliverHeldResponse(body: deliverableBody, rebuildHeaders: didRewrite)
            return
        }

        // `.afterResponse` breakpoint: park the buffered response for editing
        // instead of finishing. The app stays waiting until it's released.
        let paused = BreakpointCenter.PausedRequest(
            stage: .afterResponse,
            request: self.interceptedRequest ?? self.request,
            response: self.heldResponse as? HTTPURLResponse,
            responseBody: deliverableBody,
            resume: { [weak self] edited in
                guard let self else { return }
                self.performOnThread(self.clientThread, modes: self.modes) {
                    self.deliverHeldResponse(body: edited.responseBody ?? Data())
                }
            },
            abort: { [weak self] in
                guard let self else { return }
                self.performOnThread(self.clientThread, modes: self.modes) {
                    self.isHoldingResponse = false
                    self.client?.urlProtocol(self, didFailWithError: NSError(
                        domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "Aborted at breakpoint"]))
                }
            }
        )
        self.parkedBreakpoint = paused
        BreakpointCenter.shared.park(paused)
    }

    /// True for the completion error CFNetwork reports after our own
    /// `stopLoading()` cancelled the task. Pure, so it can be unit-tested.
    ///
    /// `didCancel` is what makes this safe to swallow. Matching on the error
    /// alone would swallow EVERY -999 — including one we did not cause — and an
    /// unconditional early return here delivers no terminal callback at all,
    /// leaving a host-app request that never resolves. A hang is worse than the
    /// spurious error the trap exists to avoid, so anything we did not cancel
    /// ourselves is still reported.
    static func isClientInitiatedCancellation(_ error: Error, didCancel: Bool) -> Bool {
        guard didCancel else { return false }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Response rewrites (see RESPONSE-REWRITE)

    /// Decides — before a single byte is buffered — whether this response is
    /// worth holding for `ResponseRewriteEngine`.
    ///
    /// This runs on every response a rule matches, so it bails on the cheapest
    /// checks first: nothing armed, a Content-Type that cannot be JSON, or a
    /// declared length past the engine's cap. When rewrites ARE armed but the
    /// response is skipped, the reason is recorded — an armed rule that quietly
    /// does nothing is exactly the failure this feature must not produce.
    private func shouldBufferForRewrites(_ response: URLResponse) -> Bool {
        guard let rule = resolvedRule, rule.hasActiveResponseRewrites else { return false }

        let expected = response.expectedContentLength
        if expected > Int64(ResponseRewriteEngine.maxBodyBytes) {
            let limit = ResponseRewriteEngine.maxBodyBytes / 1024 / 1024
            rewriteReport = RewriteReport(skippedReason:
                "The response declares \(ByteCountFormatter().string(fromByteCount: expected)), "
                + "past the \(limit) MB rewrite limit, so rewrites were skipped.")
            return false
        }

        guard Self.mimeTypeCanBeJSON(response.mimeType) else {
            rewriteReport = RewriteReport(skippedReason:
                "The response is \(response.mimeType ?? "an unknown type"), not JSON, "
                + "so rewrites were skipped.")
            return false
        }
        return true
    }

    /// Cheap Content-Type pre-filter, kept `static` so it is unit-testable.
    ///
    /// Deliberately permissive at the edges: no Content-Type at all means "let
    /// the engine's JSON parse decide", and `text/*` covers the servers that
    /// send JSON as `text/plain`. Anything else (images, video, protobuf,
    /// octet-stream) is refused here so a binary download is never buffered.
    static func mimeTypeCanBeJSON(_ mimeType: String?) -> Bool {
        guard let mime = mimeType?.lowercased().trimmingCharacters(in: .whitespaces),
              !mime.isEmpty else { return true }
        return mime.contains("json") || mime.hasPrefix("text/")
    }

    /// Applies the resolved rule's rewrites to the finished body, returning the
    /// bytes to deliver. Returns `body` unchanged whenever nothing applied.
    private func applyResponseRewrites(to body: Data) -> Data {
        guard let rule = resolvedRule, rule.hasActiveResponseRewrites else { return body }
        // Already ruled out before we buffered (too big / not JSON). Don't redo
        // the work, and don't clobber the reason the detail screen will show.
        guard rewriteReport?.skippedReason == nil else { return body }

        // Synchronous on the delivery thread, and safe to be: the engine caps
        // the body it will parse (2 MB) and the number of nodes a pattern may
        // visit, so this is bounded work, not an open-ended traversal.
        let (rewritten, report) = ResponseRewriteEngine.apply(rule.responseRewrites, to: body)
        rewriteReport = report
        return rewritten
    }

    // MARK: - Bounding a hold (see B3 / truncated deliveries)

    /// Why a hold had to be given up mid-stream.
    enum HoldAbandonReason: Equatable {
        /// Rewrite-only hold: the body outgrew the rewrite engine's cap, so
        /// there is nothing left to rewrite anyway.
        case rewriteLimitExceeded
        /// The body outgrew the buffer SwiftyDebug is willing to hold. Keeping
        /// the hold would mean truncating the only copy of the body the app is
        /// going to get.
        case holdBufferExceeded
    }

    /// Whether the in-flight hold must be given up before `incomingBytes` more
    /// bytes are buffered. Pure, so the bound can be unit-tested.
    ///
    /// A rewrite-only hold is bounded by the engine's own cap — past it there is
    /// nothing left to rewrite. Every other hold (i.e. one that includes an
    /// `.afterResponse` breakpoint) is bounded by the capture cap, because that
    /// buffer is what gets delivered.
    static func holdAbandonReason(bufferedBytes: Int,
                                  incomingBytes: Int,
                                  isHoldingForRewriteOnly: Bool) -> HoldAbandonReason? {
        let projected = bufferedBytes + incomingBytes
        if isHoldingForRewriteOnly, projected > ResponseRewriteEngine.maxBodyBytes {
            return .rewriteLimitExceeded
        }
        if projected > maxCapturedResponseBytes {
            return .holdBufferExceeded
        }
        return nil
    }

    /// The sentence shown on the transaction when a hold is abandoned. Pure so
    /// the wording is pinned by tests — a hold that silently does nothing is the
    /// exact failure these limits must not produce.
    static func holdAbandonedMessage(_ reason: HoldAbandonReason) -> String {
        switch reason {
        case .rewriteLimitExceeded:
            let limit = ResponseRewriteEngine.maxBodyBytes / 1024 / 1024
            return "The response body grew past the \(limit) MB rewrite limit, so rewrites were skipped."
        case .holdBufferExceeded:
            let limit = maxCapturedResponseBytes / 1024 / 1024
            return "The response body grew past the \(limit) MB hold limit. "
                 + "The breakpoint was released and the body was streamed to the app "
                 + "in full, unedited — nothing was truncated."
        }
    }

    /// Gives up a hold mid-stream: flushes the buffered head to the client and
    /// returns to normal streaming, so the app receives the complete body.
    ///
    /// For `.holdBufferExceeded` this also means the `.afterResponse` breakpoint
    /// never fires. Nothing has been parked yet at this point (parking happens in
    /// `didCompleteWithError`), so there is no inbox row to remove — the reason is
    /// recorded on the transaction instead, which is where the developer looking
    /// for their missing pause ends up.
    private func abandonHold(_ reason: HoldAbandonReason) {
        isHoldingResponse = false
        isHoldingForRewriteOnly = false
        // A reason may already be recorded (e.g. "not JSON, so rewrites were
        // skipped"). Both are true and both are worth reading, so append rather
        // than replace — the developer is chasing one missing effect or the other.
        let message = Self.holdAbandonedMessage(reason)
        if let existing = rewriteReport?.skippedReason, !existing.isEmpty {
            rewriteReport?.skippedReason = existing + " " + message
        } else {
            rewriteReport = RewriteReport(skippedReason: message)
        }
        // A given-up BREAKPOINT hold is not a rewrite fact — surface it where the
        // developer is waiting for the pause that never came.
        if reason == .holdBufferExceeded {
            BreakpointCenter.shared.note(message, for: (self.interceptedRequest ?? self.request).url)
        }

        if let held = heldResponse {
            client?.urlProtocol(self, didReceive: held, cacheStoragePolicy: heldCacheStoragePolicy)
        }
        if let buffered = self.data as Data?, !buffered.isEmpty {
            client?.urlProtocol(self, didLoad: buffered)
        }
        heldResponse = nil
    }

    /// Delivers the (possibly edited or rewritten) buffered response to the app.
    ///
    /// `rebuildHeaders` must be true whenever the bytes differ from what the
    /// server sent. It is false only for a body we buffered but did not touch,
    /// which is then delivered byte- and header-identical to the streamed path.
    private func deliverHeldResponse(body: Data, rebuildHeaders: Bool = true) {
        isHoldingResponse = false
        isHoldingForRewriteOnly = false
        guard let original = heldResponse else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Keep what the UI shows in sync with what the app actually received.
        self.data = NSMutableData(data: body)

        // CRITICAL: the original response's headers describe the ORIGINAL body.
        // Delivering an edited body behind them breaks the app in two ways:
        //  • `Content-Length` no longer matches — CFNetwork truncates the edited
        //    body back to the old length (or treats it as incomplete), so the app
        //    decodes garbage and shows nothing.
        //  • `Content-Encoding: gzip` is a lie — URLSession already decompressed
        //    what we buffered, so our edited body is plain text and the client
        //    would try to gunzip it.
        // Rebuild the response so the headers describe what we actually send.
        // Non-HTTP responses have no headers to correct, so they pass through.
        let response: URLResponse
        if rebuildHeaders {
            response = (original as? HTTPURLResponse)
                .flatMap { Self.responseForEditedBody(original: $0, bodyLength: body.count) } ?? original
        } else {
            response = original
        }

        // A body we changed must never be cached — the cache would then serve
        // SwiftyDebug's edit long after the rule was switched off.
        let policy: URLCache.StoragePolicy = rebuildHeaders ? .notAllowed : heldCacheStoragePolicy
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: policy)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Rebuilds an `HTTPURLResponse` so its headers match an edited body:
    /// corrects `Content-Length` and drops the encoding headers that no longer
    /// apply. Returns nil only if the response can't be reconstructed.
    static func responseForEditedBody(original: HTTPURLResponse, bodyLength: Int) -> HTTPURLResponse? {
        guard let url = original.url else { return nil }
        // Non-string header keys (never produced by CFNetwork) are dropped.
        let headers = Self.headersForEditedBody(
            original: original.allHeaderFields, bodyLength: bodyLength)
        return HTTPURLResponse(url: url,
                               statusCode: original.statusCode,
                               httpVersion: "HTTP/1.1",
                               headerFields: headers)
    }

    /// Pure header transform — extracted so it can be unit-tested.
    static func headersForEditedBody(original: [AnyHashable: Any], bodyLength: Int) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in original {
            guard let name = key as? String else { continue }
            let lower = name.lowercased()
            // These describe the ORIGINAL bytes and are wrong for an edited body.
            if lower == "content-length" || lower == "content-encoding" || lower == "transfer-encoding" {
                continue
            }
            out[name] = "\(value)"
        }
        out["Content-Length"] = "\(bodyLength)"
        return out
    }
}
