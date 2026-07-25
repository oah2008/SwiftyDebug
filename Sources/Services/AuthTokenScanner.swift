//
//  AuthTokenScanner.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

// MARK: - JWT decoding

/// A best-effort JWT decode used by the auth inspector.
///
/// Deliberately standalone (the network detail screen has its own inline decode
/// for a single request) and deliberately total: every step is optional-chained
/// so a malformed / non-JWT token simply fails to decode instead of crashing.
struct DebugJWT {

    /// The `header` segment decoded as JSON, or `[:]` when it wasn't JSON.
    let header: [String: Any]
    /// The `payload` (claims) segment decoded as JSON.
    let payload: [String: Any]
    /// Pretty-printed header JSON (empty when the segment wasn't JSON).
    let headerJSON: String
    /// Pretty-printed payload JSON.
    let payloadJSON: String
    /// The signature segment, if present (never verified — we have no key).
    let signature: String

    // Well-known registered claims, pre-extracted for the UI.
    let exp: Date?
    let iat: Date?
    let nbf: Date?
    let sub: String?
    let aud: String?
    let iss: String?
    /// `scope` / `scp` flattened to a space-joined string.
    let scope: String?
    /// `roles` / `permissions` / `authorities` flattened.
    let roles: String?
    /// Algorithm from the header (`alg`).
    let algorithm: String?

    // MARK: Decode

    /// Decodes `token` if it looks like a JWT (`a.b` or `a.b.c` with a JSON
    /// payload). Returns nil for anything else — opaque tokens are expected and
    /// are *not* an error.
    static func decode(_ token: String) -> DebugJWT? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: ".")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }

        // The payload MUST decode to a JSON object, otherwise it isn't a JWT.
        guard let payloadObj = jsonObject(fromBase64URL: parts[1]) else { return nil }

        let headerObj = jsonObject(fromBase64URL: parts[0]) ?? [:]

        let expDate = date(from: payloadObj["exp"])
        let iatDate = date(from: payloadObj["iat"])
        let nbfDate = date(from: payloadObj["nbf"])

        return DebugJWT(
            header: headerObj,
            payload: payloadObj,
            headerJSON: prettyJSON(headerObj),
            payloadJSON: prettyJSON(payloadObj),
            signature: parts.count == 3 ? parts[2] : "",
            exp: expDate,
            iat: iatDate,
            nbf: nbfDate,
            sub: flatten(payloadObj["sub"]),
            aud: flatten(payloadObj["aud"]),
            iss: flatten(payloadObj["iss"]),
            scope: flatten(payloadObj["scope"]) ?? flatten(payloadObj["scp"]),
            roles: flatten(payloadObj["roles"])
                ?? flatten(payloadObj["permissions"])
                ?? flatten(payloadObj["authorities"]),
            algorithm: flatten(headerObj["alg"])
        )
    }

    // MARK: Claim helpers

    /// Registered claims surfaced at the top of the detail screen, in this order.
    static let highlightedClaimOrder = ["exp", "iat", "nbf", "sub", "aud", "iss",
                                        "scope", "scp", "roles", "permissions", "authorities"]

    /// `true` when the token carried an `exp` that had already passed at `date`.
    func wasExpired(at date: Date) -> Bool {
        guard let exp else { return false }
        return date > exp
    }

    var isExpiredNow: Bool { wasExpired(at: Date()) }

    /// Every claim as display strings, highlighted ones first, then the rest
    /// alphabetically.
    func orderedClaims() -> [(key: String, value: String)] {
        var rows: [(String, String)] = []
        var seen = Set<String>()
        for key in Self.highlightedClaimOrder {
            guard let raw = payload[key] else { continue }
            seen.insert(key)
            rows.append((key, displayValue(forClaim: key, raw: raw)))
        }
        for key in payload.keys.sorted() where !seen.contains(key) {
            rows.append((key, displayValue(forClaim: key, raw: payload[key] ?? "")))
        }
        return rows
    }

    /// Renders a claim value, expanding the time claims into readable dates.
    func displayValue(forClaim key: String, raw: Any) -> String {
        if ["exp", "iat", "nbf", "auth_time", "updated_at"].contains(key),
           let d = Self.date(from: raw) {
            return "\(Self.absolute(d))   (\(Self.stringify(raw)))"
        }
        return Self.stringify(raw)
    }

    // MARK: Formatting

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func absolute(_ date: Date) -> String { absoluteFormatter.string(from: date) }

    /// "2d 3h" / "4m 12s" / "45s" — compact, never negative.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let total = Int(abs(interval).rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    // MARK: Private

    /// base64url → base64 (`-`/`_` swapped back, `=` padding restored).
    private static func jsonObject(fromBase64URL segment: String) -> [String: Any]? {
        var s = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func prettyJSON(_ dict: [String: Any]) -> String {
        guard !dict.isEmpty,
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    /// Accepts NSNumber, numeric strings and ISO-ish numbers; rejects nonsense.
    static func date(from raw: Any?) -> Date? {
        var seconds: Double?
        if let n = raw as? NSNumber { seconds = n.doubleValue }
        else if let s = raw as? String { seconds = Double(s.trimmingCharacters(in: .whitespaces)) }
        guard var value = seconds, value > 0, value.isFinite else { return nil }
        // Some issuers emit milliseconds. Anything past year ~5138 is ms.
        if value > 100_000_000_000 { value /= 1000 }
        return Date(timeIntervalSince1970: value)
    }

    /// Flattens a scalar / array claim into one display string.
    static func flatten(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let arr = raw as? [Any] {
            let parts = arr.compactMap { flatten($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// Human string for any JSON value (objects become compact JSON).
    static func stringify(_ raw: Any) -> String {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        if raw is NSNull { return "null" }
        if JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: raw)
    }
}

// MARK: - Credential model

/// Where a credential was found and how it is framed.
enum AuthTokenKind: Equatable {
    /// `Authorization: Bearer …`
    case bearer
    /// `Authorization: Basic …`
    case basic
    /// `Authorization: <SomethingElse> …` (Digest, Token, Negotiate, …)
    case scheme(String)
    /// A known API-key style header (X-Api-Key & friends).
    case apiKey
    /// An auth-looking entry inside the `Cookie` header.
    case cookie

    var label: String {
        switch self {
        case .bearer:            return "BEARER"
        case .basic:             return "BASIC"
        case .scheme(let s):     return s.isEmpty ? "AUTHORIZATION" : s.uppercased()
        case .apiKey:            return "API KEY"
        case .cookie:            return "COOKIE"
        }
    }
}

/// `user:pass` decoded from a Basic credential.
struct BasicCredential {
    let username: String
    let password: String
}

/// One request that carried a given credential.
struct AuthTokenUsage {
    let method: String
    let host: String
    let path: String
    let urlString: String
    let statusCode: String
    let startedAt: Date?
    /// `exp` had already passed when this request was sent — the bug this
    /// screen exists to catch.
    var sentExpired: Bool = false

    var endpointLabel: String {
        let p = path.isEmpty ? "/" : path
        return "\(method.isEmpty ? "GET" : method) \(p)"
    }
}

/// One DISTINCT credential value plus every request that used it.
struct AuthCredential {

    /// Stable identity = the token value itself (that is the grouping key).
    let id: String
    /// The credential value with any scheme prefix stripped.
    let value: String
    /// The full original header value (what the copy button yields).
    let rawValue: String
    let kind: AuthTokenKind
    /// Header / cookie names this value was seen under.
    var sources: [String]
    var usages: [AuthTokenUsage]
    let jwt: DebugJWT?
    let basic: BasicCredential?

    var hosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in usages where !u.host.isEmpty && seen.insert(u.host).inserted { out.append(u.host) }
        return out
    }

    /// Endpoints ordered by how often they used this credential.
    var endpointCounts: [(endpoint: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for u in usages {
            let key = u.endpointLabel
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.map { (endpoint: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count == $1.count ? $0.endpoint < $1.endpoint : $0.count > $1.count }
    }

    var requestCount: Int { usages.count }
    var firstSeen: Date? { usages.compactMap { $0.startedAt }.min() }
    var lastSeen: Date? { usages.compactMap { $0.startedAt }.max() }
    /// Requests that went out with an already-expired token.
    var expiredUsageCount: Int { usages.filter { $0.sentExpired }.count }
    var isJWT: Bool { jwt != nil }

    /// Masked form for the list: first/last few characters only.
    var maskedValue: String {
        AuthCredential.mask(value)
    }

    static func mask(_ value: String) -> String {
        let count = value.count
        guard count > 12 else { return String(repeating: "•", count: max(count, 6)) }
        return "\(value.prefix(6))••••••••\(value.suffix(4))"
    }

    /// Expiry state used for pills / countdowns.
    enum ExpiryState {
        case none
        case valid(Date)
        case expired(Date)
    }

    var expiryState: ExpiryState {
        guard let exp = jwt?.exp else { return .none }
        return exp > Date() ? .valid(exp) : .expired(exp)
    }
}

// MARK: - Scanner

/// Walks captured transactions and groups every auth credential it can find by
/// DISTINCT value.
///
/// Only in-memory fields are read (`requestHeaderFields`, `url`, `startTime`) —
/// request/response bodies are disk-backed and are never touched here.
enum AuthTokenScanner {

    /// API-key style headers we treat as credentials (lowercased).
    static let apiKeyHeaders: Set<String> = [
        "x-api-key", "x-apikey", "api-key", "apikey",
        "x-auth-token", "x-access-token", "x-session-token",
        "x-authorization", "x-token", "x-auth",
    ]

    /// Cookie names that look like credentials (substring match, lowercased).
    private static let cookieNeedles = [
        "token", "auth", "session", "sess", "jwt", "access", "refresh",
        "bearer", "apikey", "api_key", "api-key", "sid", "credential", "identity",
    ]

    /// Values shorter than this are ignored as noise (feature flags, "1", …).
    private static let minimumCookieValueLength = 8

    /// Snapshots the live capture list on the calling thread.
    static func liveTransactions() -> [NetworkTransaction] {
        (NetworkRequestStore.shared.httpModels as NSArray as? [NetworkTransaction]) ?? []
    }

    /// Groups credentials found across `transactions`.
    ///
    /// Ordering: credentials that were used on an already-expired request come
    /// first (that's the failure mode), then most-recently-seen.
    static func scan(_ transactions: [NetworkTransaction]) -> [AuthCredential] {

        struct Bucket {
            var value: String
            var rawValue: String
            var kind: AuthTokenKind
            var sources: [String]
            var usages: [AuthTokenUsage]
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for model in transactions {
            guard let headers = model.requestHeaderFields as? [String: Any] else { continue }

            let url = model.url as URL?
            let usageBase = AuthTokenUsage(
                method: (model.method ?? "GET").uppercased(),
                host: url?.host ?? "",
                path: url?.path ?? "",
                urlString: url?.absoluteString ?? (model.url?.absoluteString ?? ""),
                statusCode: model.statusCode ?? "",
                startedAt: startDate(of: model)
            )

            for (rawKey, rawVal) in headers {
                let name = String(rawKey)
                let lowerName = name.lowercased()
                guard let value = rawVal as? String,
                      !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                var found: [(kind: AuthTokenKind, token: String, raw: String, source: String)] = []

                if lowerName == "authorization" || lowerName == "proxy-authorization" {
                    found.append(parseAuthorization(value, headerName: name))
                } else if apiKeyHeaders.contains(lowerName) {
                    found.append((kind: .apiKey,
                                  token: value.trimmingCharacters(in: .whitespaces),
                                  raw: value, source: name))
                } else if lowerName == "cookie" {
                    found.append(contentsOf: parseCookies(value))
                }

                for hit in found where !hit.token.isEmpty {
                    let key = hit.token
                    if buckets[key] == nil {
                        buckets[key] = Bucket(value: hit.token, rawValue: hit.raw,
                                              kind: hit.kind, sources: [hit.source], usages: [])
                        order.append(key)
                    } else if !(buckets[key]?.sources.contains(hit.source) ?? true) {
                        buckets[key]?.sources.append(hit.source)
                    }
                    buckets[key]?.usages.append(usageBase)
                }
            }
        }

        var credentials: [AuthCredential] = []
        credentials.reserveCapacity(order.count)

        for key in order {
            guard let bucket = buckets[key] else { continue }
            let jwt = DebugJWT.decode(bucket.value)
            let basic = bucket.kind == .basic ? decodeBasic(bucket.value) : nil

            // Flag every request that was sent after this token's `exp`.
            var usages = bucket.usages
            if let exp = jwt?.exp {
                for i in usages.indices {
                    if let sent = usages[i].startedAt, sent > exp { usages[i].sentExpired = true }
                }
            }
            usages.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }

            credentials.append(AuthCredential(
                id: key,
                value: bucket.value,
                rawValue: bucket.rawValue,
                kind: bucket.kind,
                sources: bucket.sources,
                usages: usages,
                jwt: jwt,
                basic: basic
            ))
        }

        credentials.sort { a, b in
            let aBad = a.expiredUsageCount > 0
            let bBad = b.expiredUsageCount > 0
            if aBad != bBad { return aBad }
            return (a.lastSeen ?? .distantPast) > (b.lastSeen ?? .distantPast)
        }
        return credentials
    }

    // MARK: Parsing

    /// `startTime` is a seconds-since-1970 string.
    static func startDate(of model: NetworkTransaction) -> Date? {
        guard let raw = model.startTime, !raw.isEmpty else { return nil }
        let seconds = (raw as NSString).doubleValue
        guard seconds > 0, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseAuthorization(_ value: String, headerName: String)
        -> (kind: AuthTokenKind, token: String, raw: String, source: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else {
            // No scheme at all — the whole header value is the credential.
            return (.scheme(""), trimmed, value, headerName)
        }
        let scheme = String(trimmed[..<spaceIndex])
        let token = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        switch scheme.lowercased() {
        case "bearer": return (.bearer, token, value, headerName)
        case "basic":  return (.basic, token, value, headerName)
        default:       return (.scheme(scheme), token, value, headerName)
        }
    }

    /// Pulls auth-looking pairs out of a `Cookie` header.
    private static func parseCookies(_ value: String)
        -> [(kind: AuthTokenKind, token: String, raw: String, source: String)] {
        var out: [(AuthTokenKind, String, String, String)] = []
        for pair in value.components(separatedBy: ";") {
            let entry = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
            let cookieValue = String(entry[entry.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, cookieValue.count >= minimumCookieValueLength else { continue }
            let lower = name.lowercased()
            guard cookieNeedles.contains(where: { lower.contains($0) }) else { continue }
            out.append((.cookie, cookieValue, "\(name)=\(cookieValue)", "Cookie: \(name)"))
        }
        return out.map { (kind: $0.0, token: $0.1, raw: $0.2, source: $0.3) }
    }

    /// base64 `user:pass`. Returns nil when it isn't decodable.
    static func decodeBasic(_ token: String) -> BasicCredential? {
        var s = token.trimmingCharacters(in: .whitespaces)
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        guard let colon = decoded.firstIndex(of: ":") else {
            return BasicCredential(username: decoded, password: "")
        }
        return BasicCredential(username: String(decoded[..<colon]),
                               password: String(decoded[decoded.index(after: colon)...]))
    }

    // MARK: Comparison

    struct ClaimDiff {
        let claim: String
        let left: String?
        let right: String?
        var isDifferent: Bool { left != right }
    }

    /// Union of both tokens' claims, highlighted claims first, marking which
    /// values differ. Non-JWT credentials simply contribute no claims.
    static func compare(_ a: AuthCredential, _ b: AuthCredential) -> [ClaimDiff] {
        let left = a.jwt
        let right = b.jwt
        var keys: [String] = []
        var seen = Set<String>()
        for key in DebugJWT.highlightedClaimOrder
        where (left?.payload[key] != nil || right?.payload[key] != nil) {
            if seen.insert(key).inserted { keys.append(key) }
        }
        let rest = Set((left?.payload.keys.map { $0 } ?? []) + (right?.payload.keys.map { $0 } ?? []))
        for key in rest.sorted() where seen.insert(key).inserted { keys.append(key) }

        return keys.map { key in
            ClaimDiff(
                claim: key,
                left: left?.payload[key].map { DebugJWT.stringify($0) },
                right: right?.payload[key].map { DebugJWT.stringify($0) }
            )
        }
    }
}
