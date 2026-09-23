//
//  RequestBodyEndToEndTests.swift
//  SwiftyDebugTests
//
//  The SDK sits in the middle of the host app's uploads. These run a real
//  request through `CustomHTTPProtocol` to a loopback server and compare, byte
//  for byte, what the app asked to send against what actually arrived.
//
//  Nothing leaves the device: the server is a socket on 127.0.0.1 created by
//  the test itself.
//

import XCTest
@testable import SwiftyDebug

/// A one-shot HTTP/1.1 server on 127.0.0.1 that records the request body it
/// received. Understands both `Content-Length` and `Transfer-Encoding: chunked`,
/// because a streamed upload with no known length uses the latter.
final class LoopbackEchoServer {

    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let ready = DispatchSemaphore(value: 0)
    private let received = DispatchSemaphore(value: 0)
    private var body = Data()
    private var headerBlock = ""

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "loopback", code: 1) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // let the kernel pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { throw NSError(domain: "loopback", code: 2) }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &length) }
        }
        port = actual.sin_port.bigEndian == 0 ? actual.sin_port : actual.sin_port.bigEndian

        Thread { [weak self] in self?.serve() }.start()
        ready.signal()
    }

    func stop() { if listenFD >= 0 { close(listenFD); listenFD = -1 } }

    /// Blocks until a request has been fully read, then returns its body.
    func waitForBody(timeout: TimeInterval = 15) -> Data? {
        received.wait(timeout: .now() + timeout) == .success ? body : nil
    }

    private func serve() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { received.signal(); return }
        defer { close(clientFD); received.signal() }

        var raw = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        func readMore() -> Bool {
            let n = recv(clientFD, &chunk, chunk.count, 0)
            guard n > 0 else { return false }
            raw.append(chunk, count: n)
            return true
        }

        // Headers first.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, !readMore() { return }
        }
        guard let end = headerEnd else { return }
        headerBlock = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        var rest = Data(raw[end.upperBound...])

        let lowered = headerBlock.lowercased()
        if lowered.contains("transfer-encoding: chunked") {
            // De-chunk: <hex size>\r\n<data>\r\n ... 0\r\n\r\n
            var decoded = Data()
            var cursor = 0
            while true {
                guard let lineEnd = rest.range(of: Data("\r\n".utf8),
                                               in: rest.index(rest.startIndex, offsetBy: cursor)..<rest.endIndex) else {
                    if !readMore() { break }
                    rest.append(Data(raw.suffix(from: raw.count)))   // recv already appended to raw
                    rest = Data(raw[end.upperBound...])
                    continue
                }
                let sizeText = String(decoding: rest[rest.index(rest.startIndex, offsetBy: cursor)..<lineEnd.lowerBound],
                                      as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let size = Int(sizeText.split(separator: ";").first.map(String.init) ?? sizeText, radix: 16) ?? 0
                let dataStart = rest.distance(from: rest.startIndex, to: lineEnd.upperBound)
                if size == 0 { body = decoded; return }
                while rest.count < dataStart + size + 2 {
                    if !readMore() { body = decoded; return }
                    rest = Data(raw[end.upperBound...])
                }
                decoded.append(rest[rest.index(rest.startIndex, offsetBy: dataStart)
                                    ..< rest.index(rest.startIndex, offsetBy: dataStart + size)])
                cursor = dataStart + size + 2
            }
            body = decoded
            return
        }

        var contentLength = 0
        for line in headerBlock.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        while rest.count < contentLength {
            if !readMore() { break }
            rest = Data(raw[end.upperBound...])
        }
        body = Data(rest.prefix(contentLength))

        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        _ = Array(response.utf8).withUnsafeBufferPointer { send(clientFD, $0.baseAddress, $0.count, 0) }
    }
}

final class RequestBodyEndToEndTests: XCTestCase {

    private var server: LoopbackEchoServer!
    private var savedActive = false
    private var savedNetworkEnabled = false
    private var savedRequestsEnabled = false
    private var savedMonitorAll = false

    /// What `startLoading` reported for the most recent request.
    private var observedBody: Data?
    private var observedPath = "none"

    override func setUp() {
        super.setUp()
        savedActive = SwiftyDebugRuntime.isActive
        savedNetworkEnabled = NetworkMonitor.shared.isNetworkEnable
        savedRequestsEnabled = Settings.shared.networkRequestsEnabled
        savedMonitorAll = SwiftyDebug.monitorAllUrls

        SwiftyDebugRuntime.markActive()
        NetworkMonitor.shared.isNetworkEnable = true
        Settings.shared.networkRequestsEnabled = true
        SwiftyDebug.monitorAllUrls = true

        CustomHTTPProtocol.requestBodyCaptureObserverForTesting = { [weak self] body, path in
            self?.observedBody = body
            self?.observedPath = path
        }

        server = LoopbackEchoServer()
        try? server.start()
    }

    override func tearDown() {
        CustomHTTPProtocol.requestBodyCaptureObserverForTesting = nil
        server?.stop()
        SwiftyDebug.monitorAllUrls = savedMonitorAll
        Settings.shared.networkRequestsEnabled = savedRequestsEnabled
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        if savedActive { SwiftyDebugRuntime.markActive() } else { SwiftyDebugRuntime.markStopped() }
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    // MARK: - The regression

    /// The ordinary case, and the one that was broken: a plain `httpBody` POST.
    /// The loading system turns it into a stream before the SDK sees it, so if
    /// the SDK does not read that stream there is no captured body at all — and
    /// the request detail screen shows nothing.
    func testAPlainBodyArrivesIntactAndIsCaptured() throws {
        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        var request = URLRequest(url: url("/plain"))
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        observedPath = "none"
        observedBody = nil
        let done = expectation(description: "request finished")
        session().dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 20)

        XCTAssertEqual(observedPath, "eof",
                       "A plain body is fully available, so it must drain whole and "
                       + "become `httpBody`.")
        let arrived = try XCTUnwrap(server.waitForBody(), "the server never received a request")
        XCTAssertEqual(arrived, payload,
                       "The bytes on the wire must be exactly the bytes the app asked to send.")

        let captured = try XCTUnwrap(observedBody,
                                     "REGRESSION: no request body was captured, so the detail "
                                     + "screen shows none. URLProtocol never sees `httpBody` — "
                                     + "the stream has to be read.")
        XCTAssertEqual(captured, payload, "The captured body must be the body, not a fragment.")
    }

    /// The case the drain used to corrupt: a bound-pair stream whose producer is
    /// still writing when the request starts. Every byte must still arrive, in
    /// order — the head included.
    func testAStreamedBodyWithALateProducerArrivesWhole() throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &input, outputStream: &output)
        let readEnd = try XCTUnwrap(input)
        let writeEnd = try XCTUnwrap(output)

        let head = Data("HEAD-OF-THE-MULTIPART-BODY;".utf8)
        let tail = Data("...TAIL-WRITTEN-LATER".utf8)
        writeEnd.open()
        _ = head.withUnsafeBytes { writeEnd.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: head.count) }

        var request = URLRequest(url: url("/streamed"))
        request.httpMethod = "POST"
        request.httpBodyStream = readEnd

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            _ = tail.withUnsafeBytes {
                writeEnd.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: tail.count)
            }
            writeEnd.close()
        }

        observedPath = "none"
        observedBody = nil
        let done = expectation(description: "request finished")
        session().dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 25)

        XCTAssertEqual(observedPath, "resumed",
                       """
                       This test is only meaningful if it took the RESUME path: the \
                       producer had not finished, bytes were taken, and they had to be \
                       handed back. On the `eof` path the assertion below proves nothing.
                       """)
        let arrived = try XCTUnwrap(server.waitForBody(), "the server never received a request")
        XCTAssertEqual(arrived, head + tail,
                       """
                       The upload arrived corrupted. Every byte the app wrote has to reach the \
                       server, in order — the SDK draining the head and dropping it is exactly \
                       the defect this pins.
                       """)
    }

    /// A body past the drain ceiling takes the forwarding path — and every byte
    /// still has to arrive, in order, through CFNetwork and the pump.
    func testABodyLargerThanTheDrainCapStillArrivesIntact() throws {
        let payload = Data((0..<(CustomHTTPProtocol.maxDrainedRequestBodyBytes + 300_000))
                            .map { UInt8($0 % 251) })
        var request = URLRequest(url: url("/oversize"))
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        observedPath = "none"
        observedBody = nil
        let pumpsBefore = CustomHTTPProtocol.livePumpCountForTesting
        let done = expectation(description: "request finished")
        session().dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 30)

        XCTAssertEqual(observedPath, "resumed",
                       "Past the ceiling the body must be forwarded, not buffered.")
        let arrived = try XCTUnwrap(server.waitForBody(timeout: 25),
                                    "the server never received a request")
        XCTAssertEqual(arrived.count, payload.count,
                       "Every byte past the ceiling has to reach the server too.")
        XCTAssertEqual(arrived, payload, "...and in the right order.")

        XCTAssertLessThanOrEqual(observedBody?.count ?? 0,
                                 CustomHTTPProtocol.maxDrainedRequestBodyBytes + 64 * 1024,
                                 "Capture stays bounded; that is the point of the ceiling.")

        // And the pump that carried it must not still be running.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, CustomHTTPProtocol.livePumpCountForTesting > pumpsBefore {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(CustomHTTPProtocol.livePumpCountForTesting, pumpsBefore,
                       "The pump must exit once the body is through.")
    }
}
