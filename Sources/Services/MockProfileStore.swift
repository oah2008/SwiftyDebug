//
//  MockProfileStore.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import Foundation

extension Notification.Name {
    static let mockProfilesDidChange = Notification.Name("com.swiftydebug.mockProfilesDidChange")
}

/// Thread-safe store for mock profiles, persisted to the caches directory as JSON.
///
/// Exactly one profile is active at a time (or none). The profile list and the active
/// id live in the *same* file so activation is a single atomic write — a crash can
/// never leave two profiles active or point at a profile that was deleted.
class MockProfileStore {

    /// Master switch for the whole mock-profiles feature.
    ///
    /// Currently **off**: the feature is built and tested but hidden until it
    /// earns its place. One flag gates both the UI entry points and the request
    /// path on purpose — hiding only the UI would leave an already-activated
    /// profile silently mocking traffic with no way to reach it and turn it off.
    /// Flip to `true` to bring it back; nothing else needs changing.
    static let isFeatureEnabled = false

    static let shared = MockProfileStore()

    private var profiles: [MockProfile] = []
    private var activeId: String?

    private let fileURL: URL

    /// `shared` uses the caches directory; tests inject a temp file to stay isolated.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        loadFromDisk()
    }

    // MARK: - Lookup

    func allProfiles() -> [MockProfile] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return profiles.sorted { $0.createdAt < $1.createdAt }
    }

    func profile(id: String) -> MockProfile? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return profiles.first { $0.id == id }
    }

    func activeProfile() -> MockProfile? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard let activeId = activeId else { return nil }
        return profiles.first { $0.id == activeId }
    }

    func activeProfileId() -> String? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return activeId
    }

    func isActive(id: String) -> Bool {
        return activeProfileId() == id
    }

    // MARK: - Resolution

    /// The mock the **active profile** wants to serve for `url`, or `nil`.
    ///
    /// This is deliberately the general case: `CustomHTTPProtocol` must consult the
    /// per-endpoint rule mock first and only fall back here, so a rule the user wrote
    /// for one endpoint always beats the profile's blanket answer.
    func mock(forURL url: URL) -> MockResponse? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard let activeId = activeId,
              let profile = profiles.first(where: { $0.id == activeId }) else { return nil }
        return profile.matchingEntry(forURL: url)?.mock
    }

    /// Cheap pre-check for callers that only need to know whether mocking is armed.
    func hasActiveMock(forURL url: URL) -> Bool {
        return mock(forURL: url) != nil
    }

    /// The mock `CustomHTTPProtocol` should serve for a request.
    ///
    /// An explicit per-endpoint rule mock always beats the active profile's mock —
    /// the specific beats the general. A rule mock switched *off* counts as absent,
    /// so the profile still gets its turn.
    func resolvedMock(forURL url: URL, ruleMock: MockResponse?) -> MockResponse? {
        return Self.resolveMock(ruleMock: ruleMock, profileMock: mock(forURL: url))
    }

    /// Pure form of `resolvedMock(forURL:ruleMock:)`, kept separate so the precedence
    /// policy can be tested without a store or a URL.
    static func resolveMock(ruleMock: MockResponse?, profileMock: MockResponse?) -> MockResponse? {
        // A rule's mock is gated on `isEnabled` — that flag is exactly what the
        // rule editor's "Mock Response: Off" switch means.
        if let ruleMock = ruleMock, ruleMock.isEnabled { return ruleMock }
        // A profile's mock is NOT: whether it applies was already decided by the
        // entry being enabled inside an active profile. Checking the nested flag
        // as well made every profile silently serve nothing.
        return profileMock
    }

    // MARK: - Profile mutation

    /// Adds a new profile or replaces an existing one (matched by `id`).
    func addOrUpdate(_ profile: MockProfile) {
        objc_sync_enter(self)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    @discardableResult
    func createProfile(name: String, note: String? = nil) -> MockProfile {
        let profile = MockProfile(name: name, note: note)
        addOrUpdate(profile)
        return profile
    }

    func rename(id: String, to newName: String) {
        objc_sync_enter(self)
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx].name = newName
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    /// Copies a profile (fresh ids throughout). The copy is never auto-activated.
    @discardableResult
    func duplicate(id: String) -> MockProfile? {
        objc_sync_enter(self)
        guard let source = profiles.first(where: { $0.id == id }) else {
            objc_sync_exit(self)
            return nil
        }
        let copy = source.duplicated(named: Self.copyName(for: source.name, existing: profiles.map { $0.name }))
        profiles.append(copy)
        objc_sync_exit(self)
        saveToDisk()
        return copy
    }

    func remove(id: String) {
        objc_sync_enter(self)
        profiles.removeAll { $0.id == id }
        // Deleting the active profile must turn mocking off, not leave a dangling id.
        if activeId == id { activeId = nil }
        objc_sync_exit(self)
        saveToDisk()
    }

    func removeAll() {
        objc_sync_enter(self)
        profiles.removeAll()
        activeId = nil
        objc_sync_exit(self)
        saveToDisk()
    }

    // MARK: - Activation

    /// Activates a profile exclusively, or deactivates everything when `id` is `nil`.
    /// Unknown ids deactivate rather than silently keeping the previous profile armed.
    func activate(id: String?) {
        objc_sync_enter(self)
        if let id = id, profiles.contains(where: { $0.id == id }) {
            activeId = id
        } else {
            activeId = nil
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    func deactivate() {
        activate(id: nil)
    }

    /// Activates the profile if it is off, deactivates it if it is already on.
    func toggleActive(id: String) {
        activate(id: isActive(id: id) ? nil : id)
    }

    // MARK: - Entry mutation

    func addEntry(_ entry: MockProfileEntry, toProfileId profileId: String) {
        objc_sync_enter(self)
        if let idx = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[idx].entries.append(entry)
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    /// Upserts: an entry whose id is not in the profile yet is appended.
    /// The editor relies on this — a new entry only lands in the profile when the user
    /// saves it, so backing out of the editor discards it instead of leaving a blank row.
    func updateEntry(_ entry: MockProfileEntry, inProfileId profileId: String) {
        objc_sync_enter(self)
        if let pIdx = profiles.firstIndex(where: { $0.id == profileId }) {
            if let eIdx = profiles[pIdx].entries.firstIndex(where: { $0.id == entry.id }) {
                profiles[pIdx].entries[eIdx] = entry
            } else {
                profiles[pIdx].entries.append(entry)
            }
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    func removeEntry(id entryId: String, fromProfileId profileId: String) {
        objc_sync_enter(self)
        if let pIdx = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[pIdx].entries.removeAll { $0.id == entryId }
        }
        objc_sync_exit(self)
        saveToDisk()
    }

    // MARK: - Naming

    /// "Logged out" → "Logged out copy" → "Logged out copy 2"…
    static func copyName(for name: String, existing: [String]) -> String {
        let base = "\(name) copy"
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Persistence

    private static let directoryName = "MockProfiles"
    private static let fileName = "profiles.json"

    /// Profiles and the active id share one payload so activation survives relaunch
    /// and can never disagree with the list it points into.
    private struct Payload: Codable {
        var profiles: [MockProfile]
        var activeProfileId: String?
    }

    private static func defaultFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SwiftyDebug/\(directoryName)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func saveToDisk() {
        objc_sync_enter(self)
        let payload = Payload(profiles: profiles, activeProfileId: activeId)
        objc_sync_exit(self)

        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silent failure — debug tool, not critical path
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mockProfilesDidChange, object: nil)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }
        profiles = payload.profiles
        // Drop an active id pointing at a profile that is no longer on disk.
        if let id = payload.activeProfileId, payload.profiles.contains(where: { $0.id == id }) {
            activeId = id
        } else {
            activeId = nil
        }
    }
}
