//
//  MockProfile.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import Foundation

extension EndpointMatchMode {

    /// Higher wins when several entries of the same profile match one URL —
    /// the specific beats the general, mirroring how a rule mock beats a profile mock.
    var mockSpecificity: Int {
        switch self {
        case .exact:      return 3
        case .normalized: return 2
        case .host:       return 1
        case .global:     return 0
        }
    }

    var displayName: String {
        switch self {
        case .exact:      return "EXACT"
        case .normalized: return "PATTERN"
        case .host:       return "HOST"
        case .global:     return "GLOBAL"
        }
    }
}

/// One endpoint inside a profile: a URL match paired with the response to serve.
struct MockProfileEntry: Codable, Equatable {
    let id: String
    /// Matching semantics are identical to `InterceptRule` so a mock behaves the same
    /// whether it came from a rule or a profile.
    var matchMode: EndpointMatchMode
    /// `.exact` / `.normalized`: the request path. `.host`: a stripped-URL prefix
    /// (`api.example.com/v1`). `.global`: ignored.
    var matchPattern: String
    var mock: MockResponse
    var isEnabled: Bool

    init(matchMode: EndpointMatchMode = .normalized,
         matchPattern: String = "",
         mock: MockResponse = MockResponse(),
         isEnabled: Bool = true) {
        self.id = UUID().uuidString
        self.matchMode = matchMode
        self.matchPattern = matchPattern
        self.mock = mock
        self.isEnabled = isEnabled
    }

    /// Returns `true` when this entry should answer `url`.
    /// Disabled entries never match so toggling one off is equivalent to deleting it.
    func matches(_ url: URL) -> Bool {
        guard isEnabled else { return false }
        switch matchMode {
        case .global:
            return true
        case .exact:
            return url.path == matchPattern
        case .normalized:
            // Both sides are normalized: users paste a concrete path far more often
            // than they hand-write a `{id}` pattern.
            return EndpointNormalizer.normalize(url.path) == EndpointNormalizer.normalize(matchPattern)
        case .host:
            return InterceptRuleStore.urlMatchesPattern(url, pattern: matchPattern)
        }
    }

    /// What the row shows as its target.
    var displayPattern: String {
        switch matchMode {
        case .global: return "All requests"
        default:      return matchPattern.isEmpty ? "(no pattern)" : matchPattern
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, matchMode, matchPattern, mock, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        matchMode = try c.decodeIfPresent(EndpointMatchMode.self, forKey: .matchMode) ?? .normalized
        matchPattern = try c.decodeIfPresent(String.self, forKey: .matchPattern) ?? ""
        mock = try c.decode(MockResponse.self, forKey: .mock)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// A named set of mocks applied together — "Logged out", "Empty states", "Server on fire".
/// Exactly one profile is active at a time (or none); see `MockProfileStore`.
struct MockProfile: Codable, Equatable {
    let id: String
    var name: String
    var note: String?
    var entries: [MockProfileEntry]
    let createdAt: Date

    init(name: String, note: String? = nil, entries: [MockProfileEntry] = []) {
        self.id = UUID().uuidString
        self.name = name
        self.note = note
        self.entries = entries
        self.createdAt = Date()
    }

    /// Copy with a fresh identity — used by "Duplicate". Entry IDs are regenerated too
    /// so editing the copy can never write through to the original.
    func duplicated(named newName: String) -> MockProfile {
        var copy = MockProfile(name: newName, note: note)
        copy.entries = entries.map {
            MockProfileEntry(matchMode: $0.matchMode,
                             matchPattern: $0.matchPattern,
                             mock: $0.mock,
                             isEnabled: $0.isEnabled)
        }
        return copy
    }

    /// The entry that should answer `url`, or `nil`. The most specific match wins;
    /// ties are broken by declaration order so the list reads top-down.
    func matchingEntry(forURL url: URL) -> MockProfileEntry? {
        var best: MockProfileEntry?
        // The ENTRY's own flag decides, not the nested MockResponse's.
        // `MockResponse.isEnabled` means "this rule mocks instead of hitting the
        // network"; inside a profile that question is already answered by the
        // entry existing in an active profile. Requiring both meant an entry
        // added through the UI silently served nothing.
        for entry in entries where entry.matches(url) && entry.isEnabled {
            if let current = best, current.matchMode.mockSpecificity >= entry.matchMode.mockSpecificity {
                continue
            }
            best = entry
        }
        return best
    }

    var enabledEntryCount: Int {
        return entries.filter { $0.isEnabled && $0.mock.isEnabled }.count
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note, entries, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        note = try c.decodeIfPresent(String.self, forKey: .note)
        entries = try c.decodeIfPresent([MockProfileEntry].self, forKey: .entries) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
