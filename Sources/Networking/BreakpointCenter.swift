//
//  BreakpointCenter.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

extension Notification.Name {
    /// Posted whenever the set of paused requests changes.
    static let breakpointsDidChange = Notification.Name("com.swiftydebug.breakpointsDidChange")
}

/// Holds requests that are **paused** at a breakpoint, waiting for the developer
/// to inspect/edit and then release them.
///
/// Nothing here blocks a thread. `CustomHTTPProtocol` simply *defers* its next
/// step and parks a continuation closure; resuming calls that closure. That keeps
/// the URL loading system's threads free while a request sits on hold.
final class BreakpointCenter {

    static let shared = BreakpointCenter()
    private init() {}

    /// One paused request.
    final class PausedRequest {
        let id = UUID().uuidString
        let stage: BreakpointMode          // .beforeSend or .afterResponse
        let pausedAt = Date()

        /// The outgoing request as it stands (editable when `.beforeSend`).
        var request: URLRequest
        /// The response received (only for `.afterResponse`).
        var response: HTTPURLResponse?
        /// The response body (editable when `.afterResponse`).
        var responseBody: Data?

        /// Called with the (possibly edited) values to let the request continue.
        fileprivate let resumeHandler: (PausedRequest) -> Void
        /// Called to fail the request instead of delivering it.
        fileprivate let abortHandler: () -> Void

        /// True once the request has been resumed, aborted, or expired. Read by
        /// `CustomHTTPProtocol` so it doesn't expire a row it already delivered.
        fileprivate(set) var isSettled = false

        /// True when the host app abandoned the request while it was held, so
        /// there is no longer a client to deliver to. Distinguishes "you released
        /// it" from "it was taken away from you".
        fileprivate(set) var didExpire = false

        /// How long this request has been held.
        var heldFor: TimeInterval { Date().timeIntervalSince(pausedAt) }

        /// Seconds left before the APP gives up on this request, or nil once
        /// settled.
        ///
        /// Counts against the held request's OWN `timeoutInterval`, not against
        /// `breakpointHoldSeconds`. Those are the same number only while "Extend
        /// Request Timeouts" is on — that setting is what raises the app's
        /// timeout to the hold budget in the first place. With it off (the
        /// default), the request dies at whatever the app asked for, typically
        /// 60 s and often much less, while a fixed 600-second countdown happily
        /// told the developer they had nine minutes to edit a response that was
        /// already gone.
        var remainingHoldTime: TimeInterval? {
            guard !isSettled else { return nil }
            let deadline = request.timeoutInterval > 0
                ? request.timeoutInterval
                : Settings.shared.breakpointHoldSeconds
            return max(0, deadline - heldFor)
        }

        init(stage: BreakpointMode,
             request: URLRequest,
             response: HTTPURLResponse? = nil,
             responseBody: Data? = nil,
             resume: @escaping (PausedRequest) -> Void,
             abort: @escaping () -> Void) {
            self.stage = stage
            self.request = request
            self.response = response
            self.responseBody = responseBody
            self.resumeHandler = resume
            self.abortHandler = abort
        }

        var displayURL: String { request.url?.absoluteString ?? "—" }
        var method: String { request.httpMethod ?? "GET" }
        var statusCode: Int? { response?.statusCode }

        /// Response body as text, pretty-printed when it's JSON.
        ///
        /// Falls back to the raw UTF-8 text for non-JSON payloads (HTML, plain
        /// text, XML). Returning "" for those would let the editor deliver an
        /// empty body to the app.
        var responseBodyText: String {
            guard let data = responseBody, !data.isEmpty else { return "" }
            if let pretty = data.dataToPrettyPrintString() { return pretty }
            return String(data: data, encoding: .utf8) ?? ""
        }

        /// True when the body isn't representable as text at all (images, binary
        /// protobuf, …). Such a body must be delivered byte-for-byte, never
        /// re-encoded from the editor's string.
        var isResponseBodyBinary: Bool {
            guard let data = responseBody, !data.isEmpty else { return false }
            return String(data: data, encoding: .utf8) == nil
        }
    }

    /// A breakpoint that was armed but never actually paused, and why.
    ///
    /// Without this, the explanation for a breakpoint that silently did not fire
    /// was written into the rewrite report — so the developer had to open the
    /// request's detail screen and read a section headed RESPONSE REWRITES to
    /// find out why the thing they were staring at never happened.
    struct Notice: Equatable {
        let url: String
        let message: String
        let at: Date
    }

    private let lock = NSLock()
    private var paused: [PausedRequest] = []
    private var noticeLog: [Notice] = []
    /// Bounded — this is a diagnostic aid, not a log.
    private static let maxNotices = 20

    /// Currently paused requests, oldest first.
    var pausedRequests: [PausedRequest] {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paused.count
    }

    /// Notices, newest first.
    var notices: [Notice] {
        lock.lock(); defer { lock.unlock() }
        return noticeLog
    }

    /// Records why an armed breakpoint never paused, so it shows up in the inbox
    /// the developer is actually looking at.
    func note(_ message: String, for url: URL?, at date: Date = Date()) {
        let key = url?.absoluteString ?? "\u{2014}"
        lock.lock()
        // De-duplicate on (url, message). An app polling a mocked endpoint that
        // also has a breakpoint armed produces one of these per request, which
        // filled all 20 slots with the same sentence and evicted every other
        // notice. The newest occurrence wins its place at the top.
        if let existing = noticeLog.firstIndex(where: { $0.url == key && $0.message == message }) {
            noticeLog.remove(at: existing)
        }
        noticeLog.insert(Notice(url: key, message: message, at: date), at: 0)
        if noticeLog.count > Self.maxNotices { noticeLog.removeLast(noticeLog.count - Self.maxNotices) }
        lock.unlock()
        notifyChanged()
    }

    func clearNotices() {
        lock.lock()
        noticeLog.removeAll()
        lock.unlock()
        notifyChanged()
    }

    // MARK: - Parking

    func park(_ request: PausedRequest) {
        lock.lock()
        paused.append(request)
        lock.unlock()
        notifyChanged()
    }

    // MARK: - Releasing

    /// Lets a paused request continue, applying whatever edits were made to it.
    ///
    /// Returns `false` when the request was already settled — almost always
    /// because the host app gave up on it first. Callers **must** surface that:
    /// a delivery that silently does nothing is indistinguishable from a delivery
    /// that worked but produced an empty screen.
    @discardableResult
    func resume(_ request: PausedRequest) -> Bool {
        guard take(request) else { return false }
        request.resumeHandler(request)
        notifyChanged()
        return true
    }

    /// Fails a paused request instead of delivering it.
    @discardableResult
    func abort(_ request: PausedRequest) -> Bool {
        guard take(request) else { return false }
        request.abortHandler()
        notifyChanged()
        return true
    }

    /// Drops a paused request without resuming or aborting it. Used when the app
    /// itself gave up first — it cancelled the request, or its own
    /// `timeoutIntervalForRequest` elapsed while the request sat on hold. There is
    /// no live client left to deliver to, so the row is removed instead of
    /// offering a "Deliver" button that would silently do nothing.
    func expire(_ request: PausedRequest) {
        guard take(request) else { return }
        request.didExpire = true
        notifyChanged()
    }

    /// Releases everything currently on hold (used when the SDK is stopped, so
    /// the host app never ends up with permanently stuck requests).
    func resumeAll() {
        lock.lock()
        let all = paused
        paused.removeAll()
        for r in all { r.isSettled = true }
        lock.unlock()
        for r in all { r.resumeHandler(r) }
        notifyChanged()
    }

    /// Removes a request from the queue exactly once.
    private func take(_ request: PausedRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !request.isSettled else { return false }
        request.isSettled = true
        paused.removeAll { $0 === request }
        return true
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .breakpointsDidChange, object: nil)
        }
    }
}
