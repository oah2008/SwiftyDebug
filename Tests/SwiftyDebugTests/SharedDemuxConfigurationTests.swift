//
//  SharedDemuxConfigurationTests.swift
//  SwiftyDebugTests
//
//  Pins the settings on the SHARED DEMUX SESSION, and the position SwiftyDebug
//  takes in `protocolClasses`.
//
//  Both matter for the same reason: SwiftyDebug is embedded in other people's
//  apps, and every request those apps make is re-issued through this one
//  session. A setting here is not the SDK's setting — it silently becomes the
//  host app's. Three used to be set, and each was a measured regression in any
//  app that merely LINKS the SDK:
//
//    | measurement                    | no SDK    | SDK, as it was |
//    |--------------------------------|-----------|----------------|
//    | Cookie header on the wire      | sid=abc123| NONE           |
//    | HTTPCookieStorage.shared count | 1         | 0              |
//    | 6 concurrent 300 ms GETs       | 0.31 s    | 1.87 s         |
//
//  and `.reloadIgnoringLocalCacheData` overrode the app's per-request policy, so
//  its URLCache was never read: 3x requests, 3x data, and offline reads via
//  `.returnCacheDataDontLoad` could not succeed at all.
//
//  These tests fail if any of the three comes back.
//

import XCTest
@testable import SwiftyDebug

/// Stands in for a `URLProtocol` the HOST APP registered — OHHTTPStubs, Mocker,
/// an offline layer. Its whole job is to have a position relative to ours.
private final class HostAppStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { false }
    override func startLoading() {}
    override func stopLoading() {}
}

final class SharedDemuxConfigurationTests: XCTestCase {

    override func tearDown() {
        // Reading/creating configurations can feed the timeout bookkeeping. Put
        // it back as a fresh launch would leave it so unrelated tests are not
        // affected by the order they run in.
        CustomHTTPProtocol.resetTimeoutDecisionTrackingForTesting()
        super.tearDown()
    }

    /// The configuration the demux session was really built with — not a
    /// snapshot the source could take at a convenient moment.
    private var demuxConfiguration: URLSessionConfiguration {
        CustomHTTPProtocol.sharedDemux().session.configuration
    }

    // MARK: - BLOCKING 1: cookies

    /// `config.httpShouldSetCookies = false` stripped `Cookie` from every
    /// request the host app made and left `HTTPCookieStorage.shared` empty.
    /// Cookie-session login stopped working in any app that linked the SDK.
    func testDemuxSessionSendsCookies() {
        XCTAssertTrue(demuxConfiguration.httpShouldSetCookies,
                      "The demux session must send the host app's cookies. Setting "
                      + "httpShouldSetCookies = false strips Cookie from every request the "
                      + "app makes and empties HTTPCookieStorage — cookie logins break.")
    }

    /// Cookie *storage* is the other half: a response's Set-Cookie has to reach
    /// the shared jar, or the next request has nothing to send.
    func testDemuxSessionUsesSharedCookieStorage() {
        XCTAssertTrue(demuxConfiguration.httpCookieStorage === HTTPCookieStorage.shared,
                      "The demux session must use the app's own cookie jar, so Set-Cookie "
                      + "from a response the SDK re-issued still lands in "
                      + "HTTPCookieStorage.shared.")
        XCTAssertEqual(demuxConfiguration.httpCookieAcceptPolicy,
                       HTTPCookieStorage.shared.cookieAcceptPolicy,
                       "The demux session must not accept fewer cookies than the app does.")
    }

    // MARK: - BLOCKING 2: concurrency

    /// `httpMaximumConnectionsPerHost = 1` serialised every request to a host
    /// through a single connection. Its comment claimed it "reduced connection
    /// overhead"; measured, six concurrent 300 ms GETs went from 0.31 s to
    /// 1.87 s — a 6x slowdown the app cannot opt out of.
    func testDemuxSessionDoesNotSerialiseConnectionsPerHost() {
        XCTAssertGreaterThan(
            demuxConfiguration.httpMaximumConnectionsPerHost, 1,
            "Pinning httpMaximumConnectionsPerHost to 1 serialises all traffic to a host. "
            + "Six concurrent 300 ms requests take 1.87 s instead of 0.31 s.")
    }

    // MARK: - MAJOR 3: cache policy

    /// `.reloadIgnoringLocalCacheData` on the session overrode whatever policy
    /// the app set on its own request, so `URLCache` was never consulted.
    func testDemuxSessionDoesNotOverrideTheAppsCachePolicy() {
        XCTAssertEqual(
            demuxConfiguration.requestCachePolicy, .useProtocolCachePolicy,
            "The session-level cache policy must stay at the default, so the policy the "
            + "host app set on its own URLRequest is what governs. Forcing "
            + ".reloadIgnoringLocalCacheData disables the app's URLCache: 3x requests, "
            + "3x data, and .returnCacheDataDontLoad can never succeed.")
    }

    /// The one setting on this session that IS load-bearing, asserted so a
    /// future cleanup does not remove it along with the three above. The
    /// response is stored in the app's URLCache by its own loading system via
    /// `didReceive:cacheStoragePolicy:`; a cache here would store a second copy
    /// of every response. Nothing is lost, because cache READS go through
    /// `cachedResponseDisposition` before a request ever reaches this session.
    func testDemuxSessionKeepsItsOwnCacheDisabledToAvoidDoubleStoring() {
        XCTAssertNil(demuxConfiguration.urlCache,
                     "The demux session must not carry its own URLCache — the host app's "
                     + "loading system already stores the response, so a cache here doubles "
                     + "the bytes on disk for every response.")
    }

    /// Whole-configuration guard: whatever `URLSessionConfiguration.default`
    /// handed the SDK is what the demux session must still have. Catches a
    /// fourth transport setting being added later that these tests do not name.
    func testDemuxTransportSettingsAreUnchangedFromTheSystemDefaults() {
        _ = CustomHTTPProtocol.sharedDemux()
        XCTAssertEqual(CustomHTTPProtocol.demuxTransportSettings,
                       CustomHTTPProtocol.systemDefaultTransportSettings,
                       "SwiftyDebug changed a transport setting between reading "
                       + "URLSessionConfiguration.default and building the demux session. "
                       + "Every such change is imposed on the host app.")
    }

    // MARK: - MAJOR 3: honouring the app's cachedResponse

    func testCacheOnlyRequestIsServedFromTheCachedResponse() {
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .returnCacheDataDontLoad, hasCachedResponse: true, breakpointMode: .off),
            .serveFromCache)
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .returnCacheDataElseLoad, hasCachedResponse: true, breakpointMode: .off),
            .serveFromCache)
    }

    /// `.returnCacheDataDontLoad` with nothing cached must FAIL. Going to the
    /// network is the one thing that policy forbids, and it is what the SDK did.
    func testCacheOnlyMissFailsRatherThanSilentlyHittingTheNetwork() {
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .returnCacheDataDontLoad, hasCachedResponse: false, breakpointMode: .off),
            .failCacheOnlyMiss)
    }

    func testCacheElseLoadMissStillLoads() {
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .returnCacheDataElseLoad, hasCachedResponse: false, breakpointMode: .off),
            .load)
    }

    /// Freshness of a `.useProtocolCachePolicy` entry is HTTP revalidation,
    /// which CFNetwork does upstream. Answering it from cache here would mean
    /// the SDK guessing, and serving a stale body is worse than one extra
    /// request.
    func testProtocolCachePolicyStillLoadsEvenWithACachedEntry() {
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .useProtocolCachePolicy, hasCachedResponse: true, breakpointMode: .off),
            .load)
        XCTAssertEqual(
            CustomHTTPProtocol.cachedResponseDisposition(
                policy: .reloadIgnoringLocalCacheData, hasCachedResponse: true, breakpointMode: .off),
            .load)
    }

    /// An armed breakpoint must not be short-circuited by a cache hit — the
    /// developer asked to intervene, and a pause that never fires with nothing
    /// explaining why is the exact silent no-op the house rules forbid.
    func testArmedBreakpointSuppressesTheCacheShortcut() {
        for mode in [BreakpointMode.beforeSend, .afterResponse] {
            XCTAssertEqual(
                CustomHTTPProtocol.cachedResponseDisposition(
                    policy: .returnCacheDataElseLoad, hasCachedResponse: true, breakpointMode: mode),
                .load,
                "A \(mode.rawValue) breakpoint must still reach the network.")
        }
    }

    // MARK: - MAJOR 5: position in protocolClasses

    private var systemProtocolClasses: [AnyClass] {
        // Built by hand rather than read from a live configuration, so the test
        // is unaffected by whether the protocolClasses getter swizzle happens to
        // be installed in this test run.
        ["_NSURLHTTPProtocol", "_NSURLDataProtocol", "_NSURLFileProtocol"]
            .compactMap { NSClassFromString($0) }
    }

    func testCFNetworkBuiltInsAreRecognisedAsSystemProvided() throws {
        let http = try XCTUnwrap(NSClassFromString("_NSURLHTTPProtocol"),
                                 "CFNetwork's built-in HTTP protocol class was not found; the "
                                 + "ordering rule below depends on recognising it.")
        XCTAssertTrue(CustomHTTPProtocol.isSystemProvidedProtocolClass(http))
        XCTAssertFalse(CustomHTTPProtocol.isSystemProvidedProtocolClass(HostAppStubProtocol.self),
                       "A protocol class defined by the app or its tests is not the system's.")
        XCTAssertFalse(CustomHTTPProtocol.isSystemProvidedProtocolClass(CustomHTTPProtocol.self))
    }

    /// THE regression test for both halves of the ordering bug.
    ///
    /// `insert(at: 0)` — what the SDK used to do — puts SwiftyDebug ahead of the
    /// host app's own URLProtocol, so OHHTTPStubs/Mocker stubs never fire and
    /// the "stubbed" request silently hits the live network.
    ///
    /// A plain `append` breaks it the other way: a stock configuration lists
    /// CFNetwork's `_NSURLHTTPProtocol` FIRST and it claims every http/https
    /// request, so appending means `canInit` is never called and the SDK
    /// captures nothing.
    func testSwiftyDebugSitsAfterHostProtocolsAndBeforeSystemProtocols() throws {
        let system = systemProtocolClasses
        try XCTSkipIf(system.isEmpty, "No CFNetwork protocol classes available to order against.")

        let input: [AnyClass] = [HostAppStubProtocol.self] + system
        let result = try XCTUnwrap(
            CustomHTTPProtocol.protocolClassesInserting(CustomHTTPProtocol.self, into: input))

        let ours = try XCTUnwrap(result.firstIndex { $0 == CustomHTTPProtocol.self })
        let host = try XCTUnwrap(result.firstIndex { $0 == HostAppStubProtocol.self })
        let firstSystem = try XCTUnwrap(result.firstIndex { $0 == system[0] })

        XCTAssertGreaterThan(ours, host,
                             "SwiftyDebug must come AFTER the host app's own URLProtocol. "
                             + "Inserting at index 0 pre-empts OHHTTPStubs/Mocker and sends "
                             + "their stubbed requests to the live network.")
        XCTAssertLessThan(ours, firstSystem,
                          "SwiftyDebug must come BEFORE CFNetwork's _NSURLHTTPProtocol, which "
                          + "claims every http/https request. Appending to the end means "
                          + "canInit is never called and nothing is captured.")
        XCTAssertEqual(result.filter { $0 == CustomHTTPProtocol.self }.count, 1)
        XCTAssertEqual(result.count, input.count + 1, "No existing entry may be dropped.")
    }

    func testAlreadyPresentLeavesTheArrayAlone() {
        let input: [AnyClass] = [HostAppStubProtocol.self, CustomHTTPProtocol.self]
        XCTAssertNil(CustomHTTPProtocol.protocolClassesInserting(CustomHTTPProtocol.self, into: input),
                     "nil means 'leave it alone' — re-inserting would duplicate the entry.")
    }

    func testHostOnlyArrayKeepsHostFirst() throws {
        let result = try XCTUnwrap(
            CustomHTTPProtocol.protocolClassesInserting(CustomHTTPProtocol.self,
                                                        into: [HostAppStubProtocol.self]))
        XCTAssertTrue(result[0] == HostAppStubProtocol.self)
        XCTAssertTrue(result[1] == CustomHTTPProtocol.self)
    }

    func testEmptyArrayGetsSwiftyDebug() throws {
        let result = try XCTUnwrap(
            CustomHTTPProtocol.protocolClassesInserting(CustomHTTPProtocol.self, into: []))
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0] == CustomHTTPProtocol.self)
    }

    /// The same rule, through the real entry point the session-configuration
    /// swizzle uses.
    func testInjectProtocolPreservesHostPriorityOnARealConfiguration() throws {
        let system = systemProtocolClasses
        try XCTSkipIf(system.isEmpty, "No CFNetwork protocol classes available to order against.")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostAppStubProtocol.self] + system
        CustomHTTPProtocol.injectProtocol(into: config)

        let result = config.protocolClasses ?? []
        let ours = try XCTUnwrap(result.firstIndex { $0 == CustomHTTPProtocol.self })
        let host = try XCTUnwrap(result.firstIndex { $0 == HostAppStubProtocol.self })
        let firstSystem = try XCTUnwrap(result.firstIndex { $0 == system[0] })

        XCTAssertGreaterThan(ours, host)
        XCTAssertLessThan(ours, firstSystem)
        XCTAssertEqual(result.filter { $0 == CustomHTTPProtocol.self }.count, 1,
                       "injectProtocol must be idempotent — it runs on every config the app makes.")
    }
}
