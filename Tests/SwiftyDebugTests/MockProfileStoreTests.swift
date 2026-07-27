//
//  MockProfileStoreTests.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import XCTest
@testable import SwiftyDebug

final class MockProfileStoreTests: XCTestCase {

    private var fileURL: URL!
    private var store: MockProfileStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftyDebugTests/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        store = MockProfileStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        store = nil
        fileURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func entry(_ mode: EndpointMatchMode,
                       _ pattern: String,
                       status: Int = 200,
                       body: String = "{}") -> MockProfileEntry {
        return MockProfileEntry(matchMode: mode,
                                matchPattern: pattern,
                                mock: MockResponse(statusCode: status, body: body))
    }

    private func url(_ string: String) -> URL {
        return URL(string: string)!
    }

    // MARK: - Activation

    func testActivationIsExclusive() {
        let a = store.createProfile(name: "Logged out")
        let b = store.createProfile(name: "Empty states")

        store.activate(id: a.id)
        XCTAssertTrue(store.isActive(id: a.id))
        XCTAssertFalse(store.isActive(id: b.id))

        store.activate(id: b.id)
        XCTAssertFalse(store.isActive(id: a.id))
        XCTAssertTrue(store.isActive(id: b.id))
        XCTAssertEqual(store.activeProfile()?.id, b.id)
    }

    func testActivateNilDeactivatesEverything() {
        let a = store.createProfile(name: "Server on fire")
        store.activate(id: a.id)

        store.activate(id: nil)
        XCTAssertNil(store.activeProfileId())
        XCTAssertNil(store.activeProfile())
    }

    func testActivateUnknownIdDeactivatesRatherThanKeepingPrevious() {
        let a = store.createProfile(name: "Slow network")
        store.activate(id: a.id)

        store.activate(id: "does-not-exist")
        XCTAssertNil(store.activeProfileId())
    }

    func testToggleActiveFlipsBothWays() {
        let a = store.createProfile(name: "Logged out")

        store.toggleActive(id: a.id)
        XCTAssertTrue(store.isActive(id: a.id))

        store.toggleActive(id: a.id)
        XCTAssertNil(store.activeProfileId())
    }

    func testDeletingActiveProfileTurnsMockingOff() {
        let a = store.createProfile(name: "Logged out")
        store.activate(id: a.id)

        store.remove(id: a.id)
        XCTAssertNil(store.activeProfileId())
        XCTAssertTrue(store.allProfiles().isEmpty)
    }

    func testInactiveProfileServesNoMock() {
        var profile = MockProfile(name: "Empty states")
        profile.entries = [entry(.exact, "/api/users", status: 204)]
        store.addOrUpdate(profile)

        XCTAssertNil(store.mock(forURL: url("https://api.example.com/api/users")))

        store.activate(id: profile.id)
        XCTAssertEqual(store.mock(forURL: url("https://api.example.com/api/users"))?.statusCode, 204)
    }

    // MARK: - Resolution precedence

    func testRuleMockBeatsProfileMock() {
        var profile = MockProfile(name: "Server on fire")
        profile.entries = [entry(.global, "", status: 500)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        // Enabled on purpose: an intercept rule's mock only applies when its own
        // "Mock Response" switch is on. The disabled case is covered separately
        // by testDisabledRuleMockFallsThroughToProfile.
        let ruleMock = MockResponse(isEnabled: true, statusCode: 200, body: "[]")
        let resolved = store.resolvedMock(forURL: url("https://api.example.com/api/users"), ruleMock: ruleMock)

        XCTAssertEqual(resolved?.statusCode, 200, "The specific rule mock must beat the profile's blanket 500")
    }

    func testProfileMockUsedWhenNoRuleMock() {
        var profile = MockProfile(name: "Server on fire")
        profile.entries = [entry(.global, "", status: 500)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        let resolved = store.resolvedMock(forURL: url("https://api.example.com/api/users"), ruleMock: nil)
        XCTAssertEqual(resolved?.statusCode, 500)
    }

    func testDisabledRuleMockFallsThroughToProfile() {
        var profile = MockProfile(name: "Server on fire")
        profile.entries = [entry(.global, "", status: 500)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        var disabled = MockResponse(statusCode: 200)
        disabled.isEnabled = false

        let resolved = store.resolvedMock(forURL: url("https://api.example.com/api/users"), ruleMock: disabled)
        XCTAssertEqual(resolved?.statusCode, 500)
    }

    func testResolveMockReturnsNilWhenNothingApplies() {
        XCTAssertNil(MockProfileStore.resolveMock(ruleMock: nil, profileMock: nil))

        // A disabled RULE mock means "hit the real endpoint", so it resolves to nil.
        var offRuleMock = MockResponse(statusCode: 500)
        offRuleMock.isEnabled = false
        XCTAssertNil(MockProfileStore.resolveMock(ruleMock: offRuleMock, profileMock: nil))
    }

    // MARK: - Feature flag

    func testFeatureFlagGatesTheWholeFeature() {
        // Hidden means INERT, not just invisible: if the UI were hidden while the
        // request path still consulted the store, a profile activated in an
        // earlier build would keep mocking traffic with no way to reach it.
        // Both the entry points and CustomHTTPProtocol read this one flag.
        XCTAssertFalse(MockProfileStore.isFeatureEnabled,
                       "Mock profiles are hidden for now — flip isFeatureEnabled to restore them")
    }

    func testProfileMockIsServedRegardlessOfItsNestedEnabledFlag() {
        // By the time a profile mock reaches resolveMock, matchingEntry has already
        // confirmed the ENTRY is enabled. Re-checking the nested MockResponse flag
        // made every profile added through the UI serve nothing at all.
        var mock = MockResponse(statusCode: 500)
        mock.isEnabled = false
        XCTAssertEqual(MockProfileStore.resolveMock(ruleMock: nil, profileMock: mock)?.statusCode, 500)
    }

    // MARK: - Matching

    func testExactMatchOnlyMatchesTheSamePath() {
        var profile = MockProfile(name: "Exact")
        profile.entries = [entry(.exact, "/api/users/123", status: 201)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        XCTAssertEqual(store.mock(forURL: url("https://a.com/api/users/123"))?.statusCode, 201)
        XCTAssertNil(store.mock(forURL: url("https://a.com/api/users/456")))
    }

    func testNormalizedMatchIgnoresIDs() {
        var profile = MockProfile(name: "Pattern")
        profile.entries = [entry(.normalized, "/api/users/123/orders", status: 202)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        // The stored pattern is normalized on both sides, so a concrete path works as input.
        XCTAssertEqual(store.mock(forURL: url("https://a.com/api/users/999/orders"))?.statusCode, 202)
        XCTAssertNil(store.mock(forURL: url("https://a.com/api/users/999/invoices")))
    }

    func testHostMatchUsesURLPrefixSemantics() {
        var profile = MockProfile(name: "Host")
        profile.entries = [entry(.host, "api.example.com/v1", status: 203)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        XCTAssertEqual(store.mock(forURL: url("https://api.example.com/v1/users/1"))?.statusCode, 203)
        XCTAssertNil(store.mock(forURL: url("https://api.example.com/v2/users/1")))
        XCTAssertNil(store.mock(forURL: url("https://other.example.com/v1/users/1")))
    }

    func testGlobalMatchesEverything() {
        var profile = MockProfile(name: "All")
        profile.entries = [entry(.global, "", status: 500)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        XCTAssertEqual(store.mock(forURL: url("https://anything.io/x/y/z"))?.statusCode, 500)
    }

    func testMoreSpecificEntryWinsWithinAProfile() {
        var profile = MockProfile(name: "Mixed")
        profile.entries = [
            entry(.global, "", status: 500),
            entry(.host, "a.com", status: 502),
            entry(.normalized, "/api/users/{id}", status: 404),
            entry(.exact, "/api/users/7", status: 200),
        ]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        XCTAssertEqual(store.mock(forURL: url("https://a.com/api/users/7"))?.statusCode, 200)
        XCTAssertEqual(store.mock(forURL: url("https://a.com/api/users/8"))?.statusCode, 404)
        XCTAssertEqual(store.mock(forURL: url("https://a.com/health"))?.statusCode, 502)
        XCTAssertEqual(store.mock(forURL: url("https://b.com/health"))?.statusCode, 500)
    }

    func testDisabledEntryIsSkippedAndLetsALessSpecificOneAnswer() {
        var specific = entry(.exact, "/api/users/7", status: 200)
        specific.isEnabled = false
        var profile = MockProfile(name: "Mixed")
        profile.entries = [entry(.global, "", status: 500), specific]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        XCTAssertEqual(store.mock(forURL: url("https://a.com/api/users/7"))?.statusCode, 500)
    }

    // MARK: - Entries

    func testUpdateEntryUpsertsUnknownIDs() {
        let profile = store.createProfile(name: "Empty states")
        let newEntry = entry(.exact, "/api/feed")

        store.updateEntry(newEntry, inProfileId: profile.id)
        XCTAssertEqual(store.profile(id: profile.id)?.entries.count, 1)

        var edited = newEntry
        edited.mock.statusCode = 418
        store.updateEntry(edited, inProfileId: profile.id)
        XCTAssertEqual(store.profile(id: profile.id)?.entries.count, 1)
        XCTAssertEqual(store.profile(id: profile.id)?.entries.first?.mock.statusCode, 418)
    }

    func testRemoveEntryLeavesOtherProfilesAlone() {
        let a = store.createProfile(name: "A")
        let b = store.createProfile(name: "B")
        let shared = entry(.exact, "/api/feed")
        store.addEntry(shared, toProfileId: a.id)
        store.addEntry(shared, toProfileId: b.id)

        store.removeEntry(id: shared.id, fromProfileId: a.id)
        XCTAssertEqual(store.profile(id: a.id)?.entries.count, 0)
        XCTAssertEqual(store.profile(id: b.id)?.entries.count, 1)
    }

    // MARK: - Duplication

    func testDuplicateProducesFreshIdentitiesAndIsNotActivated() {
        var profile = MockProfile(name: "Logged out")
        profile.entries = [entry(.exact, "/api/me", status: 401)]
        store.addOrUpdate(profile)
        store.activate(id: profile.id)

        let copy = store.duplicate(id: profile.id)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, profile.id)
        XCTAssertEqual(copy?.name, "Logged out copy")
        XCTAssertEqual(copy?.entries.count, 1)
        XCTAssertNotEqual(copy?.entries.first?.id, profile.entries.first?.id)
        XCTAssertEqual(copy?.entries.first?.mock.statusCode, 401)
        XCTAssertTrue(store.isActive(id: profile.id), "Duplicating must not steal activation")
    }

    func testCopyNameAvoidsCollisions() {
        XCTAssertEqual(MockProfileStore.copyName(for: "A", existing: ["A"]), "A copy")
        XCTAssertEqual(MockProfileStore.copyName(for: "A", existing: ["A", "A copy"]), "A copy 2")
        XCTAssertEqual(MockProfileStore.copyName(for: "A", existing: ["A", "A copy", "A copy 2"]), "A copy 3")
    }

    // MARK: - Persistence

    func testPersistenceRoundTripsProfilesAndActivation() {
        var profile = MockProfile(name: "Server on fire", note: "5xx everywhere")
        profile.entries = [
            entry(.host, "api.example.com", status: 500, body: "{\"error\":\"boom\"}"),
            entry(.exact, "/health", status: 503),
        ]
        store.addOrUpdate(profile)
        store.createProfile(name: "Empty states")
        store.activate(id: profile.id)

        let reopened = MockProfileStore(fileURL: fileURL)
        XCTAssertEqual(reopened.allProfiles().count, 2)
        XCTAssertEqual(reopened.activeProfileId(), profile.id)

        let loaded = reopened.profile(id: profile.id)
        XCTAssertEqual(loaded?.name, "Server on fire")
        XCTAssertEqual(loaded?.note, "5xx everywhere")
        XCTAssertEqual(loaded?.entries.count, 2)
        XCTAssertEqual(loaded?.entries.first?.matchMode, .host)
        XCTAssertEqual(loaded?.entries.first?.mock.body, "{\"error\":\"boom\"}")
        XCTAssertEqual(reopened.mock(forURL: url("https://api.example.com/anything"))?.statusCode, 500)
    }

    func testPersistenceDropsActiveIdPointingAtADeletedProfile() {
        let a = store.createProfile(name: "A")
        store.activate(id: a.id)
        store.remove(id: a.id)

        let reopened = MockProfileStore(fileURL: fileURL)
        XCTAssertNil(reopened.activeProfileId())
    }

    func testRenamePersists() {
        let a = store.createProfile(name: "A")
        store.rename(id: a.id, to: "Renamed")

        let reopened = MockProfileStore(fileURL: fileURL)
        XCTAssertEqual(reopened.profile(id: a.id)?.name, "Renamed")
    }

    // MARK: - MockResponse

    func testHeaderFieldsSynthesizeContentTypeForJSONBodies() {
        let mock = MockResponse(statusCode: 200, body: "{\"a\":1}")
        XCTAssertEqual(mock.headerFields["Content-Type"], "application/json")
        XCTAssertEqual(mock.headerFields["Content-Length"], "7")
    }

    func testExplicitContentTypeIsNotOverwritten() {
        let mock = MockResponse(statusCode: 200, body: "<a/>",
                                headers: [KVPair(key: "content-type", value: "text/xml")])
        XCTAssertEqual(mock.headerFields["content-type"], "text/xml")
        XCTAssertNil(mock.headerFields["Content-Type"])
    }

    func testHTTPResponseCarriesStatusAndHeaders() {
        let mock = MockResponse(statusCode: 503, body: "{}",
                                headers: [KVPair(key: "Retry-After", value: "120")])
        let response = mock.httpResponse(for: url("https://a.com/x"))
        XCTAssertEqual(response?.statusCode, 503)
        XCTAssertEqual(response?.value(forHTTPHeaderField: "Retry-After"), "120")
    }

    func testScenarioPresetsAreUsableAsIs() {
        XCTAssertFalse(MockResponse.scenarios.isEmpty)
        for scenario in MockResponse.scenarios {
            XCTAssertFalse(scenario.title.isEmpty)
            XCTAssertTrue((100...599).contains(scenario.statusCode), "\(scenario.title) has an invalid status")
        }
    }

    func testMockResponseDecodesWithMissingFields() throws {
        let json = Data("{\"statusCode\":204}".utf8)
        let mock = try JSONDecoder().decode(MockResponse.self, from: json)
        XCTAssertEqual(mock.statusCode, 204)
        XCTAssertEqual(mock.body, "")
        XCTAssertEqual(mock.delay, 0)
        XCTAssertTrue(mock.isEnabled)
        XCTAssertTrue(mock.headers.isEmpty)
    }
}
