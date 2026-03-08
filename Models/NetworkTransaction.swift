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
            if fm.fileExists(atPath: resPath) {
                model.responseData = try? Data(contentsOf: URL(fileURLWithPath: resPath))
            }

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

            let fileName = "req_\(UUID().uuidString)"
            let filePath = (NetworkTransaction.diskCacheDirectory() as NSString).appendingPathComponent(fileName)
            try? data.write(to: URL(fileURLWithPath: filePath))
            _requestDataFilePath = filePath
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

            let fileName = "res_\(UUID().uuidString)"
            let filePath = (NetworkTransaction.diskCacheDirectory() as NSString).appendingPathComponent(fileName)
            try? data.write(to: URL(fileURLWithPath: filePath))
            _responseDataFilePath = filePath
        }
    }
}
