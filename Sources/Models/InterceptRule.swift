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

/// How the rule matches incoming requests.
enum EndpointMatchMode: String, Codable {
    /// Matches only the exact URL path (e.g. `/api/users/123/orders`).
    case exact
    /// Matches the normalized pattern with IDs replaced (e.g. `/api/users/{id}/orders`).
    case normalized
    /// Matches any request whose host is in `matchHosts`.
    case host
}

/// Defines how a matching network request should be modified or blocked.
/// Multiple rules can exist per endpoint — they are applied in `order` (ascending),
/// with later rules overriding earlier ones for the same keys.
struct InterceptRule: Codable {
    let id: String
    /// The key used for storage lookup.
    /// For `.normalized` / `.exact` modes: the endpoint path.
    /// For `.host` mode: a canonical key like `host:a.com,b.com`.
    let matchEndpoint: String
    /// How the rule matches incoming requests.
    var matchMode: EndpointMatchMode
    /// Hosts this rule applies to (only used when `matchMode == .host`).
    var matchHosts: [String]
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
        self.matchHosts = []
        self.isBlocked = false
        self.headerOverrides = []
        self.queryParamOverrides = []
        self.removedHeaderKeys = []
        self.removedQueryParamKeys = []
        self.isEnabled = true
        self.createdAt = Date()
        self.order = 0
    }

    /// Convenience initializer for host-based rules.
    static func hostRule(hosts: [String]) -> InterceptRule {
        let sorted = hosts.map { $0.lowercased() }.sorted()
        let key = "host:" + sorted.joined(separator: ",")
        var rule = InterceptRule(matchEndpoint: key, matchMode: .host)
        rule.matchHosts = sorted
        return rule
    }

    // Backward-compatible decoding.
    enum CodingKeys: String, CodingKey {
        case id, normalizedEndpoint, matchEndpoint, matchMode, matchHosts, isBlocked
        case headerOverrides, queryParamOverrides, removedHeaderKeys, removedQueryParamKeys
        case isEnabled, createdAt, order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let me = try c.decodeIfPresent(String.self, forKey: .matchEndpoint) {
            matchEndpoint = me
        } else {
            matchEndpoint = try c.decode(String.self, forKey: .normalizedEndpoint)
        }
        matchMode = try c.decodeIfPresent(EndpointMatchMode.self, forKey: .matchMode) ?? .normalized
        matchHosts = try c.decodeIfPresent([String].self, forKey: .matchHosts) ?? []
        isBlocked = try c.decode(Bool.self, forKey: .isBlocked)
        headerOverrides = try c.decode([KVPair].self, forKey: .headerOverrides)
        queryParamOverrides = try c.decode([KVPair].self, forKey: .queryParamOverrides)
        removedHeaderKeys = try c.decode(Set<String>.self, forKey: .removedHeaderKeys)
        removedQueryParamKeys = try c.decode(Set<String>.self, forKey: .removedQueryParamKeys)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(matchEndpoint, forKey: .matchEndpoint)
        try c.encode(matchMode, forKey: .matchMode)
        try c.encode(matchHosts, forKey: .matchHosts)
        try c.encode(isBlocked, forKey: .isBlocked)
        try c.encode(headerOverrides, forKey: .headerOverrides)
        try c.encode(queryParamOverrides, forKey: .queryParamOverrides)
        try c.encode(removedHeaderKeys, forKey: .removedHeaderKeys)
        try c.encode(removedQueryParamKeys, forKey: .removedQueryParamKeys)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(order, forKey: .order)
    }
}
