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

/// How a matching request's URL is rewritten.
enum RedirectMode: String, Codable {
    /// No redirect.
    case none
    /// Replace only the host (and optional port). Path and query are untouched.
    /// `mahaly.com/checkout/abc?p=1` + `beta.mahaly.com` → `beta.mahaly.com/checkout/abc?p=1`
    case host
    /// Replace host **and** path, preserving the original query string.
    /// `mahaly.com/checkout/abc?p=1` + `beta.mahaly.com/checkout/xyz`
    ///   → `beta.mahaly.com/checkout/xyz?p=1`
    case hostAndPath
}

/// How the rule matches incoming requests.
enum EndpointMatchMode: String, Codable {
    /// Matches only the exact URL path (e.g. `/api/users/123/orders`).
    case exact
    /// Matches the normalized pattern with IDs replaced (e.g. `/api/users/{id}/orders`).
    case normalized
    /// Matches any request whose host is in `matchHosts`.
    case host
    /// Matches every request regardless of URL.
    case global
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
    /// How matching requests' URLs are rewritten. `.none` by default.
    var redirectMode: RedirectMode
    /// Redirect destination. For `.host`: `"beta.example.com"` (optionally with a
    /// scheme and/or port). For `.hostAndPath`: `"beta.example.com/checkout/xyz"`.
    var redirectTarget: String

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
        self.redirectMode = .none
        self.redirectTarget = ""
    }

    /// Rewrites `url` per this rule's redirect settings, preserving the original
    /// query string. Returns nil when no redirect applies.
    ///
    ///   host        : mahaly.com/checkout/abc?p=1  + "beta.com"
    ///                 -> beta.com/checkout/abc?p=1
    ///   hostAndPath : mahaly.com/checkout/abc?p=1  + "beta.com/checkout/xyz"
    ///                 -> beta.com/checkout/xyz?p=1
    func redirectedURL(for url: URL) -> URL? {
        guard redirectMode != .none else { return nil }
        let target = redirectTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Peel an optional scheme off the target; otherwise keep the original.
        var rest = target
        for prefix in ["https://", "http://"] where rest.lowercased().hasPrefix(prefix) {
            comps.scheme = String(prefix.dropLast(3))  // "https" / "http"
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        // Drop any query/fragment the user pasted into the target — the original
        // request's query is always preserved.
        if let q = rest.firstIndex(of: "?") { rest = String(rest[..<q]) }
        if let f = rest.firstIndex(of: "#") { rest = String(rest[..<f]) }
        while rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        guard !rest.isEmpty else { return nil }

        // Split "host[:port]/path/segments"
        var hostPart = rest
        var pathPart = ""
        if let slash = rest.firstIndex(of: "/") {
            hostPart = String(rest[..<slash])
            pathPart = String(rest[slash...])
        }
        // Optional port on the host part.
        if let colon = hostPart.lastIndex(of: ":"),
           let port = Int(hostPart[hostPart.index(after: colon)...]) {
            comps.port = port
            hostPart = String(hostPart[..<colon])
        }
        guard !hostPart.isEmpty else { return nil }
        comps.host = hostPart

        if redirectMode == .hostAndPath {
            // Replace the path wholesale; query is left untouched by design.
            comps.path = pathPart.isEmpty ? "/" : pathPart
        }
        return comps.url
    }

    /// Convenience initializer for global rules (match every request).
    static func globalRule() -> InterceptRule {
        return InterceptRule(matchEndpoint: "global", matchMode: .global)
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
        case redirectMode, redirectTarget
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
        redirectMode = try c.decodeIfPresent(RedirectMode.self, forKey: .redirectMode) ?? .none
        redirectTarget = try c.decodeIfPresent(String.self, forKey: .redirectTarget) ?? ""
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
        try c.encode(redirectMode, forKey: .redirectMode)
        try c.encode(redirectTarget, forKey: .redirectTarget)
    }
}
