//
//  AdvancedSearchOptionsTests.swift
//  SwiftyDebugTests
//
//  The Advanced Search sheet promises specific behaviour in plain English on each
//  toggle. These pin the promise to what the engine is actually told, so a toggle
//  can never quietly do nothing — the failure mode that made mock profiles and
//  breakpoints inert.
//

import XCTest
@testable import SwiftyDebug

final class AdvancedSearchOptionsTests: XCTestCase {

    func testDefaultsSearchNoBodies() {
        let options = AdvancedSearchOptions()
        XCTAssertFalse(options.searchesAnyBody,
                       "Bodies are disk-backed — nothing may be read until asked for")
        XCTAssertFalse(options.caseSensitive)
        XCTAssertFalse(options.includeMedia)
        XCTAssertFalse(options.scanWholeBodies)
    }

    func testSearchesAnyBodyTracksEitherScope() {
        var options = AdvancedSearchOptions()
        XCTAssertFalse(options.searchesAnyBody)

        options.searchRequestBodies = true
        XCTAssertTrue(options.searchesAnyBody)

        options.searchRequestBodies = false
        options.searchResponseBodies = true
        XCTAssertTrue(options.searchesAnyBody)
    }

    // MARK: - One scan per side

    func testEngineOptionsScanExactlyOneSide() {
        // Each chip needs its own count, so a per-side scan must never also read
        // the other side — that would double-count and misreport both chips.
        let options = AdvancedSearchOptions(searchResponseBodies: true, searchRequestBodies: true)

        let response = options.engineOptions(for: .response)
        XCTAssertTrue(response.searchResponseBodies)
        XCTAssertFalse(response.searchRequestBodies)

        let request = options.engineOptions(for: .request)
        XCTAssertTrue(request.searchRequestBodies)
        XCTAssertFalse(request.searchResponseBodies)
    }

    // MARK: - Each toggle reaches the engine

    func testCaseSensitiveReachesTheEngine() {
        var options = AdvancedSearchOptions()
        XCTAssertFalse(options.engineOptions(for: .response).caseSensitive)

        options.caseSensitive = true
        XCTAssertTrue(options.engineOptions(for: .response).caseSensitive)
    }

    func testScanWholeBodiesLiftsTheByteCap() {
        var options = AdvancedSearchOptions()
        XCTAssertEqual(options.engineOptions(for: .response).byteCap,
                       ResponseBodySearch.defaultByteCap)

        options.scanWholeBodies = true
        XCTAssertEqual(options.engineOptions(for: .response).byteCap, Int.max)
    }

    func testIncludeMediaRemovesTheSkipPredicate() {
        var options = AdvancedSearchOptions()
        XCTAssertNotNil(options.engineOptions(for: .response).skipTransaction,
                        "Media must be skipped by default — binary bodies are never searchable text")

        options.includeMedia = true
        XCTAssertNil(options.engineOptions(for: .response).skipTransaction)
    }

    // MARK: - Cache invalidation

    // Every option is part of the engine's cache key, so changing one cannot
    // serve hits produced under different rules.

    func testEveryMatchingOptionChangesTheCacheKey() {
        let base = AdvancedSearchOptions(searchResponseBodies: true)
        let baseKey = base.engineOptions(for: .response).cacheKey(for: "token")

        var caseSensitive = base
        caseSensitive.caseSensitive = true
        XCTAssertNotEqual(caseSensitive.engineOptions(for: .response).cacheKey(for: "token"), baseKey)

        var whole = base
        whole.scanWholeBodies = true
        XCTAssertNotEqual(whole.engineOptions(for: .response).cacheKey(for: "token"), baseKey)
    }

    func testTheTwoSidesNeverShareACacheEntry() {
        let options = AdvancedSearchOptions(searchResponseBodies: true, searchRequestBodies: true)
        XCTAssertNotEqual(options.engineOptions(for: .response).cacheKey(for: "token"),
                          options.engineOptions(for: .request).cacheKey(for: "token"))
    }

    func testIdenticalOptionsReuseTheSameCacheEntry() {
        let a = AdvancedSearchOptions(searchResponseBodies: true, caseSensitive: true)
        let b = AdvancedSearchOptions(searchResponseBodies: true, caseSensitive: true)
        XCTAssertEqual(a.engineOptions(for: .response).cacheKey(for: "token"),
                       b.engineOptions(for: .response).cacheKey(for: "token"))
    }

    // MARK: - "Advanced is active" indicator

    func testResetEqualsDefaultsSoTheButtonGoesInactive() {
        var options = AdvancedSearchOptions()
        options.caseSensitive = true
        options.includeMedia = true
        XCTAssertNotEqual(options, AdvancedSearchOptions())

        options = AdvancedSearchOptions()
        XCTAssertEqual(options, AdvancedSearchOptions())
    }
}
