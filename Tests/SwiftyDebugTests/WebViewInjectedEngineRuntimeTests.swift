//
//  WebViewInjectedEngineRuntimeTests.swift
//  SwiftyDebugTests
//
//  Three defects in the JavaScript SwiftyDebug injects into the host app's own
//  pages, all of them invisible to a test that only greps the source string:
//
//   1. THE KILL-SWITCH DID NOT SURVIVE A PAGE LOAD. `fullStop()` pushes
//      `__cd_setEnabled(false)` into the documents that exist at that moment.
//      `window` dies with the document, WebKit offers no API to remove a user
//      script, so the next navigation re-ran the engine, took its
//      `typeof window.__cd_enabled==='undefined'` branch and re-armed itself —
//      and the re-injected rules snapshot went back to blocking and rewriting
//      the host app's traffic. A stopped SDK has to be inert; that is the whole
//      promise of the kill-switch.
//
//   2. A BLOCKED XHR NEVER COMPLETED. The block path called `abort()` before
//      `send()`, which the XHR spec says is observably nothing: no error, no
//      abort, no loadend, no readyState change. The page's completion path
//      never ran and its request hung forever.
//
//   3. AN XHR HEADER OVERRIDE APPENDED INSTEAD OF REPLACING.
//      `setRequestHeader` *combines* repeated values for one name, so the
//      page's original `Authorization` was sent to the server alongside the
//      override: `Bearer ORIGINAL, Bearer NEW`.
//
//  So these tests run the SHIPPED script — `WebViewInjectedScript.networkCapture`
//  in full, not an excerpt and not a re-implementation — inside a JSContext
//  against a browser stub whose XHR follows the spec on the three points that
//  decide these bugs: `setRequestHeader` combines rather than replaces, an
//  `abort()` before `send()` is a no-op, and a network error ends at
//  readyState 4 / status 0. Each behaviour was first confirmed in a real
//  WKWebView (a `WKURLSchemeHandler` showed `Authorization: Bearer ORIGINAL,
//  Bearer NEW` actually reaching the wire; the removal of a script message
//  handler was confirmed to be visible to JavaScript immediately, in later
//  documents and in sub-frames, which is what makes the kill-switch fix work).
//
//  A "document" here is one JSContext: a navigation is a *new* one, with the
//  same user scripts injected into it again — exactly what WebKit does.
//

import XCTest
import JavaScriptCore
@testable import SwiftyDebug

final class WebViewInjectedEngineRuntimeTests: XCTestCase {

    // MARK: - 1. The kill-switch

    /// The reported case: a full stop, then the user taps a link.
    func testAStoppedSDKStaysStoppedAcrossANavigation() throws {
        // Document 1, SDK running: the rule does what it says.
        let live = try Document(channelRegistered: true)
        live.seedRules([blockingRule()])
        XCTAssertTrue(live.blocksARequest(to: apiURL),
                      "Precondition: an enabled blocking rule blocks inside a web view.")

        // What `fullStop()` pushes into the documents that exist right now.
        live.run("window.__cd_setEnabled(false);")
        XCTAssertFalse(live.blocksARequest(to: apiURL),
                       "The live push must stop interception in the current document.")

        // The user navigates. WebKit re-runs every user script in the new
        // document — the engine and the rules snapshot — and the SDK's message
        // handlers are gone, because a full stop unregistered them.
        let afterNavigation = try Document(channelRegistered: false)
        afterNavigation.seedRules([blockingRule()])

        XCTAssertFalse(afterNavigation.blocksARequest(to: apiURL),
                       "A page load re-armed the injected engine: the SDK was fully stopped and "
                       + "was still blocking the host app's requests inside its web views.")
        XCTAssertEqual(afterNavigation.captures.count, 0,
                       "A stopped SDK must not be capturing either.")
    }

    /// The same hole, seen through a rewrite rather than a block: the host app's
    /// own `Authorization` was still being replaced after a full stop.
    func testAStoppedSDKDoesNotRewriteHeadersAfterANavigation() throws {
        let afterNavigation = try Document(channelRegistered: false)
        afterNavigation.seedRules([headerRule()])

        afterNavigation.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('Authorization','Bearer ORIGINAL');
        x.setRequestHeader('X-Trace','abc');
        x.send('{}');
        """)

        XCTAssertEqual(afterNavigation.wire.count, 1, "The request itself must still go out.")
        XCTAssertEqual(afterNavigation.wireHeaders(0)["Authorization"], "Bearer ORIGINAL",
                       "A stopped SDK rewrote the page's Authorization header on the next page load.")
        XCTAssertEqual(afterNavigation.wireHeaders(0)["X-Trace"], "abc",
                       "A stopped SDK was still stripping the page's own headers.")
    }

    /// The switch has to be a switch: once native registers the channel again
    /// (`resumeFromFullStop()` / `enable()`), a newly loaded page intercepts.
    func testAResumedSDKInterceptsAgainInANewDocument() throws {
        let resumed = try Document(channelRegistered: true)
        resumed.seedRules([blockingRule()])
        XCTAssertTrue(resumed.blocksARequest(to: apiURL),
                      "After a resume the SDK must work again — the fix must not be one-way.")
    }

    /// The flag the SDK pushes and the channel it registers are two separate
    /// halves, and *either* one being off means off. This pins the half that a
    /// navigation cannot undo, so nobody can "simplify" it away.
    func testTheChannelIsConsultedPerRequestNotOnlyAtInjectionTime() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])
        XCTAssertTrue(document.blocksARequest(to: apiURL))

        // Native detaches the SDK's handlers under a document that is already
        // running — exactly what `pushEnabledStateToWebViews(enabled:false)`
        // does, and what WebKit makes visible to JavaScript immediately.
        document.run("delete window.webkit.messageHandlers.\(WebViewMessageChannel.networkCapture);")

        XCTAssertFalse(document.blocksARequest(to: apiURL),
                       "Enablement was decided once at injection time, so detaching the SDK's "
                       + "channel left the engine still intercepting.")
    }

    /// When the SDK's channel is the *only* one registered, unregistering it
    /// takes `window.webkit` away entirely — confirmed in a real WKWebView. The
    /// engine still has to load without throwing inside the host's page, and
    /// still has to intercept nothing.
    func testAStoppedSDKIsInertWhenTheWholeWebkitNamespaceIsGone() throws {
        // The context fails the test on any uncaught exception, so simply
        // getting here proves the engine loaded and ran cleanly.
        let document = try Document(channelRegistered: false, webkitNamespaceMissing: true)
        XCTAssertEqual(document.string("typeof window.webkit"), "undefined")
        document.seedRules([blockingRule()])

        XCTAssertFalse(document.blocksARequest(to: apiURL),
                       "A stopped SDK kept blocking in a page with no bridge left at all.")
    }

    /// The console wrapper is a separate script and was not changed; this pins
    /// the property that matters after a stop — the host page's own `console`
    /// keeps working when there is nothing to post to.
    func testTheConsoleHookIsHarmlessWhenTheChannelIsGone() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this;var __pageSaw=[];
        window.console={log:function(){__pageSaw.push(Array.prototype.slice.call(arguments));}};
        var console=window.console;
        window.webkit={messageHandlers:{}};
        """)
        context.evaluateScript(WebViewInjectedScript.consoleHook(consoleFunction: "log"))
        context.evaluateScript("console.log('still', 'works');")

        XCTAssertNil(context.exception, "a stopped SDK must not throw out of the page's console")
        let pageSaw = context.objectForKeyedSubscript("__pageSaw")?.toArray() as? [[Any]]
        XCTAssertEqual(pageSaw?.count, 1, "the page's own console.log stopped running")
        XCTAssertEqual(pageSaw?.first?.count, 2)
    }

    // MARK: - 2. A blocked XHR has to fail, not hang

    func testABlockedXHRFailsTheWayANetworkErrorDoes() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])

        document.run("""
        window.__seen=[];
        var x=new XMLHttpRequest();
        var note=function(t){return function(){window.__seen.push(t+':'+x.readyState+':'+x.status);};};
        x.onreadystatechange=note('readystatechange');
        x.onerror=note('error');
        x.onload=note('load');
        x.onloadend=note('loadend');
        x.open('GET','\(apiURL)');
        window.__seen=[];
        x.send();
        window.__afterSend=window.__seen.slice();
        window.__x=x;
        """)

        XCTAssertEqual(document.strings("window.__afterSend"), [],
                       "A real XHR never re-enters the page from inside send(); the failure has "
                       + "to be delivered asynchronously.")

        document.flushTimers()

        XCTAssertEqual(document.strings("window.__seen"),
                       ["readystatechange:4:0", "error:4:0", "loadend:4:0"],
                       "A blocked XHR fired nothing at all: no error, no loadend, no readyState "
                       + "change, so the page waited for a response that could never arrive.")
        XCTAssertEqual(document.number("window.__x.readyState"), 4,
                       "The request has to end in DONE, like a failed one.")
        XCTAssertEqual(document.number("window.__x.status"), 0)
        XCTAssertEqual(document.wire.count, 0,
                       "A blocked request must never reach the network.")
        XCTAssertEqual(document.captures.count, 1,
                       "The block itself is still reported to the SDK.")
    }

    /// A page that starts a spinner on `loadstart` and stops it on `loadend`
    /// must not be left with an unbalanced pair.
    func testABlockedXHRDeliversLoadstartBeforeLoadend() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])
        document.run("""
        window.__pairs=[];
        var x=new XMLHttpRequest();
        x.addEventListener('loadstart',function(){window.__pairs.push('loadstart');});
        x.addEventListener('loadend',function(){window.__pairs.push('loadend');});
        x.open('GET','\(apiURL)');
        x.send();
        """)
        document.flushTimers()
        XCTAssertEqual(document.strings("window.__pairs"), ["loadstart", "loadend"])
    }

    /// The failure is faked with an own `readyState` accessor. Re-opening the
    /// same object must not keep reporting DONE, or a page that retries reads a
    /// finished request that has not started.
    func testReopeningABlockedXHRReportsTheRealStateAgain() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])
        document.run("""
        window.__x=new XMLHttpRequest();
        window.__x.open('GET','\(apiURL)');
        window.__x.send();
        """)
        document.flushTimers()
        XCTAssertEqual(document.number("window.__x.readyState"), 4)

        // The page retries somewhere no rule matches.
        document.run("window.__x.open('GET','\(otherURL)');")
        XCTAssertEqual(document.number("window.__x.readyState"), 1,
                       "A re-opened XHR kept reporting DONE from the previous, blocked attempt.")
        document.run("window.__x.send();")
        XCTAssertEqual(document.wire.count, 1,
                       "The retry has to reach the network — only the blocked URL is blocked.")
    }

    /// The fetch half of the same question. `fetch` already failed correctly (a
    /// rejected promise *is* how fetch reports a network failure), and it has to
    /// keep doing so.
    func testABlockedFetchRejectsAndNeverReachesTheNetwork() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])
        document.run("""
        window.__settled='PENDING';
        window.fetch('\(apiURL)').then(function(){window.__settled='resolved';},
                                       function(e){window.__settled='rejected: '+e.message;});
        """)
        document.drainMicrotasks()

        XCTAssertEqual(document.string("window.__settled"),
                       "rejected: Blocked by SwiftyDebug intercept rule",
                       "A blocked fetch must reject so the page's catch runs.")
        XCTAssertEqual(document.wire.count, 0)
    }

    // MARK: - 3. An override replaces, it does not append

    func testAnOverrideReplacesTheHeaderThePageSet() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('Authorization','Bearer ORIGINAL');
        x.send('{}');
        """)

        XCTAssertEqual(document.wireHeaders(0)["Authorization"], "Bearer NEW",
                       "The page's original Authorization went to the server alongside the "
                       + "override — `setRequestHeader` combines values, it does not replace them.")
    }

    /// HTTP header names are case-insensitive, and WebKit combines `authorization`
    /// with `Authorization`. An override typed in either case has to replace.
    func testAnOverrideReplacesEvenWhenTheCaseDiffers() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('authorization','Bearer ORIGINAL');
        x.send('{}');
        """)

        let headers = document.wireHeaders(0)
        XCTAssertEqual(headers.count, 1, "Exactly one Authorization header may reach the wire.")
        XCTAssertEqual(headers["Authorization"], "Bearer NEW")
    }

    /// The SDK's own capture must show what was sent, not both values.
    func testTheCaptureShowsTheHeaderThatWasActuallySent() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('authorization','Bearer ORIGINAL');
        x.send('{}');
        """)
        document.flushTimers()   // the capture is posted from `loadend`

        let captured = try XCTUnwrap(document.captures.first?["requestHeaders"] as? [String: Any])
        XCTAssertEqual(captured.count, 1,
                       "The Network tab listed the page's value and the override as two headers.")
        XCTAssertEqual(captured["Authorization"] as? String, "Bearer NEW")
    }

    func testAHeaderOnlyTheRuleSetsIsStillAdded() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("var x=new XMLHttpRequest();x.open('POST','\(apiURL)');x.send('{}');")

        XCTAssertEqual(document.wireHeaders(0), ["Authorization": "Bearer NEW"])
    }

    func testARemovedHeaderNeverReachesTheWire() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('X-Trace','abc');
        x.send('{}');
        """)

        XCTAssertNil(document.wireHeaders(0)["X-Trace"],
                     "A header the rule removes must not be sent.")
    }

    /// What the fix must NOT break: for a name no rule touches, repeated
    /// `setRequestHeader` calls are combined by the browser, and that is what the
    /// XHR spec requires. Dropping the page's call for *every* name would have
    /// silently changed requests nobody wrote a rule for.
    func testRepeatedHeadersThePageSetsAreStillCombined() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('Accept','text/plain');
        x.setRequestHeader('Accept','application/json');
        x.send('{}');
        """)

        XCTAssertEqual(document.wireHeaders(0)["Accept"], "text/plain, application/json",
                       "A name no rule overrides must keep the spec's combining behaviour.")
    }

    // MARK: - Adjacent behaviour: ordinary traffic still works

    func testAnUnmatchedXHRIsForwardedUntouchedAndStillCaptured() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])   // matches a different host
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(otherURL)');
        x.setRequestHeader('Authorization','Bearer ORIGINAL');
        x.send('hello');
        """)
        document.flushTimers()

        XCTAssertEqual(document.wire.count, 1)
        XCTAssertEqual(document.wireHeaders(0), ["Authorization": "Bearer ORIGINAL"],
                       "A request no rule matches must reach the network exactly as the page wrote it.")
        let capture = try XCTUnwrap(document.captures.first)
        XCTAssertEqual(capture["url"] as? String, otherURL)
        XCTAssertEqual(capture["status"] as? Int, 200)
        XCTAssertEqual(capture["responseBody"] as? String, "PAYLOAD")
        XCTAssertEqual(capture["body"] as? String, "hello")
    }

    func testAnUnmatchedFetchIsForwardedUntouchedAndStillCaptured() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([blockingRule()])
        document.run("""
        window.__settled='PENDING';
        window.fetch('\(otherURL)',{method:'POST',headers:{'Authorization':'Bearer ORIGINAL'},body:'hello'})
          .then(function(r){window.__settled='resolved '+r.status;},
                function(e){window.__settled='rejected '+e.message;});
        """)
        document.drainMicrotasks()

        XCTAssertEqual(document.string("window.__settled"), "resolved 200")
        XCTAssertEqual(document.wire.count, 1)
        XCTAssertEqual(document.wireHeaders(0), ["Authorization": "Bearer ORIGINAL"])
        XCTAssertEqual(document.captures.first?["type"] as? String, "fetch")
    }

    /// The overridden-header path is the one the fix rewrote; the *other* rule
    /// effects that share `send()` must be unaffected.
    func testARewrittenRequestStillCarriesItsBody() throws {
        let document = try Document(channelRegistered: true)
        document.seedRules([headerRule()])
        document.run("""
        var x=new XMLHttpRequest();
        x.open('POST','\(apiURL)');
        x.setRequestHeader('Authorization','Bearer ORIGINAL');
        x.send('{"a":1}');
        """)
        document.flushTimers()

        XCTAssertEqual(document.wire.first?["body"] as? String, "{\"a\":1}")
        XCTAssertEqual(document.captures.first?["body"] as? String, "{\"a\":1}")
    }

    // MARK: - Rules

    private let apiURL = "https://api.example.com/v1/orders"
    private let otherURL = "https://cdn.other.test/assets/app.js"

    /// The JSON shape `InterceptRuleStore.rulesAsJSONString()` hands the page.
    private func blockingRule() -> [String: Any] {
        [
            "matchEndpoint": "host:api.example.com",
            "matchMode": "host",
            "matchHosts": ["api.example.com"],
            "matchHost": "",
            "name": "block",
            "isBlocked": true,
            "order": 0,
            "headerOverrides": [],
            "queryParamOverrides": [],
            "removedHeaderKeys": [],
            "removedQueryParamKeys": [],
            "redirectMode": "none",
            "redirectTarget": "",
        ]
    }

    private func headerRule() -> [String: Any] {
        var rule = blockingRule()
        rule["name"] = "headers"
        rule["isBlocked"] = false
        rule["headerOverrides"] = [["key": "Authorization", "value": "Bearer NEW"]]
        rule["removedHeaderKeys"] = ["X-Trace"]
        return rule
    }

    // MARK: - One document

    /// A single web-view document running the shipped engine.
    ///
    /// `channelRegistered` is the native half of the kill-switch: whether the
    /// SDK's `WKScriptMessageHandler` is registered on this web view at the
    /// moment the document loads. A full stop unregisters it, and WebKit stops
    /// exposing the name to JavaScript — confirmed in a real WKWebView, in the
    /// current document, in later ones, and in sub-frames.
    private final class Document {

        let context: JSContext

        init(channelRegistered: Bool, webkitNamespaceMissing: Bool = false) throws {
            context = try XCTUnwrap(JSContext())
            // The default handler swallows the exception into `context.exception`
            // and keeps going, which would let a broken engine look like a
            // passing test. Anything uncaught fails the test where it happens.
            context.exceptionHandler = { _, exception in
                XCTFail("uncaught JavaScript exception: \(exception?.toString() ?? "?")")
            }
            context.evaluateScript(Document.browserStub)
            if webkitNamespaceMissing {
                // WebKit stops exposing `window.webkit` at all once no message
                // handler is registered — the shape a full stop leaves behind in
                // an app with no bridge of its own.
                context.evaluateScript("delete window.webkit;")
            }
            if channelRegistered {
                context.evaluateScript("__registerChannel('\(WebViewMessageChannel.networkCapture)');"
                    + "__registerChannel('\(WebViewMessageChannel.rulesRequest)');")
            }
            // Exactly what WebKit injects at document start, in full.
            context.evaluateScript(WebViewInjectedScript.networkCapture)
            XCTAssertTrue(context.evaluateScript("window.__cd_net_hooked===true").toBool(),
                          "the injected engine did not install itself")
        }

        /// The `.atDocumentStart` user script that seeds the rules snapshot.
        func seedRules(_ rules: [[String: Any]]) {
            let data = try! JSONSerialization.data(withJSONObject: rules, options: [])
            let json = String(data: data, encoding: .utf8)!
            run("if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(json));")
        }

        @discardableResult
        func run(_ js: String) -> JSValue? { context.evaluateScript(js) }

        func flushTimers() { run("__flushTimers();") }

        /// JSC runs promise reactions when the current script finishes, so a
        /// second evaluation is enough to let a settled promise deliver.
        func drainMicrotasks() { run(";"); run(";") }

        /// Every request that reached "the network".
        var wire: [[String: Any]] { array("__wire") }

        /// Every payload the engine posted to the SDK's capture channel.
        var captures: [[String: Any]] {
            array("__posted").compactMap { entry in
                guard let body = entry["body"] as? String,
                      let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json
            }
        }

        func wireHeaders(_ index: Int) -> [String: String] {
            guard wire.indices.contains(index) else { return [:] }
            return (wire[index]["headers"] as? [String: String]) ?? [:]
        }

        /// Sends a GET and reports whether the engine stopped it.
        func blocksARequest(to url: String) -> Bool {
            run("__wire.length=0;var __probe=new XMLHttpRequest();"
                + "__probe.open('GET','\(url)');__probe.send();")
            flushTimers()
            return wire.isEmpty
        }

        func strings(_ expression: String) -> [String] {
            (run(expression)?.toArray() as? [String]) ?? []
        }

        func string(_ expression: String) -> String? { run(expression)?.toString() }

        func number(_ expression: String) -> Int? {
            guard let value = run(expression), value.isNumber else { return nil }
            return Int(value.toInt32())
        }

        private func array(_ name: String) -> [[String: Any]] {
            (run(name)?.toArray() as? [[String: Any]]) ?? []
        }

        /// The browser this engine is written against, reduced to what it
        /// touches. The XHR follows the spec on the three points that decide
        /// these defects, each of them first checked against a real WKWebView:
        ///  * `setRequestHeader` COMBINES repeated values for one name,
        ///    case-insensitively (`Authorization: a, b`);
        ///  * `abort()` before `send()` fires nothing and changes no state;
        ///  * a request that never gets a response reads back as
        ///    `status 0`, `statusText ''`, `responseText ''`.
        private static let browserStub = """
        var window=this;
        window.window=window;
        var document={baseURI:'https://app.example.com/index.html'};
        var __wire=[],__posted=[],__timers=[];

        function setTimeout(fn,ms){__timers.push(fn);return __timers.length;}
        function __flushTimers(){var n=0;while(__timers.length&&n++<100){(__timers.shift())();}}

        window.webkit={messageHandlers:{}};
        function __registerChannel(name){
          window.webkit.messageHandlers[name]={postMessage:function(body){
            __posted.push({name:name,body:String(body)});}};}

        function Event(type){this.type=type;}
        function ProgressEvent(type){this.type=type;}
        /* Present in every browser that has `fetch`; the hook tests `init.headers
           instanceof Headers`, which would be a ReferenceError without it. */
        function Headers(){}

        /* Enough of `URL` for the matcher: absolute URLs, and relative ones
           resolved against document.baseURI. */
        function URL(input,base){
          var s=String(input);
          var m=/^([a-zA-Z][a-zA-Z0-9+.\\-]*:)\\/\\/([^\\/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?$/.exec(s);
          if(m){
            var authority=m[2],at=authority.lastIndexOf('@');
            if(at>=0)authority=authority.substring(at+1);
            this.protocol=m[1];this.host=authority;this.hostname=authority.split(':')[0];
            this.pathname=m[3]||'/';this.search=m[4]||'';this.hash=m[5]||'';
            return;}
          if(!base)throw new TypeError('Invalid URL: '+s);
          var b=new URL(base),path=s,hash='',query='';
          var hi=path.indexOf('#');if(hi>=0){hash=path.substring(hi);path=path.substring(0,hi);}
          var qi=path.indexOf('?');if(qi>=0){query=path.substring(qi);path=path.substring(0,qi);}
          if(path.charAt(0)!=='/')path=b.pathname.replace(/[^\\/]*$/,'')+path;
          this.protocol=b.protocol;this.host=b.host;this.hostname=b.hostname;
          this.pathname=path||'/';this.search=query;this.hash=hash;}
        Object.defineProperty(URL.prototype,'href',{get:function(){
          return this.protocol+'//'+this.host+this.pathname+this.search+this.hash;}});
        URL.prototype.toString=function(){return this.href;};

        function XMLHttpRequest(){
          this._listeners={};this._state=0;this._sendFlag=false;this._headers=[];
          this.status=0;this.statusText='';this.responseText='';this.responseURL='';
          this.onreadystatechange=null;this.onerror=null;this.onabort=null;
          this.onload=null;this.onloadend=null;this.onloadstart=null;}
        Object.defineProperty(XMLHttpRequest.prototype,'readyState',{
          configurable:true,get:function(){return this._state;}});
        XMLHttpRequest.prototype.addEventListener=function(type,fn){
          (this._listeners[type]=this._listeners[type]||[]).push(fn);};
        XMLHttpRequest.prototype.removeEventListener=function(type,fn){
          var l=this._listeners[type]||[],i=l.indexOf(fn);if(i>=0)l.splice(i,1);};
        XMLHttpRequest.prototype.dispatchEvent=function(evt){
          var type=evt&&evt.type,on=this['on'+type];
          if(typeof on==='function')on.call(this,evt);
          var l=(this._listeners[type]||[]).slice();
          for(var i=0;i<l.length;i++)l[i].call(this,evt);
          return true;};
        XMLHttpRequest.prototype._fire=function(type){
          this.dispatchEvent({type:type,target:this});};
        XMLHttpRequest.prototype.open=function(method,url,async){
          this._method=String(method);this._url=String(url);
          this._headers=[];this._sendFlag=false;this._state=1;this._fire('readystatechange');};
        XMLHttpRequest.prototype.setRequestHeader=function(name,value){
          if(this._state!==1||this._sendFlag)throw new Error('InvalidStateError: setRequestHeader');
          for(var i=0;i<this._headers.length;i++){
            if(this._headers[i][0].toLowerCase()===String(name).toLowerCase()){
              this._headers[i][1]=this._headers[i][1]+', '+value;return;}}
          this._headers.push([String(name),String(value)]);};
        XMLHttpRequest.prototype.getAllResponseHeaders=function(){
          return this._state===4?'content-type: text/plain':'';};
        XMLHttpRequest.prototype.send=function(body){
          if(this._state!==1||this._sendFlag)throw new Error('InvalidStateError: send');
          this._sendFlag=true;
          var headers={};
          for(var i=0;i<this._headers.length;i++)headers[this._headers[i][0]]=this._headers[i][1];
          __wire.push({method:this._method,url:this._url,headers:headers,
                       body:(body===undefined||body===null)?null:String(body)});
          var xhr=this;
          setTimeout(function(){
            xhr._state=4;xhr._sendFlag=false;xhr.status=200;xhr.statusText='OK';
            xhr.responseText='PAYLOAD';xhr.responseURL=xhr._url;
            xhr._fire('readystatechange');xhr._fire('load');xhr._fire('loadend');},0);};
        XMLHttpRequest.prototype.abort=function(){
          if(this._state===1&&this._sendFlag){
            this._state=4;this._sendFlag=false;this.status=0;
            this._fire('readystatechange');this._fire('abort');this._fire('loadend');
            this._state=0;}
          else if(this._state===4){this._state=0;}};

        window.fetch=function(input,init){
          init=init||{};
          var url=(input&&input.url)?input.url:String(input);
          __wire.push({method:init.method||'GET',url:url,headers:init.headers||{},
                       body:(init.body===undefined||init.body===null)?null:String(init.body)});
          return Promise.resolve({url:url,status:200,statusText:'OK',
            headers:{forEach:function(){}},
            clone:function(){return {text:function(){return Promise.resolve('PAYLOAD');}};}});};
        """
    }
}
