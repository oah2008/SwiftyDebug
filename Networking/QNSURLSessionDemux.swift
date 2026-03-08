//
//  QNSURLSessionDemux.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

// MARK: - BlockBox

/// A simple wrapper so we can pass a closure through `perform(_:on:with:waitUntilDone:modes:)`,
/// which requires an `AnyObject` argument.
private class BlockBox: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

// MARK: - QNSURLSessionDemuxTaskInfo

/// Holds per-task state: the delegate, the originating thread, and the run-loop modes.
private class QNSURLSessionDemuxTaskInfo: NSObject {

    let task: URLSessionDataTask
    var delegate: URLSessionDataDelegate?
    var thread: Thread?
    let modes: [String]

    init(task: URLSessionDataTask, delegate: URLSessionDataDelegate, modes: [String]) {
        self.task = task
        self.delegate = delegate
        self.thread = Thread.current
        self.modes = modes
        super.init()
    }

    /// Schedules `block` for execution on the client thread in the recorded run-loop modes.
    func performBlock(_ block: @escaping () -> Void) {
        guard let thread = self.thread else { return }
        let box = BlockBox(block)
        perform(#selector(performBlockOnClientThread(_:)),
                on: thread,
                with: box,
                waitUntilDone: false,
                modes: modes)
    }

    @objc private func performBlockOnClientThread(_ box: BlockBox) {
        box.block()
    }

    /// Clears delegate and thread references so the task info no longer retains them.
    func invalidate() {
        delegate = nil
        thread = nil
    }
}

// MARK: - QNSURLSessionDemux

/// A simple class for demultiplexing NSURLSession delegate callbacks to a per-task delegate object.
///
/// You initialise the class with a session configuration. After that you can create data tasks
/// within that session by calling `dataTask(with:delegate:modes:)`. Any delegate callbacks
/// for that data task are redirected to the delegate on the thread that created the task in
/// one of the specified run loop modes. That thread must run its run loop in order to get
/// these callbacks.
@objc class QNSURLSessionDemux: NSObject {

    /// A copy of the configuration passed to `init(configuration:)`.
    @objc private(set) var configuration: URLSessionConfiguration

    /// The session created from the configuration passed to `init(configuration:)`.
    @objc private(set) var session: URLSession!

    /// Maps `taskIdentifier` -> `QNSURLSessionDemuxTaskInfo`. Access protected by `objc_sync`.
    private var taskInfoByTaskID: [Int: QNSURLSessionDemuxTaskInfo] = [:]

    /// Serial operation queue used as the session's delegate queue.
    private let sessionDelegateQueue: OperationQueue

    // MARK: Initialisation

    @objc convenience override init() {
        self.init(configuration: nil)
    }

    @objc init(configuration: URLSessionConfiguration?) {
        let config = (configuration ?? URLSessionConfiguration.default).copy() as! URLSessionConfiguration
        self.configuration = config

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "QNSURLSessionDemux"
        self.sessionDelegateQueue = queue

        super.init()

        let realSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        realSession.sessionDescription = "QNSURLSessionDemux"
        self.session = realSession
    }

    // MARK: Creating Data Tasks

    /// Creates a new data task whose delegate callbacks are routed to the supplied delegate.
    ///
    /// The callbacks are run on the current thread (the thread that called this method) in the
    /// specified modes.
    ///
    /// The delegate is retained until the task completes, that is, until after your
    /// `urlSession(_:task:didCompleteWithError:)` delegate callback returns.
    ///
    /// The returned task is suspended. You must resume the returned task for the task to
    /// make progress. Furthermore, it is not safe to simply discard the returned task
    /// because in that case the task's delegate is never released.
    ///
    /// - Parameters:
    ///   - request: The request that the data task executes; must not be nil.
    ///   - delegate: The delegate to receive the data task's delegate callbacks; must not be nil.
    ///   - modes: The run loop modes in which to run the data task's delegate callbacks;
    ///            if nil or empty, `RunLoop.Mode.default` is used.
    /// - Returns: A suspended data task that you must resume.
    @objc func dataTask(with request: URLRequest,
                        delegate: URLSessionDataDelegate,
                        modes: [String]?) -> URLSessionDataTask {
        let effectiveModes = (modes?.isEmpty ?? true) ? [RunLoop.Mode.default.rawValue] : modes!
        let task = session.dataTask(with: request)
        let taskInfo = QNSURLSessionDemuxTaskInfo(task: task, delegate: delegate, modes: effectiveModes)

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        taskInfoByTaskID[task.taskIdentifier] = taskInfo

        return task
    }

    // MARK: Private helpers

    private func taskInfo(for task: URLSessionTask) -> QNSURLSessionDemuxTaskInfo? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        let info = taskInfoByTaskID[task.taskIdentifier]
        return info
    }
}

// MARK: - URLSessionDataDelegate

extension QNSURLSessionDemux: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let taskInfo = taskInfo(for: task) else { completionHandler(request); return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
            }
        } else {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let taskInfo = taskInfo(for: task) else { completionHandler(.performDefaultHandling, nil); return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        guard let taskInfo = taskInfo(for: task) else { completionHandler(nil); return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:needNewBodyStream:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, task: task, needNewBodyStream: completionHandler)
            }
        } else {
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let taskInfo = taskInfo(for: task) else { return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let taskInfo = taskInfo(for: task) else { return }

        // This is our last delegate callback so we remove our task info record.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        taskInfoByTaskID.removeValue(forKey: taskInfo.task.taskIdentifier)

        // Call the delegate if required. In that case we invalidate the task info on the client
        // thread after calling the delegate, otherwise the client thread side of the performBlock
        // code can find itself with an invalidated task info.
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, task: task, didCompleteWithError: error)
                taskInfo.invalidate()
            }
        } else {
            taskInfo.invalidate()
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let taskInfo = taskInfo(for: dataTask) else { completionHandler(.allow); return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:completionHandler:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
            }
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didBecome downloadTask: URLSessionDownloadTask) {
        guard let taskInfo = taskInfo(for: dataTask) else { return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didBecome:) as (URLSessionDataDelegate) -> ((URLSession, URLSessionDataTask, URLSessionDownloadTask) -> Void)?)) {
            taskInfo.performBlock {
                delegate.urlSession?(session, dataTask: dataTask, didBecome: downloadTask)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let taskInfo = taskInfo(for: dataTask) else { return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:) as (URLSessionDataDelegate) -> ((URLSession, URLSessionDataTask, Data) -> Void)?)) {
            taskInfo.performBlock {
                delegate.urlSession?(session, dataTask: dataTask, didReceive: data)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        guard let taskInfo = taskInfo(for: dataTask) else { completionHandler(proposedResponse); return }
        if let delegate = taskInfo.delegate,
           delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:willCacheResponse:completionHandler:))) {
            taskInfo.performBlock {
                delegate.urlSession?(session, dataTask: dataTask, willCacheResponse: proposedResponse, completionHandler: completionHandler)
            }
        } else {
            completionHandler(proposedResponse)
        }
    }
}
