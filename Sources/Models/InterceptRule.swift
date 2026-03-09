//
//  InterceptRule.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

/// A single key-value pair used for header or query parameter overrides.
struct KVPair: Codable, Equatable {
    let id: String
    var key: String
    var value: String

    init(key: String, value: String) {
        self.id = UUID().uuidString
        self.key = key
        self.value = value
    }
}

/// How the rule matches incoming request paths.
enum EndpointMatchMode: String, Codable {
    /// Matches only the exact URL path (e.g. `/api/users/123/orders`).
    case exact
    /// Matches the normalized pattern with IDs replaced (e.g. `/api/users/{id}/orders`).
    case normalized
}

/// Defines how a matching network request should be modified or blocked.
/// Multiple rules can exist per endpoint — they are applied in `order` (ascending),
/// with later rules overriding earlier ones for the same keys.
struct InterceptRule: Codable {
    let id: String
    /// The endpoint string used as the match key.
    /// For `.normalized` mode this is the normalized path (e.g. `/api/users/{id}/orders`).
    /// For `.exact` mode this is the literal request path (e.g. `/api/users/123/orders`).
    let matchEndpoint: String
    /// How the rule matches incoming request paths.
    var matchMode: EndpointMatchMode
    var isBlocked: Bool
    var headerOverrides: [KVPair]
    var queryParamOverrides: [KVPair]
    var removedHeaderKeys: Set<String>
    var removedQueryParamKeys: Set<String>
    var isEnabled: Bool
    let createdAt: Date
    /// Position in the rule list. Lower = applied first, higher = applied later (wins on conflict).
    var order: Int

    init(matchEndpoint: String, matchMode: EndpointMatchMode = .normalized) {
        self.id = UUID().uuidString
        self.matchEndpoint = matchEndpoint
        self.matchMode = matchMode
        self.isBlocked = false
        self.headerOverrides = []
        self.queryParamOverrides = []
        self.removedHeaderKeys = []
        self.removedQueryParamKeys = []
        self.isEnabled = true
        self.createdAt = Date()
        self.order = 0
    }

    // Backward-compatible decoding for rules persisted before matchMode / matchEndpoint existed.
    enum CodingKeys: String, CodingKey {
        case id, normalizedEndpoint, matchEndpoint, matchMode, isBlocked, headerOverrides
        case queryParamOverrides, removedHeaderKeys, removedQueryParamKeys, isEnabled, createdAt, order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Migration: old rules stored `normalizedEndpoint`, new ones store `matchEndpoint`.
        if let me = try c.decodeIfPresent(String.self, forKey: .matchEndpoint) {
            matchEndpoint = me
        } else {
            matchEndpoint = try c.decode(String.self, forKey: .normalizedEndpoint)
        }
        matchMode = try c.decodeIfPresent(EndpointMatchMode.self, forKey: .matchMode) ?? .normalized
        isBlocked = try c.decode(Bool.self, forKey: .isBlocked)
        headerOverrides = try c.decode([KVPair].self, forKey: .headerOverrides)
        queryParamOverrides = try c.decode([KVPair].self, forKey: .queryParamOverrides)
        removedHeaderKeys = try c.decode(Set<String>.self, forKey: .removedHeaderKeys)
        removedQueryParamKeys = try c.decode(Set<String>.self, forKey: .removedQueryParamKeys)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}
