//
//  NetworkRequestStore.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

class NetworkRequestStore: NSObject {

    // MARK: - Capacity

    /// Upper bound on how many captured transactions are kept in memory.
    ///
    /// Without this the array grew for the entire life of the HOST process —
    /// a long-lived app doing steady traffic accumulated every request until the
    /// user happened to tap Clear. Once the count passes this limit the OLDEST
    /// unpinned transactions are evicted; pinned ones are never evicted, so a
    /// store whose contents are all pinned deliberately exceeds the limit.
    ///
    /// Deliberately generous: a debugging session is worth little if the request
    /// you want to compare against has already been evicted. Bodies live on disk
    /// (see `NetworkTransaction.responseData`), so the in-memory cost of a
    /// retained transaction is its metadata, not its payload.
    static let maxCapturedTransactions = 1500

    // MARK: - Storage

    /// The live mutable array. PRIVATE on purpose.
    ///
    /// It is mutated from the URLProtocol threads (see `addHttpRequset`), so every
    /// read has to happen under the same `objc_sync_enter(self)` the mutations use.
    /// It used to be exposed directly, and callers did
    /// `store.httpModels as NSArray as? [NetworkTransaction]` on the main thread —
    /// that bridge ENUMERATES the array, and a concurrent `add` from a network
    /// thread mid-enumeration is the classic
    /// "Collection <__NSArrayM> was mutated while being enumerated" crash, taken in
    /// the host app just for having the network screen open. Read via `snapshot()`.
    private let storage: NSMutableArray

    static let shared = NetworkRequestStore()

    private override init() {
        storage = NSMutableArray(capacity: NetworkRequestStore.maxCapturedTransactions)
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
            storage.add(model)
        }
        // No capacity enforcement here: everything restored above is pinned, and
        // pinned entries are never evictable.
    }

    // MARK: - Reading

    /// The ONLY supported way to read the store.
    ///
    /// Copies the backing array under the same lock the network threads mutate it
    /// under, so the caller ends up with a plain Swift array nothing else can touch.
    /// Oldest first, matching insertion order.
    func snapshot() -> [NetworkTransaction] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        return storage.compactMap { $0 as? NetworkTransaction }
    }

    /// Thread-safe count. Cheaper than `snapshot().count` when only the size is needed.
    var transactionCount: Int {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        return storage.count
    }

    /// Legacy read-only accessor kept so existing call sites keep compiling.
    ///
    /// It returns a locked SNAPSHOT, not the live array — mutating what you get
    /// back cannot affect the store. Prefer `snapshot()`, which avoids the bridge
    /// entirely.
    @available(*, deprecated, message: "Use snapshot() — this returns a copy, and reading the live array off-lock crashed with 'mutated while being enumerated'.")
    var httpModels: NSArray {
        return snapshot() as NSArray
    }

    // MARK: - Writing

    /// NOTE: Keeping the typo "Requset" in the method name for compatibility
    func addHttpRequset(_ model: NetworkTransaction) -> Bool {
        if model.url?.absoluteString == "" {
            return false
        }

        // Declared outside the locked scope on purpose: dropping the last
        // reference to a NetworkTransaction runs its deinit, which deletes that
        // model's body files from disk. Doing file I/O while holding the store
        // lock would stall any main-thread `snapshot()` behind it.
        var evicted: [NetworkTransaction] = []
        var didAdd = false

        do {
            // All mutations to `storage` must be synchronized - stopLoading is called
            // from different protocol instance threads concurrently.
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }

            // detect repeated (guard against nil — in ObjC [nil isEqualToString:nil] returns NO)
            var isExist = false
            for i in 0..<storage.count {
                if let obj = storage[i] as? NetworkTransaction {
                    if let rid = obj.requestId, let mrid = model.requestId, rid == mrid {
                        isExist = true
                        break
                    }
                }
            }

            if !isExist {
                storage.add(model)
                evicted = evictOverflowLocked()
                didAdd = true
            }
        }

        // Outside the lock. Each evicted model's files are removed exactly once,
        // by its own deinit, and only once every other holder (an open detail
        // screen, an in-flight snapshot) has let go of it too.
        evicted.removeAll()

        return didAdd
    }

    func reset() {
        var dropped: [NetworkTransaction] = []

        do {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }

            // Preserve pinned requests
            let all = storage.compactMap { $0 as? NetworkTransaction }
            dropped = all.filter { !$0.isPinned }
            let pinned = all.filter { $0.isPinned }
            storage.removeAllObjects()
            for model in pinned {
                storage.add(model)
            }
        }

        // Released off-lock; see addHttpRequset.
        //
        // No directory wipe here. Dropping the last reference to every non-pinned
        // model lets `NetworkTransaction.deinit` remove exactly that model's own
        // two files. A directory-wide wipe would additionally destroy the bodies of
        // requests still being captured — a request completing around the moment
        // Clear is tapped would land in the list with its file already gone, which
        // is indistinguishable from having had no response at all.
        dropped.removeAll()
    }

    func clearPinned() {
        var dropped: [NetworkTransaction] = []

        do {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }

            NetworkTransaction.clearPinnedDiskCache()

            // Remove pinned models from memory
            let pinned = storage.compactMap { $0 as? NetworkTransaction }.filter { $0.isPinned }
            for model in pinned {
                storage.remove(model)
            }
            dropped = pinned
        }

        dropped.removeAll()

        NotificationCenter.default.post(name: .allLogsCleared, object: nil)
    }

    func remove(_ model: NetworkTransaction) {
        var dropped: [NetworkTransaction] = []

        do {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }

            for i in stride(from: storage.count - 1, through: 0, by: -1) {
                if let obj = storage[i] as? NetworkTransaction {
                    if let rid = obj.requestId, let mrid = model.requestId, rid == mrid {
                        dropped.append(obj)
                        storage.removeObject(at: i)
                    }
                }
            }
        }

        dropped.removeAll()
    }

    // MARK: - Eviction

    /// Trims `storage` to `maxCapturedTransactions` and returns what came out, so
    /// the caller can release it after unlocking. Must be called with the lock held.
    private func evictOverflowLocked() -> [NetworkTransaction] {
        guard storage.count > NetworkRequestStore.maxCapturedTransactions else { return [] }

        let pinnedFlags = storage.map { ($0 as? NetworkTransaction)?.isPinned ?? false }
        let doomed = NetworkRequestStore.evictionIndices(isPinned: pinnedFlags,
                                                         limit: NetworkRequestStore.maxCapturedTransactions)
        guard !doomed.isEmpty else { return [] }

        var evicted: [NetworkTransaction] = []
        // Descending, so removing one does not shift the indices of the rest.
        for index in doomed.reversed() {
            if let model = storage[index] as? NetworkTransaction {
                evicted.append(model)
            }
            storage.removeObject(at: index)
        }
        return evicted
    }

    /// Which entries to evict, oldest first, given each entry's pinned flag.
    /// Pure so it can be tested without the singleton.
    ///
    /// Pinned entries are skipped entirely: if there are not enough unpinned
    /// entries to get back under `limit` this returns fewer indices than the
    /// overflow — possibly none — and the store stays over the limit rather than
    /// throwing away something the user explicitly pinned.
    ///
    /// Returned indices are ascending and refer to positions in the input.
    static func evictionIndices(isPinned: [Bool], limit: Int) -> [Int] {
        var overflow = isPinned.count - limit
        guard overflow > 0 else { return [] }

        var doomed: [Int] = []
        for index in isPinned.indices where !isPinned[index] {
            if overflow == 0 { break }
            doomed.append(index)
            overflow -= 1
        }
        return doomed
    }
}
