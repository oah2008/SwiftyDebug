//
//  StreamingProgressTests.swift
//  SwiftyDebugTests
//
//  "When the tool is enabled, the download progress closure stops reporting."
//
//  An image library computes download progress purely from how many
//  `URLSessionDataDelegate` data callbacks its session receives. SwiftyDebug's
//  plain capture path forwards chunks 1:1 and was never the problem — but four
//  paths hand the app the whole body in ONE call (a mock, a URLCache replay, a
//  released `.afterResponse` breakpoint, an abandoned rewrite hold), and an
//  armed breakpoint on a media response holds it indefinitely, so progress never
//  fires at all.
//

import XCTest
@testable import SwiftyDebug

final class StreamingProgressTests: XCTestCase {

    private func response(mime: String?, length: Int64 = 1024, url: String = "https://cdn.test/asset") -> URLResponse {
        URLResponse(url: URL(string: url)!,
                    mimeType: mime,
                    expectedContentLength: Int(length),
                    textEncodingName: nil)
    }

    // MARK: - What may be buffered

    func testMediaResponsesAreNeverHeld() {
        for mime in ["image/jpeg", "image/png", "image/webp", "video/mp4", "audio/mpeg", "font/woff2"] {
            XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(response(mime: mime), requestURL: nil),
                           "\(mime) must stream")
        }
    }

    func testBinaryDownloadsAreNeverHeld() {
        for mime in ["application/octet-stream", "application/pdf", "application/zip", "application/wasm"] {
            XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(response(mime: mime), requestURL: nil),
                           "\(mime) must stream")
        }
    }

    /// Open-ended streams are the worst case: holding one means the app receives
    /// nothing, forever. `text/event-stream` passes the `text/` test the rewrite
    /// pre-filter uses, so it has to be refused explicitly.
    func testOpenEndedStreamsAreNeverHeld() {
        for mime in ["text/event-stream", "application/x-ndjson", "application/stream+json",
                     "multipart/x-mixed-replace; boundary=frame"] {
            XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(response(mime: mime, length: -1), requestURL: nil),
                           "\(mime) must stream")
        }
    }

    /// A response carrying no Content-Type at all. `URLResponse` substitutes
    /// `application/octet-stream` for a nil type — measured — so the genuinely
    /// empty case needs a stub to reach the URL fallback at all.
    private final class TypelessResponse: URLResponse {
        override var mimeType: String? { nil }
    }

    private func typeless(url: String) -> URLResponse {
        TypelessResponse(url: URL(string: url)!, mimeType: nil,
                         expectedContentLength: 1024, textEncodingName: nil)
    }

    func testATypelessResponseFallsBackToWhatTheURLSaysItIs() {
        XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(
            typeless(url: "https://cdn.test/photo.jpg"),
            requestURL: URL(string: "https://cdn.test/photo.jpg")),
            "a CDN serving photo.jpg with no Content-Type must still stream")

        XCTAssertTrue(CustomHTTPProtocol.responseIsHoldable(
            typeless(url: "https://api.test/v1/items"),
            requestURL: URL(string: "https://api.test/v1/items")),
            "a typeless response that does not look like an asset stays holdable")
    }

    /// And the practical case: Foundation's own substitution already lands on
    /// octet-stream, which is refused — so a missing Content-Type never results
    /// in a buffered download either way.
    func testAResponseBuiltWithNoMimeTypeIsRefusedByFoundationsSubstitution() {
        let substituted = response(mime: nil, url: "https://api.test/v1/items")
        XCTAssertEqual(substituted.mimeType, "application/octet-stream")
        XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(substituted, requestURL: nil))
    }

    func testAResponseLargerThanTheCaptureCapIsNeverHeld() {
        let huge = Int64(CustomHTTPProtocol.maxCapturedResponseBytes) + 1
        XCTAssertFalse(CustomHTTPProtocol.responseIsHoldable(response(mime: "application/json", length: huge),
                                                             requestURL: nil))
    }

    /// The boundary of the change: a JSON document is still holdable, so
    /// breakpoints and rewrites keep working on the bodies they exist for.
    func testJSONAndTextResponsesAreStillHoldable() {
        for mime in ["application/json", "application/vnd.api+json", "text/plain", "text/html"] {
            XCTAssertTrue(CustomHTTPProtocol.responseIsHoldable(response(mime: mime), requestURL: nil),
                          "\(mime) must remain holdable")
        }
    }

    // MARK: - Saying so out loud

    /// An armed rule that silently does nothing is the failure mode this codebase
    /// keeps producing; both stand-down paths must name themselves.
    func testStandDownMessagesNameTheTypeAndTheReason() {
        let breakpoint = CustomHTTPProtocol.streamingPreemptedBreakpointMessage(mimeType: "image/jpeg")
        XCTAssertTrue(breakpoint.contains("image/jpeg"))
        XCTAssertTrue(breakpoint.lowercased().contains("progress"))

        let rewrite = CustomHTTPProtocol.streamingPreemptedRewriteMessage(mimeType: "video/mp4")
        XCTAssertTrue(rewrite.contains("video/mp4"))
        XCTAssertTrue(rewrite.lowercased().contains("progress"))

        XCTAssertFalse(CustomHTTPProtocol.streamingPreemptedBreakpointMessage(mimeType: nil).isEmpty)
        XCTAssertFalse(CustomHTTPProtocol.streamingPreemptedRewriteMessage(mimeType: "").isEmpty)
    }

    // MARK: - Chunked delivery

    /// Records what a URLProtocol hands its client.
    private final class RecordingClient: NSObject, URLProtocolClient {
        var chunks: [Data] = []
        var finished = false
        var finishedAfterChunks: Int?

        func urlProtocol(_ p: URLProtocol, didLoad data: Data) { chunks.append(data) }
        func urlProtocolDidFinishLoading(_ p: URLProtocol) {
            finished = true
            finishedAfterChunks = chunks.count
        }
        func urlProtocol(_ p: URLProtocol, didReceive r: URLResponse, cacheStoragePolicy: URLCache.StoragePolicy) {}
        func urlProtocol(_ p: URLProtocol, didFailWithError error: Error) {}
        func urlProtocol(_ p: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
        func urlProtocol(_ p: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
        func urlProtocol(_ p: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
        func urlProtocol(_ p: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
    }

    private func makeProtocol(_ client: RecordingClient) -> CustomHTTPProtocol {
        CustomHTTPProtocol(request: URLRequest(url: URL(string: "https://cdn.test/asset.bin")!),
                           cachedResponse: nil,
                           client: client)
    }

    func testABodyIsDeliveredAsManyChunksAndOnlyThenFinishes() {
        let client = RecordingClient()
        let proto = makeProtocol(client)
        let body = Data(repeating: 0xAB, count: 640 * 1024)

        let done = expectation(description: "delivered")
        proto.deliverBodyInChunks(body, chunkSize: 64 * 1024) { done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(client.chunks.count, 10, "one callback per chunk")
        XCTAssertEqual(client.chunks.reduce(Data(), +), body, "the bytes are identical to a single delivery")
    }

    /// The ordering trap: chunks are scheduled, so a caller that finishes inline
    /// would finish before the body arrived.
    func testFinishHappensAfterEveryChunk() {
        let client = RecordingClient()
        let proto = makeProtocol(client)
        let body = Data(repeating: 0x01, count: 200 * 1024)

        let done = expectation(description: "delivered")
        proto.deliverBodyInChunks(body, chunkSize: 32 * 1024) {
            client.urlProtocolDidFinishLoading(proto)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(client.finished)
        XCTAssertEqual(client.finishedAfterChunks, client.chunks.count)
        XCTAssertGreaterThan(client.chunks.count, 1)
    }

    func testASmallBodyIsStillASingleCallback() {
        let client = RecordingClient()
        let proto = makeProtocol(client)
        let body = Data(repeating: 0x02, count: 128)

        let done = expectation(description: "delivered")
        proto.deliverBodyInChunks(body, chunkSize: 64 * 1024) { done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(client.chunks.count, 1)
        XCTAssertEqual(client.chunks.first, body)
    }

    func testAnEmptyBodyDeliversNothingAndStillCompletes() {
        let client = RecordingClient()
        let proto = makeProtocol(client)
        let done = expectation(description: "delivered")
        proto.deliverBodyInChunks(Data(), chunkSize: 1024) { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(client.chunks.isEmpty)
    }

    // MARK: - Byte order

    /// The chunk chain is SCHEDULED, one runloop turn apart. `abandonHold` runs
    /// from the middle of `didReceive data`, and the bytes that triggered it are
    /// streamed to the client inline on the very next statement — so chunking the
    /// buffered head there delivered the newer chunk FIRST and handed the app a
    /// body with its middle transposed. The flush must stay synchronous.
    func testAbandonedHoldFlushesItsBufferBeforeStreamingResumes() throws {
        let source = try XCTUnwrap(
            String(contentsOfFile: "\(Self.sourceRoot)/Sources/Networking/CustomHTTPProtocol.swift",
                   encoding: .utf8))
        let body = try XCTUnwrap(Self.functionBody(named: "abandonHold", in: source),
                                 "abandonHold not found")
        XCTAssertFalse(body.contains("deliverBodyInChunks"),
                       """
                       abandonHold must flush its buffer in ONE synchronous didLoad.                        Scheduling it interleaves the buffered head with the live chunk                        that is delivered inline immediately afterwards, which transposes                        the body the app receives.
                       """)
        XCTAssertTrue(body.contains("didLoad: buffered"),
                      "abandonHold must still deliver what it buffered")
    }

    /// Every terminal path must stop the scheduled chain — not just `stopLoading`.
    /// A chunk queued before a failure would otherwise arrive after
    /// `didFailWithError`, delivering bytes into a finished loading context.
    func testEveryFailureDeliveryMarksTheLoadTerminated() throws {
        let source = try XCTUnwrap(
            String(contentsOfFile: "\(Self.sourceRoot)/Sources/Networking/CustomHTTPProtocol.swift",
                   encoding: .utf8))
        let lines = source.components(separatedBy: "\n")
        var unguarded: [Int] = []
        for (index, line) in lines.enumerated() where line.contains("didFailWithError:") {
            let preceding = lines[max(0, index - 3)..<index].joined()
            if !preceding.contains("markTerminated()") { unguarded.append(index + 1) }
        }
        XCTAssertTrue(unguarded.isEmpty,
                      "didFailWithError at line(s) \(unguarded) does not mark the load terminated first")
    }

    private static var sourceRoot: String {
        // .../Tests/SwiftyDebugTests/StreamingProgressTests.swift -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// The text between a function's opening and matching closing brace.
    private static func functionBody(named name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - Request fidelity

    /// The SDK must not change what the app asks for. Forcing `gzip, deflate`
    /// stripped brotli from every request the host app made.
    func testTheSDKDoesNotForceAnAcceptEncodingOnTheHostApp() {
        var request = URLRequest(url: URL(string: "https://api.test/v1/items")!)
        request.httpMethod = "GET"
        let canonical = CanonicalRequestForRequest(request)
        XCTAssertNil(canonical.value(forHTTPHeaderField: "Accept-Encoding"))
    }
}
