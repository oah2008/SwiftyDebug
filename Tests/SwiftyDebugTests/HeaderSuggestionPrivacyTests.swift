//
//  HeaderSuggestionPrivacyTests.swift
//  SwiftyDebugTests
//
//  `HeaderSuggestionStore` wrote every request header VALUE it ever saw —
//  `Authorization: Bearer …`, `Cookie: …` — verbatim into a JSON file in Caches,
//  uncapped, for the life of the install. This SDK ships inside other people's
//  apps and is not `#if DEBUG`-gated, so that file lands on end users' devices.
//  Nothing read those values back, and "Clear Remembered Headers" did not delete
//  them.
//
//  What is pinned here:
//
//    * the ONLY encoder that can reach the file emits names and nothing else;
//    * the decoder reads a legacy name+value file, keeps the names, drops the
//      secrets, and reports that the file must be rewritten;
//    * a recorded header's value never reaches the file on disk (end to end,
//      through the real debounced save);
//    * `clear()` exists, empties what was learned, and removes the file — while
//      leaving the built-in catalog, which was never learned from anybody's app.
//

import XCTest
@testable import SwiftyDebug

final class HeaderSuggestionPrivacyTests: XCTestCase {

    /// The real file the store writes. Deliberately recomputed here rather than
    /// exposed by the store: if the path ever moves, this test should notice.
    private var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftyDebug")
            .appendingPathComponent("HeaderSuggestions.json")
    }

    private func suggestions(_ q: String) -> [String] {
        HeaderSuggestionStore.shared.suggestions(matching: q, excluding: [], limit: 50)
    }

    // MARK: - Nothing but names can be written

    func testEncodedPayloadCarriesNamesAndNothingElse() {
        let payload = HeaderSuggestionStore.encodePayload(names: ["Authorization", "X-Tenant"])
        XCTAssertEqual(Set(payload.keys), ["version", "names"],
                       "The persisted payload grew a field. Only names may be written.")
        XCTAssertEqual(payload["names"] as? [String], ["Authorization", "X-Tenant"])
        XCTAssertEqual(payload["version"] as? Int, HeaderSuggestionStore.formatVersion)
    }

    func testLegacyFileIsReadForItsNamesAndFlaggedForRewrite() throws {
        let legacy: [String: [String: String]] = [
            "authorization": ["name": "Authorization", "value": "Bearer live-token-abc123"],
            "cookie": ["name": "Cookie", "value": "SESSIONID=deadbeefcafe"],
            "accept": ["name": "Accept", "value": "application/vnd.acme+json"],
        ]

        let decoded = HeaderSuggestionStore.decodePayload(legacy)

        XCTAssertEqual(Set(decoded.names), ["Authorization", "Cookie", "Accept"],
                       "Names are the whole point of the store and must survive the migration.")
        XCTAssertTrue(decoded.holdsLegacyValues,
                      "A legacy file is still leaking on disk; the store must know to rewrite it.")

        // Re-encoding what was read is what actually lands back on disk.
        let data = try JSONSerialization.data(withJSONObject:
            HeaderSuggestionStore.encodePayload(names: decoded.names))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("live-token-abc123"), "Bearer token survived the rewrite.")
        XCTAssertFalse(text.contains("deadbeefcafe"), "Cookie value survived the rewrite.")
        XCTAssertFalse(text.contains("vnd.acme+json"),
                       "Non-credential values are dropped too — nothing reads them.")
        XCTAssertTrue(text.contains("Authorization"))
    }

    func testCurrentFormatRoundTripsWithoutBeingMistakenForLegacy() {
        let payload = HeaderSuggestionStore.encodePayload(names: ["X-Alpha", "X-Beta"])
        let decoded = HeaderSuggestionStore.decodePayload(payload)
        XCTAssertEqual(Set(decoded.names), ["X-Alpha", "X-Beta"])
        XCTAssertFalse(decoded.holdsLegacyValues,
                       "A value-free file must not trigger an endless rewrite loop.")
    }

    func testGarbageOnDiskYieldsNothingRatherThanCrashing() {
        let decoded = HeaderSuggestionStore.decodePayload(["not", "a", "payload"])
        XCTAssertTrue(decoded.names.isEmpty)
        XCTAssertFalse(decoded.holdsLegacyValues)
    }

    // MARK: - Bounded

    func testLearnedNamesAreCapped() {
        var bucket: [String: String] = [:]
        for i in 0..<(HeaderSuggestionStore.Limits.maxLearnedNames + 250) {
            HeaderSuggestionStore.insert(name: "X-Probe-\(i)", into: &bucket)
        }
        XCTAssertEqual(bucket.count, HeaderSuggestionStore.Limits.maxLearnedNames,
                       "The store lives in Caches forever; it must not grow without bound.")
    }

    func testOverlongAndEmptyNamesAreRefused() {
        var bucket: [String: String] = [:]
        XCTAssertFalse(HeaderSuggestionStore.insert(name: "", into: &bucket))
        XCTAssertFalse(HeaderSuggestionStore.insert(name: "   ", into: &bucket))
        XCTAssertFalse(HeaderSuggestionStore.insert(
            name: String(repeating: "a", count: HeaderSuggestionStore.Limits.maxNameLength + 1),
            into: &bucket))
        XCTAssertTrue(bucket.isEmpty)
    }

    func testNamesAlreadyInTheCatalogAreNotLearnedAgain() {
        var bucket: [String: String] = [:]
        let catalog = ["authorization": "Authorization"]
        XCTAssertFalse(HeaderSuggestionStore.insert(name: "AUTHORIZATION",
                                                    into: &bucket,
                                                    alreadyKnown: catalog),
                       "A catalog name must not also occupy one of the learned slots.")
        XCTAssertTrue(bucket.isEmpty)
    }

    // MARK: - Clear actually clears

    func testClearForgetsLearnedNamesAndDeletesTheFileButKeepsTheCatalog() {
        SwiftyDebugRuntime.markActive()
        HeaderSuggestionStore.shared.record(headers: ["X-Clear-Probe-Header": "irrelevant"] as NSDictionary)

        XCTAssertTrue(suggestions("x-clear-probe-header").contains("X-Clear-Probe-Header"),
                      "Precondition: the name was learned.")
        XCTAssertGreaterThan(HeaderSuggestionStore.shared.rememberedCount, 0)

        HeaderSuggestionStore.shared.clear()

        XCTAssertEqual(HeaderSuggestionStore.shared.rememberedCount, 0,
                       "\"Clear Remembered Headers\" must actually forget them.")
        XCTAssertFalse(suggestions("x-clear-probe-header").contains("X-Clear-Probe-Header"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "The alert promises the file is deleted from disk.")
        XCTAssertTrue(suggestions("authorization").contains("Authorization"),
                      "The built-in catalog was never learned from the app and must survive.")
    }

    // MARK: - End to end: nothing secret reaches the file

    func testRecordedHeaderValuesNeverReachTheFileOnDisk() {
        SwiftyDebugRuntime.markActive()
        HeaderSuggestionStore.shared.clear()

        let probeName = "X-Disk-Probe-Header"
        let secret = "Bearer super-secret-value-9f2c"
        HeaderSuggestionStore.shared.record(headers: [
            probeName: secret,
            "Authorization": secret,
        ] as NSDictionary)

        // The save is debounced onto a background queue; poll for it.
        var text: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: fileURL),
               let s = String(data: data, encoding: .utf8), s.contains(probeName) {
                text = s
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let text else {
            return XCTFail("The store never wrote \(probeName) to \(fileURL.path).")
        }
        XCTAssertFalse(text.contains(secret),
                       "A live credential reached disk:\n\(text.prefix(400))")
        XCTAssertFalse(text.contains("super-secret-value-9f2c"))

        HeaderSuggestionStore.shared.clear()
    }
}
