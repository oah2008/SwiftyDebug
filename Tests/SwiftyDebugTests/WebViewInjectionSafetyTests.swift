//
//  WebViewInjectionSafetyTests.swift
//  SwiftyDebugTests
//
//  Everything SwiftyDebug puts *inside* a host app's web view, pinned down here
//  because all of it runs in somebody else's process:
//
//    * the script-message channel names, because a generic name like "log" either
//      crashes the host app (WebKit throws on a duplicate name) or silently kills
//      its own JS bridge (a blanket remove);
//    * the cookie override plan, because the cookie store is shared, persistent
//      and keyed by domain — writing one to the wrong domain hands one site's
//      credentials to another, and never taking it back leaves it there;
//    * the injected JavaScript's safety invariants — idempotent injection, whole
//      console argument lists, a fetch rebuild that keeps the body and the abort
//      signal, and an in-document origin check for pinned storage.
//
//  The console hook and the pinned-storage origin guard are *executed* (in
//  JavaScriptCore) rather than string-matched, because "does not double-wrap" and
//  "refuses a foreign origin" are claims about behaviour.
//

import XCTest
import WebKit
import JavaScriptCore
@testable import SwiftyDebug

final class WebViewInjectionSafetyTests: XCTestCase {

    // MARK: - Channel names (B1: handler-name hijack)

    /// The names the SDK used to register on the app's own content controller.
    /// Any one of them coming back is the crash/silent-bridge-kill bug returning.
    private let hijackableNames = ["log", "error", "warn", "debug", "info",
                                   "networkCapture", "cdStoragePins"]

    func testEveryRegisteredChannelIsNamespaced() {
        XCTAssertFalse(WebViewMessageChannel.all.isEmpty)
        for channel in WebViewMessageChannel.all {
            XCTAssertTrue(channel.hasPrefix(WebViewMessageChannel.prefix),
                          "\(channel) is registered on the host app's content controller unnamespaced")
            XCTAssertFalse(hijackableNames.contains(channel),
                           "\(channel) collides with a name a host app plausibly uses")
        }
    }

    func testChannelNamesAreUnique() {
        XCTAssertEqual(Set(WebViewMessageChannel.all).count, WebViewMessageChannel.all.count,
                       "two channels sharing a name means the second add() throws in WebKit")
    }

    func testStoragePinChannelIsNamespacedToo() {
        XCTAssertEqual(WebViewStoragePinStore.messageName, WebViewMessageChannel.storagePins)
        XCTAssertTrue(WebViewStoragePinStore.messageName.hasPrefix(WebViewMessageChannel.prefix))
    }

    /// The namespace is an implementation detail: a developer looking at their own
    /// `console.warn` output should see "warn".
    func testDisplayNameStripsTheNamespaceAndLeavesForeignNamesAlone() {
        XCTAssertEqual(WebViewMessageChannel.displayName(for: WebViewMessageChannel.console("warn")), "warn")
        XCTAssertEqual(WebViewMessageChannel.displayName(for: WebViewMessageChannel.networkCapture),
                       "networkCapture")
        XCTAssertEqual(WebViewMessageChannel.displayName(for: "appsOwnBridge"), "appsOwnBridge")
    }

    /// The SDK must never remove a handler name it did not add — that is the half
    /// of the bug that kills an app's bridge with no error anywhere.
    func testInjectedScriptsNeverRemoveAHandler() {
        XCTAssertFalse(WebViewInjectedScript.networkCapture.contains("removeScriptMessageHandler"))
        for fn in WebViewMessageChannel.consoleFunctions {
            XCTAssertFalse(WebViewInjectedScript.consoleHook(consoleFunction: fn)
                .contains("removeScriptMessageHandler"))
        }
    }

    func testInjectedScriptsOnlyPostToNamespacedChannels() {
        var sources = [WebViewInjectedScript.networkCapture]
        sources += WebViewMessageChannel.consoleFunctions.map(WebViewInjectedScript.consoleHook)
        for source in sources {
            for handlerReference in messageHandlerReferences(in: source) {
                XCTAssertTrue(handlerReference.hasPrefix(WebViewMessageChannel.prefix),
                              "the injected JS posts to “\(handlerReference)”, which the SDK does not own")
            }
        }
    }

    /// Pulls every `messageHandlers.<name>` out of a script.
    private func messageHandlerReferences(in source: String) -> [String] {
        let marker = "messageHandlers."
        var names: [String] = []
        var rest = Substring(source)
        while let range = rest.range(of: marker) {
            rest = rest[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.append(String(name)) }
        }
        return names
    }

    // MARK: - Idempotent injection (M5: unbounded accumulation)

    func testNetworkScriptRefusesToInstallItselfTwice() {
        XCTAssertTrue(WebViewInjectedScript.networkCapture.contains("if(window.__cd_net_hooked)return;"))
    }

    func testConsoleHookExecutesOnceNoMatterHowOftenItIsInjected() {
        let js = WebViewInjectedScript.consoleHook(consoleFunction: "warn")
        let context = try! XCTUnwrap(JSContext())
        installConsoleStubs(in: context)

        // A shared WKUserContentController used to collect one copy per web view.
        for _ in 0..<5 { context.evaluateScript(js) }
        context.evaluateScript("console.warn('hello');")

        XCTAssertEqual(postedMessages(in: context), ["hello"],
                       "the console wrapper stacked, so one page log became several")
        XCTAssertEqual(context.objectForKeyedSubscript("__pageSaw")!.toArray()!.count, 1,
                       "the page's own console function ran more than once")
    }

    // MARK: - Console output (M5 addendum: only the first argument was forwarded)

    func testConsoleHookForwardsEveryArgument() {
        let context = try! XCTUnwrap(JSContext())
        installConsoleStubs(in: context)
        context.evaluateScript(WebViewInjectedScript.consoleHook(consoleFunction: "log"))
        context.evaluateScript("console.log('user', 42, {a:1}, null);")

        XCTAssertEqual(postedMessages(in: context), ["user 42 {\"a\":1} null"],
                       "the page's own console output was truncated to its first argument")
    }

    func testConsoleHookSurvivesAnUnserialisableArgument() {
        let context = try! XCTUnwrap(JSContext())
        installConsoleStubs(in: context)
        context.evaluateScript(WebViewInjectedScript.consoleHook(consoleFunction: "log"))
        // A circular object throws inside JSON.stringify; a self-referencing log
        // line must not take the page's console with it.
        context.evaluateScript("var c={};c.self=c;console.log('boom', c);")

        XCTAssertEqual(postedMessages(in: context).count, 1)
        XCTAssertTrue(postedMessages(in: context)[0].hasPrefix("boom "))
        XCTAssertNil(context.exception)
    }

    func testConsoleHookStillCallsThePagesOwnFunction() {
        let context = try! XCTUnwrap(JSContext())
        installConsoleStubs(in: context)
        context.evaluateScript(WebViewInjectedScript.consoleHook(consoleFunction: "log"))
        context.evaluateScript("console.log('a', 'b');")

        let pageSaw = context.objectForKeyedSubscript("__pageSaw")!.toArray() as? [[Any]]
        XCTAssertEqual(pageSaw?.count, 1)
        XCTAssertEqual(pageSaw?.first?.count, 2, "the page's console lost an argument")
    }

    /// `console` + a `window.webkit.messageHandlers` that records what was posted.
    private func installConsoleStubs(in context: JSContext) {
        context.evaluateScript("""
        var __posted=[];var __pageSaw=[];
        var window=this;
        window.__cd_enabled=true;
        window.console={log:function(){__pageSaw.push(Array.prototype.slice.call(arguments));},
                        warn:function(){__pageSaw.push(Array.prototype.slice.call(arguments));}};
        var console=window.console;
        window.webkit={messageHandlers:{}};
        var __make=function(n){window.webkit.messageHandlers[n]={postMessage:function(s){__posted.push(s);}};};
        __make('\(WebViewMessageChannel.console("log"))');
        __make('\(WebViewMessageChannel.console("warn"))');
        """)
    }

    private func postedMessages(in context: JSContext) -> [String] {
        (context.objectForKeyedSubscript("__posted")?.toArray() as? [String]) ?? []
    }

    // MARK: - fetch rebuild (M4: body and AbortSignal were dropped)

    /// The three things the old rebuild lost. Behaviour is covered end-to-end by
    /// running this script against a real `fetch`/`Request` implementation; what
    /// is asserted here is that the source still contains the mechanism.
    func testFetchHookPreservesTheOriginalRequest() {
        let js = WebViewInjectedScript.networkCapture

        // Unchanged URL → copy-construct, the only way to keep an owned body.
        XCTAssertTrue(js.contains("new Request(reqObj,extra)"))
        // Changed URL → carry the signal across explicitly.
        XCTAssertTrue(js.contains("merged.signal=reqObj.signal"))
        // Changed URL → read the body off a clone and put it back.
        XCTAssertTrue(js.contains("reqObj.clone()"))
        XCTAssertTrue(js.contains("merged.body=r.b"))
        // The caller's own object is forwarded untouched when nothing matches.
        XCTAssertTrue(js.contains("if(!rule)return send(input,init,fullUrl,body,false);"))
    }

    /// `mode: 'navigate'` is readable on a Request but throws in the Request
    /// constructor, so copying it forward would turn a rewritten request into an
    /// exception inside the page.
    func testFetchHookDoesNotCopyNavigateMode() {
        XCTAssertTrue(WebViewInjectedScript.networkCapture.contains("req.mode!=='navigate'"))
    }

    // MARK: - Cookie header overrides (M9: wrong-origin write that persisted)

    private func hostRule(hosts: [String],
                          cookie: String,
                          order: Int = 0,
                          enabled: Bool = true) -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: "host:" + hosts.joined(separator: ","), matchMode: .host)
        rule.matchHosts = hosts
        rule.headerOverrides = [KVPair(key: "Cookie", value: cookie)]
        rule.isEnabled = enabled
        rule.order = order
        return rule
    }

    func testCookieOverrideIsScopedToTheHostTheRuleNames() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(
            for: [hostRule(hosts: ["api.example.com"], cookie: "session=abc")])

        XCTAssertEqual(plan.cookies.count, 1)
        XCTAssertEqual(plan.cookies.first?.name, "session")
        XCTAssertEqual(plan.cookies.first?.value, "abc")
        XCTAssertEqual(plan.cookies.first?.domain, "api.example.com")
        XCTAssertTrue(plan.refusals.isEmpty)
    }

    /// The regression this replaces: a global rule's cookie was deposited on
    /// whatever domain happened to be handy.
    func testGlobalRuleCookieIsRefusedRatherThanGuessedAtADomain() {
        var rule = InterceptRule(matchEndpoint: "global", matchMode: .global)
        rule.headerOverrides = [KVPair(key: "Cookie", value: "session=abc")]

        let plan = WKWebViewSwizzling.cookieOverridePlan(for: [rule])
        XCTAssertTrue(plan.cookies.isEmpty, "a rule that names no host got its cookie written somewhere")
        XCTAssertEqual(plan.refusals.count, 1)
        XCTAssertTrue(plan.refusals[0].contains("global"))
    }

    func testPathScopedRulesCookiesAreRefused() {
        for mode in [EndpointMatchMode.exact, .normalized] {
            var rule = InterceptRule(matchEndpoint: "/v1/orders", matchMode: mode)
            rule.headerOverrides = [KVPair(key: "Cookie", value: "a=1")]
            let plan = WKWebViewSwizzling.cookieOverridePlan(for: [rule])
            XCTAssertTrue(plan.cookies.isEmpty, "\(mode) rule wrote a cookie with no host to scope it to")
            XCTAssertEqual(plan.refusals.count, 1)
        }
    }

    func testDisabledRuleContributesNothing() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(
            for: [hostRule(hosts: ["api.example.com"], cookie: "session=abc", enabled: false)])
        XCTAssertTrue(plan.cookies.isEmpty)
        XCTAssertTrue(plan.refusals.isEmpty, "a disabled rule is not a failure to report")
    }

    func testEveryHostOnARuleGetsItsOwnCookie() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(
            for: [hostRule(hosts: ["a.example.com", "https://b.example.com/v1"], cookie: "t=1")])

        XCTAssertEqual(plan.cookies.map(\.domain), ["a.example.com", "b.example.com"])
        XCTAssertTrue(plan.cookies.allSatisfy { $0.name == "t" && $0.value == "1" })
    }

    func testMultiPairCookieHeaderBecomesOneCookieEach() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(
            for: [hostRule(hosts: ["a.com"], cookie: "a=1; b=2;  c=3")])
        XCTAssertEqual(plan.cookies.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(plan.cookies.map(\.value), ["1", "2", "3"])
    }

    func testLaterRuleWinsForTheSameCookieOnTheSameHost() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(for: [
            hostRule(hosts: ["a.com"], cookie: "session=first", order: 0),
            hostRule(hosts: ["a.com"], cookie: "session=second", order: 5),
        ])
        XCTAssertEqual(plan.cookies.count, 1, "the same cookie on the same host was written twice")
        XCTAssertEqual(plan.cookies.first?.value, "second")
    }

    func testSameCookieNameOnDifferentHostsIsNotCollapsed() {
        let plan = WKWebViewSwizzling.cookieOverridePlan(for: [
            hostRule(hosts: ["a.com"], cookie: "session=one", order: 0),
            hostRule(hosts: ["b.com"], cookie: "session=two", order: 1),
        ])
        XCTAssertEqual(plan.cookies.count, 2)
        XCTAssertEqual(Set(plan.cookies.map(\.domain)), ["a.com", "b.com"])
    }

    func testNonCookieHeadersAreNotTreatedAsCookies() {
        var rule = hostRule(hosts: ["a.com"], cookie: "x=1")
        rule.headerOverrides = [KVPair(key: "Authorization", value: "Bearer x=1")]
        XCTAssertTrue(WKWebViewSwizzling.cookieOverridePlan(for: [rule]).cookies.isEmpty)
    }

    func testCookieHeaderKeyIsMatchedCaseInsensitively() {
        var rule = hostRule(hosts: ["a.com"], cookie: "x=1")
        rule.headerOverrides = [KVPair(key: "COOKIE", value: "x=1")]
        XCTAssertEqual(WKWebViewSwizzling.cookieOverridePlan(for: [rule]).cookies.count, 1)
    }

    // MARK: - Cookie header parsing

    func testCookiePairParsing() {
        XCTAssertEqual(WKWebViewSwizzling.cookiePairs(inHeaderValue: "a=1; b=2").map(\.name), ["a", "b"])
        // A value may legitimately contain "=" (base64 padding).
        XCTAssertEqual(WKWebViewSwizzling.cookiePairs(inHeaderValue: "t=YWJj==").first?.value, "YWJj==")
        // Junk without "=" is not a cookie.
        XCTAssertTrue(WKWebViewSwizzling.cookiePairs(inHeaderValue: "novalue").isEmpty)
        XCTAssertTrue(WKWebViewSwizzling.cookiePairs(inHeaderValue: "=orphan").isEmpty)
        XCTAssertTrue(WKWebViewSwizzling.cookiePairs(inHeaderValue: "   ").isEmpty)
        // An empty value is meaningful — it is how a cookie gets blanked.
        XCTAssertEqual(WKWebViewSwizzling.cookiePairs(inHeaderValue: "a=").first?.value, "")
    }

    // MARK: - Cookie identity (what "the SDK wrote this one" means)

    func testIdentityIgnoresTheValueSoAChangedValueUpdatesRatherThanDeletes() {
        let before = NativeCookieOverride(name: "s", value: "1", domain: "a.com")
        let after = NativeCookieOverride(name: "s", value: "2", domain: "a.com")
        XCTAssertEqual(before.identity, after.identity)
    }

    func testIdentityMatchesTheCookieTheStoreHandsBack() {
        let override = NativeCookieOverride(name: "s", value: "1", domain: "a.com")
        let cookie = try! XCTUnwrap(override.httpCookie)
        XCTAssertEqual(NativeCookieOverride.identity(of: cookie), override.identity,
                       "a cookie the SDK wrote would not be recognised, so it could never be removed")
    }

    func testIdentityIgnoresALeadingDotOnTheDomain() {
        XCTAssertEqual(NativeCookieOverride.normalizedDomain(".Example.com"), "example.com")
        XCTAssertEqual(NativeCookieOverride(name: "s", value: "1", domain: ".a.com").identity,
                       NativeCookieOverride(name: "s", value: "1", domain: "a.com").identity)
    }

    func testCookieIsBuiltForTheRulesDomainAtRootPath() {
        let cookie = try! XCTUnwrap(
            NativeCookieOverride(name: "s", value: "v", domain: "api.example.com").httpCookie)
        XCTAssertEqual(cookie.name, "s")
        XCTAssertEqual(cookie.value, "v")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.domain.hasSuffix("api.example.com"))
    }

    // MARK: - Taking cookies back (M9: the write that persisted forever)

    private func identity(_ name: String, _ domain: String) -> NativeCookieOverride.Identity {
        NativeCookieOverride(name: name, value: "", domain: domain).identity
    }

    func testDisablingARuleDeletesExactlyTheCookieItAddedAndNothingElse() {
        let previous: Set = [identity("session", "a.com"), identity("flag", "b.com")]
        // The b.com rule was switched off; only the a.com one is still asked for.
        let plan = NativeCookieOverrideStore.reconciliation(
            previous: previous,
            desired: [NativeCookieOverride(name: "session", value: "abc", domain: "a.com")])

        XCTAssertEqual(plan.delete, [identity("flag", "b.com")])
        XCTAssertEqual(plan.write.map(\.name), ["session"])
    }

    func testACookieTheSDKNeverWroteIsNeverACandidateForDeletion() {
        // The app's own session cookie, same name, same domain — but not ours.
        let plan = NativeCookieOverrideStore.reconciliation(previous: [], desired: [])
        XCTAssertTrue(plan.delete.isEmpty)

        let stillOurs = NativeCookieOverrideStore.reconciliation(
            previous: [identity("session", "a.com")],
            desired: [NativeCookieOverride(name: "session", value: "new", domain: "a.com")])
        XCTAssertTrue(stillOurs.delete.isEmpty, "a changed value must update the cookie, not delete it")
        XCTAssertEqual(stillOurs.write.first?.value, "new")
    }

    func testDeletingEveryRuleTakesEveryCookieBack() {
        let previous: Set = [identity("a", "x.com"), identity("b", "x.com")]
        let plan = NativeCookieOverrideStore.reconciliation(previous: previous, desired: [])
        XCTAssertEqual(plan.delete, previous)
        XCTAssertTrue(plan.write.isEmpty)
    }

    /// End-to-end: the rules go in, the cookies that come out are scoped to the
    /// rules' own hosts, and switching the rules off takes exactly those back.
    func testRulePlanAndReconcileAgreeOnWhatComesBack() {
        let rules = [hostRule(hosts: ["a.com"], cookie: "s=1"),
                     hostRule(hosts: ["b.com"], cookie: "t=2", order: 1)]
        let written = Set(WKWebViewSwizzling.cookieOverridePlan(for: rules).cookies.map(\.identity))
        XCTAssertEqual(written, [identity("s", "a.com"), identity("t", "b.com")])

        let afterDisablingAll = WKWebViewSwizzling.cookieOverridePlan(
            for: rules.map { var r = $0; r.isEnabled = false; return r })
        let plan = NativeCookieOverrideStore.reconciliation(previous: written,
                                                            desired: afterDisablingAll.cookies)
        XCTAssertEqual(plan.delete, written)
    }

    // MARK: - Pinned storage origin guard (B5: cross-origin data write)

    private func applyScript(origin: String?) -> String {
        try! XCTUnwrap(WebViewStoragePinScript.applyScript(
            object: "localStorage",
            pins: [WebViewStoragePin(key: "token", value: "A")],
            origin: origin))
    }

    /// Runs a generated apply script against a stubbed document on `origin`.
    /// Returns (script result, what actually got written).
    private func runApply(_ script: String, onDocumentAt location: (String, String, String))
        -> (result: Int, written: [String: String]) {
        let context = try! XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this;var __written={};
        window.location={protocol:'\(location.0)',hostname:'\(location.1)',port:'\(location.2)'};
        window.localStorage={setItem:function(k,v){__written[k]=v;}};
        """)
        let result = context.evaluateScript(script)
        let written = (context.objectForKeyedSubscript("__written")?.toDictionary() as? [String: String]) ?? [:]
        return (Int(result?.toInt32() ?? -99), written)
    }

    func testPinnedValuesAreWrittenOnTheOriginTheyWerePinnedOn() {
        let run = runApply(applyScript(origin: "https://example.com:443"),
                           onDocumentAt: ("https:", "example.com", ""))
        XCTAssertEqual(run.result, 1)
        XCTAssertEqual(run.written, ["token": "A"])
    }

    /// The blocking case: `webView.url` flips at provisional navigation, so native
    /// can be asked about the destination while the live document is still the old
    /// page. The document itself has the last word.
    func testPinnedValuesAreRefusedByADocumentOnAnotherOrigin() {
        let script = applyScript(origin: "https://example.com:443")
        for (label, location) in [
            ("another host", ("https:", "evil.example.net", "")),
            ("another scheme", ("http:", "example.com", "")),
            ("another port", ("https:", "example.com", "8443")),
        ] as [(String, (String, String, String))] {
            let run = runApply(script, onDocumentAt: location)
            XCTAssertEqual(run.result, -2, "\(label) was not refused")
            XCTAssertTrue(run.written.isEmpty, "\(label): one origin's value was written into another's storage")
        }
    }

    func testOriginGuardMatchesTheNativeOriginKeyIncludingDefaultPorts() {
        // `originKey` spells the default port out; `location.port` is empty for it.
        let httpsOrigin = try! XCTUnwrap(
            WebViewStoragePinScript.originKey(for: URL(string: "https://example.com/x")))
        XCTAssertEqual(runApply(applyScript(origin: httpsOrigin),
                                onDocumentAt: ("https:", "example.com", "")).result, 1)

        let httpOrigin = try! XCTUnwrap(
            WebViewStoragePinScript.originKey(for: URL(string: "http://example.com/x")))
        XCTAssertEqual(runApply(applyScript(origin: httpOrigin),
                                onDocumentAt: ("http:", "example.com", "")).result, 1)
    }

    func testOriginGuardIsCaseInsensitiveOnTheHost() {
        XCTAssertEqual(runApply(applyScript(origin: "https://example.com:443"),
                                onDocumentAt: ("https:", "EXAMPLE.COM", "")).result, 1)
    }

    /// The guard is a *literal*, not concatenated text, so an origin can never
    /// close the statement it sits in — an unescaped quote here would be a syntax
    /// error at best and arbitrary JS in the host app's page at worst.
    func testOriginGuardIsAnEscapedLiteral() {
        let nasty = "https://example.com\":443\";alert(1);//"
        let script = applyScript(origin: nasty)
        XCTAssertTrue(script.contains(WebViewStoragePinScript.jsStringLiteral(nasty)))

        // It still parses and still refuses, rather than executing the payload.
        let context = try! XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this;var __written={};var __alerted=false;
        function alert(){__alerted=true;}
        window.location={protocol:'https:',hostname:'example.com',port:''};
        window.localStorage={setItem:function(k,v){__written[k]=v;}};
        """)
        let result = context.evaluateScript(script)
        XCTAssertNil(context.exception, "the escaped origin did not parse")
        XCTAssertEqual(result?.toInt32(), -2)
        XCTAssertFalse(context.objectForKeyedSubscript("__alerted")!.toBool())
        XCTAssertTrue((context.objectForKeyedSubscript("__written")?.toDictionary() ?? [:]).isEmpty)
    }

    /// Callers that pass no origin get the previous, unguarded script — so the
    /// guard being absent is always a deliberate choice at the call site.
    func testNoOriginMeansNoGuard() {
        XCTAssertFalse(applyScript(origin: nil).contains("window.location"))
        XCTAssertTrue(applyScript(origin: "https://example.com:443").contains("window.location"))
    }
}
