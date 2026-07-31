//
//  WebViewHostPinMatcherTests.swift
//  SwiftyDebugTests
//
//  An endpoint intercept rule can be PINNED to one host (`matchHost`). Native
//  traffic honoured the pin; the copy of the matcher that runs inside web views
//  did not, so a rule written for `api.example.com` fired on every host the web
//  view touched — blocking, header-overriding and redirecting third-party
//  requests the developer never targeted.
//
//  The fix is four lines of JavaScript (`pinAllows`) inside a 400-line string
//  literal, and NOTHING in the test suite so much as mentioned it: replacing it
//  with `function pinAllows(r,u){return true;}` reinstated the reported bug with
//  the whole suite green.
//
//  So these tests run the shipped JavaScript. The rule-resolution half of the
//  injected script is lifted verbatim out of `WebViewInjectedScript.networkCapture`
//  and executed in a JSContext against a minimal `URL`/`document` stub — the
//  same functions, the same source, no re-implementation to drift out of sync.
//

import XCTest
import JavaScriptCore
@testable import SwiftyDebug

final class WebViewHostPinMatcherTests: XCTestCase {

    private var context: JSContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = try Self.makeContextRunningTheShippedMatcher()
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    // MARK: - The bug

    /// The reported case: a rule pinned to one host firing inside a web view on
    /// a completely different host.
    func testAPinnedEndpointRuleDoesNotFireOnAnotherHost() {
        install(rules: [pinnedRule(host: "api.example.com", endpoint: "/v1/orders")])

        XCTAssertTrue(matches("https://api.example.com/v1/orders"),
                      "The rule must still fire on the host it is pinned to.")
        XCTAssertFalse(matches("https://analytics.vendor.com/v1/orders"),
                       "A rule pinned to api.example.com fired on every host inside the web "
                       + "view — blocking or rewriting third-party traffic nobody targeted.")
        XCTAssertFalse(matches("https://evil.example.com/v1/orders"),
                       "A sibling host is still a different host.")
    }

    /// Same for the `normalized` match mode (`/users/{id}`), which goes through
    /// the same pin check.
    func testAPinnedNormalizedRuleDoesNotFireOnAnotherHost() {
        var rule = pinnedRule(host: "api.example.com", endpoint: "/users/{id}")
        rule["matchMode"] = "normalized"
        install(rules: [rule])

        XCTAssertTrue(matches("https://api.example.com/users/4821"),
                      "Precondition: the normalized path matches on the pinned host.")
        XCTAssertFalse(matches("https://cdn.example.com/users/4821"),
                       "The pin has to be honoured in normalized mode too.")
    }

    // MARK: - What the pin must not break

    /// Every rule written before host pinning existed has no `matchHost`, and
    /// those must keep matching on any host — a pin check that defaults to
    /// "deny" would silently switch off everyone's existing rules.
    func testAnUnpinnedRuleStillMatchesAnyHost() {
        var rule = pinnedRule(host: "", endpoint: "/v1/orders")
        rule.removeValue(forKey: "matchHost")
        install(rules: [rule])

        XCTAssertTrue(matches("https://api.example.com/v1/orders"))
        XCTAssertTrue(matches("https://anything.else.test/v1/orders"))

        // The empty-string spelling of "any host" behaves the same way.
        install(rules: [pinnedRule(host: "", endpoint: "/v1/orders")])
        XCTAssertTrue(matches("https://api.example.com/v1/orders"))
        XCTAssertTrue(matches("https://anything.else.test/v1/orders"))
    }

    /// Hosts are case-insensitive, and the pin is stored however the developer
    /// typed it.
    func testThePinIsCaseInsensitive() {
        install(rules: [pinnedRule(host: "API.Example.COM", endpoint: "/v1/orders")])
        XCTAssertTrue(matches("https://api.example.com/v1/orders"),
                      "A pin typed with capitals must still match the same host.")
    }

    /// A port or a userinfo segment is not part of the host name, and a page
    /// making a relative request must still be matched against the page's host.
    func testThePinIgnoresThePortAndResolvesRelativeURLs() {
        install(rules: [pinnedRule(host: "api.example.com", endpoint: "/v1/orders")])

        XCTAssertTrue(matches("https://api.example.com:8443/v1/orders"),
                      "A port is not part of the host name.")
        XCTAssertTrue(matches("/v1/orders"),
                      "A relative request from a page on the pinned host must match — "
                      + "this is the common case inside a web view.")
    }

    /// The query string is not part of the pin decision either.
    func testTheQueryStringDoesNotDefeatThePin() {
        install(rules: [pinnedRule(host: "api.example.com", endpoint: "/v1/orders")])
        XCTAssertTrue(matches("https://api.example.com/v1/orders?page=2&sort=date"))
        XCTAssertFalse(matches("https://other.vendor.com/v1/orders?page=2"))
    }

    // MARK: - Driving the shipped script

    private func pinnedRule(host: String, endpoint: String) -> [String: Any] {
        [
            "id": "rule-1",
            "matchMode": "exact",
            "matchEndpoint": endpoint,
            "matchHost": host,
            "order": 0,
            "isBlocked": true,
        ]
    }

    private func install(rules: [[String: Any]]) {
        context.setObject(rules, forKeyedSubscript: "__testRules" as NSString)
        context.evaluateScript("window.__cd_intercept_rules = __testRules;")
        XCTAssertNil(context.exception, "\(context.exception!)")
    }

    /// `true` when the shipped `resolveRules` returns a config for this URL —
    /// i.e. the rule fires and the request is intercepted.
    private func matches(_ url: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let value = context.evaluateScript("resolveRules(\(Self.jsString(url))) !== null")
        if let exception = context.exception {
            XCTFail("The injected matcher threw: \(exception)", file: file, line: line)
            return false
        }
        return value?.toBool() ?? false
    }

    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    /// Lifts the rule-resolution half of the injected script out of
    /// `WebViewInjectedScript.networkCapture` — verbatim, so what runs here is what
    /// ships — and evaluates it against the smallest browser stub it needs.
    private static func makeContextRunningTheShippedMatcher() throws -> JSContext {
        let script = WebViewInjectedScript.networkCapture

        let startMarker = "function normalizePath(path){"
        let endMarker = "return c;}"
        let start = try XCTUnwrap(script.range(of: startMarker),
                                  "The injected script no longer defines normalizePath — this "
                                  + "test can no longer find the matcher it is supposed to pin.")
        let end = try XCTUnwrap(script.range(of: endMarker, range: start.upperBound..<script.endIndex),
                                "The injected script no longer ends resolveRules with `return c;}`.")
        let matcherSource = String(script[start.lowerBound..<end.upperBound])

        XCTAssertTrue(matcherSource.contains("function pinAllows"),
                      "The host-pin matcher is gone from the injected script.")

        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(browserStub)
        try assertNoException(context, "the browser stub")
        context.evaluateScript(matcherSource)
        try assertNoException(context, "the injected matcher")
        return context
    }

    private static func assertNoException(_ context: JSContext, _ what: String) throws {
        if let exception = context.exception {
            throw NSError(domain: "WebViewHostPinMatcherTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(what) failed to evaluate: \(exception)",
            ])
        }
    }

    /// The two browser globals the matcher touches — a page on
    /// `https://api.example.com/shop/` and enough of `URL` to answer
    /// `hostname`/`pathname`. Everything else in the injected script (XHR,
    /// fetch, the message bridge) is outside the extracted region.
    private static let browserStub = """
    var window = { __cd_enabled: true, __cd_intercept_rules: [] };
    var document = { baseURI: 'https://api.example.com/shop/' };
    function URL(input, base) {
      var s = String(input);
      var m = /^([a-zA-Z][a-zA-Z0-9+.\\-]*:)\\/\\/([^\\/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?$/.exec(s);
      if (m) {
        var authority = m[2];
        var at = authority.lastIndexOf('@');
        if (at >= 0) { authority = authority.substring(at + 1); }
        this.protocol = m[1];
        this.host = authority;
        this.hostname = authority.split(':')[0];
        this.pathname = m[3] || '/';
        this.search = m[4] || '';
        this.hash = m[5] || '';
        return;
      }
      if (!base) { throw new TypeError('Invalid URL: ' + s); }
      var b = new URL(base);
      var path = s;
      var hash = '';
      var query = '';
      var hi = path.indexOf('#');
      if (hi >= 0) { hash = path.substring(hi); path = path.substring(0, hi); }
      var qi = path.indexOf('?');
      if (qi >= 0) { query = path.substring(qi); path = path.substring(0, qi); }
      if (path.charAt(0) !== '/') {
        path = b.pathname.replace(/[^\\/]*$/, '') + path;
      }
      this.protocol = b.protocol;
      this.host = b.host;
      this.hostname = b.hostname;
      this.pathname = path || '/';
      this.search = query;
      this.hash = hash;
    }
    """
}
