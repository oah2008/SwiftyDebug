//
//  WebViewUserAgentRevertTests.swift
//  SwiftyDebugTests
//
//  A header rule that overrides User-Agent is applied to a web view natively,
//  through `WKWebView.customUserAgent`, because JavaScript cannot set a
//  forbidden header. That means the SDK is writing a property that belongs to
//  the host app, on the host app's own web view, and the only thing that makes
//  that acceptable is that it can be given back: a flag recorded per web view
//  says "this UA is ours", and the moment no rule asks for one any more the
//  property is cleared.
//
//  That flag used to be an associated object keyed by a Swift `String`. A string
//  literal is not a stable pointer: at `-Onone` — which is how a debug-only SDK
//  actually ships — each reference can bridge to a fresh `NSString`, so the read
//  used a different key than the write, came back nil, and the revert branch was
//  never taken. The host app then kept a debugger's User-Agent on every request
//  its web views made, forever, silently. It works at `-O` through constant
//  folding, which is why a Release build never showed it.
//
//  So: this asserts the round trip and the revert, not the storage mechanism.
//

import XCTest
import WebKit
@testable import SwiftyDebug

final class WebViewUserAgentRevertTests: XCTestCase {

    private let agent = "SwiftyDebugTests/1.0 (user-agent-revert)"

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    private func installUserAgentRule() {
        var rule = InterceptRule.hostRule(hosts: ["example.com"])
        rule.isEnabled = true
        rule.headerOverrides = [KVPair(key: "User-Agent", value: agent)]
        InterceptRuleStore.shared.addOrUpdate(rule)
    }

    func testTheOverrideIsRevertedOnceTheRuleIsGone() {
        let webView = WKWebView(frame: .zero)
        XCTAssertFalse(WKWebViewSwizzling.isUserAgentOwnedBySDK(webView))

        installUserAgentRule()
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        XCTAssertEqual(webView.customUserAgent, agent)
        XCTAssertTrue(WKWebViewSwizzling.isUserAgentOwnedBySDK(webView),
                      "the ownership flag did not survive the write — the revert below cannot happen")

        InterceptRuleStore.shared.removeAll()
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        // WebKit stores a cleared override as "" rather than nil; either way the
        // web view is back on the app's own User-Agent.
        XCTAssertTrue(webView.customUserAgent?.isEmpty ?? true,
                      "the SDK left its User-Agent on the host app's web view after the rule was deleted: "
                      + "\(webView.customUserAgent ?? "nil")")
        XCTAssertFalse(WKWebViewSwizzling.isUserAgentOwnedBySDK(webView))
    }

    /// The flag has to be per web view: reverting one must not claim, or clear,
    /// another app's web view.
    func testOwnershipIsTrackedPerWebViewAndNotGlobally() {
        let owned = WKWebView(frame: .zero)
        let untouched = WKWebView(frame: .zero)

        installUserAgentRule()
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: owned)

        XCTAssertTrue(WKWebViewSwizzling.isUserAgentOwnedBySDK(owned))
        XCTAssertFalse(WKWebViewSwizzling.isUserAgentOwnedBySDK(untouched),
                       "a web view the SDK never wrote to must not be marked as owned")
    }

    /// The other half of the promise: a User-Agent the app set itself is not
    /// cleared just because the SDK ran with no rules.
    func testAnAppSetUserAgentIsLeftAlone() {
        let webView = WKWebView(frame: .zero)
        webView.customUserAgent = "HostApp/9.9"

        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)

        XCTAssertEqual(webView.customUserAgent, "HostApp/9.9",
                       "the SDK cleared a User-Agent it never set")
        XCTAssertFalse(WKWebViewSwizzling.isUserAgentOwnedBySDK(webView))
    }

    /// A rule that changes its UA twice must still be revertible: the second
    /// write must not lose the ownership flag.
    func testTheOverrideIsStillRevertibleAfterBeingRewritten() {
        let webView = WKWebView(frame: .zero)

        installUserAgentRule()
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        XCTAssertEqual(webView.customUserAgent, agent)

        InterceptRuleStore.shared.removeAll()
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        XCTAssertTrue(webView.customUserAgent?.isEmpty ?? true,
                      "a second write lost the ownership flag, so the override was never taken back")
    }
}
