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
        // The previous-session sweep does NOT happen here.
        //
        // This is a lazily-created singleton, and the thing that first touches it
        // is `CustomHTTPProtocol.stopLoading` — which has already written the
        // response body to disk 55 lines earlier. Wiping the directory from this
        // initializer therefore deleted the body of the very request that caused
        // the initialization, leaving `responseDataSize` reporting N bytes while
        // `responseData` returned nil, and the RESPONSE section silently absent.
        // It looked intermittent because it can only fire once per session, and
        // not at all if the debug UI is opened before the first network call.
        //
        // `SwiftyDebug.initializationMethod()` now runs the sweep at startup,
        // before the URLProtocol is registered and while nothing is in flight.
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
        // No directory wipe here. `removeAllObjects()` above dropped the last
        // reference to every non-pinned model, and `NetworkTransaction.deinit`
        // removes exactly that model's own two files. A directory-wide wipe would
        // additionally destroy the bodies of requests still being captured — a
        // request completing around the moment Clear is tapped would land in the
        // list with its file already gone, which is indistinguishable from having
        // had no response at all.
    }

    func clearPinned() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        NetworkTransaction.clearPinnedDiskCache()

        // Remove pinned models from memory
        let pinned = httpModels.compactMap { $0 as? NetworkTransaction }.filter { $0.isPinned }
        for model in pinned {
            httpModels.remove(model)
        }

        NotificationCenter.default.post(name: .allLogsCleared, object: nil)
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
