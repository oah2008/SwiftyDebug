//
//  ReplayRequestBuildingTests.swift
//  SwiftyDebugTests
//
//  cURL import now sends through the replay screen instead of its own editor.
//  Two behaviours were lost in that move and are pinned here: repeated headers
//  must survive, and curl's default content type must be supplied. Both failed
//  silently — the request went out subtly wrong with nothing on screen to say so.
//

import XCTest
@testable import SwiftyDebug

final class ReplayRequestBuildingTests: XCTestCase {

    private let url = URL(string: "https://api.example.com/v1/orders")!

    private func build(headers: [(name: String, value: String)] = [],
                       body: Data? = nil,
                       method: String = "POST",
                       curl: Bool = true) -> URLRequest {
        return RequestReplayViewController.makeRequest(
            url: url, method: method, headers: headers, body: body, appliesCurlDefaults: curl)
    }

    // MARK: - Repeated headers

    func testRepeatedHeadersAreAllSent() {
        let request = build(headers: [
            (name: "Cookie", value: "a=1"),
            (name: "Cookie", value: "b=2"),
        ])
        // URLRequest joins repeated fields with a comma.
        let cookie = request.value(forHTTPHeaderField: "Cookie")
        XCTAssertEqual(cookie, "a=1,b=2",
                       "setValue replaces — a repeated header must be appended, not dropped")
    }

    func testRepeatedHeaderMatchingIsCaseInsensitive() {
        let request = build(headers: [
            (name: "Accept", value: "application/json"),
            (name: "accept", value: "text/plain"),
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json,text/plain")
    }

    func testDistinctHeadersAreIndependent() {
        let request = build(headers: [
            (name: "Authorization", value: "Bearer abc"),
            (name: "X-Trace", value: "1"),
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "1")
    }

    func testEmptyHeaderNamesAreSkipped() {
        let request = build(headers: [(name: "", value: "orphan"), (name: "X-Real", value: "1")])
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 1)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Real"), "1")
    }

    // MARK: - curl's default content type

    func testImportedBodyGetsCurlsDefaultContentType() {
        let request = build(body: Data("a=1&b=2".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
    }

    func testDeclaredContentTypeIsNotOverwritten() {
        let request = build(headers: [(name: "Content-Type", value: "application/json")],
                            body: Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testDeclaredContentTypeIsMatchedCaseInsensitively() {
        let request = build(headers: [(name: "content-type", value: "text/xml")],
                            body: Data("<a/>".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "text/xml")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type").flatMap {
            $0 == "application/x-www-form-urlencoded" ? $0 : nil
        })
    }

    func testNoContentTypeIsInventedWithoutABody() {
        let request = build()
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testReplayedCaptureGetsNoInventedContentType() {
        // A captured request already carries whatever the app really sent;
        // inventing a type here would misrepresent it.
        let request = build(body: Data("a=1".utf8), curl: false)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(request.httpBody, Data("a=1".utf8))
    }

    // MARK: - Body bytes

    func testBodyIsSentVerbatim() {
        // Binary payloads must reach the wire unchanged — re-encoding through a
        // string would corrupt them, and any HMAC over the raw body would break.
        let binary = Data([0x00, 0xFF, 0x10, 0x80, 0x7F])
        let request = build(body: binary)
        XCTAssertEqual(request.httpBody, binary)
    }

    func testEmptyBodyIsTreatedAsNoBody() {
        let request = build(body: Data())
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testMethodAndURLArePreserved() {
        let request = build(method: "PATCH")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url, url)
    }
}
