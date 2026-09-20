//
//  RulesWebviewAuditFixTests.swift
//  SwiftyDebugTests
//
//  Six defects that all share one theme: the SDK knew the right answer in one
//  place and used a different one somewhere else.
//
//   1. TOGGLING A RULE REORDERED ITS SIBLINGS. `addOrUpdate` removes the rule
//      and puts it straight back, and the removal re-packed every surviving
//      rule's `order` to 0..n-1 while the incoming rule came back with the
//      number the caller had cached. Flipping an enable switch therefore moved
//      rules the user never touched — and rule order is what decides whose
//      header override reaches the wire.
//
//   2. WEB-VIEW RULE PRECEDENCE WAS RANDOM PER LAUNCH. The rules handed to the
//      injected engine came out of `rules.values`, whose enumeration order is
//      seeded per process, and the engine's own sort compares `order` alone and
//      is stable. Two rules sharing an `order` — the normal case, since each
//      bucket starts at 0 — therefore composed differently on every launch.
//
//   3. THE WEB VIEW'S User-Agent WINNER WAS PICKED BY CREATION DATE. The native
//      UA override iterated `allRules()` (sorted by `createdAt`) and let the
//      last writer win, so dragging rules in the list changed the native
//      request's UA and did nothing to the web view's.
//
//   4. A FULL STOP NEVER GAVE THE User-Agent BACK. Every writer of
//      `customUserAgent` is gated on `SwiftyDebugRuntime.isActive`, so the
//      moment the gate closed the host app was stuck with a debugger's UA until
//      it was killed. The revert has to be ungated to exist at all.
//
//   5. A WEB VIEW CREATED WHILE STOPPED STAYED UNINSTRUMENTED FOREVER. Resume
//      skipped any controller that was not already instrumented — which is
//      exactly the ones that needed it.
//
//   6. THE INJECTED ENGINE LOGGED ONE ROW PER LISTENER, NOT PER REQUEST, and
//      threw away every request body that was not a JS string.
//
//  The JavaScript half runs the SHIPPED script — `WebViewInjectedScript
//  .networkCapture` in full — inside a JSContext against a browser stub, because
//  none of these are visible to a test that only greps the source string.
//

import XCTest
import WebKit
import JavaScriptCore
@testable import SwiftyDebug

final class RulesWebviewAuditFixTests: XCTestCase {

    private let cartURL = URL(string: "https://api.example.com/cart")!

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        SwiftyDebugRuntime.markActive()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeGlobalRule(named name: String, env: String?) -> InterceptRule {
        var rule = InterceptRule.globalRule()
        rule.name = name
        rule.isEnabled = true
        if let env { rule.headerOverrides = [KVPair(key: "X-Env", value: env)] }
        return rule
    }

    private func storedRule(named name: String) throws -> InterceptRule {
        try XCTUnwrap(InterceptRuleStore.shared.allRules().first { $0.name == name })
    }

    private func makeEndpointRule(named name: String, env: String) -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: "/v1/products", matchMode: .normalized)
        rule.name = name
        rule.isEnabled = true
        rule.headerOverrides = [KVPair(key: "X-Env", value: env)]
        return rule
    }

    private func resolvedEnvHeader() -> String? {
        InterceptRuleStore.shared.resolvedRule(forURL: cartURL)?
            .headerOverrides.first { $0.key == "X-Env" }?.value
    }

    // MARK: - 1. An edit must not move the rules around it

    /// The reported case: three rules the user dragged into an order, then one
    /// enable switch flipped off and back on.
    func testTogglingARuleLeavesEveryOtherRuleWhereTheUserPutIt() throws {
        for rule in [makeGlobalRule(named: "A", env: "a"),
                     makeGlobalRule(named: "B", env: "b"),
                     makeGlobalRule(named: "C", env: nil)] {
            InterceptRuleStore.shared.addOrUpdate(rule)
        }

        // The drag: C, B, A — so A is last and its header is the one that wins.
        let ids = try ["C", "B", "A"].map { try storedRule(named: $0).id }
        InterceptRuleStore.shared.reorder(ids: ids, for: "global")
        XCTAssertEqual(resolvedEnvHeader(), "a", "Precondition: the last rule in the list wins.")

        var toggled = try storedRule(named: "B")
        toggled.isEnabled = false
        InterceptRuleStore.shared.update(toggled)
        toggled.isEnabled = true
        InterceptRuleStore.shared.update(toggled)

        XCTAssertEqual(InterceptRuleStore.shared.matchingRules(forURL: cartURL).map { $0.name },
                       ["C", "B", "A"],
                       "An enable-switch toggle re-packed the other rules' order and moved them.")
        XCTAssertEqual(resolvedEnvHeader(), "a",
                       "Flipping a switch changed which rule's header reaches the wire: the user "
                       + "changed nothing but an on/off toggle.")
    }

    /// The same guarantee for an ordinary in-place edit, which takes the same
    /// remove-and-re-insert path.
    func testEditingARulesHeaderDoesNotReorderItsSiblings() throws {
        for rule in [makeGlobalRule(named: "A", env: "a"),
                     makeGlobalRule(named: "B", env: "b"),
                     makeGlobalRule(named: "C", env: "c")] {
            InterceptRuleStore.shared.addOrUpdate(rule)
        }
        let ids = try ["B", "C", "A"].map { try storedRule(named: $0).id }
        InterceptRuleStore.shared.reorder(ids: ids, for: "global")

        var edited = try storedRule(named: "C")
        edited.headerOverrides = [KVPair(key: "X-Env", value: "c2")]
        InterceptRuleStore.shared.update(edited)

        XCTAssertEqual(InterceptRuleStore.shared.matchingRules(forURL: cartURL).map { $0.name },
                       ["B", "C", "A"])
        XCTAssertEqual(resolvedEnvHeader(), "a")
    }

    /// `remove(id:)` still re-packs — this pins that the flag did not change the
    /// deletion path, which has no incoming rule to put back.
    func testDeletingARuleStillClosesTheGapItLeaves() throws {
        for rule in [makeGlobalRule(named: "A", env: "a"),
                     makeGlobalRule(named: "B", env: "b"),
                     makeGlobalRule(named: "C", env: "c")] {
            InterceptRuleStore.shared.addOrUpdate(rule)
        }
        InterceptRuleStore.shared.remove(id: try storedRule(named: "A").id)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().sorted(by: InterceptRuleStore.precedes)
                        .map { $0.order }, [0, 1])
    }

    // MARK: - 2. The web engine gets the rules in the order it will apply them

    func testTheWebViewRuleSnapshotIsEmittedInTheStoresOwnOrder() throws {
        // A global rule and an endpoint rule land in different buckets, so both
        // start at order 0 — the tie the dictionary's enumeration used to break,
        // differently on every launch. `precedes` breaks it by creation date,
        // and the global rule here is the older one.
        InterceptRuleStore.shared.addOrUpdate(makeGlobalRule(named: "Global", env: "staging"))
        InterceptRuleStore.shared.addOrUpdate(makeEndpointRule(named: "Endpoint", env: "prod"))

        XCTAssertEqual(try emittedRuleNames(), ["Global", "Endpoint"],
                       "The rules handed to the injected engine came out in dictionary order, so a "
                       + "web view composed two equal-`order` rules in a sequence that changed on "
                       + "every launch and disagreed with the native path.")
    }

    /// And when the orders differ, the snapshot is the sequence the native path
    /// resolves in — the injected engine sorts by `order` alone and stably, so
    /// what it is handed is what it applies.
    func testTheWebViewRuleSnapshotMatchesNativeResolutionOrder() throws {
        InterceptRuleStore.shared.addOrUpdate(makeGlobalRule(named: "Global", env: "staging"))
        InterceptRuleStore.shared.addOrUpdate(makeEndpointRule(named: "Endpoint", env: "prod"))

        // The user drags the global rule last, so it is the one that wins.
        var global = try storedRule(named: "Global")
        global.order = 5
        InterceptRuleStore.shared.update(global)

        let productsURL = URL(string: "https://api.example.com/v1/products")!
        XCTAssertEqual(InterceptRuleStore.shared.matchingRules(forURL: productsURL).map { $0.name },
                       ["Endpoint", "Global"], "Precondition: the order the native path resolves in.")
        XCTAssertEqual(try emittedRuleNames(), ["Endpoint", "Global"])
    }

    private func emittedRuleNames() throws -> [String] {
        let json = InterceptRuleStore.shared.rulesAsJSONString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return array.compactMap { $0["name"] as? String }
    }

    // MARK: - 3 & 4. The native User-Agent override

    func testTheWebViewUserAgentFollowsRuleOrderNotCreationDate() throws {
        var first = InterceptRule.globalRule()
        first.name = "A"
        first.isEnabled = true
        first.headerOverrides = [KVPair(key: "User-Agent", value: "BotA")]
        InterceptRuleStore.shared.addOrUpdate(first)

        var second = InterceptRule.globalRule()
        second.name = "B"
        second.isEnabled = true
        second.headerOverrides = [KVPair(key: "User-Agent", value: "BotB")]
        InterceptRuleStore.shared.addOrUpdate(second)

        // Dragged so that A sits last and therefore wins, exactly as
        // `resolvedRule(forURL:)` resolves it on the native path.
        let ids = try ["B", "A"].map { try storedRule(named: $0).id }
        InterceptRuleStore.shared.reorder(ids: ids, for: "global")

        let webView = WKWebView(frame: .zero)
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)

        XCTAssertEqual(webView.customUserAgent, "BotA",
                       "The web view's User-Agent was picked by creation date, so reordering the "
                       + "rules had no effect on it at all.")
    }

    func testAFullStopGivesTheUserAgentBackToTheHostApp() throws {
        var rule = InterceptRule.globalRule()
        rule.name = "UA"
        rule.isEnabled = true
        rule.headerOverrides = [KVPair(key: "User-Agent", value: "DebugBot/1.0")]
        InterceptRuleStore.shared.addOrUpdate(rule)

        let webView = WKWebView(frame: .zero)
        WKWebViewSwizzling.trackedWebViews.add(webView)
        WKWebViewSwizzling.applyNativeForbiddenHeaders(to: webView)
        XCTAssertEqual(webView.customUserAgent, "DebugBot/1.0", "Precondition: the override applied.")

        // The gate closes FIRST, the way `fullStop()` does it: every other
        // writer of `customUserAgent` is inert from here on.
        SwiftyDebugRuntime.markStopped()
        WKWebViewSwizzling.revertNativeForbiddenHeaders()

        XCTAssertTrue(webView.customUserAgent?.isEmpty ?? true,
                      "A stopped SDK left the host app running with a debugger's User-Agent: "
                      + "\(webView.customUserAgent ?? "nil")")
        XCTAssertFalse(WKWebViewSwizzling.isUserAgentOwnedBySDK(webView))
    }

    /// The revert must give back only what the SDK wrote.
    func testTheRevertLeavesAnAppSetUserAgentAlone() {
        let webView = WKWebView(frame: .zero)
        webView.customUserAgent = "HostApp/9.9"
        WKWebViewSwizzling.trackedWebViews.add(webView)

        SwiftyDebugRuntime.markStopped()
        WKWebViewSwizzling.revertNativeForbiddenHeaders()

        XCTAssertEqual(webView.customUserAgent, "HostApp/9.9",
                       "The revert cleared a User-Agent the SDK never set.")
    }

    // MARK: - 5. A web view created while the SDK was stopped

    func testInstrumentingAControllerTwiceInstallsOneCopyOfEachScript() {
        let controller = WKUserContentController()
        XCTAssertFalse(controller.isSwiftyDebugInstrumented)

        WKWebViewSwizzling.instrumentIfNeeded(controller)
        let installed = controller.userScripts.count
        XCTAssertTrue(controller.isSwiftyDebugInstrumented)
        XCTAssertGreaterThan(installed, 0, "the engine was never injected")

        WKWebViewSwizzling.instrumentIfNeeded(controller)
        XCTAssertEqual(controller.userScripts.count, installed,
                       "a shared configuration would accumulate another copy of every script")
    }

    func testResumeInstrumentsAWebViewThatWasCreatedWhileStopped() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)

        // The state a web view created during a full stop is left in: tracked,
        // so resume can find it, but with nothing injected into it.
        controller.removeAllUserScripts()
        controller.isSwiftyDebugInstrumented = false
        WKWebViewSwizzling.trackedWebViews.add(webView)

        WKWebViewSwizzling.pushEnabledStateToWebViews(enabled: true)

        XCTAssertTrue(controller.isSwiftyDebugInstrumented,
                      "Resume skipped exactly the controllers that needed instrumenting, so a web "
                      + "view created during a full stop captured nothing for the rest of its life.")
        XCTAssertFalse(controller.userScripts.isEmpty)
    }

    // MARK: - 6. The injected engine

    /// The reported case: one XMLHttpRequest reused for polling.
    func testAReusedXHRIsLoggedOncePerRequest() throws {
        let document = try Document()
        document.run("var x=new XMLHttpRequest();")

        for _ in 0..<3 {
            document.run("x.open('GET','https://api.example.com/poll');x.send();")
            document.flushTimers()
        }

        XCTAssertEqual(document.captures.count, 3,
                       "Every send() added another 'loadend' listener and every listener posted "
                       + "the current request again, so a polling page flooded the Network tab "
                       + "with duplicates of the same request.")
    }

    func testAnXHRURLSearchParamsBodyIsCaptured() throws {
        let document = try Document()
        document.run("var x=new XMLHttpRequest();x.open('POST','https://api.example.com/login');"
                     + "x.send(new URLSearchParams({user:'a',pass:'b'}));")
        document.flushTimers()

        XCTAssertEqual(document.captures.first?["body"] as? String, "user=a&pass=b",
                       "A form POST showed an empty request body because the capture only kept "
                       + "bodies that were JS strings.")
    }

    func testAnXHRFormDataBodyIsSummarised() throws {
        let document = try Document()
        document.run("var f=new FormData();f.append('user','a');f.append('avatar',{name:'me.png'});"
                     + "var x=new XMLHttpRequest();x.open('POST','https://api.example.com/upload');x.send(f);")
        document.flushTimers()

        XCTAssertEqual(document.captures.first?["body"] as? String, "user=a&avatar=[file me.png]")
    }

    func testAFetchURLSearchParamsBodyIsCaptured() throws {
        let document = try Document()
        document.run("fetch('https://api.example.com/login',"
                     + "{method:'POST',body:new URLSearchParams({user:'a'})});")
        document.drainMicrotasks()

        XCTAssertEqual(document.captures.first?["body"] as? String, "user=a")
    }

    /// A `Request` carries its body on the object, not in `init`, so this path
    /// logged `null` for every body there was.
    func testAFetchRequestObjectBodyIsCaptured() throws {
        let document = try Document()
        document.run("""
        fetch(new Request('https://api.example.com/api',
          {method:'POST',headers:{'Content-Type':'application/json'},body:'{"a":1}'}));
        """)
        document.drainMicrotasks()

        XCTAssertEqual(document.captures.first?["body"] as? String, "{\"a\":1}",
                       "fetch(new Request(…)) logged no body at all, however it was sent.")
    }

    /// Reading the body must not consume the caller's Request: the request still
    /// has to reach the network with its body intact.
    func testReadingARequestObjectsBodyDoesNotDisturbTheCall() throws {
        let document = try Document()
        document.run("""
        fetch(new Request('https://api.example.com/api',
          {method:'POST',headers:{'Content-Type':'application/json'},body:'{"a":1}'}));
        """)
        document.drainMicrotasks()

        XCTAssertEqual(document.wire.count, 1)
        XCTAssertEqual(document.wire.first?["body"] as? String, "{\"a\":1}")
    }

    // MARK: - 7. Three screens

    /// "Select None" is a deliberate state, and the screen re-appears every time
    /// the user visits the paste sheet, the import preview or the file picker.
    func testSelectNoneSurvivesTheScreenReappearing() throws {
        InterceptRuleStore.shared.addOrUpdate(makeGlobalRule(named: "A", env: "a"))
        InterceptRuleStore.shared.addOrUpdate(makeGlobalRule(named: "B", env: "b"))

        let transfer = RuleTransferViewController()
        transfer.loadViewIfNeeded()
        transfer.viewWillAppear(false)
        XCTAssertEqual(exportRowTitle(of: transfer), "Export 2 Rules…",
                       "Precondition: everything is selected on first load.")

        transfer.perform(NSSelectorFromString("toggleSelectAll"))
        XCTAssertEqual(exportRowTitle(of: transfer), "Export…")

        // Back from "Paste JSON…" with nothing pasted.
        transfer.viewWillAppear(false)

        XCTAssertEqual(exportRowTitle(of: transfer), "Export…",
                       "Returning to the screen re-checked every row, so Export shared all the "
                       + "rules instead of the subset the user was building.")
    }

    private func exportRowTitle(of transfer: RuleTransferViewController) -> String? {
        let cell = transfer.tableView(transfer.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        return cell.textLabel?.text
    }

    /// The DESTINATION field promised an example of what to type and drew
    /// nothing at all: the helper only ever set an accessibility hint.
    func testTheRedirectDestinationShowsItsHintWhileEmpty() {
        let editor = RedirectEditorViewController(
            mode: .host, target: "",
            sampleURL: URL(string: "https://api.example.com/v1/products"))
        editor.loadViewIfNeeded()

        XCTAssertTrue(editor.visibleHintTexts.contains("beta.api.example.com"),
                      "The destination field drew no hint, so the card was an empty box with no "
                      + "example of what to type.")
    }

    /// …and it must not sit on top of what the user typed.
    func testTheRedirectDestinationHidesItsHintOnceThereIsText() {
        let editor = RedirectEditorViewController(
            mode: .host, target: "beta.api.example.com",
            sampleURL: URL(string: "https://api.example.com/v1/products"))
        editor.loadViewIfNeeded()

        XCTAssertFalse(editor.visibleHintTexts.contains("beta.api.example.com"),
                       "the hint was drawn over the user's own text")
    }

    /// The value text view does not scroll, so without an inset the tail of a
    /// long value — and the delete button — are simply unreachable while the
    /// keyboard is up.
    func testTheStorageValueEditorInsetsItselfForTheKeyboard() throws {
        let editor = StorageValueEditorViewController(key: "session", value: "{}")
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        let scroll = try XCTUnwrap(editor.view.allSubviewsForTesting.compactMap { $0 as? UIScrollView }.first)
        let keyboardTop: CGFloat = 500
        postKeyboardFrame(CGRect(x: 0, y: keyboardTop, width: 390, height: 344),
                          name: UIResponder.keyboardWillChangeFrameNotification)

        XCTAssertEqual(scroll.contentInset.bottom, scroll.frame.maxY - keyboardTop, accuracy: 0.5,
                       "Nothing inset the scroller, so the region under the keyboard could not be "
                       + "scrolled to at all.")
        XCTAssertEqual(scroll.verticalScrollIndicatorInsets.bottom,
                       scroll.contentInset.bottom, accuracy: 0.5)

        postKeyboardFrame(CGRect(x: 0, y: 844, width: 390, height: 344),
                          name: UIResponder.keyboardWillHideNotification)
        XCTAssertEqual(scroll.contentInset.bottom, 0, accuracy: 0.5,
                       "the inset outlived the keyboard")
    }

    private func postKeyboardFrame(_ frame: CGRect, name: Notification.Name) {
        NotificationCenter.default.post(
            name: name, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
    }

    // MARK: - One document

    /// A single web-view document running the shipped engine, with the SDK's
    /// capture channel registered (the engine refuses to do anything without
    /// it — that is the kill-switch).
    private final class Document {

        let context: JSContext

        init() throws {
            context = try XCTUnwrap(JSContext())
            context.exceptionHandler = { _, exception in
                XCTFail("uncaught JavaScript exception: \(exception?.toString() ?? "?")")
            }
            context.evaluateScript(Document.browserStub)
            context.evaluateScript("__registerChannel('\(WebViewMessageChannel.networkCapture)');"
                + "__registerChannel('\(WebViewMessageChannel.rulesRequest)');")
            context.evaluateScript(WebViewInjectedScript.networkCapture)
            XCTAssertTrue(context.evaluateScript("window.__cd_net_hooked===true").toBool(),
                          "the injected engine did not install itself")
        }

        @discardableResult
        func run(_ js: String) -> JSValue? { context.evaluateScript(js) }

        func flushTimers() { run("__flushTimers();") }

        /// JSC runs promise reactions when the current script finishes, so an
        /// empty evaluation per link in the chain is enough to settle them.
        func drainMicrotasks() { for _ in 0..<8 { run(";") } }

        var wire: [[String: Any]] { array("__wire") }

        var captures: [[String: Any]] {
            array("__posted").compactMap { entry in
                guard let body = entry["body"] as? String,
                      let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json
            }
        }

        private func array(_ name: String) -> [[String: Any]] {
            (run(name)?.toArray() as? [[String: Any]]) ?? []
        }

        /// The browser this engine is written against, reduced to what it
        /// touches — plus the body types the capture used to throw away:
        /// `URLSearchParams`, `FormData` and a `Request` that owns its body and
        /// can only be read through a clone.
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

        function Headers(init){this._h={};
          if(init)for(var k in init)if(init.hasOwnProperty(k))this._h[k.toLowerCase()]=String(init[k]);}
        Headers.prototype.get=function(name){
          var v=this._h[String(name).toLowerCase()];return v===undefined?null:v;};
        Headers.prototype.forEach=function(fn){
          for(var k in this._h)if(this._h.hasOwnProperty(k))fn(this._h[k],k);};

        function URLSearchParams(init){this._p=[];
          if(init)for(var k in init)if(init.hasOwnProperty(k))this._p.push([k,String(init[k])]);}
        URLSearchParams.prototype.toString=function(){
          var out=[];for(var i=0;i<this._p.length;i++)out.push(this._p[i][0]+'='+this._p[i][1]);
          return out.join('&');};

        function FormData(){this._p=[];}
        FormData.prototype.append=function(k,v){this._p.push([k,v]);};
        FormData.prototype.forEach=function(fn){
          for(var i=0;i<this._p.length;i++)fn(this._p[i][1],this._p[i][0]);};

        function Blob(parts){this.size=0;
          if(parts)for(var i=0;i<parts.length;i++)this.size+=String(parts[i]).length;}

        /* A Request owns its body: the only legal way to read it is a clone,
           and reading the original would break the call the page is making. */
        function Request(input,init){
          init=init||{};
          this.url=(input&&input.url)?input.url:String(input);
          this.method=init.method||(input&&input.method)||'GET';
          this.headers=new Headers(init.headers);
          this._body=(init.body===undefined)?null:init.body;
          this.bodyUsed=false;}
        Request.prototype.clone=function(){
          if(this.bodyUsed)throw new TypeError('body already used');
          var r=new Request(this.url,{method:this.method,body:this._body});
          r.headers=this.headers;return r;};
        Request.prototype.text=function(){
          this.bodyUsed=true;return Promise.resolve(this._body===null?'':String(this._body));};
        Request.prototype.arrayBuffer=function(){
          this.bodyUsed=true;return Promise.resolve({byteLength:String(this._body||'').length});};

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
          this.status=0;this.statusText='';this.responseText='';this.responseURL='';}
        Object.defineProperty(XMLHttpRequest.prototype,'readyState',{
          configurable:true,get:function(){return this._state;}});
        XMLHttpRequest.prototype.addEventListener=function(type,fn){
          (this._listeners[type]=this._listeners[type]||[]).push(fn);};
        XMLHttpRequest.prototype.dispatchEvent=function(evt){
          var type=evt&&evt.type,on=this['on'+type];
          if(typeof on==='function')on.call(this,evt);
          var l=(this._listeners[type]||[]).slice();
          for(var i=0;i<l.length;i++)l[i].call(this,evt);
          return true;};
        XMLHttpRequest.prototype._fire=function(type){
          this.dispatchEvent({type:type,target:this});};
        XMLHttpRequest.prototype.open=function(method,url){
          this._method=String(method);this._url=String(url);
          this._headers=[];this._sendFlag=false;this._state=1;this._fire('readystatechange');};
        XMLHttpRequest.prototype.setRequestHeader=function(name,value){
          for(var i=0;i<this._headers.length;i++){
            if(this._headers[i][0].toLowerCase()===String(name).toLowerCase()){
              this._headers[i][1]=this._headers[i][1]+', '+value;return;}}
          this._headers.push([String(name),String(value)]);};
        XMLHttpRequest.prototype.getAllResponseHeaders=function(){
          return this._state===4?'content-type: text/plain':'';};
        XMLHttpRequest.prototype.send=function(body){
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

        window.fetch=function(input,init){
          init=init||{};
          var isRequest=(input&&input.url!==undefined);
          var url=isRequest?input.url:String(input);
          var body=(init.body!==undefined&&init.body!==null)?init.body
                   :(isRequest?input._body:null);
          __wire.push({method:init.method||(isRequest?input.method:'GET'),url:url,
                       headers:init.headers||{},
                       body:(body===undefined||body===null)?null:String(body)});
          return Promise.resolve({url:url,status:200,statusText:'OK',
            headers:{forEach:function(){}},
            clone:function(){return {text:function(){return Promise.resolve('PAYLOAD');}};}});};
        """
    }
}

private extension UIViewController {
    /// The text drawn inside the screen's text views by something other than the
    /// text view itself — i.e. the placeholder labels.
    var visibleHintTexts: [String] {
        view.allSubviewsForTesting
            .compactMap { $0 as? UILabel }
            .filter { !$0.isHidden && $0.superview is UITextView }
            .compactMap { $0.text }
    }
}

// MARK: - View tree

private extension UIView {
    /// Every view under this one, so a test can reach a private subview without
    /// widening the screen's own API for it.
    var allSubviewsForTesting: [UIView] {
        subviews + subviews.flatMap { $0.allSubviewsForTesting }
    }
}
