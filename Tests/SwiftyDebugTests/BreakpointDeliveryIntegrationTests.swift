//
//  BreakpointDeliveryIntegrationTests.swift
//  SwiftyDebugTests
//
//  End-to-end reproduction of the ".afterResponse breakpoint delivers an empty
//  page to the app" report. Everything here is real: a real socket server, a
//  real URLSession task, the real CustomHTTPProtocol, the real BreakpointCenter.
//  Nothing is stubbed.
//

import XCTest
@testable import SwiftyDebug

// MARK: - Minimal in-process HTTP server (BSD sockets, no dependencies)

/// Answers every request with one fixed body and a correct `Content-Length`.
/// Binds 127.0.0.1 on an ephemeral port so tests never collide.
private final class TinyHTTPServer {

    enum ServerError: Error { case socket, bind, listen }

    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let responseBody: Data
    private let acceptQueue = DispatchQueue(label: "swiftydebug.tests.tinyhttp")
    private var isRunning = false

    init(body: Data) { self.responseBody = body }

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

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

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
        // Read the request head.
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            request.append(contentsOf: buf[0..<n])
            if let s = String(data: request, encoding: .utf8), s.contains("\r\n\r\n") { break }
            if request.count > 64 * 1024 { break }
        }

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(responseBody.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(responseBody)
        writeAll(fd, out)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - Tests

final class BreakpointDeliveryIntegrationTests: XCTestCase {

    private static let originalBody = Data(#"{"items":[{"id":1,"name":"ORIGINAL"}]}"#.utf8)
    private static let editedBody   = Data(#"{"items":[{"id":99,"name":"EDITED-BY-BREAKPOINT"}]}"#.utf8)

    private var server: TinyHTTPServer!
    private var ruleID: String?

    /// Everything the completion handler and the breakpoint hand-off produced,
    /// so each test can assert on the whole picture.
    private struct Outcome {
        var parked: BreakpointCenter.PausedRequest?
        var parkedAfter: TimeInterval = 0
        var settledBeforeResume = false
        var data: Data?
        var response: HTTPURLResponse?
        var error: NSError?
        var completedAfter: TimeInterval = 0
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        // --- SDK preconditions read by CustomHTTPProtocol.canInit ---
        SwiftyDebugRuntime.markActive()
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.urls = []
        Settings.shared.networkConditionerPreset = .off
        NetworkMonitor.shared.enable()          // sets isNetworkEnable + registerClass

        // The timeout clamp that keeps a held request alive lives in the session
        // swizzle, so it must be installed exactly as an app installs it.
        CustomHTTPProtocol.swizzleSessionConfiguration()
        // `Settings` writes straight through to UserDefaults, which the test host and
        // the app share — restoring a literal `true` here would permanently flip the
        // shipped default ON for anyone who ran the suite once.
        savedExtendTimeouts = Settings.shared.extendTimeoutsForBreakpoints
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600

        // Clear any leftovers from other tests.
        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        InterceptRuleStore.shared.removeAll()

        server = TinyHTTPServer(body: Self.originalBody)
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server did not bind an ephemeral port")
    }

    /// The persisted value before this test touched it, restored in tearDown.
    private var savedExtendTimeouts = false

    override func tearDownWithError() throws {
        Settings.shared.extendTimeoutsForBreakpoints = savedExtendTimeouts
        for p in BreakpointCenter.shared.pausedRequests { BreakpointCenter.shared.expire(p) }
        InterceptRuleStore.shared.removeAll()
        NetworkMonitor.shared.disable()
        SwiftyDebug.monitorAllUrls = false
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    // MARK: Rule setup

    /// Arms an `.afterResponse` breakpoint on the exact path we are about to hit.
    private func armBreakpoint(onPath path: String) {
        var rule = InterceptRule(matchEndpoint: path, matchMode: .exact)
        rule.breakpointMode = .afterResponse
        rule.isEnabled = true
        InterceptRuleStore.shared.addOrUpdate(rule)
        ruleID = rule.id

        // Sanity: the rule must actually resolve for the URL the task will use.
        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: server.url(path: path))
        XCTAssertEqual(resolved?.breakpointMode, .afterResponse,
                       "breakpoint rule did not resolve — the rest of the test would be meaningless")
    }

    // MARK: The real flow

    /// Fires a real task, waits for the park, waits `editDelay` (simulating the
    /// developer editing in the inbox), swaps the body and resumes.
    private func runBreakpointFlow(clientTimeout: TimeInterval,
                                   editDelay: TimeInterval,
                                   editedBody: Data,
                                   path: String) -> Outcome {
        armBreakpoint(onPath: path)

        var outcome = Outcome()
        let t0 = Date()

        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = clientTimeout    // mirrors the demo's BaseAPI
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        let completed = expectation(description: "dataTask completion")
        let url = server.url(path: path)
        let task = session.dataTask(with: url) { data, response, error in
            outcome.data = data
            outcome.response = response as? HTTPURLResponse
            outcome.error = error as NSError?
            outcome.completedAfter = Date().timeIntervalSince(t0)
            completed.fulfill()
        }

        // Wait for BreakpointCenter to report the paused request.
        let parked = expectation(description: "request parked at breakpoint")
        parked.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main) { _ in
                if let first = BreakpointCenter.shared.pausedRequests.first {
                    if outcome.parked == nil {
                        outcome.parked = first
                        outcome.parkedAfter = Date().timeIntervalSince(t0)
                    }
                    parked.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        task.resume()
        wait(for: [parked], timeout: 20)

        guard let paused = outcome.parked else {
            XCTFail("request never parked at the breakpoint")
            wait(for: [completed], timeout: 20)
            return outcome
        }

        XCTAssertEqual(paused.stage, .afterResponse)
        XCTAssertEqual(paused.responseBody, Self.originalBody,
                       "the parked body should be exactly what the server sent")

        // What timeout does the URLProtocol actually see? (The SDK cannot read
        // the host session's configuration; this is the only number available to
        // it, so any "time left" UI would have to be based on it.)
        print("[PROTOCOL-SEES] request.timeoutInterval=\(paused.request.timeoutInterval) " +
              "while the session config was \(clientTimeout)")

        // Simulate the developer sitting in the editor for `editDelay` seconds.
        if editDelay > 0 {
            let editing = expectation(description: "developer editing")
            DispatchQueue.main.asyncAfter(deadline: .now() + editDelay) { editing.fulfill() }
            wait(for: [editing], timeout: editDelay + 10)
        }

        // "Deliver to app" — exactly what BreakpointDetailViewController does,
        // from the main thread, just like a table-view tap.
        paused.responseBody = editedBody
        outcome.settledBeforeResume = paused.isSettled
        BreakpointCenter.shared.resume(paused)

        wait(for: [completed], timeout: 30)
        session.invalidateAndCancel()
        return outcome
    }

    // MARK: - 1. The SDK path in isolation (fast delivery)

    /// Delivers within the client's timeout budget. This proves whether the
    /// buffer → edit → deliverHeldResponse path itself is correct.
    func testEditedBodyIsDeliveredToTheAppWhenDeliveredQuickly() {
        let out = runBreakpointFlow(clientTimeout: 60,
                                    editDelay: 0.2,
                                    editedBody: Self.editedBody,
                                    path: "/fast")

        print("""
        [FAST] parkedAfter=\(out.parkedAfter)s completedAfter=\(out.completedAfter)s \
        error=\(String(describing: out.error?.code)) \
        bytes=\(out.data?.count ?? -1) \
        body=\(String(data: out.data ?? Data(), encoding: .utf8) ?? "<nil>")
        """)

        XCTAssertNil(out.error, "delivery produced an error: \(String(describing: out.error))")
        XCTAssertEqual(out.data, Self.editedBody,
                       "app received \(out.data?.count ?? -1) bytes: " +
                       "\(String(data: out.data ?? Data(), encoding: .utf8) ?? "<nil>")")
        XCTAssertEqual(out.response?.statusCode, 200)
        XCTAssertEqual(out.response?.value(forHTTPHeaderField: "Content-Length"),
                       "\(Self.editedBody.count)",
                       "Content-Length must describe the EDITED body")
        XCTAssertNil(out.response?.value(forHTTPHeaderField: "Content-Encoding"))
    }

    // MARK: - 2. The reported bug: a realistic editing pause

    /// The user's actual scenario. The demo app's URLSession uses
    /// `timeoutIntervalForRequest = 10` (Demo/Pods/SwiftyNetworkIOS/.../BaseAPI.swift:114)
    /// and no human can open the debug window, find the paused row, edit the JSON
    /// and tap Deliver in under that. Here the same shape is reproduced with a
    /// 3s client timeout and 5s of "editing".
    ///
    /// This is the regression test for the reported bug. It failed with
    /// NSURLErrorTimedOut (-1001) and `data == nil` until the SDK started raising
    /// short host timeouts to the breakpoint hold budget — the client's idle
    /// timer never resets while a request is held, because a held request streams
    /// nothing.
    func testEditedBodyIsDeliveredAfterARealisticEditingPause_REPRODUCES_REPORTED_BUG() {
        let out = runBreakpointFlow(clientTimeout: 3,
                                    editDelay: 5,
                                    editedBody: Self.editedBody,
                                    path: "/slow")

        print("""
        [SLOW] parkedAfter=\(out.parkedAfter)s completedAfter=\(out.completedAfter)s \
        settledBeforeResume=\(out.settledBeforeResume) \
        error=\(String(describing: out.error?.domain)) code=\(String(describing: out.error?.code)) \
        bytes=\(out.data?.count ?? -1) \
        body=\(String(data: out.data ?? Data(), encoding: .utf8) ?? "<nil>")
        """)

        XCTAssertNil(out.error,
                     "the app's task failed while the request sat at the breakpoint: " +
                     "\(String(describing: out.error))")
        XCTAssertEqual(out.data, Self.editedBody,
                       "app received \(out.data?.count ?? -1) bytes instead of the edited body")
    }

    // MARK: - 2b. Same long pause, only the client's timeout changed

    /// Identical to the test above — same server, same protocol, same 5s pause,
    /// same "Deliver to app" — except the *host session's*
    /// `timeoutIntervalForRequest` is generous. If this passes while the 3s
    /// version fails, the client-side timeout is the ONLY variable that matters,
    /// and nothing inside Sources/ needs to change to make delivery work.
    func testEditedBodyIsDeliveredAfterALongPauseWhenTheClientTimeoutIsGenerous() {
        let out = runBreakpointFlow(clientTimeout: 120,
                                    editDelay: 5,
                                    editedBody: Self.editedBody,
                                    path: "/patient")

        print("""
        [PATIENT] parkedAfter=\(out.parkedAfter)s completedAfter=\(out.completedAfter)s \
        settledBeforeResume=\(out.settledBeforeResume) \
        error=\(String(describing: out.error?.code)) bytes=\(out.data?.count ?? -1) \
        body=\(String(data: out.data ?? Data(), encoding: .utf8) ?? "<nil>")
        """)

        XCTAssertNil(out.error)
        XCTAssertFalse(out.settledBeforeResume, "the row must still be live when Deliver is tapped")
        XCTAssertEqual(out.data, Self.editedBody)
        XCTAssertEqual(out.response?.value(forHTTPHeaderField: "Content-Length"),
                       "\(Self.editedBody.count)")
    }

    // MARK: - 3. The exact mechanism, asserted positively

    /// Documents precisely what happens when the client gives up first — the
    /// failure mode the timeout clamp exists to prevent. The clamp is switched
    /// OFF here on purpose so the raw CFNetwork behaviour is still pinned down.
    func testClientTimeoutExpiresTheParkedRowAndMakesDeliverFail() {
        Settings.shared.extendTimeoutsForBreakpoints = false
        defer { Settings.shared.extendTimeoutsForBreakpoints = savedExtendTimeouts }
        armBreakpoint(onPath: "/expire")

        let config = URLSessionConfiguration.default
        config.protocolClasses = [CustomHTTPProtocol.self]
        config.timeoutIntervalForRequest = 3
        config.urlCache = nil
        let session = URLSession(configuration: config)

        var taskError: NSError?
        var taskData: Data?
        let completed = expectation(description: "task completes")
        let t0 = Date()
        let task = session.dataTask(with: server.url(path: "/expire")) { data, _, error in
            taskData = data
            taskError = error as NSError?
            completed.fulfill()
        }

        var paused: BreakpointCenter.PausedRequest?
        let parkedExp = expectation(description: "parked")
        parkedExp.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main) { _ in
                if paused == nil, let first = BreakpointCenter.shared.pausedRequests.first {
                    paused = first
                    parkedExp.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        task.resume()
        wait(for: [parkedExp], timeout: 20)
        wait(for: [completed], timeout: 20)

        let p = try! XCTUnwrap(paused)

        print("""
        [EXPIRE] completedAfter=\(Date().timeIntervalSince(t0))s \
        errorCode=\(String(describing: taskError?.code)) bytes=\(taskData?.count ?? -1) \
        isSettled=\(p.isSettled) inboxCount=\(BreakpointCenter.shared.count)
        """)

        // The app's own idle timer fired while nothing was streamed to it.
        XCTAssertEqual(taskError?.code, NSURLErrorTimedOut,
                       "expected -1001; got \(String(describing: taskError))")
        XCTAssertNil(taskData)

        // stopLoading() expired the row, so the still-open detail screen's
        // "Deliver to app" button can never do anything again.
        XCTAssertTrue(p.isSettled, "stopLoading() should have expired the parked row")
        XCTAssertEqual(BreakpointCenter.shared.count, 0, "inbox should be empty after expiry")

        // Tapping "Deliver to app" now REPORTS the failure instead of silently
        // doing nothing — that silence was why the bug read as "still empty".
        p.responseBody = Self.editedBody
        XCTAssertFalse(BreakpointCenter.shared.resume(p),
                       "resume() must report that there is no client left to deliver to")
        XCTAssertTrue(p.didExpire, "the row must be flagged as abandoned by the app")

        session.invalidateAndCancel()
    }

    // MARK: - 4. The clamp itself

    func testHostTimeoutIsRaisedToTheHoldBudget() {
        Settings.shared.extendTimeoutsForBreakpoints = true
        Settings.shared.breakpointHoldSeconds = 600

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10       // exactly what the demo's BaseAPI sets
        XCTAssertEqual(config.timeoutIntervalForRequest, 600,
                       "a 10s host timeout must be raised, or breakpoints cannot be edited")

        // An app that already waits longer than the hold budget keeps its value.
        config.timeoutIntervalForRequest = 900
        XCTAssertEqual(config.timeoutIntervalForRequest, 900)
    }

    func testHostTimeoutIsUntouchedWhenTheExtensionIsOff() {
        Settings.shared.extendTimeoutsForBreakpoints = false
        defer { Settings.shared.extendTimeoutsForBreakpoints = savedExtendTimeouts }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        XCTAssertEqual(config.timeoutIntervalForRequest, 10,
                       "the SDK must not silently change host behaviour when told not to")
    }
}
