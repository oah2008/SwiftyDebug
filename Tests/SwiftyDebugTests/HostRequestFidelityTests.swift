//
//  HostRequestFidelityTests.swift
//  SwiftyDebugTests
//
//  SwiftyDebug re-issues the host app's requests, so the request that reaches
//  the wire must be the request the app WOULD have sent. Two ways it was not:
//
//  1. Canonicalization hardwired `Accept-Language: en-us` onto every request
//     that did not already carry one — sample code whose own comment called it
//     "quite bogus". On a Japanese or Arabic device the server was asked for US
//     English and answered in US English, so the HOST APP's localisation looked
//     broken, with no header the app itself had set to explain it.
//
//  2. The protocol ignored `self.cachedResponse` entirely, so a request the app
//     marked `.returnCacheDataDontLoad` — the offline read — went to the
//     network, which is the one thing that policy forbids.
//

import XCTest
@testable import SwiftyDebug

// MARK: - A URLProtocolClient that just records what it was told

private final class RecordingProtocolClient: NSObject, URLProtocolClient {
    var receivedResponses: [URLResponse] = []
    var storagePolicies: [URLCache.StoragePolicy] = []
    var loadedData = Data()
    var finished = false
    var failure: Error?

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest,
                     redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse,
                     cacheStoragePolicy policy: URLCache.StoragePolicy) {
        receivedResponses.append(response)
        storagePolicies.append(policy)
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { loadedData.append(data) }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { finished = true }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { failure = error }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

final class HostRequestFidelityTests: XCTestCase {

    private var savedPreset: NetworkConditionerPreset = .off

    override func setUp() {
        super.setUp()
        savedPreset = Settings.shared.networkConditionerPreset
        Settings.shared.networkConditionerPreset = .off
    }

    override func tearDown() {
        Settings.shared.networkConditionerPreset = savedPreset
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        super.tearDown()
    }

    // MARK: - MAJOR 4: Accept-Language

    /// A host on a domain no intercept rule can plausibly match, so the store's
    /// contents cannot change the outcome of these tests.
    private func canonicalised(_ url: String = "https://accept-language-pin.swiftydebug.invalid/x",
                               headers: [String: String] = [:],
                               method: String = "GET") -> NSMutableURLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return CanonicalRequestForRequest(request)
    }

    /// The regression: canonicalization must not invent an `Accept-Language`.
    /// CFNetwork fills it in from the device's preferred languages, which is
    /// exactly the value the app would have sent with SwiftyDebug absent.
    func testCanonicalizationDoesNotHardwireAcceptLanguage() {
        let result = canonicalised()
        XCTAssertNil(result.value(forHTTPHeaderField: "Accept-Language"),
                     "SwiftyDebug must leave Accept-Language to CFNetwork. Hardwiring a value "
                     + "(it used to be \"en-us\") overrides the device language for the whole "
                     + "host app, so its localisation appears broken.")
    }

    /// Nor may it be "fixed" by writing the device locale over a value the app
    /// deliberately set.
    func testAppSuppliedAcceptLanguageIsPreservedExactly() {
        let result = canonicalised(headers: ["Accept-Language": "ja-JP, ja;q=0.9"])
        XCTAssertEqual(result.value(forHTTPHeaderField: "Accept-Language"), "ja-JP, ja;q=0.9")
    }

    /// The boundary of the change: the other defaults are still added, so this
    /// is a targeted removal rather than canonicalization being gutted.
    func testOtherCanonicalDefaultsAreStillApplied() {
        let result = canonicalised()
        XCTAssertEqual(result.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertNotNil(result.value(forHTTPHeaderField: "Accept-Encoding"))
    }

    func testCanonicalizationStillNormalisesTheURL() {
        let result = canonicalised("HTTPS://Accept-Language-Pin.SwiftyDebug.INVALID")
        XCTAssertEqual(result.url?.scheme, "https")
        XCTAssertEqual(result.url?.host, "accept-language-pin.swiftydebug.invalid")
        XCTAssertEqual(result.url?.path, "/", "An empty path is canonicalised to \"/\".")
    }

    // MARK: - MAJOR 3: the app's URLCache is actually read

    private func makeProtocol(policy: URLRequest.CachePolicy,
                              cached: CachedURLResponse?,
                              client: RecordingProtocolClient) -> CustomHTTPProtocol {
        var request = URLRequest(url: URL(string: "https://cache-pin.swiftydebug.invalid/thing")!)
        request.cachePolicy = policy
        return CustomHTTPProtocol(request: request, cachedResponse: cached, client: client)
    }

    private func cachedEntry(body: String) -> CachedURLResponse {
        let url = URL(string: "https://cache-pin.swiftydebug.invalid/thing")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return CachedURLResponse(response: response, data: Data(body.utf8))
    }

    /// `.returnCacheDataElseLoad` with an entry must be answered from that
    /// entry, with no network task created at all.
    func testCachedEntryIsServedWithoutTouchingTheNetwork() {
        let client = RecordingProtocolClient()
        let proto = makeProtocol(policy: .returnCacheDataElseLoad,
                                 cached: cachedEntry(body: "{\"from\":\"cache\"}"),
                                 client: client)
        proto.startLoading()

        XCTAssertEqual(String(decoding: client.loadedData, as: UTF8.self), "{\"from\":\"cache\"}",
                       "The body the app receives must be the cached bytes.")
        XCTAssertTrue(client.finished)
        XCTAssertNil(client.failure)
        XCTAssertEqual(client.storagePolicies, [.notAllowed],
                       "A response read from the cache must not be written back to it — that is "
                       + "how a cached entry silently gets its lifetime extended.")
        proto.stopLoading()
    }

    /// `.returnCacheDataDontLoad` with nothing cached must fail the way
    /// CFNetwork fails it. Loading anyway defeats the entire policy, and it is
    /// what the SDK did while it forced `.reloadIgnoringLocalCacheData`.
    func testCacheOnlyMissFailsInsteadOfGoingToTheNetwork() throws {
        let client = RecordingProtocolClient()
        let proto = makeProtocol(policy: .returnCacheDataDontLoad, cached: nil, client: client)
        proto.startLoading()

        let error = try XCTUnwrap(client.failure as NSError?,
                                  "A .returnCacheDataDontLoad miss must fail, not load.")
        XCTAssertEqual(error.domain, NSURLErrorDomain)
        XCTAssertEqual(error.code, NSURLErrorResourceUnavailable)
        XCTAssertTrue(client.receivedResponses.isEmpty)
        XCTAssertFalse(client.finished)
        proto.stopLoading()
    }
}
