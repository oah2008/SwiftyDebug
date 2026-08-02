//
//  NetworkTransaction.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

class NetworkTransaction: NSObject {

    var url: NSURL?
    var requestDataSize: UInt = 0
    var responseDataSize: UInt = 0
    var requestId: String?
    var method: String?
    var statusCode: String?
    var mineType: String?
    var startTime: String?
    var endTime: String?
    var totalDuration: String?
    var isImage: Bool = false
    var isResponseTruncated: Bool = false
    var isRequestBodyTruncated: Bool = false
    var isWebViewRequest: Bool = false
    var requestHeaderFields: NSDictionary?
    var responseHeaderFields: NSDictionary?
    var isTag: Bool = false
    var isSelected: Bool = false
    var isViewed: Bool = false
    var isPinned: Bool = false
    var requestSerializer: RequestSerializer = .json
    var errorDescription: String?
    var errorLocalizedDescription: String?
    var size: String?

    // MARK: - Response rewrites (see RESPONSE-REWRITE)

    /// True when `ResponseRewriteEngine` actually changed the response body
    /// before the app saw it — i.e. the app was handed data the server never
    /// sent. Everything that displays this transaction has to say so, otherwise
    /// the next bug report is a phantom hunt for a value no server ever returned.
    var isResponseRewritten: Bool = false

    /// How many individual JSON values were changed. 0 with
    /// `isResponseRewritten == false` still leaves `rewriteNotes` populated —
    /// "armed and matched nothing" is a result the developer needs to see.
    var rewrittenValueCount: Int = 0

    /// One human-readable line per rewrite that ran, INCLUDING the ones that
    /// matched nothing. Built at capture time (never re-derived in
    /// `cellForRowAt`) so the detail screen is pure layout.
    var rewriteNotes: [String] = []

    /// Why the engine never ran at all: body not JSON, body over the size cap,
    /// re-encoding failed. Shown verbatim so "my rewrite did nothing" always has
    /// an answer.
    var rewriteSkippedReason: String?
    /// Why an ARMED breakpoint never paused this request. Separate from the
    /// rewrite reason because they are different promises, and a developer
    /// chasing a pause that never came should not have to read a section headed
    /// RESPONSE REWRITES to find out why.
    var breakpointSkippedReason: String?

    /// True when this transaction has anything to say about rewrites.
    var hasRewriteInfo: Bool {
        !rewriteNotes.isEmpty || (rewriteSkippedReason?.isEmpty == false)
            || (breakpointSkippedReason?.isEmpty == false)
    }

    /// Copies a `RewriteReport` onto this transaction, resolving each entry's
    /// id back to the rewrite it came from so the notes carry the rule's own
    /// display name rather than a UUID.
    ///
    /// Called once, from `CustomHTTPProtocol.stopLoading()`, while the engine's
    /// result is still in memory.
    func recordRewriteReport(_ report: RewriteReport, rewrites: [ResponseRewrite]) {
        isResponseRewritten = report.didChange
        rewrittenValueCount = report.changedCount
        rewriteSkippedReason = report.skippedReason
        rewriteNotes = report.entries.map { entry in
            let name = rewrites.first { $0.id == entry.rewriteId }?.displayName ?? "Rewrite"
            var line = "\(name)\n  matched \(entry.matched), changed \(entry.changed)"
            // A rewrite that matched nothing is the failure mode this feature has
            // to make impossible to miss, so it gets said in words, not just a 0.
            if entry.matched == 0 {
                line += "\n  ⚠︎ no values matched this path"
            } else if entry.changed == 0 && entry.error == nil {
                line += "\n  ⚠︎ every matched value already had this value"
            }
            if let error = entry.error {
                line += "\n  ⚠︎ \(error)"
            }
            return line
        }
    }

    /// Precomputed searchable metadata, built once at capture time so search
    /// never touches disk. See `RequestSearchIndex`. Also exposes `imageURLs`
    /// for the media grid / Media tab.
    var searchIndex: RequestSearchIndex?

    /// Image URLs discovered in the response body at capture time (empty if the
    /// response wasn't JSON or contained no images).
    var imageURLs: [String] { searchIndex?.imageURLs ?? [] }

    /// Builds `searchIndex` from the current in-memory fields plus the given
    /// response body (pass the already-loaded `Data`; do not read from disk).
    /// Call once, at capture time, on a background-safe context.
    func buildSearchIndex(responseBody: Data?) {
        searchIndex = RequestSearchIndex.build(from: self, responseBody: responseBody)
        // Feed the persisted header-name suggestion registry (INTERCEPT-UX).
        HeaderSuggestionStore.shared.record(headers: requestHeaderFields)
        // Feed the persistent header/param metadata store, which survives
        // clearing captured requests and powers the intercept editor.
        RequestMetadataStore.shared.record(self)
    }

    private var _requestDataFilePath: String?
    private var _responseDataFilePath: String?

    // MARK: - Disk Cache Directory

    // Thread-safe lazy init (equivalent to ObjC dispatch_once)
    private static let _diskCacheDirectoryValue: String = {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        return (caches as NSString).appendingPathComponent("SwiftyDebug/NetworkData")
    }()

    private static let _pinnedDirectoryValue: String = {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        return (caches as NSString).appendingPathComponent("SwiftyDebug/PinnedNetworkData")
    }()

    static func diskCacheDirectory() -> String {
        let dir = _diskCacheDirectoryValue
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    static func pinnedDirectory() -> String {
        let dir = _pinnedDirectoryValue
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    static func clearDiskCache() {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        let dir = (caches as NSString).appendingPathComponent("SwiftyDebug/NetworkData")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - Pinned persistence

    func savePinToDisk() {
        let dir = NetworkTransaction.pinnedDirectory()
        let id = requestId ?? UUID().uuidString
        let safeId = id.replacingOccurrences(of: "/", with: "_")

        var dict: [String: Any] = [:]
        dict["url"] = url?.absoluteString
        dict["requestId"] = requestId
        dict["method"] = method
        dict["statusCode"] = statusCode
        dict["mineType"] = mineType
        dict["startTime"] = startTime
        dict["endTime"] = endTime
        dict["totalDuration"] = totalDuration
        dict["isImage"] = isImage
        dict["isResponseTruncated"] = isResponseTruncated
        dict["isRequestBodyTruncated"] = isRequestBodyTruncated
        dict["isWebViewRequest"] = isWebViewRequest
        dict["requestDataSize"] = requestDataSize
        dict["responseDataSize"] = responseDataSize
        dict["errorDescription"] = errorDescription
        dict["errorLocalizedDescription"] = errorLocalizedDescription
        dict["size"] = size
        // A pinned rewritten response must keep saying it was rewritten. Pinning
        // is the only place a transaction outlives the process, so this is the
        // only persistence the badge needs.
        dict["isResponseRewritten"] = isResponseRewritten
        if let breakpointSkippedReason { dict["breakpointSkippedReason"] = breakpointSkippedReason }
        dict["rewrittenValueCount"] = rewrittenValueCount
        dict["rewriteNotes"] = rewriteNotes
        dict["rewriteSkippedReason"] = rewriteSkippedReason

        // Serialize headers as JSON-compatible dictionaries
        if let reqHeaders = requestHeaderFields as? [String: Any] {
            dict["requestHeaderFields"] = reqHeaders
        }
        if let resHeaders = responseHeaderFields as? [String: Any] {
            dict["responseHeaderFields"] = resHeaders
        }

        // Save metadata JSON
        let metaPath = (dir as NSString).appendingPathComponent("pin_\(safeId).json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            try? jsonData.write(to: URL(fileURLWithPath: metaPath))
        }

        // Copy request/response data files to pinned directory
        if let reqData = requestData {
            let reqPath = (dir as NSString).appendingPathComponent("pin_\(safeId)_req")
            try? reqData.write(to: URL(fileURLWithPath: reqPath))
        }
        if let resData = responseData {
            let resPath = (dir as NSString).appendingPathComponent("pin_\(safeId)_res")
            try? resData.write(to: URL(fileURLWithPath: resPath))
        }
    }

    func removePinFromDisk() {
        let dir = NetworkTransaction.pinnedDirectory()
        let id = requestId ?? ""
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        let fm = FileManager.default
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent("pin_\(safeId).json"))
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent("pin_\(safeId)_req"))
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent("pin_\(safeId)_res"))
    }

    static func loadPinnedFromDisk() -> [NetworkTransaction] {
        let dir = pinnedDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var results: [NetworkTransaction] = []
        for file in files where file.hasSuffix(".json") {
            let metaPath = (dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let model = NetworkTransaction()
            model.isPinned = true
            if let urlStr = dict["url"] as? String { model.url = NSURL(string: urlStr) }
            model.requestId = dict["requestId"] as? String
            model.method = dict["method"] as? String
            model.statusCode = dict["statusCode"] as? String
            model.mineType = dict["mineType"] as? String
            model.startTime = dict["startTime"] as? String
            model.endTime = dict["endTime"] as? String
            model.totalDuration = dict["totalDuration"] as? String
            model.isImage = dict["isImage"] as? Bool ?? false
            model.isResponseTruncated = dict["isResponseTruncated"] as? Bool ?? false
            model.isRequestBodyTruncated = dict["isRequestBodyTruncated"] as? Bool ?? false
            model.isWebViewRequest = dict["isWebViewRequest"] as? Bool ?? false
            model.requestDataSize = (dict["requestDataSize"] as? UInt) ?? UInt(dict["requestDataSize"] as? Int ?? 0)
            model.responseDataSize = (dict["responseDataSize"] as? UInt) ?? UInt(dict["responseDataSize"] as? Int ?? 0)
            model.errorDescription = dict["errorDescription"] as? String
            model.errorLocalizedDescription = dict["errorLocalizedDescription"] as? String
            model.size = dict["size"] as? String
            model.isResponseRewritten = dict["isResponseRewritten"] as? Bool ?? false
            model.breakpointSkippedReason = dict["breakpointSkippedReason"] as? String
            model.rewrittenValueCount = dict["rewrittenValueCount"] as? Int ?? 0
            model.rewriteNotes = dict["rewriteNotes"] as? [String] ?? []
            model.rewriteSkippedReason = dict["rewriteSkippedReason"] as? String

            if let reqHeaders = dict["requestHeaderFields"] as? [String: Any] {
                model.requestHeaderFields = reqHeaders as NSDictionary
            }
            if let resHeaders = dict["responseHeaderFields"] as? [String: Any] {
                model.responseHeaderFields = resHeaders as NSDictionary
            }

            // Load request/response data from pinned directory
            let safeId = (model.requestId ?? "").replacingOccurrences(of: "/", with: "_")
            let reqPath = (dir as NSString).appendingPathComponent("pin_\(safeId)_req")
            if fm.fileExists(atPath: reqPath) {
                model.requestData = try? Data(contentsOf: URL(fileURLWithPath: reqPath))
            }
            let resPath = (dir as NSString).appendingPathComponent("pin_\(safeId)_res")
            var loadedResponse: Data?
            if fm.fileExists(atPath: resPath) {
                loadedResponse = try? Data(contentsOf: URL(fileURLWithPath: resPath))
                model.responseData = loadedResponse
            }

            // Rebuild the search/media index for pinned models (they were
            // deserialized, so the index wasn't carried over).
            model.buildSearchIndex(responseBody: loadedResponse)

            results.append(model)
        }
        return results
    }

    static func clearPinnedDiskCache() {
        let dir = _pinnedDirectoryValue
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - Init / Deinit

    override init() {
        super.init()
        self.statusCode = "0"
        self.url = NSURL(string: "")
    }

    deinit {
        // Clean up disk files when model is evicted from NetworkRequestStore
        if let path = _requestDataFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let path = _responseDataFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Disk-backed requestData

    var requestData: Data? {
        get {
            guard let path = _requestDataFilePath else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        set {
            // Remove old file if exists
            if let oldPath = _requestDataFilePath {
                try? FileManager.default.removeItem(atPath: oldPath)
                _requestDataFilePath = nil
            }

            requestDataSize = UInt(newValue?.count ?? 0)

            guard let data = newValue, data.count > 0 else {
                return
            }

            // Record the path ONLY on a successful write. Assigning it
            // unconditionally after `try?` meant a failed write left the model
            // claiming N bytes it could never produce, and the body silently
            // rendered as nothing.
            let fileName = "req_\(UUID().uuidString)"
            let filePath = (NetworkTransaction.diskCacheDirectory() as NSString).appendingPathComponent(fileName)
            do {
                try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                _requestDataFilePath = filePath
            } catch {
                _requestDataFilePath = nil
                requestDataSize = 0
            }
        }
    }

    // MARK: - Disk-backed responseData

    var responseData: Data? {
        get {
            guard let path = _responseDataFilePath else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        set {
            // Remove old file if exists
            if let oldPath = _responseDataFilePath {
                try? FileManager.default.removeItem(atPath: oldPath)
                _responseDataFilePath = nil
            }

            responseDataSize = UInt(newValue?.count ?? 0)

            guard let data = newValue, data.count > 0 else {
                return
            }

            // See requestData: size and path must agree, or the UI reports a
            // body that cannot be read back.
            let fileName = "res_\(UUID().uuidString)"
            let filePath = (NetworkTransaction.diskCacheDirectory() as NSString).appendingPathComponent(fileName)
            do {
                try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                _responseDataFilePath = filePath
            } catch {
                _responseDataFilePath = nil
                responseDataSize = 0
            }
        }
    }
}
