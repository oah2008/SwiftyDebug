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

        /// Seconds left before the hold budget runs out, or nil once settled.
        var remainingHoldTime: TimeInterval? {
            guard !isSettled else { return nil }
            return max(0, Settings.shared.breakpointHoldSeconds - heldFor)
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

    private let lock = NSLock()
    private var paused: [PausedRequest] = []

    /// Currently paused requests, oldest first.
    var pausedRequests: [PausedRequest] {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paused.count
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
