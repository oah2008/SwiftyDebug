//
//  NetlistSearchAuditFixTests.swift
//  SwiftyDebugTests
//
//  "Include media" used to be read in exactly one place, where all it did was
//  omit a skip predicate — while three other gates (the engine's own media
//  checks, its binary sniff and its result cache key) went on skipping media
//  whatever the switch said. These pin the flag to what the engine actually
//  does with a media body, which is the assertion its predecessor never made.
//

import XCTest
@testable import SwiftyDebug

final class NetlistSearchAuditFixTests: XCTestCase {

    // MARK: - Helpers

    /// A transaction with a real (disk-backed) response body, which is what the
    /// engine reads — `responseDataSize` is derived from the write, so a model
    /// built any other way would be skipped as empty before any gate is reached.
    private func makeTransaction(body: String,
                                 mime: String? = nil,
                                 isImage: Bool = false) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.mineType = mime
        model.isImage = isImage
        model.responseData = body.data(using: .utf8)
        return model
    }

    private func responseOnlyOptions(includeMedia: Bool) -> ResponseBodySearch.Options {
        var options = ResponseBodySearch.Options()
        options.searchResponseBodies = true
        options.searchRequestBodies = false
        options.includeMedia = includeMedia
        return options
    }

    // MARK: - The flag reaches the engine as data

    func testEngineOptionsCarryIncludeMediaAsData() {
        var options = AdvancedSearchOptions(searchResponseBodies: true)
        XCTAssertFalse(options.engineOptions(for: .response).includeMedia)

        options.includeMedia = true
        XCTAssertTrue(options.engineOptions(for: .response).includeMedia,
                      "The engine's own media gates read the flag — dropping the skip predicate alone changes nothing")
    }

    func testIncludeMediaChangesTheCacheKey() {
        // A scan with media off records a "no match" for every media transaction.
        // Sharing a key with the media-on scan would serve those skips straight
        // back, so the toggle would still look inert on the second scan.
        let base = AdvancedSearchOptions(searchResponseBodies: true)
        var media = base
        media.includeMedia = true

        XCTAssertNotEqual(media.engineOptions(for: .response).cacheKey(for: "cloudfront"),
                          base.engineOptions(for: .response).cacheKey(for: "cloudfront"))
    }

    // MARK: - shouldSkip

    func testImageTransactionIsSkippedOnlyWhileMediaIsExcluded() {
        let model = makeTransaction(body: "{\"host\":\"cloudfront\"}", isImage: true)

        XCTAssertTrue(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: false)))
        XCTAssertFalse(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: true)))
    }

    func testMediaMimeIsSkippedOnlyWhileMediaIsExcluded() {
        let model = makeTransaction(body: "<svg>cloudfront</svg>", mime: "image/svg+xml")

        XCTAssertTrue(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: false)))
        XCTAssertFalse(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: true)))
    }

    func testNonMediaBinaryMimeStaysSkippedEvenWithMediaIncluded() {
        // The toggle says "images, video and audio". A zip or a wasm module is
        // never searchable text and no switch offers to read one.
        let model = makeTransaction(body: "cloudfront", mime: "application/zip")

        XCTAssertTrue(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: false)))
        XCTAssertTrue(ResponseBodySearch.shouldSkip(model, options: responseOnlyOptions(includeMedia: true)))
    }

    // MARK: - A full scan over a media body

    func testRunFindsAMediaBodyOnlyWhenMediaIsIncluded() {
        let model = makeTransaction(body: "PNGtEXtcloudfront-origin", isImage: true)

        let excluded = ResponseBodySearch.run(transactions: [model],
                                              query: "cloudfront",
                                              options: responseOnlyOptions(includeMedia: false))
        XCTAssertEqual(excluded.matches.count, 0)
        XCTAssertEqual(excluded.skippedCount, 1, "The body must not even be read while media is excluded")

        let included = ResponseBodySearch.run(transactions: [model],
                                              query: "cloudfront",
                                              options: responseOnlyOptions(includeMedia: true))
        XCTAssertEqual(included.matches.count, 1,
                       "The sheet promises the body is scanned anyway — 0 hits here is the toggle doing nothing")
        XCTAssertEqual(included.matches.first?.side, .response)
        XCTAssertEqual(included.scannedCount, 1)
    }

    func testIncludedMediaSurvivesTheBinarySniff() {
        // Every image header carries a NUL in its first bytes, so an unconditional
        // binary sniff throws away exactly the bodies the toggle asked to read.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]
        bytes.append(contentsOf: Array("cloudfront".utf8))

        let match = ResponseBodySearch.findMatch(in: Data(bytes),
                                                 query: "cloudfront",
                                                 id: "png",
                                                 side: .response,
                                                 options: responseOnlyOptions(includeMedia: true))
        XCTAssertNotNil(match)

        XCTAssertNil(ResponseBodySearch.findMatch(in: Data(bytes),
                                                  query: "cloudfront",
                                                  id: "png",
                                                  side: .response,
                                                  options: responseOnlyOptions(includeMedia: false)),
                     "With media excluded the sniff is still the guard that keeps binaries out of the results")
    }

    // MARK: - Text bodies are unaffected

    func testOrdinaryTextBodyStillMatchesWithMediaExcluded() {
        let model = makeTransaction(body: "{\"order_id\":\"8842\"}", mime: "application/json")

        let outcome = ResponseBodySearch.run(transactions: [model],
                                             query: "order_id",
                                             options: responseOnlyOptions(includeMedia: false))
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.skippedCount, 0)
    }
}
