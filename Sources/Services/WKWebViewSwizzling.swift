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
        // Log to SwiftyDebug Logs tab (Web section)
        LogEntryBuilder.handleLog(
            file: "[WKWebView]",
            function: message.name,
            line: 0,
            message: "\(message.body)",
            color: .cyan,
            type: .none
        )

        // Forward to original handler
        if originalHandler.responds(to: #selector(WKScriptMessageHandler.userContentController(_:didReceive:))) {
            originalHandler.userContentController(userContentController, didReceive: message)
        }
    }
}

// MARK: - WKWebView Swizzling

@objc class WKWebViewSwizzling: NSObject {

    private static var swizzled = false
    private static var notificationObserver: NSObjectProtocol?

    /// Weak set of all live WKWebView instances so we can push rule updates.
    static let trackedWebViews = NSHashTable<WKWebView>.weakObjects()

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
        let json = InterceptRuleStore.shared.rulesAsJSONString()
        let js = "if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(json));"
        for webView in trackedWebViews.allObjects {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Swizzle setup

    private static func performSwizzling() {

        // 1. Swizzle WKWebView initWithFrame:configuration:
        if let original = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.init(frame:configuration:))),
           let replaced = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.replaced_init(frame:configuration:))) {
            method_exchangeImplementations(original, replaced)
        }

        // 2. Swizzle WKWebView dealloc
        let deallocSel = NSSelectorFromString("dealloc")
        let replacedDeallocSel = #selector(WKWebView.replaced_dealloc)
        if let originalDealloc = class_getInstanceMethod(WKWebView.self, deallocSel),
           let replacedDealloc = class_getInstanceMethod(WKWebView.self, replacedDeallocSel) {
            if !class_addMethod(WKWebView.self, deallocSel,
                                method_getImplementation(replacedDealloc),
                                method_getTypeEncoding(replacedDealloc)) {
                method_exchangeImplementations(originalDealloc, replacedDealloc)
            }
        }

        // 3. Add willDealloc method to WKWebView
        let willDeallocSel = NSSelectorFromString("willDealloc")
        let replacedWillDeallocSel = #selector(WKWebView.replaced_willDealloc)
        if let replacedWillDealloc = class_getInstanceMethod(WKWebView.self, replacedWillDeallocSel) {
            class_addMethod(WKWebView.self, willDeallocSel,
                            method_getImplementation(replacedWillDealloc),
                            method_getTypeEncoding(replacedWillDealloc))
        }

        // 4. Swizzle WKUserContentController addScriptMessageHandler:name:
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
        // Don't wrap SwiftyDebug's own handlers (WKWebView registers itself)
        if handler is WKWebViewScriptHandler || handler is WKScriptMessageProxy {
            replaced_add(handler, name: name) // calls original (swizzled)
            return
        }

        let proxy = WKScriptMessageProxy(originalHandler: handler)
        replaced_add(proxy, name: name) // calls original (swizzled)
    }
}

// MARK: - Dedicated script message handler

/// A dedicated WKScriptMessageHandler that WKWebView instances register
/// for SwiftyDebug's own message names (log, error, warn, debug, info, networkCapture).
@objc class WKWebViewScriptHandler: NSObject, WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "networkCapture" {
            handleNetworkCaptureMessage(message)
            return
        }

        LogEntryBuilder.handleLog(
            file: "[WKWebView]",
            function: message.name,
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

        let handler = WKWebViewScriptHandler()

        injectConsoleHook(configuration: configuration, handler: handler, name: "log", consoleFn: "log")
        injectConsoleHook(configuration: configuration, handler: handler, name: "error", consoleFn: "error")
        injectConsoleHook(configuration: configuration, handler: handler, name: "warn", consoleFn: "warn")
        injectConsoleHook(configuration: configuration, handler: handler, name: "debug", consoleFn: "debug")
        injectConsoleHook(configuration: configuration, handler: handler, name: "info", consoleFn: "info")
        injectNetworkCapture(configuration: configuration, handler: handler)

        // Inject current intercept rules so they're available immediately on first page load.
        let rulesJSON = InterceptRuleStore.shared.rulesAsJSONString()
        let rulesScript = WKUserScript(
            source: "if(window.__cd_updateInterceptRules)window.__cd_updateInterceptRules(\(rulesJSON));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(rulesScript)

        // Call original init (swizzled)
        let webView = replaced_init(frame: frame, configuration: configuration)
        WKWebViewSwizzling.trackedWebViews.add(webView)
        return webView
    }

    // MARK: - Swizzled dealloc

    @objc func replaced_dealloc() {
        
    }

    // MARK: - willDealloc (added dynamically)

    @objc func replaced_willDealloc() -> Bool {
        configuration.userContentController.removeScriptMessageHandler(forName: "log")
        configuration.userContentController.removeScriptMessageHandler(forName: "error")
        configuration.userContentController.removeScriptMessageHandler(forName: "warn")
        configuration.userContentController.removeScriptMessageHandler(forName: "debug")
        configuration.userContentController.removeScriptMessageHandler(forName: "info")
        configuration.userContentController.removeScriptMessageHandler(forName: "networkCapture")
        return true
    }

    // MARK: - Console hook injection

    private func injectConsoleHook(
        configuration: WKWebViewConfiguration,
        handler: WKScriptMessageHandler,
        name: String,
        consoleFn: String
    ) {
        configuration.userContentController.removeScriptMessageHandler(forName: name)
        configuration.userContentController.add(handler, name: name)

        // Rewrite the console method to post to native and still call original
        let jsCode = """
        console.\(consoleFn) = (function(oriLogFunc){\
        return function(str){\
        window.webkit.messageHandlers.\(name).postMessage(str);\
        oriLogFunc.call(console,str);\
        }\
        })(console.\(consoleFn));
        """
        let script = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
    }

    // MARK: - Network Capture injection (XMLHttpRequest + fetch)

    private func injectNetworkCapture(
        configuration: WKWebViewConfiguration,
        handler: WKScriptMessageHandler
    ) {
        configuration.userContentController.removeScriptMessageHandler(forName: "networkCapture")
        configuration.userContentController.add(handler, name: "networkCapture")

        // swiftlint:disable line_length
        let jsCode = """
        (function(){
        if(window.__cd_net_hooked)return;
        window.__cd_net_hooked=true;
        var MAX_BODY=524288;
        function trunc(s){if(typeof s==='string'&&s.length>MAX_BODY)return s.substring(0,MAX_BODY);return s;}
        function post(d){try{window.webkit.messageHandlers.networkCapture.postMessage(JSON.stringify(d));}catch(e){}}
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

        function resolveRules(urlStr){
        var rules=window.__cd_intercept_rules;if(!rules||!rules.length)return null;
        var path=getPath(urlStr);var norm=normalizePath(path);var stripped=stripForHost(urlStr);
        var matched=[];
        for(var i=0;i<rules.length;i++){var r=rules[i];
        if(r.matchMode==='exact'&&r.matchEndpoint===path){matched.push(r);}
        else if(r.matchMode==='normalized'&&r.matchEndpoint===norm){matched.push(r);}
        else if(r.matchMode==='host'&&r.matchHosts){
        for(var j=0;j<r.matchHosts.length;j++){if(hostMatch(stripped,r.matchHosts[j])){matched.push(r);break;}}}}
        if(!matched.length)return null;
        matched.sort(function(a,b){return(a.order||0)-(b.order||0);});
        var c={isBlocked:false,headerOverrides:[],removedHeaderKeys:[],queryParamOverrides:[],removedQueryParamKeys:[]};
        for(var i=0;i<matched.length;i++){var r=matched[i];
        if(r.isBlocked)c.isBlocked=true;
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

        function resolveUrl(u){try{return new URL(u,document.baseURI).href;}catch(e){return u;}}

        /* ── XHR hooks ── */
        var origOpen=XMLHttpRequest.prototype.open;
        var origSend=XMLHttpRequest.prototype.send;
        var origSetH=XMLHttpRequest.prototype.setRequestHeader;

        XMLHttpRequest.prototype.open=function(method,url){
        var urlStr=String(url);
        var fullUrl=resolveUrl(urlStr);
        var rule=resolveRules(fullUrl);
        this._cd={method:method,url:fullUrl,headers:{},startTime:Date.now(),rule:rule};
        if(rule){var effectiveUrl=applyQueryParams(fullUrl,rule);this._cd.url=effectiveUrl;
        var args=Array.prototype.slice.call(arguments);args[1]=effectiveUrl;
        return origOpen.apply(this,args);}
        return origOpen.apply(this,arguments);};

        XMLHttpRequest.prototype.setRequestHeader=function(k,v){
        if(this._cd){
        if(this._cd.rule){for(var i=0;i<this._cd.rule.removedHeaderKeys.length;i++){
        if(this._cd.rule.removedHeaderKeys[i].toLowerCase()===k.toLowerCase()){this._cd.headers[k]=v;return;}}}
        this._cd.headers[k]=v;}
        return origSetH.apply(this,arguments);};

        XMLHttpRequest.prototype.send=function(body){
        if(this._cd){
        var rule=this._cd.rule;
        if(rule){
        if(rule.isBlocked){var d=this._cd;d.body=(typeof body==='string')?trunc(body):null;
        d.requestHeaders=d.headers;d.status=0;d.statusText='Blocked by SwiftyDebug';d.responseHeaders={};d.responseBody=null;
        d.endTime=Date.now();d.type='xhr';d.intercepted=true;post(d);this.abort();return;}
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
        window.fetch=function(input,init){
        var url,method,headers={},body=null;
        if(typeof input==='string'){url=input;}
        else if(input instanceof Request){url=input.url;method=input.method;
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
        var rule=resolveRules(fullUrl);
        var intercepted=false;
        if(rule){
        if(rule.isBlocked){var startTime=Date.now();
        post({type:'fetch',url:fullUrl,method:method.toUpperCase(),requestHeaders:headers,body:body,
        status:0,statusText:'Blocked by SwiftyDebug',responseHeaders:{},responseBody:null,
        startTime:startTime,endTime:Date.now(),intercepted:true});
        return Promise.reject(new Error('Blocked by SwiftyDebug intercept rule'));}
        fullUrl=applyQueryParams(fullUrl,rule);
        for(var i=0;i<rule.removedHeaderKeys.length;i++){var rk=rule.removedHeaderKeys[i];
        var hks=Object.keys(headers);for(var j=0;j<hks.length;j++){if(hks[j].toLowerCase()===rk.toLowerCase())delete headers[hks[j]];}}
        for(var i=0;i<rule.headerOverrides.length;i++){headers[rule.headerOverrides[i].key]=rule.headerOverrides[i].value;}
        input=fullUrl;init=Object.assign({},init||{});init.method=method;init.headers=headers;
        if(body!==null&&init.body===undefined)init.body=body;
        intercepted=true;url=fullUrl;}
        var startTime=Date.now();
        return origFetch.call(this,input,init).then(function(response){
        var rh={};try{response.headers.forEach(function(v,k){rh[k]=v;});}catch(e){}
        var cloned=response.clone();
        cloned.text().then(function(text){
        post({type:'fetch',url:response.url||url,method:method.toUpperCase(),
        requestHeaders:headers,body:body,status:response.status,
        statusText:response.statusText||'',responseHeaders:rh,
        responseBody:trunc(text),startTime:startTime,endTime:Date.now(),intercepted:intercepted});}).catch(function(){});
        return response;}).catch(function(err){
        post({type:'fetch',url:url,method:method.toUpperCase(),
        requestHeaders:headers,body:body,status:0,
        statusText:err.message||'Network Error',responseHeaders:{},
        responseBody:null,startTime:startTime,endTime:Date.now(),intercepted:intercepted});
        throw err;});};
        }
        })();
        """
        // swiftlint:enable line_length
        let script = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
    }
}
