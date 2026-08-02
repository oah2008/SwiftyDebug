//
//  BeforeSendBreakpointEditingTests.swift
//  SwiftyDebugTests
//
//  The breakpoint picker promises that "before send" pauses the request "so you
//  can edit it" (`BreakpointMode.beforeSend.detail`), and `PausedRequest.request`
//  is a `var` that the protocol's resume handler sends verbatim. The screen that
//  opens on that pause offered nothing but "Send request" and "Abort request":
//  the stage existed, the transport supported it, and there was no way to reach
//  it from the UI.
//
//  Two halves are pinned here, because either one alone can be broken while the
//  other still looks right:
//
//   1. the SCREEN produces an edited request (unit, no network), and
//   2. the TRANSPORT puts that edited request on the wire, and the captured
//      transaction describes what was actually sent (end-to-end against a real
//      socket server, through the real CustomHTTPProtocol).
//

import XCTest
import UIKit
@testable import SwiftyDebug

// MARK: - Minimal in-process HTTP server that RECORDS what it received

/// Answers every request with one fixed JSON body, and keeps the request line,
/// headers and body of everything it was sent — which is the only way to prove
/// an edit made at a breakpoint actually reached the wire.
private final class RecordingHTTPServer {

    struct Received {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    enum ServerError: Error { case socket, bind, listen }

    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let responseBody: Data
    private let acceptQueue = DispatchQueue(label: "swiftydebug.tests.recordinghttp")
    private let lock = NSLock()
    private var _received: [Received] = []
    private var isRunning = false

    init(body: Data) { self.responseBody = body }

    var received: [Received] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ServerError.socket }

        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listenFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ServerError.bind }
        guard Darwin.listen(listenFD, 16) == 0 else { throw ServerError.listen }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFD, sa, &len)
            }
        }
        port = UInt16(bigEndian: assigned.sin_port)

        isRunning = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        isRunning = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    func url(path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &clientAddr, &clientLen)
            if fd < 0 {
                if errno == EINTR && isRunning { continue }
                break
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            handle(fd)
            close(fd)
        }
    }

    private func handle(_ fd: Int32) {
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)

        // 1. Head.
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
            headEnd = raw.range(of: Data("\r\n\r\n".utf8))
            if raw.count > 256 * 1024 { break }
        }
        guard let separator = headEnd,
              let head = String(data: raw[raw.startIndex..<separator.lowerBound], encoding: .utf8)
        else { return }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        // 2. Body, if the head declared one.
        var body = Data(raw[separator.upperBound...])
        let declared = Int(headers["content-length"] ?? "") ?? 0
        while body.count < declared {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            body.append(contentsOf: buf[0..<n])
        }

        lock.lock()
        _received.append(Received(method: parts.first ?? "",
                                  path: parts.count > 1 ? parts[1] : "",
                                  headers: headers,
                                  body: body))
        lock.unlock()

        var responseHead = "HTTP/1.1 200 OK\r\n"
        responseHead += "Content-Type: application/json\r\n"
        responseHead += "Content-Length: \(responseBody.count)\r\n"
        responseHead += "Connection: close\r\n\r\n"
        var out = Data(responseHead.utf8)
        out.append(responseBody)
        writeAll(fd, out)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let n = write(fd, base + sent, rawBuffer.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - Tests

final class BeforeSendBreakpointEditingTests: XCTestCase {

    private static let serverBody = Data(#"{"from":"server"}"#.utf8)

    private var server: RecordingHTTPServer!
    private var savedExtendTimeouts = false
    private var savedHoldSeconds: TimeInterval = 0

    override func setUpWithError() throws {
        try super.setUpWithError()

        SwiftyDebugRuntime.markActive()
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.urls = []
        Settings.shared.networkConditionerPreset = .off
        NetworkMonitor.shared.enable()
        CustomHTTPProtocol.swizzleSessionConfiguration()

        // Written straight through to UserDefaults, which the test host shares
        // with the app — both are restored in tearDown.
        savedExtendTimeouts = Settings.shared.extendTimeoutsForBreakpoints
        savedHoldSeconds = Settings.shared.breakpointHoldSeconds
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600

        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        BreakpointCenter.shared.clearNotices()
        InterceptRuleStore.shared.removeAll()

        server = RecordingHTTPServer(body: Self.serverBody)
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server did not bind an ephemeral port")
    }

    override func tearDownWithError() throws {
        Settings.shared.extendTimeoutsForBreakpoints = savedExtendTimeouts
        Settings.shared.breakpointHoldSeconds = savedHoldSeconds
        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        BreakpointCenter.shared.clearNotices()
        InterceptRuleStore.shared.removeAll()
        NetworkMonitor.shared.disable()
        SwiftyDebug.monitorAllUrls = false
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func armBeforeSend(onPath path: String) {
        var rule = InterceptRule(matchEndpoint: path, matchMode: .exact)
        rule.breakpointMode = .beforeSend
        rule.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertEqual(InterceptRuleStore.shared.resolvedRule(forURL: server.url(path: path))?.breakpointMode,
                       .beforeSend,
                       "breakpoint rule did not resolve — the rest of the test would be meaningless")
    }

    /// Every row title the screen currently renders, section by section. Read
    /// through the data source, so it is what a user would actually see.
    private func rowTitles(of vc: BreakpointDetailViewController) -> [String] {
        var titles: [String] = []
        for section in 0..<vc.numberOfSections(in: vc.tableView) {
            for row in 0..<vc.tableView(vc.tableView, numberOfRowsInSection: section) {
                let ip = IndexPath(row: row, section: section)
                let cell = vc.tableView(vc.tableView, cellForRowAt: ip)
                titles.append(cell.textLabel?.text ?? "")
            }
        }
        return titles
    }

    private func indexPath(of title: String, in vc: BreakpointDetailViewController) -> IndexPath? {
        for section in 0..<vc.numberOfSections(in: vc.tableView) {
            for row in 0..<vc.tableView(vc.tableView, numberOfRowsInSection: section) {
                let ip = IndexPath(row: row, section: section)
                if vc.tableView(vc.tableView, cellForRowAt: ip).textLabel?.text == title { return ip }
            }
        }
        return nil
    }

    /// The screen as it is really used: inside a navigation controller, view
    /// loaded, laid out.
    private func makeScreen(for paused: BreakpointCenter.PausedRequest) -> BreakpointDetailViewController {
        let vc = BreakpointDetailViewController(paused: paused)
        let nav = SwiftyDebugNavigationController(rootViewController: vc)
        nav.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.loadViewIfNeeded()
        vc.view.frame = nav.view.bounds
        vc.tableView.reloadData()
        vc.view.layoutIfNeeded()
        return vc
    }

    // MARK: - 1. The screen produces an edited request (no network)

    /// The reported defect, stated positively: a before-send pause has to offer
    /// the four things the picker promises — method, URL, headers and body.
    func testBeforeSendScreenOffersMethodURLHeadersAndBodyRows() throws {
        var request = URLRequest(url: URL(string: "https://example.com/original")!)
        request.httpMethod = "POST"
        request.setValue("yes", forHTTPHeaderField: "X-Original")
        request.httpBody = Data(#"{"who":"app"}"#.utf8)

        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request, resume: { _ in }, abort: {})
        let vc = makeScreen(for: paused)
        let titles = rowTitles(of: vc)

        XCTAssertTrue(titles.contains("Method"),
                      "A before-send pause exists to edit the OUTGOING request; without a method "
                      + "row the picker's promise is false. Rows were: \(titles)")
        XCTAssertTrue(titles.contains("URL"), "No URL row. Rows were: \(titles)")
        XCTAssertTrue(titles.contains("X-Original"),
                      "The request's own headers must be listed as editable rows. Rows were: \(titles)")
        XCTAssertTrue(titles.contains("Add header"), "No way to add a header. Rows were: \(titles)")
        XCTAssertTrue(titles.contains("Send request"), "Rows were: \(titles)")
        XCTAssertTrue(titles.contains("Abort request"), "Rows were: \(titles)")
        // The body is the shared JSON card (no textLabel), exactly as the
        // after-response side edits its body — so assert on the card itself.
        XCTAssertNotNil(bodyCard(in: vc),
                        "A JSON body has to open in the same editor the after-response side uses.")
    }

    /// Tapping "Send request" must hand the resume handler the EDITED request —
    /// this is the whole hand-off, and it is what the transport already honours.
    func testTappingSendHandsTheEditedRequestToTheResumeHandler() throws {
        var request = URLRequest(url: URL(string: "https://example.com/original")!)
        request.httpMethod = "POST"
        request.setValue("yes", forHTTPHeaderField: "X-Original")
        request.setValue("13", forHTTPHeaderField: "Content-Length")
        request.httpBody = Data(#"{"who":"app"}"#.utf8)

        var delivered: URLRequest?
        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request,
            resume: { delivered = $0.request }, abort: {})
        BreakpointCenter.shared.park(paused)

        let vc = makeScreen(for: paused)
        vc.applyMethod("put")
        XCTAssertTrue(vc.applyURLString("https://example.com/edited?x=1"))
        XCTAssertTrue(vc.applyHeader(name: "X-Edited", value: "1", at: nil))
        vc.applyRequestBody(#"{"who":"developer"}"#)

        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)

        let sent = try XCTUnwrap(delivered, "Send request never released the parked request.")
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.url?.absoluteString, "https://example.com/edited?x=1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Edited"), "1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Original"), "yes",
                       "Editing one header must not drop the others.")
        XCTAssertEqual(sent.httpBody, Data(#"{"who":"developer"}"#.utf8))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Length"), "19",
                       "An edited body behind the original Content-Length makes the server read "
                       + "the wrong number of bytes.")
    }

    /// Deleting a header has to reach the wire too — a row that disappears from
    /// the screen while the header still goes out is worse than no editing.
    func testDeletingAHeaderRemovesItFromTheRequestThatIsSent() throws {
        var request = URLRequest(url: URL(string: "https://example.com/original")!)
        request.setValue("yes", forHTTPHeaderField: "X-Original")
        request.setValue("keep", forHTTPHeaderField: "X-Keep")

        var delivered: URLRequest?
        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request,
            resume: { delivered = $0.request }, abort: {})
        let vc = makeScreen(for: paused)

        let doomed = try XCTUnwrap(indexPath(of: "X-Original", in: vc))
        let actions = vc.tableView(vc.tableView, trailingSwipeActionsConfigurationForRowAt: doomed)
        let delete = try XCTUnwrap(actions?.actions.first, "No delete action on a header row.")
        delete.handler(delete, UIView()) { _ in }

        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)

        let sent = try XCTUnwrap(delivered)
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Original"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Keep"), "keep")
    }

    /// A URL the request cannot be sent to is refused, and refused *visibly*:
    /// `applyURLString` reports failure so the caller can say so, and the request
    /// keeps the URL the screen is still showing.
    func testAnUnusableURLIsRefusedAndTheRequestKeepsItsOwn() throws {
        let request = URLRequest(url: URL(string: "https://example.com/original")!)
        var delivered: URLRequest?
        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request,
            resume: { delivered = $0.request }, abort: {})
        let vc = makeScreen(for: paused)

        XCTAssertFalse(vc.applyURLString("not a url"))
        XCTAssertFalse(vc.applyURLString("ftp://example.com/x"))
        XCTAssertFalse(vc.applyURLString(""))

        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)
        XCTAssertEqual(try XCTUnwrap(delivered).url?.absoluteString, "https://example.com/original")
    }

    /// A body the JSON editor cannot round-trip (form encoding, protobuf, an
    /// image upload) is shown read-only and sent byte-for-byte, rather than
    /// silently turned into `{}` — the same rule the response side applies to a
    /// binary payload.
    func testANonJSONRequestBodyIsReadOnlyAndSentUnchanged() throws {
        var request = URLRequest(url: URL(string: "https://example.com/form")!)
        request.httpMethod = "POST"
        request.httpBody = Data("user=me&password=hunter2".utf8)

        var delivered: URLRequest?
        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request,
            resume: { delivered = $0.request }, abort: {})
        let vc = makeScreen(for: paused)

        XCTAssertNil(bodyCard(in: vc), "A form-encoded body must not open in the JSON editor.")
        XCTAssertTrue(rowTitles(of: vc).contains("Request body"),
                      "The body still has to be visible, just not editable.")

        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)
        XCTAssertEqual(try XCTUnwrap(delivered).httpBody, Data("user=me&password=hunter2".utf8))
    }

    // MARK: - 2. Adjacent behaviour: the after-response screen is unchanged

    func testAfterResponseScreenStillShowsReadOnlyRequestAndAnEditableResponseBody() throws {
        let request = URLRequest(url: URL(string: "https://example.com/original")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])
        var delivered: Data?
        let paused = BreakpointCenter.PausedRequest(
            stage: .afterResponse, request: request, response: response,
            responseBody: Data(#"{"from":"server"}"#.utf8),
            resume: { delivered = $0.responseBody }, abort: {})

        let vc = makeScreen(for: paused)
        let titles = rowTitles(of: vc)
        XCTAssertTrue(titles.contains("Request headers (0)"),
                      "After the response, the request is history — it stays read-only. "
                      + "Rows were: \(titles)")
        XCTAssertFalse(titles.contains("Method"), "Rows were: \(titles)")
        XCTAssertFalse(titles.contains("Add header"), "Rows were: \(titles)")
        XCTAssertTrue(titles.contains("Deliver to app"), "Rows were: \(titles)")
        XCTAssertNotNil(bodyCard(in: vc), "The response body must still open in the JSON editor.")

        let deliver = try XCTUnwrap(indexPath(of: "Deliver to app", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: deliver)
        XCTAssertEqual(delivered, Data(#"{"from":"server"}"#.utf8),
                       "An untouched body must be delivered exactly as the server sent it.")
    }

    /// The inbox's escape hatch. It releases what was PARKED — edits are only
    /// committed by tapping Send on the detail screen — and it has to empty the
    /// list, or the host app is left holding requests with no way out.
    func testResumeAllStillReleasesEveryParkedRequest() throws {
        var released: [String] = []
        for path in ["/one", "/two"] {
            let request = URLRequest(url: URL(string: "https://example.com\(path)")!)
            let paused = BreakpointCenter.PausedRequest(
                stage: .beforeSend, request: request,
                resume: { released.append($0.request.url?.path ?? "") }, abort: {})
            BreakpointCenter.shared.park(paused)
        }
        XCTAssertEqual(BreakpointCenter.shared.count, 2, "precondition: both parked")

        let inbox = BreakpointInboxViewController()
        inbox.loadViewIfNeeded()
        let resumeAll = try XCTUnwrap(inbox.navigationItem.rightBarButtonItem)
        XCTAssertEqual(resumeAll.title, "Resume All")
        _ = (resumeAll.target as? NSObject)?.perform(try XCTUnwrap(resumeAll.action))

        XCTAssertEqual(released.sorted(), ["/one", "/two"])
        XCTAssertEqual(BreakpointCenter.shared.count, 0)
    }

    func testAbortStillFailsTheRequest() throws {
        let request = URLRequest(url: URL(string: "https://example.com/original")!)
        var aborted = false
        let paused = BreakpointCenter.PausedRequest(
            stage: .beforeSend, request: request, resume: { _ in }, abort: { aborted = true })
        let vc = makeScreen(for: paused)

        let abort = try XCTUnwrap(indexPath(of: "Abort request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: abort)
        XCTAssertTrue(aborted)
    }

    // MARK: - 3. End-to-end: the edits reach the wire

    /// Real socket server, real `URLSession`, real `CustomHTTPProtocol`, real
    /// screen. Proves the whole chain: screen → `PausedRequest.request` →
    /// resume handler → `sendUpstream` → the server's own socket.
    func testEditsMadeAtABeforeSendBreakpointReachTheServer() throws {
        armBeforeSend(onPath: "/original")

        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var appData: Data?
        var appError: NSError?
        let completed = expectation(description: "task completes")

        var request = URLRequest(url: server.url(path: "/original"))
        request.httpMethod = "POST"
        request.setValue("yes", forHTTPHeaderField: "X-Original")
        request.httpBody = Data(#"{"who":"app"}"#.utf8)
        let task = session.dataTask(with: request) { data, _, error in
            appData = data
            appError = error as NSError?
            completed.fulfill()
        }

        var parked: BreakpointCenter.PausedRequest?
        let didPark = expectation(description: "request parked")
        didPark.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main) { _ in
                if let first = BreakpointCenter.shared.pausedRequests.first, parked == nil {
                    parked = first
                    didPark.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        task.resume()
        wait(for: [didPark], timeout: 20)
        let paused = try XCTUnwrap(parked, "the request never parked at the before-send breakpoint")
        XCTAssertEqual(paused.stage, .beforeSend)

        // Everything below happens exactly as a tap would: through the screen.
        let vc = makeScreen(for: paused)
        vc.applyMethod("PUT")
        XCTAssertTrue(vc.applyURLString(server.url(path: "/edited").absoluteString))
        XCTAssertTrue(vc.applyHeader(name: "X-Edited", value: "1", at: nil))
        vc.applyRequestBody(#"{"who":"developer"}"#)
        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)

        wait(for: [completed], timeout: 30)

        XCTAssertNil(appError, "the edited request failed: \(String(describing: appError))")
        XCTAssertEqual(appData, Self.serverBody, "the app did not get the server's response back")

        XCTAssertEqual(server.received.count, 1,
                       "the server should have been hit exactly once — more than one means the "
                       + "edited request lost its recursion flag and was re-captured")
        let got = try XCTUnwrap(server.received.first)
        XCTAssertEqual(got.method, "PUT", "the edited METHOD never reached the wire")
        XCTAssertEqual(got.path, "/edited", "the edited URL never reached the wire")
        XCTAssertEqual(got.headers["x-edited"], "1", "the added HEADER never reached the wire")
        XCTAssertEqual(got.headers["x-original"], "yes", "an untouched header was dropped")
        XCTAssertEqual(String(data: got.body, encoding: .utf8), #"{"who":"developer"}"#,
                       "the edited BODY never reached the wire")
        XCTAssertEqual(got.headers["content-length"], "\(got.body.count)",
                       "Content-Length must describe the edited body")
    }

    /// The Network list has to describe what was SENT, not what the app
    /// originally asked for. Both fields it reads were latched before the
    /// developer edited anything.
    func testTheCapturedTransactionDescribesTheEditedRequest() throws {
        armBeforeSend(onPath: "/capture")

        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let completed = expectation(description: "task completes")
        var request = URLRequest(url: server.url(path: "/capture"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"who":"app"}"#.utf8)
        let task = session.dataTask(with: request) { _, _, _ in completed.fulfill() }

        var parked: BreakpointCenter.PausedRequest?
        let didPark = expectation(description: "request parked")
        didPark.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main) { _ in
                if let first = BreakpointCenter.shared.pausedRequests.first, parked == nil {
                    parked = first
                    didPark.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        task.resume()
        wait(for: [didPark], timeout: 20)
        let paused = try XCTUnwrap(parked)

        let vc = makeScreen(for: paused)
        vc.applyMethod("PUT")
        XCTAssertTrue(vc.applyURLString(server.url(path: "/captured-edited").absoluteString))
        vc.applyRequestBody(#"{"who":"developer"}"#)
        let send = try XCTUnwrap(indexPath(of: "Send request", in: vc))
        vc.tableView(vc.tableView, didSelectRowAt: send)
        wait(for: [completed], timeout: 30)

        // `stopLoading` writes the transaction after the client completes.
        var model: NetworkTransaction?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            model = NetworkRequestStore.shared.snapshot().first {
                ($0.url as URL?)?.path == "/captured-edited"
            }
        }
        let captured = try XCTUnwrap(model,
                                     "no transaction was recorded for the URL that was actually "
                                     + "requested — the list still describes the un-edited request")
        XCTAssertEqual(captured.method, "PUT")
        XCTAssertEqual(captured.requestData, Data(#"{"who":"developer"}"#.utf8),
                       "the list shows a request body that was never sent")
        NetworkRequestStore.shared.remove(captured)
    }

    // MARK: - Card lookup

    /// The JSON body card, if this screen is showing one.
    private func bodyCard(in vc: BreakpointDetailViewController) -> JSONEditorCardCell? {
        for section in 0..<vc.numberOfSections(in: vc.tableView) {
            for row in 0..<vc.tableView(vc.tableView, numberOfRowsInSection: section) {
                let ip = IndexPath(row: row, section: section)
                if let card = vc.tableView(vc.tableView, cellForRowAt: ip) as? JSONEditorCardCell {
                    return card
                }
            }
        }
        return nil
    }
}
