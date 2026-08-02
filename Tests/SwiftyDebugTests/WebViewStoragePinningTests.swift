//
//  WebViewStoragePinningTests.swift
//  SwiftyDebugTests
//
//  Force-overwrite ("pinning") re-writes a developer's edited values back into a
//  live web view after the page loads. That makes it the one place in the storage
//  editor that writes without anybody pressing Save, so the blast radius is
//  pinned down here rather than in a running web view:
//
//    * the escaper, because an under-escaped value is arbitrary JS running in the
//      host app's page;
//    * the pin model, because "which keys get written" IS the safety argument —
//      never a key the developer did not edit, never onto a different origin;
//    * the cookie field mapping, because silently dropping HttpOnly/Secure on an
//      edit turns a protected cookie into a readable one.
//

import XCTest
import WebKit
@testable import SwiftyDebug

final class WebViewStoragePinningTests: XCTestCase {

    private func lit(_ s: String) -> String { WebViewStoragePinScript.jsStringLiteral(s) }

    /// Decodes an emitted literal back to a string. Every escape the encoder
    /// produces is also valid JSON, so a JSON parse is a faithful stand-in for
    /// the JS parser and proves the literal is both lossless and unbreakable.
    private func decode(_ literal: String) -> String? {
        guard let data = "[\(literal)]".data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return array.first
    }

    // MARK: - JS string escaping

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(lit("plain"), "\"plain\"")
        XCTAssertEqual(lit(""), "\"\"")
        XCTAssertEqual(lit("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(lit("a\\b"), "\"a\\\\b\"")
        // A value ending in a backslash must not escape the closing quote.
        XCTAssertEqual(lit("trailing\\"), "\"trailing\\\\\"")
    }

    func testEscapesNewlinesAndControlCharacters() {
        XCTAssertEqual(lit("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(lit("a\r\nb"), "\"a\\r\\nb\"")
        XCTAssertEqual(lit("a\tb"), "\"a\\tb\"")
        // Anything below 0x20 has to become a \uXXXX escape, not a raw byte.
        XCTAssertEqual(lit("a\u{01}b"), "\"a\\u0001b\"")
        XCTAssertEqual(lit("a\u{08}b"), "\"a\\bb\"")
    }

    /// U+2028 / U+2029 are legal *raw* inside a JSON string but were line
    /// terminators in JS string literals before ES2019 — routing this through
    /// JSONSerialization would emit them unescaped and could break the script.
    func testEscapesLineAndParagraphSeparators() {
        XCTAssertEqual(lit("a\u{2028}b"), "\"a\\u2028b\"")
        XCTAssertEqual(lit("a\u{2029}b"), "\"a\\u2029b\"")
    }

    func testEscapesMarkupSensitiveCharacters() {
        XCTAssertEqual(lit("</script>"), "\"\\u003C/script\\u003E\"")
        XCTAssertEqual(lit("a&b"), "\"a\\u0026b\"")
    }

    func testPreservesUnicodeAndAstralCharacters() {
        XCTAssertEqual(lit("café"), "\"café\"")
        XCTAssertEqual(lit("🎈 done"), "\"🎈 done\"")
        XCTAssertEqual(lit("日本語"), "\"日本語\"")
    }

    func testHandlesVeryLongValues() {
        let long = String(repeating: "x\"\n", count: 20_000)
        let escaped = lit(long)
        XCTAssertTrue(escaped.hasPrefix("\""))
        XCTAssertTrue(escaped.hasSuffix("\""))
        // No raw newline survives inside the literal…
        XCTAssertFalse(escaped.dropFirst().dropLast().contains("\n"))
        // …and the whole thing still decodes back to exactly what went in.
        XCTAssertEqual(decode(escaped), long)
    }

    /// The property that actually matters: whatever the value contains, the
    /// literal decodes back to it unchanged and cannot terminate early.
    func testEveryEscapedValueRoundTripsLosslessly() {
        let nasty = [
            "", "plain", "a\"b", "a\\b", "trailing\\", "a\nb", "a\r\n\tb",
            "a\u{01}\u{08}\u{0C}b", "a\u{2028}b\u{2029}c", "</script><script>x()</script>",
            "café 🎈 日本語", "{\"nested\":\"json \\\" here\"}",
            "\");alert(1);//", String(repeating: "long \"value\"\n", count: 500),
        ]
        for value in nasty {
            XCTAssertEqual(decode(lit(value)), value, "did not round-trip: \(value.prefix(40))")
        }
    }

    // MARK: - Apply script

    /// A script that provably does nothing must never be evaluated, or "nothing
    /// to do" becomes indistinguishable from "applied".
    func testApplyScriptIsNilWhenThereIsNothingToApply() {
        XCTAssertNil(WebViewStoragePinScript.applyScript(object: "localStorage", pins: []))
    }

    func testApplyScriptWritesExactlyThePinnedKeysInOrder() {
        let pins = [
            WebViewStoragePin(key: "token", value: "abc"),
            WebViewStoragePin(key: "flag", value: "true"),
        ]
        let js = WebViewStoragePinScript.applyScript(object: "sessionStorage", pins: pins)
        let script = try! XCTUnwrap(js)

        XCTAssertTrue(script.contains("window.sessionStorage"))
        XCTAssertTrue(script.contains("s.setItem(\"token\",\"abc\");"))
        XCTAssertTrue(script.contains("s.setItem(\"flag\",\"true\");"))
        // Exactly two writes — nothing else is touched.
        XCTAssertEqual(script.components(separatedBy: "setItem").count - 1, 2)
        XCTAssertFalse(script.contains("removeItem"))
        XCTAssertFalse(script.contains("clear()"))
        // Reports how many it wrote so the caller can tell success from silence.
        XCTAssertTrue(script.contains("return 2;"))
        XCTAssertTrue(script.range(of: "token")!.lowerBound < script.range(of: "flag")!.lowerBound)
    }

    func testApplyScriptEscapesTheKeyAndValue() {
        let key = "k\"1"
        let value = "line1\nline2\")};alert(1);//"
        let script = try! XCTUnwrap(
            WebViewStoragePinScript.applyScript(object: "localStorage",
                                                pins: [WebViewStoragePin(key: key, value: value)]))

        // The call is composed from escaped literals, so a value containing a
        // quote-and-close cannot terminate the statement it sits in.
        XCTAssertTrue(script.contains("s.setItem(\(lit(key)),\(lit(value)));"))
        XCTAssertEqual(decode(lit(value)), value)
        XCTAssertFalse(script.contains("\nline2"), "a raw newline reached the script body")
    }

    // MARK: - Origin gating

    func testOriginKeyNormalisesSchemeHostAndPort() {
        XCTAssertEqual(WebViewStoragePinScript.originKey(for: URL(string: "https://Example.COM/a/b?x=1")),
                       "https://example.com:443")
        XCTAssertEqual(WebViewStoragePinScript.originKey(for: URL(string: "http://example.com/")),
                       "http://example.com:80")
        XCTAssertEqual(WebViewStoragePinScript.originKey(for: URL(string: "https://example.com:8443/x")),
                       "https://example.com:8443")
        // Same site, different scheme or port is a *different* storage origin.
        XCTAssertNotEqual(WebViewStoragePinScript.originKey(for: URL(string: "http://example.com/")),
                          WebViewStoragePinScript.originKey(for: URL(string: "https://example.com/")))
    }

    func testOriginKeyIsNilWithoutARealWebOrigin() {
        XCTAssertNil(WebViewStoragePinScript.originKey(for: nil))
        XCTAssertNil(WebViewStoragePinScript.originKey(for: URL(string: "about:blank")))
        XCTAssertNil(WebViewStoragePinScript.originKey(for: URL(string: "file:///tmp/page.html")))
        XCTAssertNil(WebViewStoragePinScript.originKey(for: URL(string: "data:text/html,<b>hi</b>")))
    }

    // MARK: - Pin set model

    func testNothingIsForcedByDefault() {
        let set = WebViewStoragePinSet()
        XCTAssertFalse(set.isForcing)
        XCTAssertTrue(set.isEmpty)
        XCTAssertFalse(set.shouldApply(on: "https://example.com:443"))
    }

    func testForcingAloneAppliesNothingWithoutPins() {
        var set = WebViewStoragePinSet()
        set.isForcing = true
        XCTAssertFalse(set.shouldApply(on: "https://example.com:443"))
    }

    func testPinnedKeysApplyOnlyOnTheOriginTheyWereCapturedOn() {
        var set = WebViewStoragePinSet()
        set.isForcing = true
        set.pin(key: "token", value: "abc", origin: "https://example.com:443")

        XCTAssertTrue(set.shouldApply(on: "https://example.com:443"))
        XCTAssertFalse(set.shouldApply(on: "https://evil.com:443"))
        XCTAssertFalse(set.shouldApply(on: nil))
    }

    func testPinsAreNeverAppliedWhenForcingIsOff() {
        var set = WebViewStoragePinSet()
        set.pin(key: "token", value: "abc", origin: "https://example.com:443")
        XCTAssertFalse(set.shouldApply(on: "https://example.com:443"))
        // …and switching it on later uses the same remembered keys.
        set.isForcing = true
        XCTAssertTrue(set.shouldApply(on: "https://example.com:443"))
    }

    func testRepinningAKeyUpdatesInPlaceAndKeepsOrder() {
        var set = WebViewStoragePinSet()
        set.pin(key: "a", value: "1", origin: "o")
        set.pin(key: "b", value: "2", origin: "o")
        set.pin(key: "a", value: "9", origin: "o")

        XCTAssertEqual(set.pins.map(\.key), ["a", "b"])
        XCTAssertEqual(set.value(for: "a"), "9")
        XCTAssertEqual(set.value(for: "b"), "2")
    }

    /// Mixing two origins' keys into one set would guarantee half of them are a
    /// silent no-op, so the older origin's pins are dropped instead.
    func testPinningOnANewOriginDiscardsTheOldOriginsPins() {
        var set = WebViewStoragePinSet()
        set.pin(key: "a", value: "1", origin: "https://one.com:443")
        set.pin(key: "b", value: "2", origin: "https://two.com:443")

        XCTAssertEqual(set.pins.map(\.key), ["b"])
        XCTAssertFalse(set.isPinned("a"))
        XCTAssertEqual(set.origin, "https://two.com:443")
    }

    func testUnpinningRemovesOnlyThatKey() {
        var set = WebViewStoragePinSet()
        set.isForcing = true
        set.pin(key: "a", value: "1", origin: "o")
        set.pin(key: "b", value: "2", origin: "o")

        set.unpin(key: "a")
        XCTAssertFalse(set.isPinned("a"))
        XCTAssertTrue(set.isPinned("b"))
        XCTAssertTrue(set.shouldApply(on: "o"))
    }

    func testUnpinningTheLastKeyStopsApplyingEntirely() {
        var set = WebViewStoragePinSet()
        set.isForcing = true
        set.pin(key: "a", value: "1", origin: "o")
        set.unpin(key: "a")

        XCTAssertTrue(set.isEmpty)
        XCTAssertNil(set.origin)
        XCTAssertFalse(set.shouldApply(on: "o"))
    }

    func testUnpinAllClearsEverythingButLeavesTheToggle() {
        var set = WebViewStoragePinSet()
        set.isForcing = true
        set.pin(key: "a", value: "1", origin: "o")
        set.unpinAll()

        XCTAssertTrue(set.isEmpty)
        XCTAssertTrue(set.isForcing)
        XCTAssertFalse(set.shouldApply(on: "o"))
    }

    // MARK: - Cookie field mapping

    private func makeCookie(_ setCookie: String, url: String = "https://example.com/app") -> HTTPCookie {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie],
                                         for: URL(string: url)!)
        return cookies[0]
    }

    func testCookieMappingReplacesOnlyTheValue() {
        let original = makeCookie("sid=old; Path=/app; Domain=example.com")
        let props = WebViewStoragePinScript.cookieProperties(from: original, newValue: "new")
        let rebuilt = try! XCTUnwrap(HTTPCookie(properties: props))

        XCTAssertEqual(rebuilt.value, "new")
        XCTAssertEqual(rebuilt.name, "sid")
        XCTAssertEqual(rebuilt.path, "/app")
        XCTAssertTrue(rebuilt.domain.contains("example.com"))
    }

    /// Losing these on an edit changes the cookie's security behaviour, which is
    /// the difference between "edited a value" and "corrupted a cookie".
    func testCookieMappingPreservesSecureHttpOnlyAndExpiry() {
        let original = makeCookie(
            "sid=old; Path=/app; Domain=example.com; Secure; HttpOnly; "
            + "Expires=Wed, 21 Oct 2099 07:28:00 GMT")
        XCTAssertTrue(original.isSecure)
        XCTAssertTrue(original.isHTTPOnly)
        XCTAssertNotNil(original.expiresDate)

        let props = WebViewStoragePinScript.cookieProperties(from: original, newValue: "new")
        let rebuilt = try! XCTUnwrap(HTTPCookie(properties: props))

        XCTAssertEqual(rebuilt.value, "new")
        XCTAssertTrue(rebuilt.isSecure, "Secure was dropped")
        XCTAssertTrue(rebuilt.isHTTPOnly, "HttpOnly was dropped — the cookie became page-readable")
        XCTAssertEqual(rebuilt.expiresDate?.timeIntervalSince1970 ?? 0,
                       original.expiresDate?.timeIntervalSince1970 ?? -1,
                       accuracy: 1)
    }

    func testCookieMappingPreservesSameSitePolicy() throws {
        let original = makeCookie("sid=old; Path=/; Domain=example.com; SameSite=Lax")
        try XCTSkipIf(original.sameSitePolicy == nil, "platform did not parse SameSite")

        let props = WebViewStoragePinScript.cookieProperties(from: original, newValue: "new")
        let rebuilt = try! XCTUnwrap(HTTPCookie(properties: props))
        XCTAssertEqual(rebuilt.sameSitePolicy, original.sameSitePolicy)
    }

    func testSessionCookieStaysASessionCookie() {
        let original = makeCookie("sid=old; Path=/; Domain=example.com")
        XCTAssertNil(original.expiresDate)

        let props = WebViewStoragePinScript.cookieProperties(from: original, newValue: "new")
        let rebuilt = try! XCTUnwrap(HTTPCookie(properties: props))
        XCTAssertNil(rebuilt.expiresDate, "an expiry was invented for a session cookie")
    }

    func testCookieMappingHandlesAwkwardValues() {
        let original = makeCookie("sid=old; Path=/; Domain=example.com")
        let awkward = "a=b; c=d \"quoted\" \\ back"
        let props = WebViewStoragePinScript.cookieProperties(from: original, newValue: awkward)
        let rebuilt = try! XCTUnwrap(HTTPCookie(properties: props))
        XCTAssertEqual(rebuilt.value, awkward)
    }

    // MARK: - Cookie domain fallback for header-override rules

    func testHostComponentStripsSchemePathAndPort() {
        XCTAssertEqual(WKWebViewSwizzling.hostComponent(of: "https://api.example.com/v1"), "api.example.com")
        XCTAssertEqual(WKWebViewSwizzling.hostComponent(of: "http://example.com"), "example.com")
        XCTAssertEqual(WKWebViewSwizzling.hostComponent(of: "example.com:8443/x"), "example.com")
        XCTAssertEqual(WKWebViewSwizzling.hostComponent(of: "  Example.COM  "), "example.com")
        XCTAssertNil(WKWebViewSwizzling.hostComponent(of: ""))
        XCTAssertNil(WKWebViewSwizzling.hostComponent(of: "/just/a/path"))
    }

    // MARK: - Row display

    func testRowDisplayIsNotPinnedUnlessToldSo() {
        let row = StorageRowDisplay(key: "k", value: "v", detail: nil)
        XCTAssertFalse(row.isPinned)
        XCTAssertTrue(StorageRowDisplay(key: "k", value: "v", detail: nil, isPinned: true).isPinned)
    }

    /// The row must never hand a megabyte-long string to a label — that is what
    /// crashed this screen while scrolling.
    func testRowDisplayCapsHugeValuesAndCollapsesNewlines() {
        let huge = String(repeating: "abcdefghij", count: 100_000) // ~1 MB
        let row = StorageRowDisplay(key: "blob", value: huge, detail: nil)
        XCTAssertLessThan(row.preview.count, 300)

        let multiline = StorageRowDisplay(key: "k", value: "one\ntwo\nthree", detail: nil)
        XCTAssertFalse(multiline.preview.contains("\n"))
    }
}
