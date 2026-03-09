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

    /// Call once (e.g. from `SwiftyDebug.enable()`) to install all swizzles.
    /// Idempotent — always enabled.
    @objc static func enableIfNeeded() {
        guard !swizzled else { return }
        swizzled = true
        performSwizzling()
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

        // Call original init (swizzled)
        return replaced_init(frame: frame, configuration: configuration)
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
        var origOpen=XMLHttpRequest.prototype.open;
        var origSend=XMLHttpRequest.prototype.send;
        var origSetH=XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.open=function(method,url){
        this._cd={method:method,url:String(url),headers:{},startTime:Date.now()};
        return origOpen.apply(this,arguments);};
        XMLHttpRequest.prototype.setRequestHeader=function(k,v){
        if(this._cd)this._cd.headers[k]=v;
        return origSetH.apply(this,arguments);};
        XMLHttpRequest.prototype.send=function(body){
        if(this._cd){
        this._cd.body=(typeof body==='string')?trunc(body):null;
        var xhr=this;
        this.addEventListener('loadend',function(){
        var d=xhr._cd;if(!d)return;
        d.url=xhr.responseURL||d.url;
        d.status=xhr.status;
        d.statusText=xhr.statusText||'';
        d.responseHeaders=parseH(xhr.getAllResponseHeaders());
        d.endTime=Date.now();
        try{d.responseBody=trunc(xhr.responseText);}catch(e){d.responseBody=null;}
        d.type='xhr';post(d);});}
        return origSend.apply(this,arguments);};
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
        var startTime=Date.now();
        return origFetch.apply(this,arguments).then(function(response){
        var rh={};try{response.headers.forEach(function(v,k){rh[k]=v;});}catch(e){}
        var cloned=response.clone();
        cloned.text().then(function(text){
        post({type:'fetch',url:response.url||url,method:method.toUpperCase(),
        requestHeaders:headers,body:body,status:response.status,
        statusText:response.statusText||'',responseHeaders:rh,
        responseBody:trunc(text),startTime:startTime,endTime:Date.now()});}).catch(function(){});
        return response;}).catch(function(err){
        post({type:'fetch',url:url,method:method.toUpperCase(),
        requestHeaders:headers,body:body,status:0,
        statusText:err.message||'Network Error',responseHeaders:{},
        responseBody:null,startTime:startTime,endTime:Date.now()});
        throw err;});};
        }
        })();
        """
        let script = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
    }
}
