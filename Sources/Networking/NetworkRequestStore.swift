//
//  NetworkRequestStore.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

class NetworkRequestStore: NSObject {

    var httpModels: NSMutableArray

    static let shared = NetworkRequestStore()

    private override init() {
        httpModels = NSMutableArray(capacity: 500)
        super.init()
        // Clear leftover disk cache from previous app session
        NetworkTransaction.clearDiskCache()
        // Restore pinned requests from previous session
        let pinned = NetworkTransaction.loadPinnedFromDisk()
        for model in pinned {
            httpModels.add(model)
        }
    }

    /// NOTE: Keeping the typo "Requset" in the method name for compatibility
    func addHttpRequset(_ model: NetworkTransaction) -> Bool {
        if model.url?.absoluteString == "" {
            return false
        }

        // All mutations to httpModels must be synchronized - stopLoading is called
        // from different protocol instance threads concurrently.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        // detect repeated (guard against nil — in ObjC [nil isEqualToString:nil] returns NO)
        var isExist = false
        for i in 0..<httpModels.count {
            if let obj = httpModels[i] as? NetworkTransaction {
                if let rid = obj.requestId, let mrid = model.requestId, rid == mrid {
                    isExist = true
                    break
                }
            }
        }
        if isExist {
            return false
        }

        httpModels.add(model)

        return true
    }

    func reset() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        // Preserve pinned requests
        let pinned = httpModels.compactMap { $0 as? NetworkTransaction }.filter { $0.isPinned }
        httpModels.removeAllObjects()
        for model in pinned {
            httpModels.add(model)
        }
        // Only clear disk cache for non-pinned entries (pinned files still on disk)
        if pinned.isEmpty {
            NetworkTransaction.clearDiskCache()
        }
    }

    func remove(_ model: NetworkTransaction) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        for i in stride(from: httpModels.count - 1, through: 0, by: -1) {
            if let obj = httpModels[i] as? NetworkTransaction {
                if let rid = obj.requestId, let mrid = model.requestId, rid == mrid {
                    httpModels.removeObject(at: i)
                }
            }
        }
    }
}
