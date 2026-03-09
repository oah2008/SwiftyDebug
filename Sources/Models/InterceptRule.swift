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
    }
}
