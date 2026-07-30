//
//  WebViewStorageService.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import WebKit

/// Reads and edits a WKWebView's web storage: `localStorage`, `sessionStorage`
/// (via injected JS — both are synchronous, fully editable web APIs) and cookies
/// (via `WKHTTPCookieStore`). Powers the Storage editor. (See Phase 2 webview.)
///
/// All calls hop to the main thread (WKWebView is main-thread-only) and return on
/// the main thread.
final class WebViewStorageService {

    enum Scope: Int, CaseIterable {
        case local = 0
        case session = 1
        case cookies = 2

        var title: String {
            switch self {
            case .local:   return "Local Storage"
            case .session: return "Session Storage"
            case .cookies: return "Cookies"
            }
        }

        /// JS global name for the two web storages.
        var jsObject: String? {
            switch self {
            case .local:   return "localStorage"
            case .session: return "sessionStorage"
            case .cookies: return nil
            }
        }
    }

    /// One editable storage entry.
    struct Item {
        var key: String
        var value: String
        /// Cookie-only metadata (domain/path), nil for web storage.
        var cookie: HTTPCookie?
    }

    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The page the target web view is currently showing (for display).
    var pageURL: URL? { webView?.url }

    // MARK: - Read

    func loadItems(scope: Scope, completion: @escaping ([Item]) -> Void) {
        switch scope {
        case .local, .session:
            loadWebStorage(scope: scope, completion: completion)
        case .cookies:
            loadCookies(completion: completion)
        }
    }

    private func loadWebStorage(scope: Scope, completion: @escaping ([Item]) -> Void) {
        guard let webView, let obj = scope.jsObject else { DispatchQueue.main.async { completion([]) }; return }
        // Serialize the whole store to a JSON object of key -> value.
        let js = """
        (function(){try{var o=Object.create(null);for(var i=0;i<\(obj).length;i++){var k=\(obj).key(i);o[k]=\(obj).getItem(k);}return JSON.stringify(o);}catch(e){return '{}';}})();
        """
        runOnMain {
            webView.evaluateJavaScript(js) { result, _ in
                var items: [Item] = []
                if let jsonString = result as? String,
                   let data = jsonString.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in dict {
                        items.append(Item(key: k, value: "\(v)", cookie: nil))
                    }
                }
                items.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                DispatchQueue.main.async { completion(items) }
            }
        }
    }

    private func loadCookies(completion: @escaping ([Item]) -> Void) {
        guard let webView else { completion([]); return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let host = webView.url?.host?.lowercased()
        runOnMain {
            store.getAllCookies { cookies in
                // Prefer cookies for the current page's host, but include all so
                // nothing is hidden.
                let sorted = cookies.sorted { a, b in
                    if let host {
                        let aMatch = a.domain.lowercased().contains(host)
                        let bMatch = b.domain.lowercased().contains(host)
                        if aMatch != bMatch { return aMatch }
                    }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                let items = sorted.map { Item(key: $0.name, value: $0.value, cookie: $0) }
                DispatchQueue.main.async { completion(items) }
            }
        }
    }

    // MARK: - Write

    /// Sets (adds or updates) a key/value. Completion indicates success.
    func setItem(scope: Scope, key: String, value: String, completion: @escaping (Bool) -> Void) {
        switch scope {
        case .local, .session:
            guard let webView, let obj = scope.jsObject else { DispatchQueue.main.async { completion(false) }; return }
            let js = "(function(){try{\(obj).setItem(\(jsString(key)),\(jsString(value)));return true;}catch(e){return false;}})();"
            runOnMain {
                webView.evaluateJavaScript(js) { result, error in
                    // `?? true` fabricated success: a nil result (page navigated away,
                    // storage disabled for the origin, JS off) reported as written.
                    // The script returns an explicit true/false, so nil means failure.
                    DispatchQueue.main.async { completion(error == nil && (result as? Bool) == true) }
                }
            }
        case .cookies:
            setCookie(name: key, value: value, existing: nil, completion: completion)
        }
    }

    /// Updates an existing cookie's value while preserving its domain/path/flags.
    func updateCookie(_ existing: HTTPCookie, newValue: String, completion: @escaping (Bool) -> Void) {
        setCookie(name: existing.name, value: newValue, existing: existing, completion: completion)
    }

    private func setCookie(name: String, value: String, existing: HTTPCookie?, completion: @escaping (Bool) -> Void) {
        guard let webView else { DispatchQueue.main.async { completion(false) }; return }
        let store = webView.configuration.websiteDataStore.httpCookieStore

        // Editing an existing cookie goes through the shared, unit-tested mapping so
        // HttpOnly, SameSite, version and comment survive. Rebuilding the dictionary
        // by hand dropped them, which silently made an HttpOnly session cookie
        // readable by page JavaScript — exactly the corruption this screen must not
        // cause.
        let props: [HTTPCookiePropertyKey: Any]
        if let existing {
            props = WebViewStoragePinScript.cookieProperties(from: existing, newValue: value)
        } else {
            var fresh: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .path: "/",
            ]
            if let domain = webView.url?.host { fresh[.domain] = domain }
            props = fresh
        }

        guard let cookie = HTTPCookie(properties: props) else { completion(false); return }
        runOnMain {
            store.setCookie(cookie) {
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    // MARK: - Delete

    func deleteItem(scope: Scope, item: Item, completion: @escaping (Bool) -> Void) {
        switch scope {
        case .local, .session:
            guard let webView, let obj = scope.jsObject else { DispatchQueue.main.async { completion(false) }; return }
            let js = "(function(){try{\(obj).removeItem(\(jsString(item.key)));return true;}catch(e){return false;}})();"
            runOnMain {
                webView.evaluateJavaScript(js) { result, error in
                    // `?? true` fabricated success: a nil result (page navigated away,
                    // storage disabled for the origin, JS off) reported as written.
                    // The script returns an explicit true/false, so nil means failure.
                    DispatchQueue.main.async { completion(error == nil && (result as? Bool) == true) }
                }
            }
        case .cookies:
            guard let webView, let cookie = item.cookie else { DispatchQueue.main.async { completion(false) }; return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            runOnMain {
                store.delete(cookie) {
                    DispatchQueue.main.async { completion(true) }
                }
            }
        }
    }

    /// Clears every entry in a web-storage scope (not applicable to cookies).
    func clearAll(scope: Scope, completion: @escaping (Bool) -> Void) {
        guard let webView, let obj = scope.jsObject else { DispatchQueue.main.async { completion(false) }; return }
        let js = "(function(){try{\(obj).clear();return true;}catch(e){return false;}})();"
        runOnMain {
            webView.evaluateJavaScript(js) { result, error in
                DispatchQueue.main.async { completion(error == nil && (result as? Bool) == true) }
            }
        }
    }

    // MARK: - Helpers

    /// JSON-encodes a string so it can be safely embedded as a JS string literal.
    private func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let json = String(data: data, encoding: .utf8) {
            // json is like ["value"] — drop the brackets to get the quoted string.
            return String(json.dropFirst().dropLast())
        }
        return "\"\""
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
