//
//  RequestReplayHeaderSuggestionTests.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import XCTest
@testable import SwiftyDebug

/// Covers the "Available headers" picker list built by the replay screen —
/// ordering, de-duplication, exclusion and value pre-fill. (See REPLAY.)
final class RequestReplayHeaderSuggestionTests: XCTestCase {

    private typealias Suggestion = RequestReplayViewController.HeaderSuggestion

    private func entry(_ name: String, _ value: String = "") -> RequestMetadataStore.Entry {
        RequestMetadataStore.Entry(name: name, value: value)
    }

    // MARK: - Ordering

    func testCurrentRequestHeadersComeBeforeRememberedAndCatalog() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [(name: "X-Trace-Id", value: "abc")],
            remembered: [entry("X-Api-Key", "k1")],
            catalog: ["X-Device-Id"],
            excluding: [])

        XCTAssertEqual(result.map { $0.name }, ["X-Trace-Id", "X-Api-Key", "X-Device-Id"])
        XCTAssertEqual(result.map { $0.origin }, [.thisRequest, .remembered, .catalog])
    }

    func testRememberedOrderIsPreserved() {
        // RequestMetadataStore already returns endpoint, then host, then global —
        // the builder must not re-sort it.
        let result = RequestReplayViewController.headerSuggestions(
            current: [],
            remembered: [entry("X-Endpoint", "e"), entry("X-Host", "h"), entry("X-Global", "g")],
            catalog: [],
            excluding: [])

        XCTAssertEqual(result.map { $0.name }, ["X-Endpoint", "X-Host", "X-Global"])
    }

    // MARK: - De-duplication

    func testDuplicateNamesAreCaseInsensitiveAndKeepTheMostRelevantSource() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [(name: "authorization", value: "Bearer live")],
            remembered: [entry("Authorization", "Bearer old")],
            catalog: ["Authorization"],
            excluding: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "authorization")
        XCTAssertEqual(result.first?.value, "Bearer live")
        XCTAssertEqual(result.first?.origin, .thisRequest)
    }

    func testEmptyNamesAreDropped() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [(name: "", value: "x")],
            remembered: [entry("", "y")],
            catalog: [""],
            excluding: [])

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Exclusion

    func testHeadersAlreadyInTheReplayAreExcluded() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [(name: "Accept", value: "*/*"), (name: "X-Api-Key", value: "k")],
            remembered: [entry("Cookie", "a=b")],
            catalog: ["Authorization"],
            excluding: ["accept", "cookie"])

        XCTAssertEqual(result.map { $0.name }, ["X-Api-Key", "Authorization"])
    }

    // MARK: - Value pre-fill

    func testNeverSeenCatalogHeaderPrefillsItsValueTemplate() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [], remembered: [], catalog: ["Authorization"], excluding: [])

        XCTAssertEqual(result.first?.value, "Bearer ")
    }

    func testCatalogHeaderWithoutATemplateGetsAnEmptyValue() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [], remembered: [], catalog: ["X-Device-Id"], excluding: [])

        XCTAssertEqual(result.first?.value, "")
    }

    func testRememberedHeaderWithNoValueFallsBackToTheTemplate() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [], remembered: [entry("Content-Type", "")], catalog: [], excluding: [])

        XCTAssertEqual(result.first?.value, "application/json")
    }

    func testRememberedValueWinsOverTheTemplate() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [], remembered: [entry("Content-Type", "text/csv")], catalog: [], excluding: [])

        XCTAssertEqual(result.first?.value, "text/csv")
    }

    func testTheRealCatalogIsOfferedForHeadersNeverSeen() {
        let result = RequestReplayViewController.headerSuggestions(
            current: [], remembered: [],
            catalog: HTTPHeaderCatalog.allHeaderNames,
            excluding: [])

        XCTAssertEqual(result.count, Set(HTTPHeaderCatalog.allHeaderNames.map { $0.lowercased() }).count)
        XCTAssertTrue(result.contains { $0.name == "Authorization" && $0.value == "Bearer " })
    }

    // MARK: - Subtitles

    func testSubtitleNamesTheOriginWhenThereIsNoValue() {
        let s = Suggestion(name: "X-Device-Id", value: "", origin: .catalog)
        XCTAssertEqual(RequestReplayViewController.suggestionSubtitle(for: s), "well-known header")
    }

    func testSubtitleShowsTheRememberedValue() {
        let s = Suggestion(name: "Accept", value: "*/*", origin: .remembered)
        XCTAssertEqual(RequestReplayViewController.suggestionSubtitle(for: s), "previously sent · */*")
    }

    func testSubtitleTruncatesOversizedValues() {
        let long = String(repeating: "j", count: 400)
        let s = Suggestion(name: "Cookie", value: long, origin: .thisRequest)
        let subtitle = RequestReplayViewController.suggestionSubtitle(for: s, limit: 10)

        XCTAssertEqual(subtitle, "this request · jjjjjjjjjj…")
    }

    func testSubtitleDescribesTheUUIDSentinelInsteadOfShowingIt() {
        let s = Suggestion(name: "Idempotency-Key",
                           value: HTTPHeaderCatalog.UUIDPlaceholder,
                           origin: .remembered)

        XCTAssertEqual(RequestReplayViewController.suggestionSubtitle(for: s), "previously sent · a new UUID")
    }
}
