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

        fileprivate var isSettled = false

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
        var responseBodyText: String {
            guard let data = responseBody, !data.isEmpty else { return "" }
            return data.dataToPrettyPrintString() ?? ""
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
    func resume(_ request: PausedRequest) {
        guard take(request) else { return }
        request.resumeHandler(request)
        notifyChanged()
    }

    /// Fails a paused request instead of delivering it.
    func abort(_ request: PausedRequest) {
        guard take(request) else { return }
        request.abortHandler()
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
