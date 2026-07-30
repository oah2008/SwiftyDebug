//
//  NetworkRequestStoreSnapshotTests.swift
//  SwiftyDebugTests
//
//  `NetworkRequestStore.httpModels` was an NSMutableArray mutated from the
//  URLProtocol threads under `objc_sync_enter(self)`, and the UI read it on the
//  main thread with no lock at all:
//
//      httpModels as NSArray as? [NetworkTransaction]
//
//  That bridge enumerates the array. An `add` landing from a network thread
//  mid-enumeration is "Collection <__NSArrayM> was mutated while being
//  enumerated" — a main-thread crash in somebody else's app, triggered by
//  nothing more than leaving the network screen open while requests flow.
//
//  These tests cover the replacement (`snapshot()`, copied under the same lock)
//  and the capacity cap that stops the array growing for the life of the host
//  process.
//

import XCTest
@testable import SwiftyDebug

final class NetworkRequestStoreSnapshotTests: XCTestCase {

    private var store: NetworkRequestStore { NetworkRequestStore.shared }

    override func setUp() {
        super.setUp()
        emptyStore()
    }

    override func tearDown() {
        emptyStore()
        super.tearDown()
    }

    /// `reset()` deliberately keeps pinned entries, so unpin first.
    /// `clearPinned()` is avoided on purpose — it wipes the pinned disk cache,
    /// which is shared state no test should be destroying.
    private func emptyStore() {
        for model in store.snapshot() {
            model.isPinned = false
        }
        store.reset()
    }

    private func makeTransaction(_ path: String) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com\(path)")
        return model
    }

    @discardableResult
    private func fill(_ count: Int, prefix: String = "/req") -> Int {
        var added = 0
        for i in 0..<count where store.addHttpRequset(makeTransaction("\(prefix)/\(i)")) {
            added += 1
        }
        return added
    }

    // MARK: - evictionIndices (pure)

    func testNoEvictionBelowOrAtTheLimit() {
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: [], limit: 3), [])
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: [false, false], limit: 3), [])
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: [false, false, false], limit: 3), [])
    }

    func testEvictsOldestFirst() {
        let flags = Array(repeating: false, count: 6)
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: flags, limit: 4), [0, 1])
    }

    func testPinnedEntriesAreSkippedAndTheNextOldestGoesInstead() {
        // index 0 and 1 pinned; overflow of 2 must come from 2 and 3.
        let flags = [true, true, false, false, false, false]
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: flags, limit: 4), [2, 3])
    }

    func testEvictionStopsRatherThanTouchingPinnedEntries() {
        // Five entries, limit 2, but only one is unpinned: overflow is 3 and we
        // can only satisfy 1 of it. Staying over the limit beats deleting
        // something the user pinned.
        let flags = [true, false, true, true, true]
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: flags, limit: 2), [1])
    }

    func testAllPinnedEvictsNothing() {
        let flags = Array(repeating: true, count: 8)
        XCTAssertEqual(NetworkRequestStore.evictionIndices(isPinned: flags, limit: 2), [])
    }

    // MARK: - snapshot()

    func testSnapshotReturnsInsertionOrder() {
        fill(5, prefix: "/ordered")

        let models = store.snapshot()
        XCTAssertEqual(models.count, 5)
        XCTAssertEqual(models.compactMap { $0.url?.path }, (0..<5).map { "/ordered/\($0)" })
    }

    func testSnapshotIsACopyAndNotAViewOntoTheStore() {
        fill(3)

        var models = store.snapshot()
        models.removeAll()
        models.append(makeTransaction("/not-in-the-store"))

        XCTAssertEqual(store.snapshot().count, 3, "mutating a snapshot must not reach the store")
        XCTAssertEqual(store.transactionCount, 3)
    }

    func testTransactionCountMatchesSnapshot() {
        fill(7)
        XCTAssertEqual(store.transactionCount, store.snapshot().count)
    }

    func testRemovedModelLeavesTheSnapshot() {
        let doomed = makeTransaction("/remove-me")
        XCTAssertTrue(store.addHttpRequset(doomed))
        fill(2)

        store.remove(doomed)

        let ids = store.snapshot().compactMap { $0.requestId }
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains(doomed.requestId ?? ""))
    }

    // MARK: - The crash this whole change exists for

    func testSnapshotIsSafeWhileOtherThreadsAdd() {
        let producers = DispatchGroup()

        for producer in 0..<3 {
            producers.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { producers.leave() }
                guard let self = self else { return }
                for i in 0..<800 {
                    _ = self.store.addHttpRequset(self.makeTransaction("/p\(producer)/\(i)"))
                }
            }
        }

        // Read the way the UI reads, as hard as possible, for as long as the
        // writers are running. Under the old unlocked bridge this is the
        // "mutated while being enumerated" repro.
        var reads = 0
        while producers.wait(timeout: .now()) == .timedOut {
            let models = store.snapshot()
            for model in models {
                _ = model.requestId
                _ = model.url?.absoluteString
            }
            reads += 1
        }

        XCTAssertGreaterThan(reads, 0, "the read loop never ran; the test proves nothing")
        XCTAssertLessThanOrEqual(store.transactionCount, NetworkRequestStore.maxCapturedTransactions)
    }

    // MARK: - Capacity

    func testStoreStopsGrowingAtTheCap() {
        let limit = NetworkRequestStore.maxCapturedTransactions
        fill(limit + 120, prefix: "/capped")

        XCTAssertEqual(store.transactionCount, limit)
    }

    func testTheOldestUnpinnedEntriesAreTheOnesDropped() {
        let limit = NetworkRequestStore.maxCapturedTransactions
        let overflow = 25
        fill(limit + overflow, prefix: "/aged")

        let paths = store.snapshot().compactMap { $0.url?.path }
        XCTAssertEqual(paths.count, limit)
        XCTAssertEqual(paths.first, "/aged/\(overflow)", "eviction should start at the oldest entry")
        XCTAssertEqual(paths.last, "/aged/\(limit + overflow - 1)", "the newest entry must survive")
    }

    func testPinnedEntriesSurviveEvictionForever() {
        let limit = NetworkRequestStore.maxCapturedTransactions

        let pinned = makeTransaction("/pinned")
        pinned.isPinned = true
        XCTAssertTrue(store.addHttpRequset(pinned))

        fill(limit + 200, prefix: "/noise")

        let models = store.snapshot()
        XCTAssertEqual(models.count, limit)
        XCTAssertTrue(models.contains { $0 === pinned }, "a pinned entry must never be evicted")
        XCTAssertTrue(models.first === pinned, "it also keeps its position as the oldest entry")

        pinned.isPinned = false
    }

    func testEvictionReleasesTheEvictedModelsBodyFile() {
        let directory = NetworkTransaction.diskCacheDirectory()
        let before = Self.fileNames(in: directory)

        autoreleasepool {
            let doomed = makeTransaction("/with-body")
            doomed.responseData = Data(repeating: 0x41, count: 128)
            XCTAssertTrue(store.addHttpRequset(doomed))
        }

        let written = Self.fileNames(in: directory).subtracting(before)
        XCTAssertEqual(written.count, 1, "one captured body should be one file on disk")

        // Push it out of the store.
        autoreleasepool {
            fill(NetworkRequestStore.maxCapturedTransactions + 10, prefix: "/evictor")
        }

        let gone = Self.wait(upTo: 2.0) {
            Self.fileNames(in: directory).isDisjoint(with: written)
        }
        XCTAssertTrue(gone, "evicting a model must release its body file, not leak it")
    }

    // MARK: - Helpers

    private static func fileNames(in directory: String) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return Set(contents)
    }

    /// Deinit-driven file removal can land one autorelease-pool drain late, so
    /// poll instead of asserting on the first read.
    private static func wait(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return condition()
    }
}
