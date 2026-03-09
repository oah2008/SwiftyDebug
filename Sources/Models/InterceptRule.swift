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

/// Defines how a matching network request should be modified or blocked.
/// Multiple rules can exist per endpoint — they are applied in `order` (ascending),
/// with later rules overriding earlier ones for the same keys.
struct InterceptRule: Codable {
    let id: String
    let normalizedEndpoint: String
    var isBlocked: Bool
    var headerOverrides: [KVPair]
    var queryParamOverrides: [KVPair]
    var removedHeaderKeys: Set<String>
    var removedQueryParamKeys: Set<String>
    var isEnabled: Bool
    let createdAt: Date
    /// Position in the rule list. Lower = applied first, higher = applied later (wins on conflict).
    var order: Int

    init(normalizedEndpoint: String) {
        self.id = UUID().uuidString
        self.normalizedEndpoint = normalizedEndpoint
        self.isBlocked = false
        self.headerOverrides = []
        self.queryParamOverrides = []
        self.removedHeaderKeys = []
        self.removedQueryParamKeys = []
        self.isEnabled = true
        self.createdAt = Date()
        self.order = 0
    }

    // Backward-compatible decoding for rules persisted without `order`.
    enum CodingKeys: String, CodingKey {
        case id, normalizedEndpoint, isBlocked, headerOverrides, queryParamOverrides
        case removedHeaderKeys, removedQueryParamKeys, isEnabled, createdAt, order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        normalizedEndpoint = try c.decode(String.self, forKey: .normalizedEndpoint)
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
