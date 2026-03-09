//
//  CustomHTTPProtocol.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

// MARK: - BlockBox

/// A simple wrapper so we can pass a closure through `perform(_:on:with:waitUntilDone:modes:)`,
/// which requires an `AnyObject` argument.
private class CPBlockBox: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

// MARK: - CPURLSessionChallengeSender

// https://stackoverflow.com/questions/27604052/nsurlsessiontask-authentication-challenge-completionhandler-and-nsurlauthenticat
@objc private class CPURLSessionChallengeSender: NSObject, URLAuthenticationChallengeSender {

    private let sessionCompletionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    init(sessionCompletionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.sessionCompletionHandler = sessionCompletionHandler
        super.init()
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.useCredential, credential)
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.useCredential, nil)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.cancelAuthenticationChallenge, nil)
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.performDefaultHandling, nil)
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        sessionCompletionHandler(.rejectProtectionSpace, nil)
    }
}

// MARK: - Session Configuration Swizzling

/// Store original IMP pointers for session configuration class methods.
private var orig_defaultSessionConfiguration: IMP?
private var orig_ephemeralSessionConfiguration: IMP?
/// Store original IMP for protocolClasses getter.
private var orig_protocolClassesGetter: IMP?

/// Type alias for the original session configuration constructor.
private typealias SessionConfigConstructor = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
/// Type alias for the protocolClasses getter.
private typealias ProtocolClassesGetterFunc = @convention(c) (AnyObject, Selector) -> NSArray?

// MARK: - CustomHTTPProtocolDelegate

@objc protocol CustomHTTPProtocolDelegate: NSObjectProtocol {

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           canAuthenticateAgainstProtectionSpace protectionSpace: URLProtectionSpace) -> Bool

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge)

    @objc optional func customHTTPProtocol(_ protocol: CustomHTTPProtocol,
                                           didCancelAuthenticationChallenge challenge: URLAuthenticationChallenge)

}

// MARK: - CustomHTTPProtocol

@objc class CustomHTTPProtocol: URLProtocol {

    // MARK: Class-level delegate storage

    private static var sDelegate: CustomHTTPProtocolDelegate?

    @objc static func start() {
        URLProtocol.registerClass(self)
    }

    @objc static func stop() {
        URLProtocol.unregisterClass(self)
    }

    @objc static func getDelegate() -> CustomHTTPProtocolDelegate? {
        var result: CustomHTTPProtocolDelegate?
        objc_sync_enter(self)
        result = sDelegate
        objc_sync_exit(self)
        return result
    }

    @objc static func setDelegate(_ newValue: CustomHTTPProtocolDelegate?) {
        objc_sync_enter(self)
        sDelegate = newValue
        objc_sync_exit(self)
    }

    // MARK: Shared demux (lazily created once)

    private static var sharedDemuxInstance: QNSURLSessionDemux?
    private static let demuxOnce: Void = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        // Disable cache on the demux session - caching is already handled by the original
        // request's session. Without this, every response gets cached TWICE (doubling memory).
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Limit concurrent connections to reduce connection overhead.
        config.httpMaximumConnectionsPerHost = 1
        // You have to explicitly configure the session to use your own protocol subclass here
        // otherwise you don't see redirects <rdar://problem/17384498>.
        config.protocolClasses = [CustomHTTPProtocol.self]
        sharedDemuxInstance = QNSURLSessionDemux(configuration: config)
    }()

    @objc class func sharedDemux() -> QNSURLSessionDemux {
        _ = demuxOnce
        return sharedDemuxInstance!
    }

    // MARK: Session configuration swizzling

    private static var configSwizzled = false

    /// Replaces the original `+load` from ObjC. Must be called explicitly
    /// (e.g. from `Settings` or app delegate) because Swift
    /// does not support `+load`. Idempotent — safe to call multiple times.
    @objc class func swizzleSessionConfiguration() {
        guard !configSwizzled else { return }
        configSwizzled = true

        let defaultSel = Selector(("defaultSessionConfiguration"))
            let ephemeralSel = Selector(("ephemeralSessionConfiguration"))

            // Replacement block for +defaultSessionConfiguration.
            // imp_implementationWithBlock blocks receive (self, args...) -- no _cmd.
            let replacedDefault: @convention(block) (AnyObject) -> URLSessionConfiguration = { selfObj in
                let original = unsafeBitCast(orig_defaultSessionConfiguration!, to: SessionConfigConstructor.self)
                let config = original(selfObj, defaultSel)
                CustomHTTPProtocol.injectProtocol(into: config)
                return config
            }

            orig_defaultSessionConfiguration = replaceMethod(
                defaultSel,
                imp_implementationWithBlock(replacedDefault),
                URLSessionConfiguration.self,
                true
            )

            // Replacement block for +ephemeralSessionConfiguration.
            let replacedEphemeral: @convention(block) (AnyObject) -> URLSessionConfiguration = { selfObj in
                let original = unsafeBitCast(orig_ephemeralSessionConfiguration!, to: SessionConfigConstructor.self)
                let config = original(selfObj, ephemeralSel)
                CustomHTTPProtocol.injectProtocol(into: config)
                return config
            }

            orig_ephemeralSessionConfiguration = replaceMethod(
                ephemeralSel,
                imp_implementationWithBlock(replacedEphemeral),
                URLSessionConfiguration.self,
                true
            )

            // Also swizzle the protocolClasses GETTER on the actual runtime class
            // of URLSessionConfiguration. This is critical because in ObjC, +load
            // ran the class method swizzle before main(), so ALL configs were created
            // post-swizzle. In Swift there is no +load — the class method swizzle
            // happens later. Configs created before the swizzle (by third-party SDKs
            // or the system) won't have our protocol. By swizzling the getter, we
            // ensure that when URLSession reads a config's protocolClasses at session
            // creation time, our protocol is always included — regardless of when the
            // config was created.
            let protocolClassesSel = NSSelectorFromString("protocolClasses")
            // Use the actual runtime class of a config instance (class cluster).
            let sampleConfig = orig_defaultSessionConfiguration.flatMap { imp in
                unsafeBitCast(imp, to: SessionConfigConstructor.self)(
                    URLSessionConfiguration.self, defaultSel
                )
            }
            let configClass: AnyClass = sampleConfig.map { object_getClass($0)! } ?? URLSessionConfiguration.self
            if let getterMethod = class_getInstanceMethod(configClass, protocolClassesSel) {
                orig_protocolClassesGetter = method_getImplementation(getterMethod)

                let replacedGetter: @convention(block) (AnyObject) -> NSArray? = { configObj in
                    let original = unsafeBitCast(orig_protocolClassesGetter!, to: ProtocolClassesGetterFunc.self)
                    let result = original(configObj, protocolClassesSel)
                    let classes = (result as? [AnyClass]) ?? []
                    let protoCls: AnyClass = CustomHTTPProtocol.self
                    if classes.contains(where: { $0 == protoCls }) {
                        return result
                    }
                    var mutable = classes
                    mutable.insert(protoCls, at: 0)
                    return mutable as NSArray
                }

                method_setImplementation(getterMethod, imp_implementationWithBlock(replacedGetter))
            }
    }

    /// Injects `CustomHTTPProtocol` at the front of the given configuration's `protocolClasses`.
    private class func injectProtocol(into config: URLSessionConfiguration) {
        if config.responds(to: #selector(getter: URLSessionConfiguration.protocolClasses)),
           config.responds(to: #selector(setter: URLSessionConfiguration.protocolClasses)) {
            var urlProtocolClasses = config.protocolClasses ?? []
            let protoCls: AnyClass = CustomHTTPProtocol.self
            if !urlProtocolClasses.contains(where: { $0 == protoCls }) {
                urlProtocolClasses.insert(protoCls, at: 0)
            }
            config.protocolClasses = urlProtocolClasses
        }
    }

    // MARK: Instance properties

    private var clientThread: Thread?
    private var modes: [String]?
    private var startTime: TimeInterval = 0
    private var _dataTask: URLSessionDataTask?
    @objc var pendingChallenge: URLAuthenticationChallenge?
    private var pendingChallengeCompletionHandler: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
    private var response: URLResponse?
    private var data: NSMutableData?
    private var error: Error?
    private var responseTruncated: Bool = false
    /// Request body captured from HTTPBodyStream in startLoading.
    /// self.request.HTTPBody is nil when the body was sent via a stream,
    /// so we must capture it from the recursiveRequest after reading the stream.
    private var capturedRequestBody: Data?
    /// The request after intercept rules have been applied (headers/query params modified).
    /// Used in stopLoading() so the UI reflects the actual request that was sent.
    private var interceptedRequest: URLRequest?

    // MARK: Recursive request flag

    private static let kOurRecursiveRequestFlagProperty = "com.apple.dts.CustomHTTPProtocol"

    // MARK: Skipped file extensions

    private static let skippedExtensions: Set<String> = {
        return Set([
            "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "heic", "heif",
            "mp4", "mov", "avi", "m4v", "m4a", "mp3", "wav", "aac",
            "woff", "woff2", "ttf", "otf", "eot"
        ])
    }()

    // MARK: NSURLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme, scheme == "http" || scheme == "https" else {
            return false
        }

        if URLProtocol.property(forKey: kOurRecursiveRequestFlagProperty, in: request) != nil {
            return false
        }

        // Skip media requests unless monitorMedia is enabled
        if !SwiftyDebug.monitorMedia {
            if let pathExtension = request.url?.pathExtension.lowercased(),
               !pathExtension.isEmpty,
               skippedExtensions.contains(pathExtension) {
                return false
            }
        }

        // If monitorAllUrls is set, capture everything
        if SwiftyDebug.monitorAllUrls {
            return true
        }

        // Filter by SwiftyDebug.urls
        let urls = SwiftyDebug.urls
        if !urls.isEmpty {
            let url = request.url?.absoluteString.lowercased() ?? ""
            for filterURL in urls {
                if url.contains(filterURL.lowercased()) {
                    return true
                }
            }
            return false
        }

        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return CanonicalRequestForRequest(request) as URLRequest
    }

    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    deinit {
        // We should have cleared task and pending challenge by now.
    }

    override func startLoading() {
        // At this point we kick off the process of loading the URL via NSURLSession.
        // The thread that calls this method becomes the client thread.

        // Calculate our effective run loop modes. In some circumstances (yes I'm looking at
        // you UIWebView!) we can be called from a non-standard thread which then runs a
        // non-standard run loop mode waiting for the request to finish. We detect this
        // non-standard mode and add it to the list of run loop modes we use when scheduling
        // our callbacks.
        var calculatedModes: [String] = [RunLoop.Mode.default.rawValue]
        if let currentMode = RunLoop.current.currentMode?.rawValue,
           currentMode != RunLoop.Mode.default.rawValue {
            calculatedModes.append(currentMode)
        }
        self.modes = calculatedModes

        // Create new request that's a clone of the request we were initialised with,
        // except that it has our 'recursive request flag' property set on it.
        let recursiveRequest = (self.request as NSURLRequest).mutableCopy() as! NSMutableURLRequest

        CustomHTTPProtocol.setProperty(true,
                                        forKey: CustomHTTPProtocol.kOurRecursiveRequestFlagProperty,
                                        in: recursiveRequest)

        // Convert body stream to body data to avoid needNewBodyStream overhead.
        // When a request with HTTPBodyStream is cloned, CFNetwork calls needNewBodyStream:
        // which bounces through the demux delegate on another thread - 11.4% of CPU in traces.
        // Reading the stream into HTTPBody eliminates this callback entirely.
        if recursiveRequest.httpBodyStream != nil && recursiveRequest.httpBody == nil {
            let stream = recursiveRequest.httpBodyStream!
            let bodyData = NSMutableData()
            var buffer = [UInt8](repeating: 0, count: 4096)
            stream.open()
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    bodyData.append(buffer, length: bytesRead)
                } else {
                    break
                }
            }
            stream.close()
            if bodyData.length > 0 {
                recursiveRequest.httpBody = bodyData as Data
            }
        }

        // Capture the request body for the debug model.
        // The original request's HTTPBody may be nil when the body was sent via
        // HTTPBodyStream. recursiveRequest now has the stream data converted to HTTPBody.
        self.capturedRequestBody = recursiveRequest.httpBody

        // --- Interception: check for matching intercept rules ---
        if let url = recursiveRequest.url {
            let normalized = EndpointNormalizer.normalize(url.path)
            if let rule = InterceptRuleStore.shared.rule(for: normalized), rule.isEnabled {
                if rule.isBlocked {
                    let error = NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "Blocked by SwiftyDebug intercept rule"]
                    )
                    self.client?.urlProtocol(self, didFailWithError: error)
                    return
                }
                // Apply header overrides
                for pair in rule.headerOverrides {
                    recursiveRequest.setValue(pair.value, forHTTPHeaderField: pair.key)
                }
                for key in rule.removedHeaderKeys {
                    recursiveRequest.setValue(nil, forHTTPHeaderField: key)
                }
                // Apply query param overrides
                if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    var items = components.queryItems ?? []
                    items.removeAll { rule.removedQueryParamKeys.contains($0.name) }
                    for pair in rule.queryParamOverrides {
                        if let idx = items.firstIndex(where: { $0.name == pair.key }) {
                            items[idx] = URLQueryItem(name: pair.key, value: pair.value)
                        } else {
                            items.append(URLQueryItem(name: pair.key, value: pair.value))
                        }
                    }
                    components.queryItems = items.isEmpty ? nil : items
                    if let newURL = components.url {
                        recursiveRequest.url = newURL
                    }
                }
                // Save the modified request so stopLoading() reflects what was actually sent.
                // Only set when a rule was applied; non-intercepted requests use self.request as before.
                self.interceptedRequest = recursiveRequest as URLRequest
            }
        }

        self.startTime = Date().timeIntervalSince1970
        self.data = NSMutableData()

        // Latch the thread we were called on, primarily for debugging purposes.
        self.clientThread = Thread.current

        // Once everything is ready to go, create a data task with the new request.
        self._dataTask = type(of: self).sharedDemux().dataTask(
            with: recursiveRequest as URLRequest,
            delegate: self,
            modes: self.modes
        )

        self._dataTask?.resume()
    }

    override func stopLoading() {
        // The implementation just cancels the current load (if it's still running).

        cancelPendingChallenge()

        if let task = self._dataTask {
            task.cancel()
            self._dataTask = nil
            // The following ends up calling urlSession(_:task:didCompleteWithError:) with
            // NSURLErrorDomain / NSURLErrorCancelled, which specifically traps and ignores the error.
        }
        // Don't nil out self.modes; see property declaration comments for a discussion of this.

        if !NetworkMonitor.shared.isNetworkEnable {
            return
        }

        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        // Use the intercepted request (with rule modifications applied) if available,
        // so the UI, cURL command, and request info reflect what was actually sent.
        let effectiveRequest = self.interceptedRequest ?? self.request
        model.url = effectiveRequest.url as NSURL?
        model.method = effectiveRequest.httpMethod
        model.mineType = self.response?.mimeType

        // Use capturedRequestBody which includes stream-based bodies
        // (self.request.HTTPBody is nil when the body was sent via HTTPBodyStream)
        if let reqBody = self.capturedRequestBody, reqBody.count > 0 {
            let maxBodySize = UInt(512 * 1024)
            if reqBody.count <= maxBodySize {
                model.requestData = reqBody
            } else {
                model.requestData = reqBody.subdata(in: 0..<Int(maxBodySize))
                model.isRequestBodyTruncated = true
            }
        }
        // NOTE: Do NOT re-read HTTPBodyStream here - it's already consumed by the URL loading
        // system at this point. The body was already converted to HTTPBody in startLoading.

        if let httpResponse = self.response as? HTTPURLResponse {
            model.statusCode = "\(httpResponse.statusCode)"
        } else {
            model.statusCode = "0"
        }

        model.size = ByteCountFormatter().string(fromByteCount: Int64(self.data?.length ?? 0))
        model.responseData = self.data as Data?  // setter writes to disk, frees NSData
        model.isResponseTruncated = self.responseTruncated
        model.isImage = (self.response?.mimeType?.range(of: "image") != nil)

        // Time
        let startTimeDouble = self.startTime
        let endTimeDouble = Date().timeIntervalSince1970
        let durationDouble = abs(endTimeDouble - startTimeDouble)

        model.startTime = String(format: "%f", startTimeDouble)
        model.endTime = String(format: "%f", endTimeDouble)
        model.totalDuration = String(format: "%f (s)", durationDouble)

        model.errorDescription = (self.error as NSError?)?.description
        model.errorLocalizedDescription = self.error?.localizedDescription
        model.requestHeaderFields = effectiveRequest.allHTTPHeaderFields as NSDictionary?

        if let httpResponse = self.response as? HTTPURLResponse {
            model.responseHeaderFields = httpResponse.allHeaderFields as NSDictionary
        }

        if self.response?.mimeType == nil {
            model.isImage = false
        }

        if let absoluteString = model.url?.absoluteString, absoluteString.count > 4 {
            let suffix4 = String(absoluteString.suffix(4))
            if suffix4 == ".png" || suffix4 == ".PNG" ||
               suffix4 == ".jpg" || suffix4 == ".JPG" ||
               suffix4 == ".gif" || suffix4 == ".GIF" {
                model.isImage = true
            }
        }
        if let absoluteString = model.url?.absoluteString, absoluteString.count > 5 {
            let suffix5 = String(absoluteString.suffix(5))
            if suffix5 == ".jpeg" || suffix5 == ".JPEG" {
                model.isImage = true
            }
        }

        // Handling errors 404...
        handleError(self.error, model: model)

        if NetworkRequestStore.shared.addHttpRequset(model) {
            NotificationCenter.default.post(
                name: .networkRequestCompleted,
                object: nil,
                userInfo: ["statusCode": model.statusCode ?? "0"]
            )
        }

        // Release accumulated data immediately - don't wait for dealloc.
        // The model now owns the data; keeping a second reference wastes memory.
        self.data = nil
        self.response = nil
        self.error = nil
        self.interceptedRequest = nil
    }

    // MARK: Authentication challenge handling

    /// Performs the block on the specified thread in one of specified modes.
    private func performOnThread(_ thread: Thread?, modes: [String]?, block: @escaping () -> Void) {
        let effectiveThread = thread ?? Thread.main
        let effectiveModes = (modes?.isEmpty ?? true) ? [RunLoop.Mode.default.rawValue] : modes!
        let box = CPBlockBox(block)
        perform(#selector(onThreadPerformBlock(_:)),
                on: effectiveThread,
                with: box,
                waitUntilDone: false,
                modes: effectiveModes)
    }

    @objc private func onThreadPerformBlock(_ box: CPBlockBox) {
        box.block()
    }

    /// Called by our NSURLSession delegate callback to pass the challenge to our delegate.
    /// This simply passes the challenge over to the main thread.
    private func didReceiveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        performOnThread(nil, modes: nil) {
            self.mainThreadDidReceiveAuthenticationChallenge(challenge, completionHandler: completionHandler)
        }
    }

    /// The main thread side of authentication challenge processing.
    private func mainThreadDidReceiveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if self.pendingChallenge != nil {
            // Our delegate is not expecting a second authentication challenge before resolving the
            // first. Cancel the new challenge.
            clientThreadCancelAuthenticationChallenge(challenge, completionHandler: completionHandler)
        } else {
            let strongDelegate = type(of: self).getDelegate()

            if !(strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:canAuthenticateAgainstProtectionSpace:))) ?? false) {
                clientThreadCancelAuthenticationChallenge(challenge, completionHandler: completionHandler)
            } else {
                // Remember that this challenge is in progress.
                self.pendingChallenge = challenge
                self.pendingChallengeCompletionHandler = completionHandler

                // Pass the challenge to the delegate.
                strongDelegate?.customHTTPProtocol?(self, didReceiveAuthenticationChallenge: self.pendingChallenge!)
            }
        }
    }

    /// Cancels an authentication challenge that hasn't made it to the pending challenge state.
    private func clientThreadCancelAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        performOnThread(self.clientThread, modes: self.modes) {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Cancels an authentication challenge that /has/ made it to the pending challenge state.
    private func cancelPendingChallenge() {
        performOnThread(nil, modes: nil) {
            if self.pendingChallenge == nil {
                // Not unusual - happens every time you shut down the connection.
            } else {
                let strongDelegate = type(of: self).getDelegate()
                let challenge = self.pendingChallenge!
                self.pendingChallenge = nil
                self.pendingChallengeCompletionHandler = nil

                if strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:didCancelAuthenticationChallenge:))) ?? false {
                    strongDelegate?.customHTTPProtocol?(self, didCancelAuthenticationChallenge: challenge)
                }
            }
        }
    }

    @objc func resolveAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                              withCredential credential: URLCredential?) {
        if challenge !== self.pendingChallenge {
            // This should never happen.
            return
        }

        let completionHandler = self.pendingChallengeCompletionHandler!
        self.pendingChallenge = nil
        self.pendingChallengeCompletionHandler = nil

        performOnThread(self.clientThread, modes: self.modes) {
            if credential == nil {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.useCredential, credential)
            }
        }
    }

    // MARK: Error handling

    @discardableResult
    private func handleError(_ error: Error?, model: NetworkTransaction) -> NetworkTransaction {
        if error == nil {
            // https://httpcodes.co/status/
            switch (model.statusCode as NSString?)?.integerValue ?? 0 {
            case 100:
                model.errorDescription = "Informational :\nClient should continue with request"
                model.errorLocalizedDescription = "Continue"
            case 101:
                model.errorDescription = "Informational :\nServer is switching protocols"
                model.errorLocalizedDescription = "Switching Protocols"
            case 102:
                model.errorDescription = "Informational :\nServer has received and is processing the request"
                model.errorLocalizedDescription = "Processing"
            case 103:
                model.errorDescription = "Informational :\nresume aborted PUT or POST requests"
                model.errorLocalizedDescription = "Checkpoint"
            case 122:
                model.errorDescription = "Informational :\nURI is longer than a maximum of 2083 characters"
                model.errorLocalizedDescription = "Request-URI too long"
            case 300:
                model.errorDescription = "Redirection :\nMultiple options for the resource delivered"
                model.errorLocalizedDescription = "Multiple Choices"
            case 301:
                model.errorDescription = "Redirection :\nThis and all future requests directed to the given URI"
                model.errorLocalizedDescription = "Moved Permanently"
            case 302:
                model.errorDescription = "Redirection :\nTemporary response to request found via alternative URI"
                model.errorLocalizedDescription = "Found"
            case 303:
                model.errorDescription = "Redirection :\nPermanent response to request found via alternative URI"
                model.errorLocalizedDescription = "See Other"
            case 304:
                model.errorDescription = "Redirection :\nResource has not been modified since last requested"
                model.errorLocalizedDescription = "Not Modified"
            case 305:
                model.errorDescription = "Redirection :\nContent located elsewhere, retrieve from there"
                model.errorLocalizedDescription = "Use Proxy"
            case 306:
                model.errorDescription = "Redirection :\nSubsequent requests should use the specified proxy"
                model.errorLocalizedDescription = "Switch Proxy"
            case 307:
                model.errorDescription = "Redirection :\nConnect again to different URI as provided"
                model.errorLocalizedDescription = "Temporary Redirect"
            case 308:
                model.errorDescription = "Redirection :\nConnect again to a different URI using the same method"
                model.errorLocalizedDescription = "Permanent Redirect"
            case 400:
                model.errorDescription = "Client Error :\nRequest cannot be fulfilled due to bad syntax"
                model.errorLocalizedDescription = "Bad Request"
            case 401:
                model.errorDescription = "Client Error :\nAuthentication is possible but has failed"
                model.errorLocalizedDescription = "Unauthorized"
            case 402:
                model.errorDescription = "Client Error :\nPayment required, reserved for future use"
                model.errorLocalizedDescription = "Payment Required"
            case 403:
                model.errorDescription = "Client Error :\nServer refuses to respond to request"
                model.errorLocalizedDescription = "Forbidden"
            case 404:
                model.errorDescription = "Client Error :\nRequested resource could not be found"
                model.errorLocalizedDescription = "Not Found"
            case 405:
                model.errorDescription = "Client Error :\nRequest method not supported by that resource"
                model.errorLocalizedDescription = "Method Not Allowed"
            case 406:
                model.errorDescription = "Client Error :\nContent not acceptable according to the Accept headers"
                model.errorLocalizedDescription = "Not Acceptable"
            case 407:
                model.errorDescription = "Client Error :\nClient must first authenticate itself with the proxy"
                model.errorLocalizedDescription = "Proxy Authentication Required"
            case 408:
                model.errorDescription = "Client Error :\nServer timed out waiting for the request"
                model.errorLocalizedDescription = "Request Timeout"
            case 409:
                model.errorDescription = "Client Error :\nRequest could not be processed because of conflict"
                model.errorLocalizedDescription = "Conflict"
            case 410:
                model.errorDescription = "Client Error :\nResource is no longer available and will not be available again"
                model.errorLocalizedDescription = "Gone"
            case 411:
                model.errorDescription = "Client Error :\nRequest did not specify the length of its content"
                model.errorLocalizedDescription = "Length Required"
            case 412:
                model.errorDescription = "Client Error :\nServer does not meet request preconditions"
                model.errorLocalizedDescription = "Precondition Failed"
            case 413:
                model.errorDescription = "Client Error :\nRequest is larger than the server is willing or able to process"
                model.errorLocalizedDescription = "Request Entity Too Large"
            case 414:
                model.errorDescription = "Client Error :\nURI provided was too long for the server to process"
                model.errorLocalizedDescription = "Request-URI Too Long"
            case 415:
                model.errorDescription = "Client Error :\nServer does not support media type"
                model.errorLocalizedDescription = "Unsupported Media Type"
            case 416:
                model.errorDescription = "Client Error :\nClient has asked for unprovidable portion of the file"
                model.errorLocalizedDescription = "Requested Range Not Satisfiable"
            case 417:
                model.errorDescription = "Client Error :\nServer cannot meet requirements of Expect request-header field"
                model.errorLocalizedDescription = "Expectation Failed"
            case 418:
                model.errorDescription = "Client Error :\nI'm a teapot"
                model.errorLocalizedDescription = "I'm a Teapot"
            case 420:
                model.errorDescription = "Client Error :\nTwitter rate limiting"
                model.errorLocalizedDescription = "Enhance Your Calm"
            case 421:
                model.errorDescription = "Client Error :\nMisdirected Request"
                model.errorLocalizedDescription = "Misdirected Request"
            case 422:
                model.errorDescription = "Client Error :\nRequest unable to be followed due to semantic errors"
                model.errorLocalizedDescription = "Unprocessable Entity"
            case 423:
                model.errorDescription = "Client Error :\nResource that is being accessed is locked"
                model.errorLocalizedDescription = "Locked"
            case 424:
                model.errorDescription = "Client Error :\nRequest failed due to failure of a previous request"
                model.errorLocalizedDescription = "Failed Dependency"
            case 426:
                model.errorDescription = "Client Error :\nClient should switch to a different protocol"
                model.errorLocalizedDescription = "Upgrade Required"
            case 428:
                model.errorDescription = "Client Error :\nOrigin server requires the request to be conditional"
                model.errorLocalizedDescription = "Precondition Required"
            case 429:
                model.errorDescription = "Client Error :\nUser has sent too many requests in a given amount of time"
                model.errorLocalizedDescription = "Too Many Requests"
            case 431:
                model.errorDescription = "Client Error :\nServer is unwilling to process the request"
                model.errorLocalizedDescription = "Request Header Fields Too Large"
            case 444:
                model.errorDescription = "Client Error :\nServer returns no information and closes the connection"
                model.errorLocalizedDescription = "No Response"
            case 449:
                model.errorDescription = "Client Error :\nRequest should be retried after performing action"
                model.errorLocalizedDescription = "Retry With"
            case 450:
                model.errorDescription = "Client Error :\nWindows Parental Controls blocking access to webpage"
                model.errorLocalizedDescription = "Blocked by Windows Parental Controls"
            case 451:
                model.errorDescription = "Client Error :\nThe server cannot reach the client's mailbox"
                model.errorLocalizedDescription = "Wrong Exchange server"
            case 499:
                model.errorDescription = "Client Error :\nConnection closed by client while HTTP server is processing"
                model.errorLocalizedDescription = "Client Closed Request"
            case 500:
                model.errorDescription = "Server Error :\ngeneric error message"
                model.errorLocalizedDescription = "Internal Server Error"
            case 501:
                model.errorDescription = "Server Error :\nserver does not recognise method or lacks ability to fulfill"
                model.errorLocalizedDescription = "Not Implemented"
            case 502:
                model.errorDescription = "Server Error :\nserver received an invalid response from upstream server"
                model.errorLocalizedDescription = "Bad Gateway"
            case 503:
                model.errorDescription = "Server Error :\nserver is currently unavailable"
                model.errorLocalizedDescription = "Service Unavailable"
            case 504:
                model.errorDescription = "Server Error :\ngateway did not receive response from upstream server"
                model.errorLocalizedDescription = "Gateway Timeout"
            case 505:
                model.errorDescription = "Server Error :\nserver does not support the HTTP protocol version"
                model.errorLocalizedDescription = "HTTP Version Not Supported"
            case 506:
                model.errorDescription = "Server Error :\ncontent negotiation for the request results in a circular reference"
                model.errorLocalizedDescription = "Variant Also Negotiates"
            case 507:
                model.errorDescription = "Server Error :\nserver is unable to store the representation"
                model.errorLocalizedDescription = "Insufficient Storage"
            case 508:
                model.errorDescription = "Server Error :\nserver detected an infinite loop while processing the request"
                model.errorLocalizedDescription = "Loop Detected"
            case 509:
                model.errorDescription = "Server Error :\nbandwidth limit exceeded"
                model.errorLocalizedDescription = "Bandwidth Limit Exceeded"
            case 510:
                model.errorDescription = "Server Error :\nfurther extensions to the request are required"
                model.errorLocalizedDescription = "Not Extended"
            case 511:
                model.errorDescription = "Server Error :\nclient needs to authenticate to gain network access"
                model.errorLocalizedDescription = "Network Authentication Required"
            case 526:
                model.errorDescription = "Server Error :\nThe origin web server does not have a valid SSL certificate"
                model.errorLocalizedDescription = "Invalid SSL certificate"
            case 598:
                model.errorDescription = "Server Error :\nnetwork read timeout behind the proxy"
                model.errorLocalizedDescription = "Network Read Timeout Error"
            case 599:
                model.errorDescription = "Server Error :\nnetwork connect timeout behind the proxy"
                model.errorLocalizedDescription = "Network Connect Timeout Error"
            default:
                break
            }
        }
        return model
    }
}

// MARK: - URLSessionDataDelegate

extension CustomHTTPProtocol: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirect: code >= 300 && < 400
        var redirectedRequest: URLRequest? = request
        if response.statusCode >= 300 && response.statusCode < 400 {
            self.client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
            // Remember to set to nil, otherwise the normal request will be requested twice
            redirectedRequest = nil
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Ask our delegate whether it wants this challenge. We do this from this thread, not the
        // main thread, to avoid the overload of bouncing to the main thread for challenges that
        // aren't going to be customised anyway.
        let strongDelegate = type(of: self).getDelegate()

        var result = false
        if strongDelegate?.responds(to: #selector(CustomHTTPProtocolDelegate.customHTTPProtocol(_:canAuthenticateAgainstProtectionSpace:))) ?? false {
            result = strongDelegate!.customHTTPProtocol?(self, canAuthenticateAgainstProtectionSpace: challenge.protectionSpace) ?? false
        }

        // If the client wants the challenge, kick off that process. If not, resolve it by doing
        // the default thing.
        if result {
            didReceiveAuthenticationChallenge(challenge, completionHandler: completionHandler)
        } else {
            // Callback the original method
            let challengeWrapper = URLAuthenticationChallenge(
                authenticationChallenge: challenge,
                sender: CPURLSessionChallengeSender(sessionCompletionHandler: completionHandler)
            )
            self.client?.urlProtocol(self, didReceive: challengeWrapper)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Pass the call on to our client. The only tricky thing is that we have to decide on a
        // cache storage policy, which is based on the actual request we issued, not the request
        // we were given.
        let cacheStoragePolicy: URLCache.StoragePolicy
        if let httpResponse = response as? HTTPURLResponse {
            cacheStoragePolicy = CacheStoragePolicyForRequestAndResponse(
                self._dataTask?.originalRequest ?? self.request,
                httpResponse
            )
        } else {
            cacheStoragePolicy = .notAllowed
        }

        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: cacheStoragePolicy)

        self.response = response

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        // Just pass the call on to our client.
        self.client?.urlProtocol(self, didLoad: data)

        // Only accumulate for SwiftyDebug's capture if under the size cap.
        // The client always receives the full, unmodified data above.
        if !self.responseTruncated {
            let maxSize = Int(UInt(10 * 1024 * 1024))
            let currentLength = self.data?.length ?? 0
            if currentLength + data.count <= maxSize {
                self.data?.append(data)
            } else {
                let remaining = maxSize - currentLength
                if remaining > 0 {
                    self.data?.append(data.subdata(in: 0..<remaining))
                }
                self.responseTruncated = true
            }
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(proposedResponse)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            self.client?.urlProtocol(self, didFailWithError: error)
            self.error = error
        } else {
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}
