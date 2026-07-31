//
//  WebViewStorageCookieIdentityTests.swift
//  SwiftyDebugTests
//
//  The storage editor identified a cookie by its NAME. Two sites both having a
//  `session`, `token` or `jwt` cookie is the normal case, so:
//
//    * editing one site's cookie pinned whichever same-named cookie the list
//      happened to return first;
//    * the write read-back "confirmed" against that other cookie, so a write
//      that never landed looked successful;
//    * with force overwrite on, the pinned value was then written back onto the
//      host app's real session cookie for a DIFFERENT domain after every page
//      load;
//    * the delete read-back matched on name + path only, so a successful delete
//      reported failure whenever another domain still had the same cookie.
//
//  Everything below is about one rule: a cookie is (name, domain, path), never
//  a name. These are pure tests — no WKWebView — because the rule has to hold
//  before any of it reaches a live web view.
//

import XCTest
import WebKit
@testable import SwiftyDebug

final class WebViewStorageCookieIdentityTests: XCTestCase {

    // MARK: - Helpers

    private func cookie(_ name: String,
                        domain: String,
                        path: String = "/",
                        value: String = "v") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: domain, .path: path,
        ])!
    }

    private func item(_ cookie: HTTPCookie) -> WebViewStorageService.Item {
        WebViewStorageService.Item(key: cookie.name, value: cookie.value, cookie: cookie)
    }

    private func pinKey(_ c: HTTPCookie) -> String {
        StorageEntryIdentity.pinKey(for: item(c), scope: .cookies)
    }

    // MARK: - Pin keys

    func testSameCookieNameOnDifferentDomainsPinsSeparately() {
        let mine = pinKey(cookie("session", domain: "example.com"))
        let theirs = pinKey(cookie("session", domain: "other.com"))
        XCTAssertNotEqual(mine, theirs,
                          "Two sites' `session` cookies shared one pin — editing one force-wrote the other.")
    }

    func testSameCookieNameAndDomainOnDifferentPathsPinsSeparately() {
        let root = pinKey(cookie("token", domain: "example.com", path: "/"))
        let admin = pinKey(cookie("token", domain: "example.com", path: "/admin"))
        XCTAssertNotEqual(root, admin)
    }

    func testDomainCasingDoesNotSplitOnePin() {
        XCTAssertEqual(StorageEntryIdentity.cookiePinKey(name: "s", domain: "Example.COM", path: "/"),
                       StorageEntryIdentity.cookiePinKey(name: "s", domain: "example.com", path: "/"),
                       "Cookie domains are case-insensitive; the same cookie must not pin twice.")
    }

    func testLeadingDotDomainIsNotCollapsedIntoTheBareDomain() {
        // `.example.com` and `example.com` are separate records in the jar.
        // Collapsing them is the same class of bug as collapsing two hosts.
        XCTAssertNotEqual(StorageEntryIdentity.cookiePinKey(name: "s", domain: ".example.com", path: "/"),
                          StorageEntryIdentity.cookiePinKey(name: "s", domain: "example.com", path: "/"))
    }

    func testEmptyPathIsTreatedAsRoot() {
        XCTAssertEqual(StorageEntryIdentity.cookiePinKey(name: "s", domain: "a.com", path: ""),
                       StorageEntryIdentity.cookiePinKey(name: "s", domain: "a.com", path: "/"))
    }

    func testPinKeysAreUniqueAcrossAdversarialTriples() {
        let triples: [(String, String, String)] = [
            ("session", "example.com", "/"),
            ("session", "example.com", "/admin"),
            ("session", "sub.example.com", "/"),
            ("session", ".example.com", "/"),
            ("session", "example.com.evil.test", "/"),
            ("sessionx", "example.com", "/"),
            ("session", "example.com", "/x/"),
            ("session", "example.co", "m/"),
        ]
        let keys = triples.map { StorageEntryIdentity.cookiePinKey(name: $0.0, domain: $0.1, path: $0.2) }
        XCTAssertEqual(Set(keys).count, triples.count,
                       "Two different cookies collapsed onto one pin key: \(keys)")
    }

    func testWebStorageKeysAreTheirOwnPinKey() {
        let entry = WebViewStorageService.Item(key: "user @ example.com/", value: "v", cookie: nil)
        for scope in [WebViewStorageService.Scope.local, .session] {
            XCTAssertEqual(StorageEntryIdentity.pinKey(for: entry, scope: scope), "user @ example.com/",
                           "A localStorage key is already unique; it must not be rewritten.")
        }
    }

    // MARK: - Write read-back

    func testReadBackFindsThisDomainsCookieNotTheOneListedFirst() {
        let foreign = cookie("session", domain: "other.com", value: "their-value")
        let mine = cookie("session", domain: "example.com", value: "my-value")
        let items = [item(foreign), item(mine)]

        let found = StorageEntryIdentity.find(
            .cookie(name: "session", domain: "example.com", path: "/"),
            in: items, scope: .cookies)

        XCTAssertEqual(found?.cookie?.domain, "example.com")
        XCTAssertEqual(found?.value, "my-value",
                       "The read-back confirmed against another site's cookie.")
    }

    func testReadBackReportsFailureWhenOnlyAForeignCookieSharesTheName() {
        let items = [item(cookie("session", domain: "other.com", value: "their-value"))]

        XCTAssertNil(StorageEntryIdentity.find(
            .cookie(name: "session", domain: "example.com", path: "/"),
            in: items, scope: .cookies),
            "A same-named cookie for another domain is not evidence that our write landed.")
    }

    func testReadBackDistinguishesPathsOnTheSameDomain() {
        let items = [item(cookie("token", domain: "example.com", path: "/admin", value: "admin"))]
        XCTAssertNil(StorageEntryIdentity.find(
            .cookie(name: "token", domain: "example.com", path: "/"),
            in: items, scope: .cookies))
        XCTAssertNotNil(StorageEntryIdentity.find(
            .cookie(name: "token", domain: "example.com", path: "/admin"),
            in: items, scope: .cookies))
    }

    // MARK: - Newly created cookies

    func testNewCookieIsRecognisedThroughTheStoresLeadingDot() {
        // The SDK asks for domain = page host; the jar may store `.host`.
        let items = [item(cookie("flag", domain: ".example.com", path: "/", value: "1"))]
        let found = StorageEntryIdentity.find(.newCookie(name: "flag", host: "example.com"),
                                              in: items, scope: .cookies)
        XCTAssertEqual(found?.value, "1")
    }

    func testNewCookieNeverMatchesAnotherHost() {
        let items = [item(cookie("flag", domain: "other.com", path: "/", value: "1"))]
        XCTAssertNil(StorageEntryIdentity.find(.newCookie(name: "flag", host: "example.com"),
                                               in: items, scope: .cookies))
    }

    func testNewCookieWithNoPageHostMatchesNothing() {
        // No host means no domain was sent, which means no cookie was created.
        let items = [item(cookie("flag", domain: "example.com", path: "/"))]
        XCTAssertNil(StorageEntryIdentity.find(.newCookie(name: "flag", host: nil),
                                               in: items, scope: .cookies))
        XCTAssertNil(StorageEntryIdentity.find(.newCookie(name: "flag", host: ""),
                                               in: items, scope: .cookies))
    }

    func testHostEquivalenceIgnoresLeadingDotsAndCasing() {
        XCTAssertTrue(StorageEntryIdentity.domain(".Example.com", isEquivalentToHost: "example.com"))
        XCTAssertTrue(StorageEntryIdentity.domain("example.com", isEquivalentToHost: ".example.com"))
        XCTAssertFalse(StorageEntryIdentity.domain("sub.example.com", isEquivalentToHost: "example.com"))
        XCTAssertFalse(StorageEntryIdentity.domain("example.com.evil.test", isEquivalentToHost: "example.com"))
    }

    // MARK: - Web storage targets stay separate from cookies

    func testWebStorageTargetNeverMatchesInCookieScope() {
        let items = [item(cookie("session", domain: "example.com"))]
        XCTAssertNil(StorageEntryIdentity.find(.webStorage(key: "session"),
                                               in: items, scope: .cookies),
                     "A cookie must never be identified by a bare key.")
    }

    func testWebStorageTargetMatchesByKey() {
        let items = [
            WebViewStorageService.Item(key: "a", value: "1", cookie: nil),
            WebViewStorageService.Item(key: "b", value: "2", cookie: nil),
        ]
        XCTAssertEqual(StorageEntryIdentity.find(.webStorage(key: "b"), in: items, scope: .local)?.value, "2")
        XCTAssertNil(StorageEntryIdentity.find(.webStorage(key: "c"), in: items, scope: .local))
    }
}
