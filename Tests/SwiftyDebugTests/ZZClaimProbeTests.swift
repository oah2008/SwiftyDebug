//
//  ZZClaimProbeTests.swift  (TEMPORARY REVIEW PROBE — delete after reading)
//

import XCTest
@testable import SwiftyDebug

// MARK: - A. Does a slow startLoading stall other requests?

final class ConcurrencyProbeProtocol: URLProtocol {
    struct Entry { let path: String; let thread: String; let at: TimeInterval }
    static let lock = NSLock()
    static var entries: [Entry] = []
    static var t0: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "conc-probe.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? "?"
        let th = "\(Thread.current)"
        Self.lock.lock()
        Self.entries.append(Entry(path: path, thread: th,
                                  at: Date().timeIntervalSince1970 - Self.t0))
        Self.lock.unlock()
        if path.hasPrefix("/slow") { Thread.sleep(forTimeInterval: 2.0) }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

final class ZZConcurrencyProbeTests: XCTestCase {

    private func run(session: URLSession, label: String) {
        ConcurrencyProbeProtocol.lock.lock()
        ConcurrencyProbeProtocol.entries = []
        ConcurrencyProbeProtocol.t0 = Date().timeIntervalSince1970
        ConcurrencyProbeProtocol.lock.unlock()

        var exps: [XCTestExpectation] = []
        func fire(_ path: String) {
            let e = expectation(description: path)
            exps.append(e)
            let url = URL(string: "https://conc-probe.invalid\(path)")!
            session.dataTask(with: url) { _, _, _ in e.fulfill() }.resume()
        }
        fire("/slow")
        Thread.sleep(forTimeInterval: 0.3)
        fire("/fast-1")
        fire("/fast-2")
        fire("/fast-3")
        wait(for: exps, timeout: 30)

        ConcurrencyProbeProtocol.lock.lock()
        let entries = ConcurrencyProbeProtocol.entries
        ConcurrencyProbeProtocol.lock.unlock()
        for e in entries.sorted(by: { $0.at < $1.at }) {
            print(String(format: "PROBE-A[\(label)] %@ enteredStartLoading@%.3fs thread=%@",
                         e.path, e.at, e.thread))
        }
    }

    func testSlowStartLoadingOnAnOwnedSession() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ConcurrencyProbeProtocol.self]
        let session = URLSession(configuration: cfg)
        run(session: session, label: "own-session")
        session.invalidateAndCancel()
    }

    func testSlowStartLoadingOnURLSessionShared() {
        URLProtocol.registerClass(ConcurrencyProbeProtocol.self)
        defer { URLProtocol.unregisterClass(ConcurrencyProbeProtocol.self) }
        run(session: URLSession.shared, label: "shared")
    }
}

// MARK: - B. Is a file-backed InputStream reachable, and what does draining it cost?

final class FileStreamProbeProtocol: URLProtocol {
    static var sawStream = false
    static var sameObject = false
    static var appStream: InputStream?
    static var drainedBytes = -1
    static var reachedEOF = false
    static var drainSeconds: Double = -1
    static var peakNote = ""

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "file-stream-probe.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let copy = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        Self.sawStream = copy.httpBodyStream != nil
        Self.sameObject = (copy.httpBodyStream === Self.appStream)
        if let s = copy.httpBodyStream {
            let t = Date()
            let out = CustomHTTPProtocol.drainBody(from: s)
            Self.drainSeconds = Date().timeIntervalSince(t)
            Self.drainedBytes = out.data.count
            Self.reachedEOF = out.reachedEOF
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

final class ZZFileStreamProbeTests: XCTestCase {

    func testFileBackedBodyStreamReachesTheProtocolAndIsFullyDrained() throws {
        let size = 32 * 1024 * 1024   // 32 MB stand-in for the "200 MB upload"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-body-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: size).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let stream = InputStream(url: url) else { return XCTFail("no stream") }
        FileStreamProbeProtocol.appStream = stream

        URLProtocol.registerClass(FileStreamProbeProtocol.self)
        defer { URLProtocol.unregisterClass(FileStreamProbeProtocol.self) }

        var req = URLRequest(url: URL(string: "https://file-stream-probe.invalid/up")!)
        req.httpMethod = "POST"
        req.httpBodyStream = stream

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FileStreamProbeProtocol.self]
        let session = URLSession(configuration: cfg)
        let done = expectation(description: "done")
        session.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 60)
        session.invalidateAndCancel()

        print("PROBE-B sawStream=\(FileStreamProbeProtocol.sawStream) "
              + "sameObject=\(FileStreamProbeProtocol.sameObject) "
              + "drained=\(FileStreamProbeProtocol.drainedBytes)/\(size) "
              + "eof=\(FileStreamProbeProtocol.reachedEOF) "
              + String(format: "drainSeconds=%.3f", FileStreamProbeProtocol.drainSeconds))
    }

    /// Does `uploadTask(with:fromFile:)` — the normal way to upload a big file —
    /// even present a body stream to a URLProtocol?
    func testUploadTaskFromFileShape() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-upload-\(UUID().uuidString).bin")
        try Data(repeating: 0x42, count: 4 * 1024 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        FileStreamProbeProtocol.appStream = nil
        FileStreamProbeProtocol.sawStream = false
        FileStreamProbeProtocol.drainedBytes = -1

        URLProtocol.registerClass(FileStreamProbeProtocol.self)
        defer { URLProtocol.unregisterClass(FileStreamProbeProtocol.self) }

        var req = URLRequest(url: URL(string: "https://file-stream-probe.invalid/upload-task")!)
        req.httpMethod = "POST"

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FileStreamProbeProtocol.self]
        let session = URLSession(configuration: cfg)
        let done = expectation(description: "done")
        session.uploadTask(with: req, fromFile: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 60)
        session.invalidateAndCancel()

        print("PROBE-B2 uploadTaskFromFile sawStream=\(FileStreamProbeProtocol.sawStream) "
              + "drained=\(FileStreamProbeProtocol.drainedBytes) "
              + "eof=\(FileStreamProbeProtocol.reachedEOF)")
    }
}

// MARK: - C. Does upload progress reach the app at all through a custom protocol?

final class ProgressProbeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "progress-probe.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Consume the body the way SwiftyDebug does, then answer 200.
        if let s = request.httpBodyStream { _ = CustomHTTPProtocol.drainBody(from: s) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProgressSpy: NSObject, URLSessionTaskDelegate {
    var callbacks: [(Int64, Int64)] = []
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        callbacks.append((totalBytesSent, totalBytesExpectedToSend))
    }
}

final class ZZProgressProbeTests: XCTestCase {
    func testUploadProgressThroughACustomURLProtocol() {
        let spy = ProgressSpy()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProgressProbeProtocol.self]
        let session = URLSession(configuration: cfg, delegate: spy, delegateQueue: nil)

        var req = URLRequest(url: URL(string: "https://progress-probe.invalid/up")!)
        req.httpMethod = "POST"
        req.httpBody = Data(repeating: 0x43, count: 8 * 1024 * 1024)

        let done = expectation(description: "done")
        session.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 60)
        session.invalidateAndCancel()

        print("PROBE-C didSendBodyData callbacks=\(spy.callbacks.count) values=\(spy.callbacks.prefix(5))")
    }
}
