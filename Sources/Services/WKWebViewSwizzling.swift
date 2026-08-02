//
//  WKWebViewSwizzling.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import WebKit
import ObjectiveC

// MARK: - WKScriptMessageProxy

/// Wraps an app-registered WKScriptMessageHandler so SwiftyDebug can log the
/// message before forwarding it to the original handler.
///
/// - Important: the original handler is held **strongly**, on purpose. Apple's
///   documented ownership model is that `WKUserContentController.add(_:name:)`
///   retains the handler, and apps commonly register a handler object relying on
///   WebKit to keep it alive. Since we swap our proxy in as the registered
///   handler, the proxy must strongly retain the app's handler or the app would
///   silently stop receiving its own messages. This proxy references no web view
///   or configuration, so it cannot participate in the WKWebView retain cycle —
///   that leak is fixed separately by registering SwiftyDebug's *own* handler
///   through `WeakScriptMessageHandler` pointing at an immortal shared instance.
///   (See WEBVIEW-LEAK.)
class WKScriptMessageProxy: NSObject, WKScriptMessageHandler {

    let originalHandler: WKScriptMessageHandler

    init(originalHandler: WKScriptMessageHandler) {
        self.originalHandler = originalHandler
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Skip all work when the SDK is fully stopped.
        if SwiftyDebugRuntime.isActive {
            // Log to SwiftyDebug Logs tab (Web section)
            LogEntryBuilder.handleLog(
                file: "[WKWebView]",
                function: message.name,
                line: 0,
                message: "\(message.body)",
                color: .cyan,
                type: .none
            )
        }

        // Forward to original handler
        if originalHandler.responds(to: #selector(WKScriptMessageHandler.userContentController(_:didReceive:))) {
            originalHandler.userContentController(userContentController, didReceive: message)
        }
    }
}

// MARK: - WeakScriptMessageHandler

/// A weak forwarding shim for SwiftyDebug's *own* handler. Registering a handler
/// with `WKUserContentController` creates a strong retain from the content
/// controller (owned by the web view's configuration) to the handler. By
/// registering this shim instead of the real handler, and having the shim point
/// weakly at a single shared handler, no per-web-view strong retain cycle keeps
/// the web view alive. (See WEBVIEW-LEAK.)
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {

    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard SwiftyDebugRuntime.isActive else { return }
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Native cookie overrides

/// One cookie the SDK places in a web view's cookie store to honour a `Cookie:`
/// header override.
///
/// `domain` always comes from the **rule's own** host list — never from whatever
/// page the web view happens to be showing. A rule for `api.a.com` that deposited
/// its cookie on `b.com` would be handing one site's credentials to another.
struct NativeCookieOverride: Equatable {

    /// What makes two writes "the same cookie" as far as the store is concerned.
    /// The value is excluded on purpose: re-writing a changed value must update
    /// the cookie, not delete-then-add it.
    struct Identity: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    let name: String
    let value: String
    let domain: String
    var path: String { "/" }

    var identity: Identity {
        Identity(name: name, domain: NativeCookieOverride.normalizedDomain(domain), path: path)
    }

    /// A cookie set for `example.com` reads back as `example.com` or
    /// `.example.com` depending on how it was created, so compare without the
    /// leading dot or a stale entry never matches and never gets deleted.
    static func normalizedDomain(_ domain: String) -> String {
        var d = domain.lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        return d
    }

    static func identity(of cookie: HTTPCookie) -> Identity {
        Identity(name: cookie.name,
                 domain: normalizedDomain(cookie.domain),
                 path: cookie.path.isEmpty ? "/" : cookie.path)
    }

    var httpCookie: HTTPCookie? {
        HTTPCookie(properties: [.name: name, .value: value, .path: path, .domain: domain])
    }
}

/// Remembers every cookie the SDK wrote on behalf of a Cookie header override,
/// so disabling or deleting the rule takes back exactly those cookies and
/// nothing else.
///
/// Holds the cookie stores strongly (they are per-`WKWebsiteDataStore`, normally
/// one process-wide) rather than the web views, so a rule can still be undone
/// after the web view that triggered it is gone. Holding the store is also what
/// makes the `ObjectIdentifier` key safe: a tracked store cannot deallocate, so
/// its address cannot be handed to a different one.
///
/// Main-thread only, like everything else here: it is driven by web-view creation
/// and by the rules-changed notification, both of which are main-thread.
///
/// Known gap, stated rather than hidden: cookies written by a build that predates
/// this bookkeeping are not attributable to any rule and are therefore left
/// alone. Deleting by name alone could remove the app's real session cookie.
final class NativeCookieOverrideStore {

    static let shared = NativeCookieOverrideStore()

    private struct Entry {
        let store: WKHTTPCookieStore
        var written: Set<NativeCookieOverride.Identity>
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    /// What a reconcile turns into store calls.
    ///
    /// Pure, because "which cookies does the SDK take back" is the half of this
    /// feature that can destroy the app's own session if it is too eager. Note
    /// the deletion set is drawn from `previous` only — a cookie the SDK never
    /// wrote is never a candidate, however much it looks like one of ours.
    static func reconciliation(
        previous: Set<NativeCookieOverride.Identity>,
        desired: [NativeCookieOverride]
    ) -> (delete: Set<NativeCookieOverride.Identity>, write: [NativeCookieOverride]) {
        (previous.subtracting(desired.map(\.identity)), desired)
    }

    /// Makes `store` hold exactly `desired` of the SDK's cookies: writes the
    /// wanted ones, deletes the previously-written ones that are no longer
    /// wanted, and touches nothing else in the store.
    func reconcile(_ desired: [NativeCookieOverride], in store: WKHTTPCookieStore) {
        let key = ObjectIdentifier(store)
        let plan = Self.reconciliation(previous: entries[key]?.written ?? [], desired: desired)

        if !plan.delete.isEmpty {
            let stale = plan.delete
            store.getAllCookies { cookies in
                for cookie in cookies where stale.contains(NativeCookieOverride.identity(of: cookie)) {
                    store.delete(cookie, completionHandler: nil)
                }
            }
        }

        var applied: Set<NativeCookieOverride.Identity> = []
        for override in plan.write {
            guard let cookie = override.httpCookie else {
                WKWebViewSwizzling.logCookieOverrideSkipped(
                    reason: "“\(override.name)” could not be built for domain \(override.domain) "
                          + "(rejected by HTTPCookie).")
                continue
            }
            store.setCookie(cookie, completionHandler: nil)
            applied.insert(override.identity)
        }

        // Nothing of ours is left here, so stop tracking the store rather than
        // holding it alive for an empty set.
        if applied.isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = Entry(store: store, written: applied)
        }
    }
}

// MARK: - Script message channel names

/// Every `WKScriptMessageHandler` name this SDK registers.
///
/// The names are namespaced (`__swiftydebug_…`) because the handler table they
/// live in belongs to the **host app's** `WKUserContentController`, not to one
/// the SDK owns. Generic names (`log`, `error`, `info`, `networkCapture`) collide
/// with the app's own JS bridge in two ways, both of them observed:
///
///  * the app registers `log` *after* creating its web view → WebKit raises
///    `NSInvalidArgumentException` ("…when one already exists"), which is
///    uncatchable from Swift, and the host app crashes on a screen that worked
///    before SwiftyDebug was linked;
///  * the app registers `log` *before* creating it → a blanket
///    `removeScriptMessageHandler(forName:)` silently unregisters it, and the
///    app's bridge is dead with no error anywhere.
///
/// Hence the two rules this type exists to enforce: namespaced names only, and
/// the SDK never removes a name it did not itself add.
enum WebViewMessageChannel {

    /// Long enough that a collision with an app-registered name is not a
    /// realistic accident.
    static let prefix = "__swiftydebug_"

    /// The `console` functions that get a channel each.
    static let consoleFunctions = ["log", "error", "warn", "debug", "info"]

    static func console(_ consoleFunction: String) -> String { prefix + consoleFunction }

    static let networkCapture = prefix + "networkCapture"

    /// The page asking native for the current intercept rules at document start.
    static let rulesRequest = prefix + "rulesRequest"

    /// The page telling native it has parsed, so pinned storage can be re-applied.
    static let storagePins = prefix + "storagePins"

    /// Every channel the SDK can register, in registration order.
    static var all: [String] {
        consoleFunctions.map(console) + [networkCapture, rulesRequest, storagePins]
    }

    /// The name shown in the Logs tab. The namespace is an implementation
    /// detail; a developer reading their own `console.warn` should see "warn".
    static func displayName(for channel: String) -> String {
        channel.hasPrefix(prefix) ? String(channel.dropFirst(prefix.count)) : channel
    }
}

/// Stable addresses for the per-content-controller bookkeeping below. Addresses
/// rather than `ObjectIdentifier` sets, because an identifier can be recycled
/// once the original object deallocates.
private let sdkHandlerNamesKey = UnsafeRawPointer(
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
private let sdkInstrumentedKey = UnsafeRawPointer(
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

/// Marks a web view whose `customUserAgent` **this SDK** set, so it can be given
/// back when the rule goes away.
///
/// An address, not a `String`. A Swift string literal used as an associated
/// object key is not a stable pointer: at `-Onone` — which is how this debug-only
/// SDK ships — each reference can bridge to a fresh `NSString`, so the write and
/// the read use different keys, the read-back returns nil, and the override is
/// never reverted. It happens to work at `-O` through constant folding, which is
/// why a Release build will not show it. (See WEBVIEW-UA-REVERT.)
private let sdkSetUserAgentKey = UnsafeRawPointer(
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

extension WKUserContentController {

    /// The channels **this SDK** registered on this content controller. Anything
    /// not in here belongs to the host app and is untouchable.
    var swiftyDebugHandlerNames: [String] {
        get { objc_getAssociatedObject(self, sdkHandlerNamesKey) as? [String] ?? [] }
        set { objc_setAssociatedObject(self, sdkHandlerNamesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// True once the SDK's user scripts are installed here.
    ///
    /// A `WKWebViewConfiguration` copy shares its `userContentController`, so
    /// `window.open` / `target="_blank"` children — and any app that reuses one
    /// configuration for several web views — land on the same controller. Without
    /// this flag every such web view appended another copy of every script and
    /// re-registered every handler, growing without bound (and, since WebKit
    /// throws on a duplicate handler name, crashing).
    var isSwiftyDebugInstrumented: Bool {
        get { objc_getAssociatedObject(self, sdkInstrumentedKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, sdkInstrumentedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Registers one of the SDK's own channels, at most once per controller.
    ///
    /// Deliberately does **not** call `removeScriptMessageHandler(forName:)`
    /// first: that call cannot distinguish "a name I added" from "the app's
    /// bridge", and removing the latter kills it silently. The record above is
    /// what prevents the duplicate-name exception instead.
    func swiftyDebugAddHandler(_ handler: WKScriptMessageHandler, name: String) {
        guard !swiftyDebugHandlerNames.contains(name) else { return }
        add(handler, name: name)
        swiftyDebugHandlerNames.append(name)
    }

    /// Teardown. Removes only the channels this SDK added — never a name the app
    /// registered, even if the app happened to choose one of ours.
    ///
    /// No-op when the SDK never registered anything here, which is the case for
    /// every web view created while the SDK was stopped.
    func swiftyDebugRemoveOwnHandlers() {
        let names = swiftyDebugHandlerNames
        guard !names.isEmpty else { return }
        for name in names { removeScriptMessageHandler(forName: name) }
        swiftyDebugHandlerNames = []
    }
}

// MARK: - WKWebView Swizzling

@objc class WKWebViewSwizzling: NSObject {

    private static var swizzled = false
    private static var notificationObserver: NSObjectProtocol?

    /// Weak set of all live WKWebView instances so we can push rule updates.
    static let trackedWebViews = NSHashTable<WKWebView>.weakObjects()

    /// A single shared handler that actually processes SwiftyDebug's own
    /// messages (console + networkCapture). Web views register a *weak* shim
    /// pointing at this instance rather than retaining a per-web-view handler,
    /// which is what keeps WKWebViews from leaking. (See WEBVIEW-LEAK.)
    static let sharedScriptHandler = WKWebViewScriptHandler()

    /// Call once (e.g. from `SwiftyDebug.enable()`) to install all swizzles.
    /// Idempotent — always enabled.
    @objc static func enableIfNeeded() {
        guard !swizzled else { return }
        swizzled = true
        performSwizzling()
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .interceptRulesDidChange,
            object: nil,
            queue: .main
        ) { _ in
            pushRulesToWebViews()
        }
    }

    /// Push latest intercept rules to all tracked WKWebViews.
    private static func pushRulesToWebViews() {
        guard SwiftyDebugRuntime.isActive else { return }
        let json = InterceptRuleStore.shared.rulesAsJSONString()
        let js = "if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(json));"
        for webView in trackedWebViews.allObjects {
            webView.evaluateJavaScript(js, completionHandler: nil)
            applyNativeForbiddenHeaders(to: webView)
        }
    }

    /// Applies the two request headers that JavaScript **cannot** set on webview
    /// requests (they are "forbidden headers" per the Fetch spec and are silently
    /// dropped by `setRequestHeader`/`fetch`): `User-Agent` and `Cookie`.
    ///
    /// These are the only forbidden headers with a supported native override on
    /// iOS — `WKWebView.customUserAgent` and `WKHTTPCookieStore`. Every other
    /// forbidden header (Host, Origin, Referer, …) has no supported override on
    /// arbitrary host-app web views, so header rules targeting those are
    /// best-effort JS only (and surfaced as such in the editor UI).
    ///
    /// Note: `WKURLSchemeHandler` is intentionally **not** used — WebKit refuses
    /// to register scheme handlers for `http`/`https`, so it cannot rewrite real
    /// page traffic.
    static func applyNativeForbiddenHeaders(to webView: WKWebView) {
        guard SwiftyDebugRuntime.isActive else { return }

        // The User-Agent override: only broad rules (host/global) can be applied
        // natively at the web-view level, since `customUserAgent` is not
        // per-request. We can only set one per web view, so the last-writing rule
        // wins, matching the "later rule overrides" composition used elsewhere.
        var userAgent: String?
        for rule in InterceptRuleStore.shared.allRules() where rule.isEnabled {
            guard rule.matchMode == .host || rule.matchMode == .global else { continue }
            for pair in rule.headerOverrides where pair.key.lowercased() == "user-agent" {
                userAgent = pair.value
            }
        }

        // Apply the User-Agent override only when a rule provides one. Never
        // clobber an app-set customUserAgent: only overwrite/clear the UA if
        // SwiftyDebug was the one that set it (tracked via associated object).
        if let userAgent {
            webView.customUserAgent = userAgent
            setUserAgentOwnedBySDK(webView, true)
        } else if isUserAgentOwnedBySDK(webView) {
            // A rule that used to set the UA was removed — restore the default.
            webView.customUserAgent = nil
            setUserAgentOwnedBySDK(webView, false)
        }
        // else: no UA rule and we never set one — leave the app's UA untouched.

        applyCookieOverrides(to: webView.configuration.websiteDataStore.httpCookieStore)
    }

    /// True while `webView.customUserAgent` is a value **this SDK** wrote.
    ///
    /// The whole revert path hangs off this read: if it comes back false when it
    /// should be true, the host app is left running with a debugger's User-Agent
    /// forever, and nothing says so. Internal rather than private so a test can
    /// prove the flag survives the round trip.
    static func isUserAgentOwnedBySDK(_ webView: WKWebView) -> Bool {
        objc_getAssociatedObject(webView, sdkSetUserAgentKey) as? Bool ?? false
    }

    private static func setUserAgentOwnedBySDK(_ webView: WKWebView, _ owned: Bool) {
        objc_setAssociatedObject(webView, sdkSetUserAgentKey, owned, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Reconciles the Cookie header overrides into `store`: writes exactly the
    /// cookies the currently-enabled rules ask for, and deletes exactly the ones
    /// the SDK previously wrote that no rule asks for any more.
    ///
    /// A `Cookie:` header cannot be set from JavaScript (it is a forbidden
    /// header), so the only way to honour such a rule in a web view is the cookie
    /// store — which is *shared*, persistent, and not scoped to the rule. That
    /// makes attribution the whole safety argument: a cookie is written only to
    /// the host the rule itself names, and every write is recorded so it can be
    /// taken back. Rules that name no host (`global`) are refused rather than
    /// deposited on an arbitrary domain.
    static func applyCookieOverrides(to store: WKHTTPCookieStore) {
        let plan = cookieOverridePlan(for: InterceptRuleStore.shared.allRules())
        for reason in plan.refusals { logCookieOverrideSkipped(reason: reason) }
        NativeCookieOverrideStore.shared.reconcile(plan.cookies, in: store)
    }

    /// The cookies the enabled rules ask the SDK to place in the cookie store,
    /// plus a human-readable refusal for every override that could not be
    /// attributed to an origin.
    ///
    /// Pure so the attribution rules — the part that decides whose storage gets
    /// written — are unit-testable without a web view.
    static func cookieOverridePlan(
        for rules: [InterceptRule]
    ) -> (cookies: [NativeCookieOverride], refusals: [String]) {
        var ordered: [NativeCookieOverride] = []
        var indexByIdentity: [NativeCookieOverride.Identity: Int] = [:]
        var refusals: [String] = []

        // Ascending order, then creation date: later rules override earlier ones
        // for the same cookie, same as every other override in the SDK.
        let sorted = rules
            .filter(\.isEnabled)
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }

        for rule in sorted {
            for pair in rule.headerOverrides where pair.key.lowercased() == "cookie" {
                let pairs = cookiePairs(inHeaderValue: pair.value)
                guard !pairs.isEmpty else { continue }

                guard rule.matchMode == .host else {
                    // `global`, `exact` and `normalized` rules name no host. The
                    // cookie store is keyed by domain, so honouring them would
                    // mean picking a domain at random and writing another site's
                    // storage. Refuse, loudly.
                    refusals.append(
                        "the rule for “\(rule.matchEndpoint)” is \(rule.matchMode.rawValue)-scoped, which "
                        + "names no host. A Cookie header can only be applied natively to a specific "
                        + "domain, so nothing was written. Use a host rule to apply it.")
                    continue
                }

                let domains = rule.matchHosts.compactMap(hostComponent(of:))
                guard !domains.isEmpty else {
                    refusals.append(
                        "the host rule for “\(rule.matchEndpoint)” has no usable host, so there is no "
                        + "domain to scope the cookie to. Nothing was written.")
                    continue
                }

                for domain in domains {
                    for cookie in pairs {
                        let override = NativeCookieOverride(
                            name: cookie.name, value: cookie.value, domain: domain)
                        if let existing = indexByIdentity[override.identity] {
                            ordered[existing] = override
                        } else {
                            indexByIdentity[override.identity] = ordered.count
                            ordered.append(override)
                        }
                    }
                }
            }
        }
        return (ordered, refusals)
    }

    /// Splits a `Cookie:` header value (`a=1; b=2`) into its pairs.
    static func cookiePairs(inHeaderValue value: String) -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        for component in value.components(separatedBy: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let cookieValue = String(trimmed[trimmed.index(after: eq)...])
            if !name.isEmpty { out.append((name, cookieValue)) }
        }
        return out
    }

    /// Extracts the host out of a rule host pattern, which may carry a scheme
    /// and/or a path (`https://api.example.com/v1` → `api.example.com`).
    static func hostComponent(of pattern: String) -> String? {
        var s = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("https://") { s.removeFirst(8) } else if s.hasPrefix("http://") { s.removeFirst(7) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        return s.isEmpty ? nil : s
    }

    static func logCookieOverrideSkipped(reason: String) {
        LogEntryBuilder.handleLog(
            file: "[SwiftyDebug]", function: "cookieHeaderOverride", line: 0,
            message: "Cookie header override skipped: \(reason)",
            color: .systemOrange, type: .none)
    }

    /// All currently-live tracked WKWebViews (most recently created first), for
    /// the Storage editor's web-view picker. (See Phase 2 webview storage.)
    static func liveWebViews() -> [WKWebView] {
        // allObjects order isn't guaranteed; return as-is (UI sorts/labels).
        return trackedWebViews.allObjects
    }

    /// Enable/disable the injected JS capture+intercept engine in every live
    /// WKWebView. When disabled, the injected hooks pass through to the original
    /// XHR/fetch/console with zero SwiftyDebug work. Used by the kill-switch.
    ///
    /// Also detaches (and re-attaches) the SDK's message handlers, so a stopped
    /// SDK holds nothing in the app's handler table. Only names this SDK
    /// registered are removed; the injected user scripts stay, because WebKit
    /// offers no API to remove one script, and every `postMessage` they make is
    /// wrapped in `try/catch` so posting to a detached channel is inert.
    ///
    /// - Important: the handler removal is not only tidiness — it is what makes
    ///   the kill-switch survive a navigation. The `__cd_setEnabled(false)` push
    ///   below only reaches documents that exist right now; the user scripts
    ///   re-run on the next page load and re-arm the flag. The injected engine
    ///   therefore also asks, per request, whether the SDK's channel is still
    ///   registered, and WebKit answers that live. Removing the handlers is the
    ///   half a page load cannot undo, so it must keep happening here.
    static func pushEnabledStateToWebViews(enabled: Bool) {
        let js = "if(window.__cd_setEnabled)window.__cd_setEnabled(\(enabled ? "true" : "false"));"
        let run = {
            for webView in trackedWebViews.allObjects {
                webView.evaluateJavaScript(js, completionHandler: nil)
                let controller = webView.configuration.userContentController
                if enabled {
                    guard controller.isSwiftyDebugInstrumented else { continue }
                    installMessageHandlers(on: controller)
                } else {
                    controller.swiftyDebugRemoveOwnHandlers()
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    /// Registers every channel the SDK owns on `controller`, each at most once.
    /// A no-op for a controller that already has them.
    ///
    /// The handlers are *weak* shims pointing at the shared handler: the content
    /// controller strongly retains whatever is registered, so a per-web-view
    /// handler would keep the web view alive. (See WEBVIEW-LEAK.)
    static func installMessageHandlers(on controller: WKUserContentController) {
        let handler = sharedScriptHandler
        for channel in WebViewMessageChannel.all {
            controller.swiftyDebugAddHandler(WeakScriptMessageHandler(target: handler), name: channel)
        }
    }

    // MARK: - Swizzle setup

    private static func performSwizzling() {

        // 1. Swizzle WKWebView initWithFrame:configuration:
        if let original = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.init(frame:configuration:))),
           let replaced = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.replaced_init(frame:configuration:))) {
            method_exchangeImplementations(original, replaced)
        }

        // NOTE: We intentionally do NOT swizzle WKWebView's `dealloc`. The old
        // approach swizzled `dealloc` to an empty method (which skipped the real
        // dealloc chain) plus a `willDealloc` cleanup that was never invoked —
        // both contributing to the WKWebView leak and risking crashes app-wide.
        // The leak is now prevented at registration time by using weak message
        // handler shims (see `replaced_init` / `WeakScriptMessageHandler`), so no
        // dealloc-time cleanup is required.

        // 2. Swizzle WKUserContentController addScriptMessageHandler:name:
        let ucOriginal = #selector(WKUserContentController.add(_:name:))
        let ucReplaced = #selector(WKUserContentController.replaced_add(_:name:))
        if let ucOrigMethod = class_getInstanceMethod(WKUserContentController.self, ucOriginal),
           let ucReplMethod = class_getInstanceMethod(WKUserContentController.self, ucReplaced) {
            if !class_addMethod(WKUserContentController.self, ucOriginal,
                                method_getImplementation(ucReplMethod),
                                method_getTypeEncoding(ucReplMethod)) {
                method_exchangeImplementations(ucOrigMethod, ucReplMethod)
            }
        }
    }
}

// MARK: - WKUserContentController swizzled methods

extension WKUserContentController {

    @objc func replaced_add(_ handler: WKScriptMessageHandler, name: String) {
        // Don't wrap SwiftyDebug's own handlers (WKWebView registers itself).
        // When the SDK is fully stopped, register the app's handler unchanged so
        // the SDK has zero involvement.
        if handler is WKWebViewScriptHandler
            || handler is WKScriptMessageProxy
            || handler is WeakScriptMessageHandler
            || !SwiftyDebugRuntime.isActive {
            replaced_add(handler, name: name) // calls original (swizzled)
            return
        }

        // Wrap the app's handler in a proxy that holds it *strongly* — see
        // `WKScriptMessageProxy`: WebKit's documented ownership model is that the
        // content controller retains the handler, and apps rely on it, so the
        // proxy standing in its place must retain it too. The proxy references no
        // web view, so it cannot be part of the WKWebView retain cycle; that leak
        // is handled by `WeakScriptMessageHandler` on the SDK's own registrations.
        // (See WEBVIEW-LEAK.)
        let proxy = WKScriptMessageProxy(originalHandler: handler)
        replaced_add(proxy, name: name) // calls original (swizzled)
    }
}

// MARK: - Dedicated script message handler

/// A dedicated WKScriptMessageHandler that WKWebView instances register for
/// SwiftyDebug's own, namespaced message names (see `WebViewMessageChannel`).
@objc class WKWebViewScriptHandler: NSObject, WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Kill-switch: do nothing when the SDK is fully stopped.
        guard SwiftyDebugRuntime.isActive else { return }

        // Anything that is not one of the SDK's own channels reached us by
        // mistake; forwarding it into the log would leak the app's own bridge
        // traffic into the SDK.
        guard message.name.hasPrefix(WebViewMessageChannel.prefix) else { return }

        if message.name == WebViewMessageChannel.storagePins {
            // The page just finished parsing. Re-apply only the keys the
            // developer pinned, and only if force-overwrite is switched on for
            // this web view — `reapplyAllScopes` is a no-op otherwise.
            if let webView = message.webView {
                WebViewStoragePinStore.shared.reapplyAllScopes(webView: webView)
            }
            return
        }

        if message.name == WebViewMessageChannel.rulesRequest {
            // A document just started. Answer with the rules as they are *now*:
            // the user script injected at web-view creation carries a snapshot,
            // and a content controller shared by several web views (window.open,
            // target="_blank") would otherwise keep replaying the snapshot taken
            // when the first of them was created.
            if let webView = message.webView {
                let json = InterceptRuleStore.shared.rulesAsJSONString()
                webView.evaluateJavaScript(
                    "if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(json));",
                    completionHandler: nil)
            }
            return
        }

        if message.name == WebViewMessageChannel.networkCapture {
            // Respect the web-network toggle.
            guard Settings.shared.webNetworkRequestsEnabled else { return }
            handleNetworkCaptureMessage(message)
            return
        }

        // Console messages — respect the web-logs toggle.
        guard Settings.shared.webLogsEnabled else { return }

        LogEntryBuilder.handleLog(
            file: "[WKWebView]",
            function: WebViewMessageChannel.displayName(for: message.name),
            line: 0,
            message: "\(message.body)",
            color: .white,
            type: .none
        )
    }

    // MARK: - Network Capture handler

    private func handleNetworkCaptureMessage(_ message: WKScriptMessage) {
        guard let jsonString = message.body as? String else { return }
        guard let jsonData = jsonString.data(using: .utf8) else { return }
        guard let data = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else { return }

        DispatchQueue.main.async {
            let model = NetworkTransaction()

            // URL
            let urlString = data["url"] as? String ?? ""
            model.url = NSURL(string: urlString) ?? NSURL(string: "")

            // Method
            let method = data["method"] as? String ?? "GET"
            model.method = method.uppercased()

            // Request ID
            model.requestId = UUID().uuidString

            // Status code
            let status = data["status"] as? Int ?? 0
            model.statusCode = String(format: "%d", status)

            // Timing
            let startMs = data["startTime"] as? Double ?? 0
            let endMs = data["endTime"] as? Double ?? 0
            model.startTime = String(format: "%f", startMs / 1000.0)
            model.endTime = String(format: "%f", endMs / 1000.0)
            model.totalDuration = String(format: "%0.f ms", endMs - startMs)

            // Request headers
            if let reqHeaders = data["requestHeaders"] as? [String: Any] {
                model.requestHeaderFields = reqHeaders as NSDictionary
            }

            // Request body
            if let reqBody = data["body"] as? String, !reqBody.isEmpty {
                model.requestData = reqBody.data(using: .utf8)
            }

            // Response headers
            let respHeaders = data["responseHeaders"] as? [String: Any]
            if let respHeaders = respHeaders {
                model.responseHeaderFields = respHeaders as NSDictionary
            }

            // Response body
            if let respBody = data["responseBody"] as? String, !respBody.isEmpty {
                model.responseData = respBody.data(using: .utf8)
            }

            // MIME type from response headers
            let contentType = (respHeaders?["content-type"] as? String)
                ?? (respHeaders?["Content-Type"] as? String)
                ?? ""
            model.mineType = contentType

            // Mark as WebView request
            model.isWebViewRequest = true

            // Size
            let size = UInt(model.requestDataSize) + UInt(model.responseDataSize)
            if size > 1024 * 1024 {
                model.size = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
            } else if size > 1024 {
                model.size = String(format: "%.1f KB", Double(size) / 1024.0)
            } else {
                model.size = String(format: "%lu B", size)
            }

            // Build the searchable metadata index once, while the response body
            // string is still in memory.
            let respBodyData = (data["responseBody"] as? String)?.data(using: .utf8)
            model.buildSearchIndex(responseBody: respBodyData)

            // Add to datasource
            NetworkRequestStore.shared.addHttpRequset(model)

            // Notify UI
            NotificationCenter.default.post(name: .networkRequestCompleted, object: nil, userInfo: nil)
        }
    }
}

// MARK: - WKWebView swizzled methods

extension WKWebView {

    // MARK: - Swizzled init

    @objc func replaced_init(frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {

        // If the SDK is fully stopped, inject nothing — behave like a plain
        // WKWebView so there is zero SwiftyDebug involvement.
        guard SwiftyDebugRuntime.isActive else {
            return replaced_init(frame: frame, configuration: configuration)
        }

        // Instrument the content controller once. A `WKWebViewConfiguration`
        // copy shares its `userContentController`, so child web views opened by
        // `window.open` / `target="_blank"` — and any app that reuses one
        // configuration — arrive here with a controller that is already hooked.
        // Injecting again would append another copy of every script (and
        // re-register every handler) on every web view, forever.
        let controller = configuration.userContentController
        if !controller.isSwiftyDebugInstrumented {
            controller.isSwiftyDebugInstrumented = true

            // Register *weak* shims pointing at the shared handler. The content
            // controller strongly retains whatever is registered; a weak shim
            // therefore never keeps a per-web-view handler (or the VC behind it)
            // alive, which is the WKWebView leak fix. (See WEBVIEW-LEAK.)
            WKWebViewSwizzling.installMessageHandlers(on: controller)

            for consoleFunction in WebViewMessageChannel.consoleFunctions {
                controller.addUserScript(WKUserScript(
                    source: WebViewInjectedScript.consoleHook(consoleFunction: consoleFunction),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
            }

            controller.addUserScript(WKUserScript(
                source: WebViewInjectedScript.networkCapture,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))

            // Seed the rules so they are available in the very first line of the
            // very first page, before the async refresh (see
            // `WebViewMessageChannel.rulesRequest`) can come back.
            let rulesJSON = InterceptRuleStore.shared.rulesAsJSONString()
            controller.addUserScript(WKUserScript(
                source: "if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(rulesJSON));",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        }

        // Call original init (swizzled)
        let webView = replaced_init(frame: frame, configuration: configuration)
        WKWebViewSwizzling.trackedWebViews.add(webView)
        // Apply any User-Agent / Cookie rules natively (JS can't set these).
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        return webView
    }
}

// MARK: - Injected JavaScript

/// Every line of JavaScript SwiftyDebug puts into a host app's web view.
///
/// Kept as pure `String` builders, separate from the injection call sites, so the
/// parts that decide *what runs inside someone else's page* can be asserted on in
/// tests: that the SDK only ever posts to its own namespaced channels, that the
/// console wrapper cannot wrap itself twice, and that the fetch hook rebuilds a
/// request without losing its body or its abort signal.
enum WebViewInjectedScript {

    /// Wraps one `console` function so the page's output also reaches the Logs
    /// tab, then calls the page's original function unchanged.
    ///
    /// Two properties matter and are both enforced here:
    ///  * **idempotent** — the wrapper marks itself, so a second injection (a
    ///    shared content controller, or an app that also wraps console) cannot
    ///    stack wrappers and multiply every log line;
    ///  * **complete** — every argument is forwarded, not just the first.
    ///    `console.log('user', id, obj)` used to arrive as "user".
    static func consoleHook(consoleFunction: String) -> String {
        let channel = WebViewMessageChannel.console(consoleFunction)
        // swiftlint:disable line_length
        return """
        (function(){
        var c=window.console;
        if(!c||typeof c.\(consoleFunction)!=='function')return;
        if(c.\(consoleFunction).__cd_wrapped)return;
        var orig=c.\(consoleFunction);
        function fmt(args){var out=[];
        for(var i=0;i<args.length;i++){var a=args[i],s;
        if(typeof a==='string'){s=a;}
        else{try{s=JSON.stringify(a);}catch(e){s=null;}
        if(typeof s!=='string'){try{s=String(a);}catch(e2){s='[unprintable]';}}}
        out.push(s);}
        return out.join(' ');}
        var wrapper=function(){
        if(window.__cd_enabled!==false){try{window.webkit.messageHandlers.\(channel).postMessage(fmt(arguments));}catch(e){}}
        return orig.apply(c,arguments);};
        wrapper.__cd_wrapped=true;
        c.\(consoleFunction)=wrapper;
        })();
        """
        // swiftlint:enable line_length
    }

    // swiftlint:disable line_length
    /// The XHR + fetch capture/intercept engine. Injected at document start in
    /// every frame; self-guarded so a duplicate injection returns immediately.
    static let networkCapture: String = """
        (function(){
        if(window.__cd_net_hooked)return;
        window.__cd_net_hooked=true;
        var MAX_BODY=524288;
        /* ── Master enable flag (kill-switch). When disabled, hooks pass through. ── */
        if(typeof window.__cd_enabled==='undefined')window.__cd_enabled=true;
        window.__cd_setEnabled=function(v){window.__cd_enabled=!!v;};
        /* …and the half of the kill-switch a page load cannot undo. A full stop
           pushes `__cd_setEnabled(false)` into the documents that exist *now*,
           but `window` dies with the document and WebKit offers no API to remove
           an installed user script: the next navigation re-ran this file, took
           the `undefined` branch above, and re-armed itself. A stopped SDK went
           back to blocking and rewriting the host app's own traffic on the next
           tap, forever.
           So enablement is also derived from the one thing only native grants
           and a re-injection cannot forge: the SDK's own message channel, which
           a full stop unregisters. WebKit reflects that removal live — in the
           document already loaded, in every later one, and in sub-frames — so a
           stopped SDK is inert everywhere until native registers the channel
           again. Asked per request, never cached.
           `resolveRules` stays a pure matcher — "which rules match this URL" —
           and every hook asks `cdOn()` before it is allowed to act on the
           answer, so there is exactly one gate per entry point. */
        function chanUp(){try{return !!(window.webkit&&window.webkit.messageHandlers
        &&window.webkit.messageHandlers.\(WebViewMessageChannel.networkCapture));}catch(e){return false;}}
        function cdOn(){return window.__cd_enabled!==false&&chanUp();}
        function trunc(s){if(typeof s==='string'&&s.length>MAX_BODY)return s.substring(0,MAX_BODY);return s;}
        function post(d){if(!cdOn())return;try{window.webkit.messageHandlers.\(WebViewMessageChannel.networkCapture).postMessage(JSON.stringify(d));}catch(e){}}
        function parseH(raw){var h={};if(!raw)return h;var lines=raw.trim().split('\\r\\n');
        for(var i=0;i<lines.length;i++){var idx=lines[i].indexOf(':');
        if(idx>0)h[lines[i].substring(0,idx).trim()]=lines[i].substring(idx+1).trim();}return h;}

        /* ── Intercept rules engine ── */
        window.__cd_intercept_rules=[];
        window.__cd_updateInterceptRules=function(rules){
        if(Array.isArray(rules)){window.__cd_intercept_rules=rules;}
        else{try{window.__cd_intercept_rules=JSON.parse(rules);}catch(e){window.__cd_intercept_rules=[];}}};

        function normalizePath(path){
        return path.split('/').map(function(seg){
        if(!seg)return seg;
        if(/^\\d[\\d-]*$/.test(seg)&&/\\d/.test(seg))return '{id}';
        if(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(seg))return '{id}';
        return seg;}).join('/');}

        function getPath(u){try{return new URL(u,document.baseURI).pathname;}catch(e){
        var s=u;var qi=s.indexOf('?');if(qi>=0)s=s.substring(0,qi);
        var fi=s.indexOf('#');if(fi>=0)s=s.substring(0,fi);return s;}}

        function stripForHost(u){var s;try{var p=new URL(u,document.baseURI);s=p.host+p.pathname;}catch(e){s=u.toLowerCase();
        if(s.indexOf('https://')===0)s=s.substring(8);else if(s.indexOf('http://')===0)s=s.substring(7);
        var qi=s.indexOf('?');if(qi>=0)s=s.substring(0,qi);var fi=s.indexOf('#');if(fi>=0)s=s.substring(0,fi);}
        s=s.toLowerCase();if(s.charAt(s.length-1)==='/')s=s.substring(0,s.length-1);return s;}

        function hostMatch(stripped,pat){var p=pat.toLowerCase();
        if(p.charAt(p.length-1)==='/')p=p.substring(0,p.length-1);
        return stripped===p||stripped.indexOf(p+'/')===0;}

        /* An endpoint rule may be PINNED to one host (`matchHost`). Empty means
           any host, which is what every rule written before host pinning has.
           Without this check a rule pinned to api.example.com fired on every
           host inside a web view while behaving correctly on native traffic. */
        function hostOf(u){try{return new URL(u,document.baseURI).hostname.toLowerCase();}catch(e){return '';}}
        function pinAllows(r,u){if(!r.matchHost)return true;
        return hostOf(u)===String(r.matchHost).toLowerCase();}

        function resolveRules(urlStr){
        if(!window.__cd_enabled)return null;
        var rules=window.__cd_intercept_rules;if(!rules||!rules.length)return null;
        var path=getPath(urlStr);var norm=normalizePath(path);var stripped=stripForHost(urlStr);
        var matched=[];
        for(var i=0;i<rules.length;i++){var r=rules[i];
        if(r.matchMode==='global'){matched.push(r);}
        else if(r.matchMode==='exact'&&r.matchEndpoint===path&&pinAllows(r,urlStr)){matched.push(r);}
        else if(r.matchMode==='normalized'&&r.matchEndpoint===norm&&pinAllows(r,urlStr)){matched.push(r);}
        else if(r.matchMode==='host'&&r.matchHosts){
        for(var j=0;j<r.matchHosts.length;j++){if(hostMatch(stripped,r.matchHosts[j])){matched.push(r);break;}}}}
        if(!matched.length)return null;
        matched.sort(function(a,b){return(a.order||0)-(b.order||0);});
        var c={isBlocked:false,headerOverrides:[],removedHeaderKeys:[],queryParamOverrides:[],removedQueryParamKeys:[],redirectMode:'none',redirectTarget:''};
        for(var i=0;i<matched.length;i++){var r=matched[i];
        if(r.isBlocked)c.isBlocked=true;
        if(r.redirectMode&&r.redirectMode!=='none'&&r.redirectTarget){c.redirectMode=r.redirectMode;c.redirectTarget=r.redirectTarget;}
        if(r.headerOverrides){for(var h=0;h<r.headerOverrides.length;h++){var ho=r.headerOverrides[h];var found=false;
        for(var e=0;e<c.headerOverrides.length;e++){if(c.headerOverrides[e].key.toLowerCase()===ho.key.toLowerCase()){c.headerOverrides[e]=ho;found=true;break;}}
        if(!found)c.headerOverrides.push(ho);}}
        if(r.removedHeaderKeys){for(var h=0;h<r.removedHeaderKeys.length;h++){if(c.removedHeaderKeys.indexOf(r.removedHeaderKeys[h])<0)c.removedHeaderKeys.push(r.removedHeaderKeys[h]);}}
        if(r.queryParamOverrides){for(var q=0;q<r.queryParamOverrides.length;q++){var qo=r.queryParamOverrides[q];var found=false;
        for(var e=0;e<c.queryParamOverrides.length;e++){if(c.queryParamOverrides[e].key===qo.key){c.queryParamOverrides[e]=qo;found=true;break;}}
        if(!found)c.queryParamOverrides.push(qo);}}
        if(r.removedQueryParamKeys){for(var q=0;q<r.removedQueryParamKeys.length;q++){if(c.removedQueryParamKeys.indexOf(r.removedQueryParamKeys[q])<0)c.removedQueryParamKeys.push(r.removedQueryParamKeys[q]);}}}
        for(var i=0;i<c.headerOverrides.length;i++){var lk=c.headerOverrides[i].key.toLowerCase();
        for(var j=c.removedHeaderKeys.length-1;j>=0;j--){if(c.removedHeaderKeys[j].toLowerCase()===lk)c.removedHeaderKeys.splice(j,1);}}
        for(var i=0;i<c.queryParamOverrides.length;i++){var k=c.queryParamOverrides[i].key;
        var idx=c.removedQueryParamKeys.indexOf(k);if(idx>=0)c.removedQueryParamKeys.splice(idx,1);}
        return c;}

        function applyQueryParams(urlStr,rule){
        if(!rule.queryParamOverrides.length&&!rule.removedQueryParamKeys.length)return urlStr;
        try{var u=new URL(urlStr,document.baseURI);
        for(var i=0;i<rule.removedQueryParamKeys.length;i++)u.searchParams.delete(rule.removedQueryParamKeys[i]);
        for(var i=0;i<rule.queryParamOverrides.length;i++)u.searchParams.set(rule.queryParamOverrides[i].key,rule.queryParamOverrides[i].value);
        return u.toString();}catch(e){return urlStr;}}

        /* Rewrite host (and optionally path), always preserving the query. */
        function applyRedirect(urlStr,rule){
        if(!rule.redirectMode||rule.redirectMode==='none'||!rule.redirectTarget)return urlStr;
        try{var u=new URL(urlStr,document.baseURI);var t=(''+rule.redirectTarget).trim();
        if(/^https:\\/\\//i.test(t)){u.protocol='https:';t=t.replace(/^https:\\/\\//i,'');}
        else if(/^http:\\/\\//i.test(t)){u.protocol='http:';t=t.replace(/^http:\\/\\//i,'');}
        var qi=t.indexOf('?');if(qi>=0)t=t.substring(0,qi);
        var fi=t.indexOf('#');if(fi>=0)t=t.substring(0,fi);
        while(t.length&&t.charAt(t.length-1)==='/')t=t.substring(0,t.length-1);
        if(!t)return urlStr;
        var hostPart=t,pathPart='';var si=t.indexOf('/');
        if(si>=0){hostPart=t.substring(0,si);pathPart=t.substring(si);}
        var ci=hostPart.lastIndexOf(':');
        if(ci>0&&/^\\d+$/.test(hostPart.substring(ci+1))){u.port=hostPart.substring(ci+1);hostPart=hostPart.substring(0,ci);}
        if(!hostPart)return urlStr;
        u.hostname=hostPart;
        if(rule.redirectMode==='hostAndPath')u.pathname=pathPart||'/';
        return u.toString();}catch(e){return urlStr;}}

        function resolveUrl(u){try{return new URL(u,document.baseURI).href;}catch(e){return u;}}

        /* ── XHR hooks ── */
        var origOpen=XMLHttpRequest.prototype.open;
        var origSend=XMLHttpRequest.prototype.send;
        var origSetH=XMLHttpRequest.prototype.setRequestHeader;
        /* The page's own `readyState` getter, kept so a blocked request can
           report DONE without lying to a page that re-opens the same object. */
        var rsDesc=Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype,'readyState');
        var rsGet=rsDesc&&rsDesc.get;
        var rsSet=rsDesc&&rsDesc.set;

        /* A blocked request has to fail the way an unreachable server does.
           `abort()` before `send()` is observably NOTHING — the spec only errors
           a request that is already in flight — so a blocked XHR fired no error,
           no abort, no loadend and no readystatechange, `readyState` sat at
           OPENED, and the page's completion path simply never ran: its callback
           waited for a response that could not arrive.
           Nothing is sent. The *terminal state* of a network error is
           synthesised instead, and only `readyState` has to be faked for it:
           with no response, `status`, `statusText`, `responseText`,
           `responseURL` and `getAllResponseHeaders()` already read exactly as
           they do after a real failure (0, '', '', '', ''). */
        function cdEvent(type){try{return new ProgressEvent(type);}catch(e){}
        try{return new Event(type);}catch(e2){}return{type:type};}
        function failBlocked(x){
        if(x._cd)x._cd.blocked=true;
        /* configurable AND with a setter: without one, an implementation whose
           readyState is a writable own property throws on the next x.open(), so
           reusing a blocked XHR object broke the page. The setter is a no-op
           while blocked and forwards otherwise. */
        try{Object.defineProperty(x,'readyState',{configurable:true,
        get:function(){return(this._cd&&this._cd.blocked)?4:(rsGet?rsGet.call(this):0);},
        set:function(v){if(rsSet)try{rsSet.call(this,v);}catch(e){}}});}catch(e){}
        var fire=function(){
        try{x.dispatchEvent(cdEvent('loadstart'));}catch(e){}
        try{x.dispatchEvent(cdEvent('readystatechange'));}catch(e){}
        try{x.dispatchEvent(cdEvent('error'));}catch(e){}
        try{x.dispatchEvent(cdEvent('loadend'));}catch(e){}};
        /* Asynchronously, like a real failure: handlers a page attaches after
           calling send() still have to run, and no page expects its error path
           to re-enter it from inside send(). */
        if(typeof setTimeout==='function')setTimeout(fire,0);else fire();}

        XMLHttpRequest.prototype.open=function(method,url){
        var urlStr=String(url);
        var fullUrl=resolveUrl(urlStr);
        /* `cdOn()` first: a stopped SDK must not intercept, even in a document
           that re-injected this file after the stop. (See the kill-switch note.) */
        var rule=cdOn()?resolveRules(fullUrl):null;
        this._cd={method:method,url:fullUrl,headers:{},startTime:Date.now(),rule:rule};
        if(rule){var effectiveUrl=applyRedirect(applyQueryParams(fullUrl,rule),rule);this._cd.url=effectiveUrl;
        var args=Array.prototype.slice.call(arguments);args[1]=effectiveUrl;
        return origOpen.apply(this,args);}
        if(this._cd)this._cd.blocked=false;   /* a reused object is not still blocked */
        return origOpen.apply(this,arguments);};

        XMLHttpRequest.prototype.setRequestHeader=function(k,v){
        if(this._cd){var r=this._cd.rule,lk=String(k).toLowerCase();
        if(r){
        for(var i=0;i<r.removedHeaderKeys.length;i++){
        if(String(r.removedHeaderKeys[i]).toLowerCase()===lk){this._cd.headers[k]=v;return;}}
        /* An override has to REPLACE. `setRequestHeader` *combines* repeated
           values for one name — "a" then "b" is sent as "a, b", case-insensitively
           — so forwarding the page's own call and then setting the override in
           send() put BOTH on the wire: the page's original Authorization
           travelled to the server alongside the one the rule specified. The
           page's value is dropped here; the override is applied once, in send().
           Every other name is forwarded untouched, so repeated calls the page
           makes for a name no rule overrides still combine exactly as the XHR
           spec requires. */
        for(var i=0;i<r.headerOverrides.length;i++){
        if(String(r.headerOverrides[i].key).toLowerCase()===lk)return;}}
        this._cd.headers[k]=v;}
        return origSetH.apply(this,arguments);};

        XMLHttpRequest.prototype.send=function(body){
        if(this._cd){
        var rule=this._cd.rule;
        if(rule){
        if(rule.isBlocked){var d=this._cd;d.body=(typeof body==='string')?trunc(body):null;
        d.requestHeaders=d.headers;d.status=0;d.statusText='Blocked by SwiftyDebug';d.responseHeaders={};d.responseBody=null;
        d.endTime=Date.now();d.type='xhr';d.intercepted=true;post(d);failBlocked(this);return;}
        for(var i=0;i<rule.headerOverrides.length;i++){var ho=rule.headerOverrides[i];
        this._cd.headers[ho.key]=ho.value;origSetH.call(this,ho.key,ho.value);}
        this._cd.intercepted=true;}
        this._cd.body=(typeof body==='string')?trunc(body):null;
        var xhr=this;
        this.addEventListener('loadend',function(){
        var d=xhr._cd;if(!d)return;
        d.url=xhr.responseURL||d.url;
        d.status=xhr.status;d.statusText=xhr.statusText||'';
        d.responseHeaders=parseH(xhr.getAllResponseHeaders());d.endTime=Date.now();
        try{d.responseBody=trunc(xhr.responseText);}catch(e){d.responseBody=null;}
        d.requestHeaders=d.headers;d.type='xhr';post(d);});}
        return origSend.apply(this,arguments);};

        /* ── Fetch hook ── */
        if(window.fetch){
        var origFetch=window.fetch;
        /* Standard init fields copied off a Request when a changed URL forces us
           to build a new one. `mode:'navigate'` is legal on a Request but throws
           in the Request constructor, so it is dropped. `body` and `signal` are
           NOT copyable by assignment and are handled explicitly below. */
        function requestInitFrom(req){
        var o={};
        try{o.method=req.method;}catch(e){}
        try{if(req.mode&&req.mode!=='navigate')o.mode=req.mode;}catch(e){}
        try{o.credentials=req.credentials;}catch(e){}
        try{o.cache=req.cache;}catch(e){}
        try{o.redirect=req.redirect;}catch(e){}
        try{o.referrer=req.referrer;}catch(e){}
        try{o.referrerPolicy=req.referrerPolicy;}catch(e){}
        try{o.integrity=req.integrity;}catch(e){}
        try{o.keepalive=req.keepalive;}catch(e){}
        return o;}
        /* Drains a *clone*, so the caller's Request is never disturbed. Text for
           textual content types (so the body still shows up in the SDK), raw
           bytes otherwise (so binary uploads survive the round trip). */
        function readBody(req){
        var ct='';try{ct=req.headers.get('content-type')||'';}catch(e){}
        if(/json|text|xml|urlencoded|javascript|graphql/i.test(ct))
        return req.text().then(function(t){return {b:t,log:trunc(t)};});
        return req.arrayBuffer().then(function(a){return {b:a,log:null};});}
        window.fetch=function(input,init){
        var ctx=this||window;
        var url,method,headers={},body=null,reqObj=null;
        if(typeof input==='string'){url=input;}
        else if(typeof Request!=='undefined'&&input instanceof Request){reqObj=input;url=input.url;method=input.method;
        try{input.headers.forEach(function(v,k){headers[k]=v;});}catch(e){}}
        else{url=String(input);}
        if(init){
        if(init.method)method=init.method;
        if(init.headers){
        if(init.headers instanceof Headers){try{init.headers.forEach(function(v,k){headers[k]=v;});}catch(e){}}
        else if(typeof init.headers==='object'){var ks=Object.keys(init.headers);
        for(var i=0;i<ks.length;i++)headers[ks[i]]=init.headers[ks[i]];}}
        if(init.body&&typeof init.body==='string')body=trunc(init.body);}
        method=method||'GET';
        var fullUrl=resolveUrl(url);
        /* Same gate as the XHR hook: stopped means stopped. */
        var rule=cdOn()?resolveRules(fullUrl):null;
        /* One place that actually calls through and logs, so every path below —
           untouched, rewritten, or rebuilt-after-reading-the-body — reports the
           same way. */
        function send(sendInput,sendInit,logUrl,logBody,intercepted){
        var startTime=Date.now();
        return origFetch.call(ctx,sendInput,sendInit).then(function(response){
        var rh={};try{response.headers.forEach(function(v,k){rh[k]=v;});}catch(e){}
        try{response.clone().text().then(function(text){
        post({type:'fetch',url:response.url||logUrl,method:method.toUpperCase(),
        requestHeaders:headers,body:logBody,status:response.status,
        statusText:response.statusText||'',responseHeaders:rh,
        responseBody:trunc(text),startTime:startTime,endTime:Date.now(),intercepted:intercepted});}).catch(function(){});}catch(e){}
        return response;}).catch(function(err){
        post({type:'fetch',url:logUrl,method:method.toUpperCase(),
        requestHeaders:headers,body:logBody,status:0,
        statusText:err.message||'Network Error',responseHeaders:{},
        responseBody:null,startTime:startTime,endTime:Date.now(),intercepted:intercepted});
        throw err;});}
        /* No rule matched: hand the caller's own arguments straight through. */
        if(!rule)return send(input,init,fullUrl,body,false);
        if(rule.isBlocked){var blockedAt=Date.now();
        post({type:'fetch',url:fullUrl,method:method.toUpperCase(),requestHeaders:headers,body:body,
        status:0,statusText:'Blocked by SwiftyDebug',responseHeaders:{},responseBody:null,
        startTime:blockedAt,endTime:Date.now(),intercepted:true});
        return Promise.reject(new TypeError('Blocked by SwiftyDebug intercept rule'));}
        var newUrl=applyRedirect(applyQueryParams(fullUrl,rule),rule);
        for(var i=0;i<rule.removedHeaderKeys.length;i++){var rk=rule.removedHeaderKeys[i];
        var hks=Object.keys(headers);for(var j=0;j<hks.length;j++){if(hks[j].toLowerCase()===rk.toLowerCase())delete headers[hks[j]];}}
        for(var i=0;i<rule.headerOverrides.length;i++){headers[rule.headerOverrides[i].key]=rule.headerOverrides[i].value;}
        if(reqObj){
        /* Same URL: copy-construct from the caller's Request. This is the only
           way to keep a body and an AbortSignal the page owns — neither can be
           carried across by assignment. */
        if(newUrl===reqObj.url){
        var extra=Object.assign({},init||{});extra.headers=headers;
        try{return send(new Request(reqObj,extra),undefined,newUrl,body,true);}catch(e){}}
        /* URL changed, so a new Request is unavoidable. Carry every init field,
           the signal, and the body (read off a clone) rather than dropping them. */
        var merged=Object.assign({},requestInitFrom(reqObj),init||{});
        merged.method=method;merged.headers=headers;
        if(merged.signal===undefined||merged.signal===null){try{merged.signal=reqObj.signal;}catch(e){}}
        if(merged.body===undefined&&method!=='GET'&&method!=='HEAD'&&!reqObj.bodyUsed){
        var clone=null;try{clone=reqObj.clone();}catch(e){clone=null;}
        if(clone)return readBody(clone).then(function(r){merged.body=r.b;
        return send(newUrl,merged,newUrl,r.log,true);},function(){
        return send(newUrl,merged,newUrl,null,true);});}
        return send(newUrl,merged,newUrl,body,true);}
        init=Object.assign({},init||{});init.method=method;init.headers=headers;
        if(body!==null&&init.body===undefined)init.body=body;
        return send(newUrl,init,newUrl,body,true);};
        }
        /* Ask native for the rules as they are right now. The user script that
           seeded them carries a snapshot from web-view creation time, which a
           content controller shared by several web views would otherwise replay
           forever. */
        try{window.webkit.messageHandlers.\(WebViewMessageChannel.rulesRequest).postMessage(1);}catch(e){}
        })();
        """
    // swiftlint:enable line_length
}

// MARK: - Force-overwrite ("pinning") for web-view storage
//
// The problem this solves: a container app commonly re-injects values into a web
// view's storage on every page load (auth tokens, feature flags, locale). A value
// edited in the SDK is therefore clobbered the moment the page reloads, and the
// developer sees their edit "not work".
//
// The fix is deliberately narrow. The SDK remembers ONLY the keys the developer
// edited in this session, and — when the per-store toggle is on — writes exactly
// those keys back after the page has loaded. It never restores a whole store,
// never touches a key the developer did not edit, and never re-applies onto an
// origin other than the one the edit was made on.

/// One value the developer edited in the SDK and asked to have reinstated.
struct WebViewStoragePin: Equatable {
    let key: String
    let value: String
}

/// The pinned keys for ONE (web view, storage scope) pair.
///
/// A value type with no WebKit references on purpose: "which keys get written
/// back" is the entire safety argument for this feature, so that decision is
/// pure, inspectable and unit-tested rather than buried inside a JS string.
struct WebViewStoragePinSet: Equatable {

    /// Off by default. The SDK re-applies nothing until explicitly asked to.
    var isForcing: Bool = false

    /// The origin the pins were captured on (`https://example.com:443`).
    ///
    /// Re-applying on a different origin would write one site's value into
    /// another site's storage — precisely the corruption this feature must never
    /// cause — so a mismatch skips the re-apply entirely.
    private(set) var origin: String?

    /// Insertion-ordered so re-application is deterministic and reviewable.
    private(set) var pins: [WebViewStoragePin] = []

    var isEmpty: Bool { pins.isEmpty }

    /// Records (or updates) a pinned key.
    ///
    /// Editing on a *different* origin discards the old pins rather than mixing
    /// two sites' keys into one set — a mixed set could only ever be applied to
    /// one of them, so the other half would be a silent no-op.
    mutating func pin(key: String, value: String, origin: String?) {
        if self.origin != origin {
            self.origin = origin
            pins.removeAll()
        }
        if let idx = pins.firstIndex(where: { $0.key == key }) {
            pins[idx] = WebViewStoragePin(key: key, value: value)
        } else {
            pins.append(WebViewStoragePin(key: key, value: value))
        }
    }

    mutating func unpin(key: String) {
        pins.removeAll { $0.key == key }
        if pins.isEmpty { origin = nil }
    }

    mutating func unpinAll() {
        pins.removeAll()
        origin = nil
    }

    func isPinned(_ key: String) -> Bool { pins.contains { $0.key == key } }

    func value(for key: String) -> String? { pins.first { $0.key == key }?.value }

    /// True when re-applying is both switched on and safe for `currentOrigin`.
    func shouldApply(on currentOrigin: String?) -> Bool {
        guard isForcing, !pins.isEmpty, let origin, currentOrigin != nil else { return false }
        return origin == currentOrigin
    }
}

/// Pure builders for everything the pin store injects or writes.
enum WebViewStoragePinScript {

    /// Escapes a Swift string into a JavaScript string literal, quotes included.
    ///
    /// Hand-rolled rather than routed through `JSONSerialization` because JSON is
    /// **not** a subset of JS string-literal syntax in every engine: U+2028 and
    /// U+2029 are legal raw inside a JSON string but were line terminators in JS
    /// before ES2019, and `<` is escaped so a value can never close a `<script>`
    /// block if this source is ever embedded in markup.
    static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":       out += "\\\""
            case "\\":       out += "\\\\"
            case "\n":       out += "\\n"
            case "\r":       out += "\\r"
            case "\t":       out += "\\t"
            case "\u{08}":   out += "\\b"
            case "\u{0C}":   out += "\\f"
            case "<":        out += "\\u003C"
            case ">":        out += "\\u003E"
            case "&":        out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// JS that writes exactly `pins` into `object` (`localStorage` /
    /// `sessionStorage`).
    ///
    /// Returns `nil` for an empty pin list rather than an empty script: a script
    /// that provably does nothing must not be evaluated, so callers can never
    /// mistake "nothing to do" for "applied".
    ///
    /// Evaluates to the number of keys written, `0` if the store is unavailable
    /// (opaque origin / storage disabled), `-1` if a write threw (quota), and
    /// `-2` if the document that ran the script is not `origin`.
    ///
    /// `origin` is the second half of the origin check, and the only half that
    /// cannot be raced: native gates on `webView.url`, which changes at
    /// *provisional* navigation while the committed document is still the
    /// previous page. This check runs inside the document being written to, so a
    /// value pinned on site A can never land in site B's storage even if the
    /// native gate is asked at the wrong moment. Pass `nil` only where there is
    /// no origin to check against — the script then writes wherever it runs.
    static func applyScript(object: String,
                            pins: [WebViewStoragePin],
                            origin: String? = nil) -> String? {
        guard !pins.isEmpty else { return nil }
        var body = ""
        for pin in pins {
            body += "s.setItem(\(jsStringLiteral(pin.key)),\(jsStringLiteral(pin.value)));"
        }
        var originGuard = ""
        if let origin {
            // Built to match `originKey(for:)`: scheme://host:port, default port
            // spelled out, lowercased.
            originGuard = "var l=window.location,p=l.port||(l.protocol==='https:'?'443':'80');"
                + "if((l.protocol+'//'+l.hostname+':'+p).toLowerCase()!==\(jsStringLiteral(origin)))return -2;"
        }
        return "(function(){try{var s=window.\(object);if(!s)return 0;"
            + originGuard
            + body
            + "return \(pins.count);}catch(e){return -1;}})();"
    }

    /// The origin key used to decide whether a re-apply is safe.
    /// `nil` for anything without a real web origin (`about:blank`, `file:`),
    /// which can never match and therefore never gets written to.
    static func originKey(for url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// Rebuilds a cookie's property dictionary with a new value, preserving every
    /// field the original carried.
    ///
    /// Starts from the live `properties` dictionary rather than re-deriving a
    /// handful of fields, because the fields that are easy to forget are the ones
    /// that change behaviour: dropping `HttpOnly` makes a cookie readable by page
    /// JS, and dropping `SameSite` changes which requests carry it.
    static func cookieProperties(from existing: HTTPCookie, newValue: String) -> [HTTPCookiePropertyKey: Any] {
        var props = existing.properties ?? [:]
        props[.value] = newValue

        // Re-assert the fields `HTTPCookie(properties:)` requires, in case the
        // system dictionary omitted them.
        if props[.name] == nil { props[.name] = existing.name }
        if props[.path] == nil { props[.path] = existing.path.isEmpty ? "/" : existing.path }
        if props[.domain] == nil, props[.originURL] == nil { props[.domain] = existing.domain }
        if existing.isSecure, props[.secure] == nil { props[.secure] = "TRUE" }
        if existing.isHTTPOnly, props[httpOnlyKey] == nil { props[httpOnlyKey] = "TRUE" }
        if let expires = existing.expiresDate, props[.expires] == nil { props[.expires] = expires }
        if let sameSite = existing.sameSitePolicy, props[.sameSitePolicy] == nil {
            props[.sameSitePolicy] = sameSite.rawValue
        }
        return props
    }

    /// `HTTPCookie` exposes `isHTTPOnly` but ships no public property key for it;
    /// the string is the one Foundation itself puts in `properties`.
    static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
}

/// A unique, stable address to hang the "bootstrap already installed" flag off a
/// `WKUserContentController`. An address rather than an `ObjectIdentifier` set,
/// because an identifier can be recycled once the original object deallocates.
private let pinBootstrapAssociationKey = UnsafeRawPointer(
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

/// Owns the pinned keys for every web view and re-applies them at page load.
///
/// Main-thread only (WKWebView is), and holds web views **weakly** — the SDK must
/// never keep a host app's web view alive.
final class WebViewStoragePinStore {

    static let shared = WebViewStoragePinStore()

    /// Message name the document-end bootstrap posts on. Namespaced, like every
    /// other channel, because the handler table belongs to the host app.
    static let messageName = WebViewMessageChannel.storagePins

    /// What a re-apply attempt actually did. Every outcome is reportable: a
    /// force-overwrite that quietly stops working is worse than one that fails
    /// loudly, because the developer keeps trusting a stale value.
    enum Outcome: Equatable {
        case notForcing
        case noPins
        case originMismatch(pinned: String?, current: String?)
        case applied(Int)
        case failed(String)

        var isSuccess: Bool { if case .applied = self { return true }; return false }
    }

    private struct ScopeKey: Hashable {
        let webView: ObjectIdentifier
        let scope: Int
    }

    private final class WeakWebViewBox {
        weak var webView: WKWebView?
        init(_ webView: WKWebView) { self.webView = webView }
    }

    private var sets: [ScopeKey: WebViewStoragePinSet] = [:]
    /// Cookie pins need the original cookie to preserve domain/path/flags; the
    /// pin set only carries strings.
    private var cookieTemplates: [ScopeKey: [String: HTTPCookie]] = [:]
    private var boxes: [ObjectIdentifier: WeakWebViewBox] = [:]
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    private init() {}

    // MARK: - Registration

    /// Must be called before any other call for `webView`. Also drops the state
    /// of any web view that has since deallocated.
    func register(_ webView: WKWebView) {
        purge()
        boxes[ObjectIdentifier(webView)] = WeakWebViewBox(webView)
    }

    /// Drops state belonging to deallocated web views.
    ///
    /// This is a correctness requirement, not housekeeping: `ObjectIdentifier` is
    /// an address, and addresses are reused. Without this, a newly created web
    /// view landing on a dead one's address would inherit its pins.
    private func purge() {
        let dead = boxes.filter { $0.value.webView == nil }.map(\.key)
        guard !dead.isEmpty else { return }
        for id in dead {
            boxes.removeValue(forKey: id)
            observations.removeValue(forKey: id)?.forEach { $0.invalidate() }
            sets = sets.filter { $0.key.webView != id }
            cookieTemplates = cookieTemplates.filter { $0.key.webView != id }
        }
    }

    private func key(_ webView: WKWebView, _ scope: WebViewStorageService.Scope) -> ScopeKey {
        ScopeKey(webView: ObjectIdentifier(webView), scope: scope.rawValue)
    }

    // MARK: - Reading state

    func pinSet(for webView: WKWebView, scope: WebViewStorageService.Scope) -> WebViewStoragePinSet {
        purge()
        return sets[key(webView, scope)] ?? WebViewStoragePinSet()
    }

    func isForcing(_ webView: WKWebView, scope: WebViewStorageService.Scope) -> Bool {
        pinSet(for: webView, scope: scope).isForcing
    }

    func isPinned(_ key: String, webView: WKWebView, scope: WebViewStorageService.Scope) -> Bool {
        pinSet(for: webView, scope: scope).isPinned(key)
    }

    // MARK: - Mutating state

    /// Turns force-overwrite on or off for one store of one web view.
    ///
    /// Turning it **off** is a full stop: nothing is re-applied afterwards and
    /// whatever the page wrote is left exactly as the page left it. The pinned
    /// keys are remembered so the toggle can be flipped back on, but they are
    /// inert.
    func setForcing(_ on: Bool, webView: WKWebView, scope: WebViewStorageService.Scope) {
        register(webView)
        var set = sets[key(webView, scope)] ?? WebViewStoragePinSet()
        set.isForcing = on
        sets[key(webView, scope)] = set
        if on { installHooksIfNeeded(for: webView) }
    }

    /// Remembers a key the developer just wrote, so it can be reinstated.
    /// Returns false when the pin could not be recorded (a cookie with no
    /// template, or a page with no real origin) — callers must surface that
    /// rather than showing a pinned badge that will never fire.
    @discardableResult
    func record(webView: WKWebView,
                scope: WebViewStorageService.Scope,
                key entryKey: String,
                value: String,
                cookie: HTTPCookie? = nil) -> Bool {
        register(webView)
        guard let origin = WebViewStoragePinScript.originKey(for: webView.url) else { return false }
        if scope == .cookies, cookie == nil { return false }

        let k = key(webView, scope)
        var set = sets[k] ?? WebViewStoragePinSet()
        let originChanged = (set.origin != nil && set.origin != origin)
        set.pin(key: entryKey, value: value, origin: origin)
        sets[k] = set

        if originChanged { cookieTemplates[k] = [:] }
        if let cookie { cookieTemplates[k, default: [:]][entryKey] = cookie }
        return true
    }

    func unpin(webView: WKWebView, scope: WebViewStorageService.Scope, key entryKey: String) {
        purge()
        let k = key(webView, scope)
        guard var set = sets[k] else { return }
        set.unpin(key: entryKey)
        sets[k] = set
        cookieTemplates[k]?.removeValue(forKey: entryKey)
    }

    func unpinAll(webView: WKWebView, scope: WebViewStorageService.Scope) {
        purge()
        let k = key(webView, scope)
        guard var set = sets[k] else { return }
        set.unpinAll()
        sets[k] = set
        cookieTemplates[k] = [:]
    }

    // MARK: - Re-applying

    /// Re-applies every store that has force-overwrite switched on.
    func reapplyAllScopes(webView: WKWebView) {
        for scope in WebViewStorageService.Scope.allCases {
            reapply(webView: webView, scope: scope, completion: nil)
        }
    }

    /// Writes the pinned keys of one store back into the web view.
    ///
    /// Every early return reports *why* through `completion`; nothing here fails
    /// silently.
    func reapply(webView: WKWebView,
                 scope: WebViewStorageService.Scope,
                 completion: ((Outcome) -> Void)?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak webView] in
                guard let webView else { completion?(.failed("web view was released")); return }
                self.reapply(webView: webView, scope: scope, completion: completion)
            }
            return
        }
        purge()
        let k = key(webView, scope)
        let set = sets[k] ?? WebViewStoragePinSet()
        guard set.isForcing else { completion?(.notForcing); return }
        guard !set.isEmpty else { completion?(.noPins); return }

        let currentOrigin = WebViewStoragePinScript.originKey(for: webView.url)
        guard set.shouldApply(on: currentOrigin) else {
            completion?(.originMismatch(pinned: set.origin, current: currentOrigin))
            return
        }

        switch scope {
        case .local, .session:
            // `currentOrigin` is non-nil here: `shouldApply(on:)` above rejects
            // anything without a real web origin.
            guard let object = scope.jsObject,
                  let js = WebViewStoragePinScript.applyScript(object: object,
                                                               pins: set.pins,
                                                               origin: currentOrigin)
            else { completion?(.noPins); return }
            webView.evaluateJavaScript(js) { result, error in
                DispatchQueue.main.async {
                    if let error {
                        completion?(.failed(error.localizedDescription))
                        return
                    }
                    let written = (result as? NSNumber)?.intValue ?? -1
                    if written > 0 { completion?(.applied(written)) }
                    else if written == 0 { completion?(.failed("\(object) is unavailable on this page")) }
                    else if written == -2 {
                        // The document disagreed with `webView.url`: a navigation
                        // is in flight and the committed page is not the one the
                        // values were pinned on. Nothing was written.
                        completion?(.originMismatch(pinned: set.origin,
                                                    current: "a page that is still loading"))
                    } else { completion?(.failed("a write was rejected (storage quota or disabled)")) }
                }
            }

        case .cookies:
            let templates = cookieTemplates[k] ?? [:]
            let store = webView.configuration.websiteDataStore.httpCookieStore
            var rebuilt: [HTTPCookie] = []
            var unbuildable: [String] = []
            for pin in set.pins {
                guard let template = templates[pin.key] else { unbuildable.append(pin.key); continue }
                let props = WebViewStoragePinScript.cookieProperties(from: template, newValue: pin.value)
                if let cookie = HTTPCookie(properties: props) { rebuilt.append(cookie) }
                else { unbuildable.append(pin.key) }
            }
            guard !rebuilt.isEmpty else {
                completion?(.failed("no cookie could be rebuilt (\(unbuildable.joined(separator: ", ")))"))
                return
            }
            let group = DispatchGroup()
            for cookie in rebuilt {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                if unbuildable.isEmpty { completion?(.applied(rebuilt.count)) }
                else { completion?(.failed("skipped \(unbuildable.joined(separator: ", "))")) }
            }
        }
    }

    // MARK: - Re-apply triggers

    /// Installs the two triggers that make force-overwrite work, once per web
    /// view. Both are additive — no existing user script, message handler or
    /// delegate is removed or replaced.
    ///
    /// 1. A `.atDocumentEnd` user script that pings native as soon as the page's
    ///    own scripts have parsed. This is the earliest safe re-apply point.
    /// 2. KVO on `isLoading` / `url`, which fires *after* `didFinish` and so also
    ///    catches values the container app injects from native once the page has
    ///    loaded — the case this feature exists for.
    ///
    /// Neither can win against a page that writes on a timer after load; the UI
    /// says so and offers a manual re-apply.
    private func installHooksIfNeeded(for webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        if observations[id] == nil {
            var tokens: [NSKeyValueObservation] = []
            // `NSKeyValueObservation` holds the observed object weakly, so these
            // cannot keep the host app's web view alive. (See WEBVIEW-LEAK.)
            tokens.append(webView.observe(\.isLoading, options: [.new]) { [weak self] observed, change in
                guard change.newValue == false else { return }
                self?.reapplyAllScopes(webView: observed)
            })
            tokens.append(webView.observe(\.url, options: [.new]) { [weak self] observed, _ in
                // `url` changes at *provisional* navigation, while the committed
                // document is still the previous page. Re-applying then would
                // check the origin against the destination and write the old
                // page's values into the new site's storage. Waiting for
                // `isLoading == false` keeps `url` and the live document in
                // agreement; the in-document check in `applyScript` is the
                // backstop. This observer still earns its keep for same-document
                // navigations (`pushState`), which never toggle `isLoading`.
                guard observed.isLoading == false else { return }
                self?.reapplyAllScopes(webView: observed)
            })
            observations[id] = tokens
        }

        let controller = webView.configuration.userContentController
        guard objc_getAssociatedObject(controller, pinBootstrapAssociationKey) == nil else { return }
        objc_setAssociatedObject(controller, pinBootstrapAssociationKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Registers the SDK's channels if they are not registered already, and
        // removes nothing: a blanket `removeScriptMessageHandler(forName:)`
        // cannot tell the SDK's own name from the app's and would silently kill
        // the app's bridge. Normally a no-op — `replaced_init` already did this.
        WKWebViewSwizzling.installMessageHandlers(on: controller)

        // The script carries no values: it only asks native "anything pinned?".
        // Values live natively so the toggle stays reversible — a page load after
        // the toggle is switched off gets an answer of "nothing", and this script
        // (which WebKit offers no API to remove individually) becomes inert
        // rather than replaying stale data.
        let source = "(function(){try{window.webkit.messageHandlers."
            + Self.messageName + ".postMessage(1);}catch(e){}})();"
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
    }
}
