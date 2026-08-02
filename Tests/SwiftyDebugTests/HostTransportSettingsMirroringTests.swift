//
//  HostTransportSettingsMirroringTests.swift
//  SwiftyDebugTests
//
//  SwiftyDebug re-issues every host-app request on a session of its own. That
//  hand-off drops every session-level setting the app chose, so the SDK has to
//  MIRROR the originating configuration — it may impose neither its own tuning
//  nor Foundation's defaults.
//
//  Removing the SDK's old pins (`httpShouldSetCookies = false`,
//  `httpMaximumConnectionsPerHost = 1`) fixed the apps that had never asked for
//  them and broke the apps that HAD:
//
//    | host app's own session          | before the pins were removed | after |
//    |---------------------------------|------------------------------|-------|
//    | httpShouldSetCookies = false    | honoured (by accident)       | IGNORED — shared jar's cookie on the wire |
//    | private per-account cookie jar  | no cookie sent               | IGNORED — account A's cookie on account B |
//    | httpMaximumConnectionsPerHost=2 | 1 (wrong, but safe)          | 6 — wrong in the unsafe direction |
//
//  and a session-level `requestCachePolicy` was invisible either way, because a
//  request that inherits its policy from the session reports
//  `.useProtocolCachePolicy`.
//
//  Every test below drives the real `startLoading`, so it fails if the wiring is
//  reverted, not only if the lookup tables are.
//

import XCTest
@testable import SwiftyDebug

/// Records what a `URLProtocol` told the URL loading system.
private final class RecordingProtocolClient: NSObject, URLProtocolClient {
    var receivedResponse: URLResponse?
    var receivedData = Data()
    var failure: Error?
    var didFinish = false

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest,
                     redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse,
                     cacheStoragePolicy policy: URLCache.StoragePolicy) {
        receivedResponse = response
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { receivedData.append(data) }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { didFinish = true }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { failure = error }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

final class HostTransportSettingsMirroringTests: XCTestCase {

    /// `.invalid` is reserved and never resolves, so an upstream task that does
    /// get created fails locally instead of reaching anyone. The tests assert on
    /// the request that was ISSUED, not on any response.
    private let url = URL(string: "https://swiftydebug-host-transport.invalid/resource")!

    private var openedSessions: [URLSession] = []
    private var startedProtocols: [CustomHTTPProtocol] = []

    override func setUp() {
        super.setUp()
        CustomHTTPProtocol.resetDedicatedDemuxesForTesting()
    }

    override func tearDown() {
        for proto in startedProtocols { proto.upstreamTaskForTesting?.cancel() }
        startedProtocols.removeAll()
        for session in openedSessions { session.invalidateAndCancel() }
        openedSessions.removeAll()
        CustomHTTPProtocol.resetDedicatedDemuxesForTesting()
        // Building configurations feeds the timeout bookkeeping; leave it as a
        // fresh launch would so test order cannot matter.
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A task on a session the HOST APP configured — exactly what
    /// `URLProtocol.task` hands `startLoading` in a real app.
    private func hostTask(_ configure: (URLSessionConfiguration) -> Void) -> URLSessionDataTask {
        let config = URLSessionConfiguration.default
        configure(config)
        let session = URLSession(configuration: config)
        openedSessions.append(session)
        return session.dataTask(with: url)
    }

    /// Runs the real `startLoading` for a request the host app made on `task`.
    @discardableResult
    private func startLoading(on task: URLSessionDataTask,
                              cachedResponse: CachedURLResponse? = nil,
                              client: RecordingProtocolClient) -> CustomHTTPProtocol {
        let proto = CustomHTTPProtocol(task: task, cachedResponse: cachedResponse, client: client)
        startedProtocols.append(proto)
        proto.startLoading()
        return proto
    }

    /// The session the request was really issued on — the only place a setting
    /// that a `URLRequest` cannot express is observable.
    private func issuingSession(of proto: CustomHTTPProtocol) throws -> URLSession {
        let task = try XCTUnwrap(proto.upstreamTaskForTesting,
                                 "SwiftyDebug never issued the request upstream.")
        return try XCTUnwrap(CustomHTTPProtocol.originatingSession(of: task))
    }

    private func issuedRequest(of proto: CustomHTTPProtocol) throws -> URLRequest {
        let task = try XCTUnwrap(proto.upstreamTaskForTesting,
                                 "SwiftyDebug never issued the request upstream.")
        return try XCTUnwrap(task.originalRequest)
    }

    // MARK: - The route itself

    /// Everything else here rests on being able to read the originating
    /// configuration at all. If this stops working the SDK falls back to
    /// Foundation's defaults silently, which is the whole regression — so it is
    /// asserted on its own rather than only implied by the tests below.
    func testTheOriginatingSessionsConfigurationIsReadable() throws {
        let jar = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "swiftydebug.route")
        let task = hostTask {
            $0.httpShouldSetCookies = false
            $0.httpMaximumConnectionsPerHost = 2
            $0.allowsCellularAccess = false
            $0.requestCachePolicy = .returnCacheDataElseLoad
            $0.httpCookieStorage = jar
        }
        let settings = try XCTUnwrap(CustomHTTPProtocol.hostTransportSettings(for: task),
                                     "The originating session could not be reached, so every "
                                     + "host transport setting would be silently replaced by "
                                     + "Foundation's defaults.")
        XCTAssertFalse(settings.httpShouldSetCookies)
        XCTAssertEqual(settings.httpMaximumConnectionsPerHost, 2)
        XCTAssertFalse(settings.allowsCellularAccess)
        XCTAssertEqual(settings.requestCachePolicy, .returnCacheDataElseLoad)
        XCTAssertTrue(settings.httpCookieStorage === jar)

        // ...and none of it is visible on the request, which is why the session
        // has to be consulted.
        let asRequest = try XCTUnwrap(task.originalRequest)
        XCTAssertTrue(asRequest.httpShouldHandleCookies)
        XCTAssertTrue(asRequest.allowsCellularAccess)
        XCTAssertEqual(asRequest.cachePolicy, .useProtocolCachePolicy)
    }

    func testUnknownOriginatingSessionIsToleratedRatherThanGuessed() {
        XCTAssertNil(CustomHTTPProtocol.hostTransportSettings(for: nil))
        let untouched = URLRequest(url: url)
        XCTAssertEqual(
            CustomHTTPProtocol.upstreamRequest(untouched, hostSettings: nil,
                                               sessionSharesHostCookieStorage: true),
            untouched,
            "With no originating configuration to mirror, the request must be forwarded "
            + "byte-for-byte rather than have defaults written onto it.")
    }

    // MARK: - REGRESSION 1: the host app's cookie policy

    /// An app that sets `httpShouldSetCookies = false` has opted out. Once the
    /// SDK's own pin was removed, the demux session's default (`true`) put the
    /// SHARED jar's `Cookie` on the wire for it.
    func testHostCookieOptOutSurvivesOntoTheIssuedRequest() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.httpShouldSetCookies = false }, client: client)

        XCTAssertFalse(try issuedRequest(of: proto).httpShouldHandleCookies,
                       "The host app opted out of cookies on its own session. SwiftyDebug "
                       + "re-issues the request on a session that sends them, so unless the "
                       + "opt-out is carried onto the request the shared jar's Cookie header "
                       + "goes out anyway.")
    }

    /// The multi-account case. A private jar is not the shared jar, so leaving
    /// the request on a session backed by `HTTPCookieStorage.shared` sends
    /// account A's credential on account B's session.
    func testHostPrivateCookieJarIsNotReplacedByTheSharedJar() throws {
        let jar = try XCTUnwrap(
            HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "swiftydebug.accountA"))
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.httpCookieStorage = jar }, client: client)

        let issuedOn = try issuingSession(of: proto)
        XCTAssertFalse(issuedOn.configuration.httpCookieStorage === HTTPCookieStorage.shared,
                       "The request went out on a session backed by the SHARED cookie jar even "
                       + "though the host app deliberately used a private one — in a "
                       + "multi-account app that is one account's credential on another "
                       + "account's session.")
        XCTAssertTrue(issuedOn.configuration.httpCookieStorage === jar,
                      "The session the request is issued on must use the host app's own jar, "
                      + "so both the Cookie sent and the Set-Cookie stored stay in it.")
    }

    /// A jar we could not give the request a session for must mean NO cookie,
    /// never the wrong jar's cookie. This is the direction the fallback has to
    /// fail in.
    func testACookieJarThatCannotBeMirroredDisablesCookiesRatherThanUsingTheWrongJar() {
        let privateJar = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "swiftydebug.unmirrorable")
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = privateJar
        let settings = CustomHTTPProtocol.DemuxTransportSettings(config)

        let issued = CustomHTTPProtocol.upstreamRequest(URLRequest(url: url),
                                                        hostSettings: settings,
                                                        sessionSharesHostCookieStorage: false)
        XCTAssertFalse(issued.httpShouldHandleCookies,
                       "When the request cannot be issued on a session using the host's own "
                       + "jar, cookie handling must be switched off. Sending the shared jar's "
                       + "cookie instead is the multi-account credential leak.")
    }

    /// An app that turned cookie storage off entirely (`httpCookieStorage = nil`)
    /// gets no cookies either.
    func testHostWithNoCookieStorageSendsNoCookies() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        let settings = CustomHTTPProtocol.DemuxTransportSettings(config)
        XCTAssertFalse(
            CustomHTTPProtocol.upstreamRequest(URLRequest(url: url), hostSettings: settings,
                                               sessionSharesHostCookieStorage: true)
                .httpShouldHandleCookies)
    }

    /// The ordinary app must keep sending cookies — the fix must not reintroduce
    /// the very regression the pin removal cured.
    func testAnOrdinaryHostSessionStillSendsCookies() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { _ in }, client: client)

        XCTAssertTrue(try issuedRequest(of: proto).httpShouldHandleCookies)
        XCTAssertTrue(try issuingSession(of: proto).configuration.httpCookieStorage
                        === HTTPCookieStorage.shared)
    }

    // MARK: - REGRESSION 2: the host app's connection cap

    /// `httpMaximumConnectionsPerHost` cannot be expressed on a `URLRequest`, so
    /// honouring it means issuing the request on a session that was built with
    /// it. An app that throttles itself to 2 was silently given 6.
    func testHostConnectionCapSurvivesOntoTheSessionTheRequestIsIssuedOn() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.httpMaximumConnectionsPerHost = 2 },
                                 client: client)

        XCTAssertEqual(try issuingSession(of: proto).configuration.httpMaximumConnectionsPerHost, 2,
                       "The host app throttled itself to 2 connections per host. Re-issuing its "
                       + "request on a session with Foundation's default of 6 discards that — "
                       + "wrong in the unsafe direction.")
    }

    /// Two host sessions with the same signature must share one demux session:
    /// the fix must not stand up a session per request.
    func testOneDemuxSessionServesEveryHostSessionWithTheSameSignature() throws {
        let client1 = RecordingProtocolClient()
        let client2 = RecordingProtocolClient()
        let a = startLoading(on: hostTask { $0.httpMaximumConnectionsPerHost = 2 }, client: client1)
        let b = startLoading(on: hostTask { $0.httpMaximumConnectionsPerHost = 2 }, client: client2)

        XCTAssertTrue(try issuingSession(of: a) === (try issuingSession(of: b)))
        XCTAssertEqual(CustomHTTPProtocol.dedicatedDemuxCountForTesting, 1)
    }

    /// The common case — a stock `URLSessionConfiguration.default` — must still
    /// go through the ONE shared session, with no extra sessions created.
    func testAStockHostConfigurationStillUsesTheSingleSharedSession() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { _ in }, client: client)

        XCTAssertTrue(try issuingSession(of: proto) === CustomHTTPProtocol.sharedDemux().session)
        XCTAssertEqual(CustomHTTPProtocol.dedicatedDemuxCountForTesting, 0,
                       "An app that configures nothing must not cause a second session to exist.")
    }

    // MARK: - The rest of the transport settings

    func testHostCellularOptOutSurvivesOntoTheIssuedRequest() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.allowsCellularAccess = false }, client: client)

        XCTAssertFalse(try issuedRequest(of: proto).allowsCellularAccess,
                       "\"Wi-Fi only\" is usually a user-visible setting. Re-issuing the request "
                       + "on a session that allows cellular spends the user's data plan.")
    }

    func testNeitherSideCanTurnCellularAccessBackOn() {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        let settings = CustomHTTPProtocol.DemuxTransportSettings(config)
        var request = URLRequest(url: url)
        request.allowsCellularAccess = false
        XCTAssertFalse(
            CustomHTTPProtocol.upstreamRequest(request, hostSettings: settings,
                                               sessionSharesHostCookieStorage: true)
                .allowsCellularAccess,
            "A request-level opt-out must survive a session that permits cellular.")
    }

    func testHostPipeliningIsCarried() {
        let config = URLSessionConfiguration.default
        config.httpShouldUsePipelining = true
        let settings = CustomHTTPProtocol.DemuxTransportSettings(config)
        XCTAssertTrue(
            CustomHTTPProtocol.upstreamRequest(URLRequest(url: url), hostSettings: settings,
                                               sessionSharesHostCookieStorage: true)
                .httpShouldUsePipelining)
    }

    // MARK: - The session-level cache policy (the coverage gap)

    /// A request that inherits its policy from the session reports
    /// `.useProtocolCachePolicy`, so a table that reads only the request never
    /// sees the app's choice.
    func testTheSessionsPolicyGovernsARequestThatDidNotChooseOne() {
        XCTAssertEqual(
            CustomHTTPProtocol.effectiveCachePolicy(request: .useProtocolCachePolicy,
                                                    session: .returnCacheDataDontLoad),
            .returnCacheDataDontLoad)
        XCTAssertEqual(
            CustomHTTPProtocol.effectiveCachePolicy(request: .useProtocolCachePolicy,
                                                    session: .returnCacheDataElseLoad),
            .returnCacheDataElseLoad)
    }

    /// A request that DID choose one outranks the session — that is what
    /// per-request policies are for.
    func testARequestsOwnPolicyOutranksTheSessions() {
        XCTAssertEqual(
            CustomHTTPProtocol.effectiveCachePolicy(request: .reloadIgnoringLocalCacheData,
                                                    session: .returnCacheDataElseLoad),
            .reloadIgnoringLocalCacheData)
        XCTAssertEqual(
            CustomHTTPProtocol.effectiveCachePolicy(request: .useProtocolCachePolicy, session: nil),
            .useProtocolCachePolicy)
    }

    /// End to end: a session-level `.returnCacheDataElseLoad` plus a cached
    /// entry must be answered from the cache and never reach the network.
    func testSessionLevelCachePolicyServesTheCachedResponseWithoutLoading() throws {
        let cached = CachedURLResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: nil)!,
            data: Data("from-the-app-cache".utf8))
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.requestCachePolicy = .returnCacheDataElseLoad },
                                 cachedResponse: cached,
                                 client: client)

        XCTAssertEqual(String(decoding: client.receivedData, as: UTF8.self), "from-the-app-cache",
                       "The host app set .returnCacheDataElseLoad on its SESSION, which is how "
                       + "most apps set it. Reading only the request's policy sees "
                       + ".useProtocolCachePolicy, so the URLCache read never fires and every "
                       + "cache hit becomes a network round trip.")
        XCTAssertTrue(client.didFinish)
        XCTAssertNil(proto.upstreamTaskForTesting,
                     "Serving from cache means no upstream request at all.")
    }

    /// And the offline read: session-level `.returnCacheDataDontLoad` with
    /// nothing cached must FAIL rather than quietly do the one thing the policy
    /// forbids.
    func testSessionLevelCacheOnlyMissFailsInsteadOfHittingTheNetwork() throws {
        let client = RecordingProtocolClient()
        let proto = startLoading(on: hostTask { $0.requestCachePolicy = .returnCacheDataDontLoad },
                                 client: client)

        XCTAssertNil(proto.upstreamTaskForTesting,
                     "A session-level .returnCacheDataDontLoad miss must not reach the network.")
        let error = try XCTUnwrap(client.failure as NSError?)
        XCTAssertEqual(error.domain, NSURLErrorDomain)
        XCTAssertEqual(error.code, NSURLErrorResourceUnavailable)
    }
}
