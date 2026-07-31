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
    /// What this rule matches against.
    /// For `.normalized` / `.exact` modes: the endpoint path.
    /// For `.host` mode: a canonical key like `host:a.com,b.com`.
    /// For `.global`: the literal `"global"`.
    ///
    /// **`var`, deliberately.** It used to be `let`, and that single word was the
    /// root of "exact rules override each other": the editor does
    /// `rule = existingRule ?? InterceptRule(...)`, so editing a rule and
    /// switching its scope from Pattern to Exact changed `matchMode` but left
    /// `matchEndpoint` holding the *normalized* pattern. The rule was then filed
    /// as exact under `/product/{id}/{id}`, which no real request path ever
    /// equals — every such rule landed in the same bucket and none of them
    /// matched anything. See `storageKey` for the other half of the fix.
    var matchEndpoint: String
    /// How the rule matches incoming requests.
    var matchMode: EndpointMatchMode
    /// Hosts this rule applies to (only used when `matchMode == .host`).
    var matchHosts: [String]
    /// Host an **endpoint** rule (`.exact` / `.normalized`) is pinned to, e.g.
    /// `"api.example.com"`. Empty means *any host*.
    ///
    /// Empty is the backward-compatible default on purpose: `.exact` and
    /// `.normalized` have always matched on path alone, so every rule already on
    /// a device decodes with no pin and keeps behaving exactly as it did. Only a
    /// rule the user explicitly pins to a host gains the host check.
    ///
    /// Unused by `.host` (which has `matchHosts`) and `.global`; `canonicalized()`
    /// clears it for those modes so it can never quietly change their key.
    var matchHost: String
    /// User-given name. Empty means "describe yourself" — see `displayName`.
    var name: String
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
        self.matchHost = ""
        self.name = ""
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
        let sorted = Self.canonicalHosts(hosts)
        var rule = InterceptRule(matchEndpoint: Self.hostKey(for: sorted), matchMode: .host)
        rule.matchHosts = sorted
        return rule
    }

    /// The one way to build an endpoint-scoped (`.exact` / `.normalized`) rule.
    ///
    /// Use this rather than `init(matchEndpoint:matchMode:)` when a host pin is
    /// involved: it lowercases and trims the host and guarantees the rule's
    /// `storageKey` agrees with its scope.
    ///
    /// - Parameters:
    ///   - path: the request path — the FULL path for `.exact`
    ///     (`/product/10289032912/20920220`), the normalizer's output for
    ///     `.normalized` (`/product/{id}/{id}`).
    ///   - mode: `.exact` or `.normalized`. Anything else is a programmer error
    ///     and is coerced to `.normalized`.
    ///   - host: the host to pin to, or `nil` / `""` for **any host** (the
    ///     behaviour every pre-existing rule has).
    static func endpointRule(path: String,
                             mode: EndpointMatchMode = .normalized,
                             host: String? = nil) -> InterceptRule {
        let safeMode: EndpointMatchMode = (mode == .exact) ? .exact : .normalized
        var rule = InterceptRule(matchEndpoint: path, matchMode: safeMode)
        rule.matchHost = Self.canonicalHost(host ?? "")
        return rule
    }

    // MARK: - Storage key

    /// Stands in for a host pin of "any host" inside `storageKey`.
    /// `*` is not a legal host, so it can never collide with a real one.
    static let anyHostToken = "*"

    /// A separator no URL path, host or pattern can contain, so a key can never
    /// be forged by ordinary content.
    private static let keySeparator = "\u{1}"

    /// The key `InterceptRuleStore` files this rule under.
    ///
    /// DERIVED, never persisted — `rules.json` is a flat array of rules, so the
    /// store's bucketing is pure in-memory state and changing this scheme needs
    /// no on-disk migration at all.
    ///
    /// Two things this fixes, both reported as "exact rules override each other":
    ///
    /// 1. The mode is part of the key, so an `.exact` rule and a `.normalized`
    ///    rule can never share a bucket. They used to: a path with no ids
    ///    normalizes to itself, so `/api/users` exact and `/api/users` pattern
    ///    were the same dictionary key, and `rules(for:).first { $0.matchMode == mode }`
    ///    could hand back the wrong one.
    /// 2. The host pin is part of the key, so `/cart` on `a.com` and `/cart` on
    ///    `b.com` are separate rules that each apply only to their own host.
    ///
    /// Distinct full paths were already distinct keys and still are:
    /// `/product/1/2` and `/product/3/4` coexist and never see each other's edits.
    var storageKey: String {
        switch matchMode {
        case .global:
            return "global"
        case .host:
            return Self.hostKey(for: Self.canonicalHosts(matchHosts))
        case .exact, .normalized:
            return Self.endpointKey(mode: matchMode, host: matchHost, endpoint: matchEndpoint)
        }
    }

    /// Builds the storage key for an endpoint rule without needing a rule.
    /// The store probes with this, so lookup and storage can never disagree.
    static func endpointKey(mode: EndpointMatchMode, host: String, endpoint: String) -> String {
        let pin = canonicalHost(host)
        let hostPart = pin.isEmpty ? anyHostToken : pin
        return mode.rawValue + keySeparator + hostPart + keySeparator + endpoint
    }

    /// Builds the storage key for a host rule. Hosts must already be canonical.
    static func hostKey(for hosts: [String]) -> String {
        return "host:" + hosts.joined(separator: ",")
    }

    static func canonicalHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func canonicalHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { canonicalHost($0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    /// True when this rule's host pin lets `url` through.
    ///
    /// Always true for a rule with no pin — that is every rule written before
    /// `matchHost` existed — and for `.host` / `.global`, whose host handling
    /// lives in `matchHosts` and "everything" respectively.
    ///
    /// The store does not need this (the pin is baked into `storageKey`), but the
    /// WKWebView JS bridge matches rules by hand and does, so it lives here where
    /// both can see the same definition.
    func hostPinAllows(_ url: URL) -> Bool {
        guard matchMode == .exact || matchMode == .normalized else { return true }
        let pin = Self.canonicalHost(matchHost)
        guard !pin.isEmpty else { return true }
        return Self.canonicalHost(url.host ?? "") == pin
    }

    /// True when this endpoint rule applies to every host (the legacy behaviour).
    var appliesToAnyHost: Bool {
        switch matchMode {
        case .exact, .normalized: return Self.canonicalHost(matchHost).isEmpty
        case .host, .global:      return false
        }
    }

    // MARK: - Canonicalization / migration

    /// A copy whose `matchEndpoint`, `matchHosts` and `matchHost` agree with its
    /// `matchMode`, so its `storageKey` is the one lookup will probe.
    ///
    /// Applied on the way into the store — both on load and on every write — so a
    /// rule that arrives mis-keyed (hand-edited export, an older build's editor
    /// bug, an import) is repaired instead of being stored somewhere lookup never
    /// looks. A rule filed under a key nothing probes is invisible AND inert,
    /// which is the worst failure this file can have.
    ///
    /// The one behaviour change it makes is deliberate and narrow: an `.exact`
    /// rule whose endpoint is literally a normalizer *output* (`/product/{id}/{id}`)
    /// is re-filed as `.normalized`. Such a rule can never match — no real
    /// `url.path` contains `{id}` — so it is provably doing nothing today, and
    /// "pattern" is the only reading under which the user's rule works at all.
    /// It is exactly what the old editor produced when you opened a pattern rule
    /// and tapped Exact.
    func canonicalized() -> InterceptRule {
        var copy = self
        switch matchMode {
        case .global:
            copy.matchEndpoint = "global"
            copy.matchHosts = []
            copy.matchHost = ""
        case .host:
            var hosts = Self.canonicalHosts(matchHosts)
            if hosts.isEmpty, matchEndpoint.hasPrefix("host:") {
                // Recover the hosts from the key when only the key survived.
                hosts = Self.canonicalHosts(
                    String(matchEndpoint.dropFirst("host:".count)).components(separatedBy: ",")
                )
            }
            copy.matchHosts = hosts
            copy.matchEndpoint = Self.hostKey(for: hosts)
            copy.matchHost = ""
        case .exact:
            copy.matchHost = Self.canonicalHost(matchHost)
            copy.matchHosts = []
            if Self.looksLikeNormalizerOutput(matchEndpoint) { copy.matchMode = .normalized }
        case .normalized:
            copy.matchHost = Self.canonicalHost(matchHost)
            copy.matchHosts = []
        }
        return copy
    }

    /// True for a path that the normalizer produced and that therefore cannot be
    /// a literal request path: it contains `{id}` and normalizing it is a no-op.
    static func looksLikeNormalizerOutput(_ endpoint: String) -> Bool {
        guard endpoint.contains("{id}") else { return false }
        return EndpointNormalizer.normalize(endpoint) == endpoint
    }

    // Backward-compatible decoding.
    enum CodingKeys: String, CodingKey {
        case id, normalizedEndpoint, matchEndpoint, matchMode, matchHosts, matchHost, name, isBlocked
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
        // Absent on every rule already on a device. Empty = any host, which is
        // what `.exact` / `.normalized` have always done, so an old rule decodes
        // to exactly the behaviour it had. Lenient for the usual reason: a field
        // nobody typed must never be able to take a whole rule down.
        matchHost = lenient(c, String.self, .matchHost, "")
        // Also absent on every existing rule; `displayName` derives one from what
        // the rule does, so an unnamed rule is still identifiable in a list.
        name = lenient(c, String.self, .name, "")
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
        try c.encode(matchHost, forKey: .matchHost)
        try c.encode(name, forKey: .name)
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

// MARK: - Naming

extension InterceptRule {

    /// What to call this rule anywhere it is listed.
    ///
    /// The user's `name` when they gave one, otherwise `derivedName` — a
    /// description built from what the rule actually does.
    ///
    /// This exists because the rule rows only ever counted headers and query
    /// parameters, so a rule that ONLY mocked, ONLY held a breakpoint, ONLY
    /// rewrote a response or ONLY redirected all displayed as "Empty rule" and
    /// were indistinguishable from each other in a list.
    var displayName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? derivedName : typed
    }

    /// A name derived purely from this rule's own configuration.
    ///
    /// PURE — no store, no singletons, no I/O, no dates, no locale-dependent
    /// formatting. Same rule in, same string out, so it is safe to call from
    /// `cellForRowAt` and can be unit-tested exhaustively.
    ///
    ///     "Mock 404 · /product/{id}"
    ///     "Breakpoint after response · api.example.com"
    ///     "Rewrite data.url · /cart"
    ///     "Blocked · /analytics"
    ///     "3 headers · /product/{id}"
    var derivedName: String {
        let scope = scopeSummary
        return scope.isEmpty ? armedSummary : armedSummary + " · " + scope
    }

    /// Everything this rule has actually ARMED, most decisive first, joined with
    /// " + ". `"Empty rule"` when nothing is armed — that is the honest answer
    /// and the editor refuses to save one.
    ///
    /// "Armed" means *would do something on the wire*: a redirect with a blank
    /// target and a mock that is switched off are both left out, because naming
    /// a rule after something it silently will not do is how a feature ships
    /// inert without anyone noticing.
    var armedSummary: String {
        var parts: [String] = []

        if isBlocked { parts.append("Blocked") }
        if mock.isEnabled { parts.append("Mock \(mock.statusCode)") }

        switch breakpointMode {
        case .off:            break
        case .beforeSend:     parts.append("Breakpoint before send")
        case .afterResponse:  parts.append("Breakpoint after response")
        }

        let target = redirectTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if redirectMode != .none, !target.isEmpty {
            parts.append("Redirect \u{2192} " + target)
        }

        parts.append(contentsOf: rewriteSummaryParts)

        let headerCount = headerOverrides.count + removedHeaderKeys.count
        if headerCount > 0 {
            parts.append("\(headerCount) header" + (headerCount == 1 ? "" : "s"))
        }
        let paramCount = queryParamOverrides.count + removedQueryParamKeys.count
        if paramCount > 0 {
            parts.append("\(paramCount) param" + (paramCount == 1 ? "" : "s"))
        }

        return parts.isEmpty ? "Empty rule" : parts.joined(separator: " + ")
    }

    /// One rewrite is named after itself ("Rewrite data.url"); several are
    /// counted. Rewrites that are all switched OFF still get a part — with
    /// "(off)" on it — because the alternative is a rule that visibly carries
    /// rewrites being called "Empty rule".
    private var rewriteSummaryParts: [String] {
        guard !responseRewrites.isEmpty else { return [] }
        let live = responseRewrites.filter { $0.isEnabled }
        guard !live.isEmpty else {
            let n = responseRewrites.count
            return ["\(n) rewrite" + (n == 1 ? "" : "s") + " (off)"]
        }
        if live.count == 1 {
            let label = Self.rewriteLabel(live[0])
            return [label.isEmpty ? "1 rewrite" : "Rewrite " + label]
        }
        return ["\(live.count) rewrites"]
    }

    private static func rewriteLabel(_ rewrite: ResponseRewrite) -> String {
        let named = rewrite.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        return rewrite.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the rule applies, in the shortest form that is still unambiguous.
    /// Empty when there is nothing worth saying, in which case `derivedName`
    /// drops the separator rather than trailing a lonely " · ".
    var scopeSummary: String {
        switch matchMode {
        case .global:
            return "All requests"
        case .host:
            let hosts = Self.canonicalHosts(matchHosts)
            return hosts.isEmpty ? "" : hosts.joined(separator: ", ")
        case .exact, .normalized:
            let pin = Self.canonicalHost(matchHost)
            if pin.isEmpty { return matchEndpoint }
            // Host-pinned: "api.example.com/cart" reads as one address, which is
            // exactly what the rule now matches.
            return matchEndpoint.isEmpty ? pin : pin + matchEndpoint
        }
    }
}
