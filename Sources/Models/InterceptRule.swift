//
//  InterceptRule.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

/// Reads one field without ever throwing.
///
/// `decodeIfPresent` **throws** on a value it cannot make sense of — most
/// notably an unknown enum raw value; it does **not** return nil. A single
/// `try c.decode(...)` in a rule's decoder is therefore enough to destroy the
/// whole rule (and, before `LenientElement` below, the whole rules file) the
/// first time an older build reads something a newer one wrote. Every field
/// that should degrade to a default instead of killing its container reads
/// through here.
fileprivate func lenient<T: Decodable, K: CodingKey>(
    _ c: KeyedDecodingContainer<K>, _ type: T.Type, _ key: K, _ fallback: T
) -> T {
    ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
}

extension CodingUserInfoKey {
    /// Set to `true` on a decoder to make `InterceptRule` fill in a default for
    /// any field it cannot read, instead of throwing.
    ///
    /// Off by default, and deliberately so — the two callers want opposite
    /// things:
    ///
    /// * **Our own `rules.json`** (`InterceptRuleStore`) turns it ON. Whatever
    ///   is in that file is all the user has; refusing to read a field there
    ///   means silently losing a rule they created.
    /// * **A teammate's imported file** (`RuleTransfer`) leaves it OFF. There
    ///   the file is untrusted input the user can go and fix, and the import
    ///   preview earns its keep by saying `Rule #3: missing "isBlocked"`
    ///   rather than quietly inventing values.
    static let swiftyDebugLenientRuleDecoding =
        CodingUserInfoKey(rawValue: "com.swiftydebug.lenientRuleDecoding")!
}

/// Wraps a `Decodable` so that decoding an ARRAY of them drops only the
/// elements this build cannot make sense of, instead of failing the array.
///
/// The wrapper's own `init(from:)` never throws, which is the point: an
/// `UnkeyedDecodingContainer` does not reliably advance past an element whose
/// decode threw, so "try, catch, continue" spins forever. Succeeding with a
/// nil payload always advances.
struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

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

    /// Lenient decoding, matching `InterceptRule`'s own.
    ///
    /// The synthesized decoder makes `id` required, so a hand-written pair —
    /// or one exported before `id` existed — throws, and that throw used to
    /// travel all the way up and delete the entire rules file. A pair with no
    /// id simply gets a fresh one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = lenient(c, String.self, .id, UUID().uuidString)
        key = lenient(c, String.self, .key, "")
        value = lenient(c, String.self, .value, "")
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

/// Where a matching request is paused for manual inspection/editing.
///
/// Deliberately a single choice rather than two flags: pausing both before and
/// after would stop the same request twice, which is confusing.
enum BreakpointMode: String, Codable {
    case off
    /// Hold before sending — edit the outgoing request, then deliver it.
    case beforeSend
    /// Let it go out, then hold the response — edit the body, then deliver.
    case afterResponse

    var title: String {
        switch self {
        case .off:            return "Off"
        case .beforeSend:     return "Before send"
        case .afterResponse:  return "After response"
        }
    }

    var detail: String {
        switch self {
        case .off:           return "Requests are never paused."
        case .beforeSend:    return "Pause before the request leaves the app so you can edit it."
        case .afterResponse: return "Let the request go out, then pause so you can edit the response before the app sees it."
        }
    }
}

/// A canned response returned instead of hitting the network.
struct MockResponse: Codable, Equatable {
    var isEnabled: Bool
    var statusCode: Int
    /// Response body (usually JSON text).
    var body: String
    /// Extra response headers to send with the mock.
    var headers: [KVPair]
    /// Artificial delay in seconds, to simulate a slow endpoint.
    var delay: Double

    init(isEnabled: Bool = false, statusCode: Int = 200, body: String = "",
         headers: [KVPair] = [], delay: Double = 0) {
        self.isEnabled = isEnabled
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
        self.delay = delay
    }

    /// Lenient decoding, matching `InterceptRule`'s own.
    ///
    /// Synthesized `Codable` makes every field required, so a rule exported by a
    /// build that predates one of these fields — or a hand-written document —
    /// fails to decode the mock and takes the entire rule down with it. Every
    /// field falls back to its default instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Defaults to true, unlike the memberwise init: an absent `mock` key
        // yields no MockResponse at all, so reaching here means a mock object was
        // written deliberately and omitting the flag should not disarm it.
        isEnabled = lenient(c, Bool.self, .isEnabled, true)
        statusCode = lenient(c, Int.self, .statusCode, 200)
        body = lenient(c, String.self, .body, "")
        headers = lenient(c, [LenientElement<KVPair>].self, .headers, []).compactMap { $0.value }
        delay = lenient(c, Double.self, .delay, 0)
    }

    /// Common scenarios offered as one-tap presets.
    struct Scenario {
        let title: String
        let subtitle: String
        let statusCode: Int
        let body: String
    }

    static let scenarios: [Scenario] = [
        .init(title: "200 OK", subtitle: "Success with an empty object",
              statusCode: 200, body: "{\n  \"success\" : true\n}"),
        .init(title: "201 Created", subtitle: "Resource created",
              statusCode: 201, body: "{\n  \"id\" : 1,\n  \"created\" : true\n}"),
        .init(title: "204 No Content", subtitle: "Success, empty body", statusCode: 204, body: ""),
        .init(title: "400 Bad Request", subtitle: "Validation failure",
              statusCode: 400, body: "{\n  \"error\" : \"bad_request\",\n  \"message\" : \"Invalid parameters\"\n}"),
        .init(title: "401 Unauthorized", subtitle: "Expired or missing token",
              statusCode: 401, body: "{\n  \"error\" : \"unauthorized\",\n  \"message\" : \"Token expired\"\n}"),
        .init(title: "403 Forbidden", subtitle: "Not allowed",
              statusCode: 403, body: "{\n  \"error\" : \"forbidden\",\n  \"message\" : \"Access denied\"\n}"),
        .init(title: "404 Not Found", subtitle: "Missing resource",
              statusCode: 404, body: "{\n  \"error\" : \"not_found\",\n  \"message\" : \"Resource not found\"\n}"),
        .init(title: "409 Conflict", subtitle: "Duplicate / conflicting state",
              statusCode: 409, body: "{\n  \"error\" : \"conflict\",\n  \"message\" : \"Already exists\"\n}"),
        .init(title: "422 Unprocessable", subtitle: "Field-level validation errors",
              statusCode: 422, body: "{\n  \"error\" : \"unprocessable\",\n  \"errors\" : {\n    \"field\" : [\"is required\"]\n  }\n}"),
        .init(title: "429 Too Many Requests", subtitle: "Rate limited",
              statusCode: 429, body: "{\n  \"error\" : \"rate_limited\",\n  \"retry_after\" : 60\n}"),
        .init(title: "500 Server Error", subtitle: "Backend blew up",
              statusCode: 500, body: "{\n  \"error\" : \"internal_error\",\n  \"message\" : \"Something went wrong\"\n}"),
        .init(title: "502 Bad Gateway", subtitle: "Upstream failure",
              statusCode: 502, body: "{\n  \"error\" : \"bad_gateway\"\n}"),
        .init(title: "503 Unavailable", subtitle: "Maintenance / overloaded",
              statusCode: 503, body: "{\n  \"error\" : \"unavailable\",\n  \"message\" : \"Try again later\"\n}"),
        .init(title: "Empty list", subtitle: "Common empty-state test",
              statusCode: 200, body: "{\n  \"data\" : [\n\n  ],\n  \"total\" : 0\n}"),
    ]
}

extension MockResponse {

    /// Response headers this mock should be served with.
    ///
    /// `Content-Length` is always recomputed from the body — a stale one makes
    /// CFNetwork truncate the delivered bytes, which is the same class of bug
    /// that made edited breakpoint responses arrive empty. A `Content-Type` the
    /// mock declares itself wins over the JSON default.
    var headerFields: [String: String] {
        var out: [String: String] = [:]
        for pair in headers where !pair.key.isEmpty { out[pair.key] = pair.value }
        if !out.keys.contains(where: { $0.lowercased() == "content-type" }) {
            out["Content-Type"] = "application/json"
        }
        out["Content-Length"] = "\(body.utf8.count)"
        return out
    }

    /// The synthetic response handed to the app in place of a real one.
    func httpResponse(for url: URL) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: statusCode,
                        httpVersion: "HTTP/1.1", headerFields: headerFields)
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
    /// Canned response returned instead of hitting the network.
    var mock: MockResponse
    /// Where matching requests are paused for manual editing.
    var breakpointMode: BreakpointMode
    /// Automated edits applied to a matching JSON response body — the same edits
    /// people were making by hand at an `.afterResponse` breakpoint, without the
    /// pause. Empty by default, so an existing rule behaves exactly as before.
    var responseRewrites: [ResponseRewrite]

    /// True when this rule has at least one armed rewrite. Cheap enough to check
    /// on every response before touching the body.
    var hasActiveResponseRewrites: Bool {
        responseRewrites.contains { $0.isEnabled }
    }

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
        self.mock = MockResponse()
        self.breakpointMode = .off
        self.responseRewrites = []
    }

    /// Rewrites `url` per this rule's redirect settings, preserving the original
    /// query string. Returns nil when no redirect applies.
    ///
    ///   host        : mahaly.com/checkout/abc?p=1  + "beta.com"
    ///                 -> beta.com/checkout/abc?p=1
    ///   hostAndPath : mahaly.com/checkout/abc?p=1  + "beta.com/checkout/xyz"
    ///                 -> beta.com/checkout/xyz?p=1
    func redirectedURL(for url: URL) -> URL? {
        Self.rewritingURL(url, mode: redirectMode, target: redirectTarget)
    }

    /// The single implementation of "change the host (and optionally the path)".
    ///
    /// Both halves of the feature go through this: redirecting a request
    /// (`redirectedURL(for:)`) and rewriting a URL inside a response body
    /// (`RewriteAction.replaceHost`). Keeping one implementation means a
    /// redirect and a rewrite can never disagree about what the user meant.
    static func rewritingURL(_ url: URL, mode: RedirectMode, target rawTarget: String) -> URL? {
        guard mode != .none else { return nil }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if mode == .hostAndPath {
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
        case mock, breakpointMode
        case responseRewrites
    }

    /// Decodes a rule field by field.
    ///
    /// Fields that carry no information the user typed — the enums, the
    /// optional extras — always degrade to a default rather than throwing:
    /// `decodeIfPresent` THROWS on an unknown enum raw value, so a rule written
    /// by a newer build used to fail to decode ENTIRELY, and the store then
    /// discarded every rule on the device.
    ///
    /// The fields a rule genuinely needs (`isBlocked`, `isEnabled`, `createdAt`
    /// and the override lists) are strict unless the decoder opts in via
    /// `.swiftyDebugLenientRuleDecoding` — see that key for why the local store
    /// and an import want different answers.
    ///
    /// `id` and the endpoint are hard requirements either way: a rule with no
    /// identity cannot be updated, toggled or deleted, and a rule with no
    /// endpoint is keyed under nothing and can never match. `LenientElement`
    /// makes even that survivable at the file level — the one bad rule is
    /// skipped, the rest load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let isLenient = decoder.userInfo[.swiftyDebugLenientRuleDecoding] as? Bool == true
        /// Strict by default, defaulted when the decoder asked for leniency.
        func required<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) throws -> T {
            isLenient ? lenient(c, type, key, fallback) : try c.decode(type, forKey: key)
        }

        id = try c.decode(String.self, forKey: .id)

        // No default for the endpoint in either mode: a rule keyed under nothing
        // can never match, so it is right for it to fail and be skipped. The
        // legacy key is still the last word, so the thrown error names it.
        if let modern = ((try? c.decodeIfPresent(String.self, forKey: .matchEndpoint)) ?? nil) {
            matchEndpoint = modern
        } else {
            matchEndpoint = try c.decode(String.self, forKey: .normalizedEndpoint)
        }

        // Always lenient — an unknown raw value here is the exact throw that
        // took whole rules (and then whole files) down.
        matchMode = lenient(c, EndpointMatchMode.self, .matchMode, .normalized)
        matchHosts = lenient(c, [String].self, .matchHosts, [])
        isBlocked = try required(Bool.self, .isBlocked, false)
        // Element by element: one malformed pair loses that pair, not the list.
        headerOverrides = try required([LenientElement<KVPair>].self, .headerOverrides, [])
            .compactMap { $0.value }
        queryParamOverrides = try required([LenientElement<KVPair>].self, .queryParamOverrides, [])
            .compactMap { $0.value }
        removedHeaderKeys = try required(Set<String>.self, .removedHeaderKeys, [])
        removedQueryParamKeys = try required(Set<String>.self, .removedQueryParamKeys, [])
        // Defaults to enabled, matching `init(matchEndpoint:)` and `MockResponse`
        // above: an absent flag means hand-written or pre-flag JSON, and someone
        // who writes a rule out by hand means it to be armed.
        isEnabled = try required(Bool.self, .isEnabled, true)
        // A rule with no readable timestamp sorts as if it were just created —
        // `allRules()` orders by this, so it needs *some* answer.
        createdAt = try required(Date.self, .createdAt, Date())
        order = lenient(c, Int.self, .order, 0)
        redirectMode = lenient(c, RedirectMode.self, .redirectMode, .none)
        redirectTarget = lenient(c, String.self, .redirectTarget, "")
        mock = lenient(c, MockResponse.self, .mock, MockResponse())
        breakpointMode = lenient(c, BreakpointMode.self, .breakpointMode, .off)
        // Decoded element by element: one rewrite written by a newer build is
        // dropped on its own instead of taking the whole rule with it.
        responseRewrites = lenient(c, [ResponseRewrite.Lenient].self, .responseRewrites, [])
            .compactMap { $0.rewrite }
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
        try c.encode(mock, forKey: .mock)
        try c.encode(breakpointMode, forKey: .breakpointMode)
        try c.encode(responseRewrites, forKey: .responseRewrites)
    }
}
