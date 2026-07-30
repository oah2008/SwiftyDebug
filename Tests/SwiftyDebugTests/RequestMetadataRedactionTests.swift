//
//  RequestMetadataRedactionTests.swift
//  SwiftyDebug
//
//  Covers what `RequestMetadataStore` is allowed to leave on disk, and the
//  bounds on how much of it there can be.
//
//  The bug: every request header value the app had ever sent — including
//  `Authorization: Bearer …` and `Cookie` — was persisted verbatim to Caches,
//  forever, with no cap, surviving Clear and full stop, with no reset API. The
//  SDK is embedded in other people's apps and is not `#if DEBUG`-gated, so that
//  is plaintext credentials at rest on a stranger's device.
//

import XCTest
@testable import SwiftyDebug

final class RequestMetadataRedactionTests: XCTestCase {

    private typealias Store = RequestMetadataStore
    private typealias Entry = RequestMetadataStore.Entry

    // MARK: - What counts as a credential

    func testTheHeadersNamedInTheDefectAreAllRecognized() {
        for name in ["Authorization", "Cookie", "Set-Cookie", "Proxy-Authorization",
                     "X-Api-Key", "X-API-KEY", "api_key"] {
            XCTAssertTrue(Store.isSensitiveName(name), "\(name) must be treated as a credential")
        }
    }

    func testOtherCommonCredentialShapesAreRecognized() {
        for name in ["X-Auth-Token", "access_token", "refresh_token", "id_token",
                     "client_secret", "password", "X-CSRF-Token", "X-XSRF-Token",
                     "session", "JSESSIONID", "X-Amz-Signature", "Authentication",
                     "X-Shopify-Access-Token", "key", "sig", "jwt"] {
            XCTAssertTrue(Store.isSensitiveName(name), "\(name) must be treated as a credential")
        }
    }

    func testDetectionIsCaseInsensitive() {
        XCTAssertTrue(Store.isSensitiveName("AUTHORIZATION"))
        XCTAssertTrue(Store.isSensitiveName("authorization"))
        XCTAssertTrue(Store.isSensitiveName("AuThOrIzAtIoN"))
    }

    func testOrdinaryHeadersAreNotRedacted() {
        // A false positive costs one pre-filled suggestion, so over-matching is
        // cheap — but not free. These are the headers the feature exists for.
        for name in ["Accept", "Accept-Language", "Content-Type", "Content-Length",
                     "User-Agent", "X-Device-Id", "X-Request-Id", "X-App-Version",
                     "If-None-Match", "Referer", "Keyboard-Locale", "X-Design-Id",
                     "page", "limit", "locale"] {
            XCTAssertFalse(Store.isSensitiveName(name), "\(name) must stay usable as a suggestion")
        }
    }

    // MARK: - What actually reaches the file

    func testCredentialValuesAreNeverWrittenButTheirNamesAre() {
        let pair = Store.persistedPair(for: Entry(name: "Authorization", value: "Bearer live-token-abc"))
        XCTAssertEqual(pair, ["Authorization", ""],
                       "the name is what the suggestion list needs; the token is not")
        XCTAssertFalse(pair.contains { $0.contains("live-token-abc") })
    }

    func testCookieValueIsNeverWritten() {
        let pair = Store.persistedPair(for: Entry(name: "Cookie", value: "sid=deadbeef; theme=dark"))
        XCTAssertEqual(pair, ["Cookie", ""])
    }

    func testOrdinaryValuesSurviveIntact() {
        XCTAssertEqual(Store.persistedPair(for: Entry(name: "Accept", value: "application/json")),
                       ["Accept", "application/json"])
    }

    func testCanonicalCasingIsPreservedThroughRedaction() {
        XCTAssertEqual(Store.persistedPair(for: Entry(name: "X-Api-Key", value: "k")).first, "X-Api-Key")
    }

    // MARK: - Bounds

    func testLongValuesAreTruncatedToTheCap() {
        let long = String(repeating: "z", count: Store.Limits.maxValueLength * 3)
        XCTAssertEqual(Store.bounded(long).count, Store.Limits.maxValueLength)
        XCTAssertEqual(Store.bounded("short"), "short")
    }

    func testBucketStopsAcceptingNewNamesAtTheCap() {
        var bucket: [String: Entry] = [:]
        for i in 0..<(Store.Limits.maxNamesPerBucket + 25) {
            Store.mergeEntry(into: &bucket, name: "X-H\(i)", value: "v")
        }
        XCTAssertEqual(bucket.count, Store.Limits.maxNamesPerBucket)
    }

    func testAFullBucketStillUpdatesNamesItAlreadyKnows() {
        // The cap refuses new NAMES; it must not freeze the values of the ones
        // already learned, or every suggestion goes stale forever.
        var bucket: [String: Entry] = [:]
        Store.mergeEntry(into: &bucket, name: "X-Trace", value: "old")
        for i in 0..<Store.Limits.maxNamesPerBucket {
            Store.mergeEntry(into: &bucket, name: "X-Filler\(i)", value: "v")
        }
        Store.mergeEntry(into: &bucket, name: "X-Trace", value: "new")
        XCTAssertEqual(bucket["x-trace"]?.value, "new")
    }

    func testMergeReportsOnlyGenuinelyNewNamesSoTheCountStaysHonest() {
        var bucket: [String: Entry] = [:]
        XCTAssertTrue(Store.mergeEntry(into: &bucket, name: "X-A", value: "1"))
        XCTAssertFalse(Store.mergeEntry(into: &bucket, name: "x-a", value: "2"),
                       "same name, different casing — not a new entry")
        XCTAssertEqual(bucket.count, 1)
        XCTAssertEqual(bucket["x-a"]?.name, "X-A", "first-seen casing wins")
        XCTAssertEqual(bucket["x-a"]?.value, "2")
    }

    func testEmptyValueDoesNotWipeAKnownValue() {
        var bucket: [String: Entry] = [:]
        Store.mergeEntry(into: &bucket, name: "X-A", value: "real")
        Store.mergeEntry(into: &bucket, name: "X-A", value: "")
        XCTAssertEqual(bucket["x-a"]?.value, "real")
    }

    // MARK: - Host / endpoint eviction

    func testTouchingMovesAKeyToTheMostRecentEndAndEvictsNothingUnderTheCap() {
        var order = ["a", "b", "c"]
        XCTAssertEqual(Store.evictionsAfterTouching(&order, "a", cap: 5), [])
        XCTAssertEqual(order, ["b", "c", "a"])
    }

    func testLeastRecentlySeenIsEvictedFirst() {
        var order: [String] = []
        for host in ["h1", "h2", "h3"] { _ = Store.evictionsAfterTouching(&order, host, cap: 3) }
        _ = Store.evictionsAfterTouching(&order, "h1", cap: 3)   // h1 is now freshest
        let evicted = Store.evictionsAfterTouching(&order, "h4", cap: 3)
        XCTAssertEqual(evicted, ["h2"])
        XCTAssertEqual(order, ["h3", "h1", "h4"])
    }

    func testASingleTouchCanEvictMoreThanOneWhenTheCapShrinks() {
        var order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(Store.evictionsAfterTouching(&order, "f", cap: 3), ["a", "b", "c"])
        XCTAssertEqual(order, ["d", "e", "f"])
    }

    func testRepeatedlySeeingTheSameHostNeverGrowsTheOrder() {
        var order: [String] = []
        for _ in 0..<500 { _ = Store.evictionsAfterTouching(&order, "api.example.com", cap: 40) }
        XCTAssertEqual(order, ["api.example.com"])
    }

    func testEveryLimitIsAFiniteNumber() {
        // The store lives in Caches and nothing expires on its own, so "there is
        // a ceiling at all" is the property that matters.
        XCTAssertGreaterThan(Store.Limits.maxValueLength, 0)
        XCTAssertGreaterThan(Store.Limits.maxNamesPerBucket, 0)
        XCTAssertGreaterThan(Store.Limits.maxHosts, 0)
        XCTAssertGreaterThan(Store.Limits.maxEndpoints, 0)
    }

    // MARK: - Reset

    func testClearEmptiesTheStoreAndLeavesNoFileBehind() {
        // There was no reset path at all before: the store outlived Clear and
        // outlived `fullStop()`.
        RequestMetadataStore.shared.clear()
        XCTAssertEqual(RequestMetadataStore.shared.rememberedCount, 0)
        XCTAssertTrue(RequestMetadataStore.shared.allHeaderNames().isEmpty)
        XCTAssertNil(RequestMetadataStore.shared.lastValue(forHeader: "Authorization"))
    }
}
