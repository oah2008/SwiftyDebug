//
//  TagResolver.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 19/09/2026.
//

import Foundation

/// The identity of a network tag: one row in the filter sheet, one pill on a
/// request cell, one filter key. (See TAGS-FILTER.)
///
/// `key` is the identity. Two tags are the same tag when their keys match, and
/// the key is what a filter selection stores — so the pill a row shows and the
/// row a filter keeps can never disagree, because both come from the same
/// resolution.
struct NetworkTag: Hashable {

    /// Where the tag came from. Also the precedence order: a developer's own tag
    /// beats the built-in catalog, which beats a name derived from the host.
    enum Origin: Int, Comparable {
        case userTag = 0
        /// An entry of `SwiftyDebug.urls`, the capture allow-list.
        case allowListURL = 1
        case knownAPI = 2
        case derivedHost = 3

        static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Stable, unique identity. Namespaced by origin so a user tag keyed
    /// `algolia.net` and a catalog entry for the same domain stay distinct.
    let key: String

    /// What the pill and the filter row display.
    let label: String

    let origin: Origin

    /// The matcher that produced this tag, kept so filtering never has to
    /// re-derive it. Empty for derived-host tags, whose key is the host.
    let matchedKeyword: String
}

/// The one place SwiftyDebug decides what a request is called and what a filter
/// selection means.
///
/// ## Why this exists
///
/// Tag lookup used to be copy-pasted into five call sites with three different
/// matching rules. `NetworkCell` iterated the tag dictionary and took the FIRST
/// substring hit — and a Swift dictionary has no order, so a URL matching two
/// keywords got a different pill on different launches. The filter sheet used
/// longest-keyword-wins instead, so the pill and the filter disagreed by
/// construction. Meanwhile the filter predicate compared a tag keyword against
/// `absoluteString`, which includes the query string, so selecting a tag for
/// `algolia.mahally.com/1/events` matched nothing at all the moment the request
/// carried `?x-algolia-api-key=…`.
///
/// Everything now goes through `tag(for:)`. One resolution, one precedence
/// order, one definition of "matches".
///
/// ## Resolution order
///
/// 1. **Developer tags** (`SwiftyDebug.addTag(keyword:label:)`), most specific
///    first — a path-scoped or wildcard keyword beats a host keyword beats a
///    bare substring keyword; within a tier the longer keyword wins, and ties
///    break lexicographically so the answer never depends on hash order.
/// 2. **`KnownAPICatalog`** — a domain-suffix match against ~600 well-known API
///    hosts, so untagged third-party traffic still reads as "Stripe", not
///    `api.stripe.com`.
/// 3. **Derived from the host** — every request gets a tag, always.
enum TagResolver {

    // MARK: - Public resolution

    /// The tag for `url`, or nil only when there is no host to work with.
    static func tag(for url: URL?) -> NetworkTag? {
        guard let url else { return nil }
        return tag(forURLString: url.absoluteString)
    }

    /// `NetworkTransaction.url` is an `NSURL`, so the whole UI layer would
    /// otherwise have to bridge at every call site.
    static func tag(for url: NSURL?) -> NetworkTag? {
        guard let absolute = url?.absoluteString else { return nil }
        return tag(forURLString: absolute)
    }

    /// The tag for a raw URL string. Cached per string, because the network list
    /// resolves every visible row on every keystroke.
    static func tag(forURLString urlString: String) -> NetworkTag? {
        guard !urlString.isEmpty else { return nil }
        let generation = SwiftyDebug.tagGeneration

        // One critical section for the whole lookup. Resolving outside the lock
        // and re-taking it to store would let a tag change land in between, so a
        // URL could be cached under a generation whose keywords never produced
        // it — a stale pill that no later change would ever clear.
        lock.lock()
        defer { lock.unlock() }

        if cacheGeneration != generation {
            cache.removeAll(keepingCapacity: true)
            regexCache.removeAll(keepingCapacity: true)
            compiledKeywords = nil
            cacheGeneration = generation
        }
        if let hit = cache[urlString] { return hit.tag }

        let resolved = resolveUncached(urlString)
        // A session can see tens of thousands of distinct URLs; the cache is a
        // hot-path accelerator, not a record, so it is dropped wholesale rather
        // than grown without bound.
        if cache.count >= cacheCeiling { cache.removeAll(keepingCapacity: true) }
        cache[urlString] = CacheEntry(tag: resolved)
        return resolved
    }

    /// True when `url` belongs to the tag identified by `key`.
    ///
    /// Defined as "resolves to that tag", which is what makes a filter selection
    /// show exactly the rows that display that pill. A request matching two
    /// user keywords belongs to the more specific one and to that one only, so
    /// selecting `algolia.mahally.com/1/events` never drags in `/1/indexes`.
    static func matches(tagKey: String, url: URL?) -> Bool {
        guard let url else { return false }
        return tag(for: url)?.key == tagKey
    }

    static func matches(tagKey: String, url: NSURL?) -> Bool {
        guard let url else { return false }
        return tag(for: url)?.key == tagKey
    }

    /// Same, for callers that only hold the string.
    static func matches(tagKey: String, urlString: String) -> Bool {
        tag(forURLString: urlString)?.key == tagKey
    }

    // MARK: - Enumeration

    /// One entry per tag that has at least one request in `urlStrings`, ordered
    /// developer tags first, then catalog, then derived — alphabetically within
    /// each group.
    ///
    /// This is what the filter sheet lists, and it is derived from the traffic
    /// rather than from the tag table, which is the whole point: a tag with no
    /// requests is noise, and a request whose tag was never configured still
    /// gets a row. Every tag with traffic appears — there is no dedup step left
    /// that can swallow one.
    static func tags(forURLStrings urlStrings: [String]) -> [(tag: NetworkTag, count: Int)] {
        var counts: [String: Int] = [:]
        var byKey: [String: NetworkTag] = [:]
        for urlString in urlStrings {
            guard let tag = tag(forURLString: urlString) else { continue }
            counts[tag.key, default: 0] += 1
            // Several keywords can share one label and so one key. Keep the
            // lexicographically first as the row's subtitle, so the sheet does
            // not change what it says depending on capture order.
            if let existing = byKey[tag.key] {
                if tag.matchedKeyword < existing.matchedKeyword { byKey[tag.key] = tag }
            } else {
                byKey[tag.key] = tag
            }
        }

        // No disambiguation pass, deliberately. A tag's label is a pure function
        // of its key, so the pill a row shows and the row this list renders are
        // the same string by construction — a listing that "fixed up" labels
        // using the whole set would reintroduce exactly the cell/sheet
        // disagreement this type exists to remove.
        let resolved: [(tag: NetworkTag, count: Int)] = byKey.values.map { tag in
            (tag: tag, count: counts[tag.key] ?? 0)
        }

        return resolved.sorted { a, b in
            if a.tag.origin != b.tag.origin { return a.tag.origin < b.tag.origin }
            let la = a.tag.label.lowercased(), lb = b.tag.label.lowercased()
            if la != lb { return la < lb }
            return a.tag.key < b.tag.key
        }
    }

    // MARK: - Presentation

    /// What a request's pill shows: the resolved label, plus the string every
    /// surface must hash to pick the colour.
    ///
    /// The colour key is the tag's `key`, never the matched keyword and never
    /// the label. Hashing the keyword gave one tag different hues on the row and
    /// in the group header; hashing the label gave two different tags the same
    /// hue whenever their labels collided. The key is the only value that is
    /// one-per-tag.
    static func pill(for url: URL?, isWebView: Bool = false) -> (label: String, colorKey: String)? {
        guard let tag = tag(for: url) else { return nil }
        return (displayLabel(for: tag, isWebView: isWebView), tag.key)
    }

    static func pill(for url: NSURL?, isWebView: Bool = false) -> (label: String, colorKey: String)? {
        guard let tag = tag(for: url) else { return nil }
        return (displayLabel(for: tag, isWebView: isWebView), tag.key)
    }

    /// The pill text. A webview request keeps its tag — identity, colour and
    /// filtering are unchanged — and gains a marker, because on the Pinned tab
    /// and in search results app and webview traffic sit side by side and were
    /// otherwise indistinguishable. The filter sheet annotates its rows the same
    /// way, so the two still read alike.
    static func displayLabel(for tag: NetworkTag, isWebView: Bool) -> String {
        guard isWebView else { return tag.label }
        return tag.label + " \u{00B7} web"
    }

    // MARK: - Normalisation (shared by matching and display)

    /// Lowercased host with the port, any trailing dot and a leading `www.`
    /// removed — the form both sides of every host comparison are put in.
    static func normalizeHost(_ host: String) -> String {
        KnownAPICatalog.normalizeHost(host)
    }

    /// `host + path`, lowercased, without scheme, port, query or fragment, and
    /// with a trailing slash trimmed.
    ///
    /// This — not `absoluteString` — is what a tag keyword is matched against.
    /// Matching against the absolute string is what made a tag stop working the
    /// moment the request carried query parameters.
    static func canonicalHostPath(ofURLString urlString: String) -> String {
        let (host, path, _) = split(urlString)
        return host + path
    }

    /// The same canonical form a keyword is reduced to: no scheme, no `www.`,
    /// no trailing slash, lowercased, trimmed.
    static func canonicalKeyword(_ keyword: String) -> String {
        var value = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "//"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: - Resolution internals

    private static func resolveUncached(_ urlString: String) -> NetworkTag? {
        let (host, path, query) = split(urlString)
        let hostPath = host + path
        let full = query.isEmpty ? hostPath : hostPath + "?" + query

        // 1. Developer tags, most specific first.
        //
        // Keyed by the LABEL, not by the keyword that matched. `addTag` is a
        // many-keywords-to-one-label API and real configurations use it that way
        // — the reporter registers "segment" for two hosts, "algolia" for three,
        // "adjust" for two. Keying by keyword split each of those into several
        // filter rows with identical names and different pill colours, which is
        // the same unreadable sheet this work exists to fix. Two tags stay
        // separate when their LABELS differ, which is exactly the
        // "algolia events" vs "algolia proxy" case. (See TAGS-FILTER.)
        if let match = bestUserKeyword(hostPath: hostPath, full: full, host: host) {
            return NetworkTag(key: "tag:" + match.label.lowercased(),
                              label: match.label,
                              origin: .userTag,
                              matchedKeyword: match.keyword)
        }

        guard !host.isEmpty else { return nil }

        // 2. `SwiftyDebug.urls` — the capture allow-list — as an IMPLICIT tag.
        //
        // Before this type existed, each allow-list entry produced its own
        // path-scoped row in the filter sheet and its own group, whether or not
        // anyone had tagged it. Resolving purely from `addTag` would have dropped
        // that silently, so an entry the developer went to the trouble of listing
        // still names its own traffic — it just loses to an explicit tag.
        if let match = bestAllowListEntry(hostPath: hostPath) {
            return NetworkTag(key: "url:" + match,
                              label: match,
                              origin: .allowListURL,
                              matchedKeyword: match)
        }

        // 2. Built-in catalog of known APIs.
        if let label = KnownAPICatalog.label(forHost: host) {
            return NetworkTag(key: "api:" + label.lowercased(),
                              label: label,
                              origin: .knownAPI,
                              matchedKeyword: host)
        }

        // 3. A tag derived from the host, so nothing is ever untagged.
        //
        // Keyed by the REGISTRABLE DOMAIN, not the full host: `algolia.mahally.com`
        // and `cdn.mahally.com` are one untagged "mahally" tag rather than two
        // rows with the same name, and the label stays a pure function of the key
        // so no listing has to rename anything to keep the sheet readable.
        let domain = registrableDomain(forHost: host)
        return NetworkTag(key: "host:" + domain,
                          label: derivedLabel(forHost: domain),
                          origin: .derivedHost,
                          matchedKeyword: domain)
    }

    /// Splits a URL string into `(normalizedHost, trimmedLowercasedPath, query)`.
    ///
    /// `URLComponents` is tried first and a manual split is the fallback, because
    /// a captured URL is whatever the app actually sent — including strings
    /// Foundation declines to parse (an unencoded space or brace in a path is
    /// common in real traffic, and returning nothing for those would silently
    /// drop the row's tag).
    private static func split(_ urlString: String) -> (host: String, path: String, query: String) {
        if let components = URLComponents(string: urlString), let rawHost = components.host {
            let host = normalizeHost(rawHost)
            var path = components.percentEncodedPath.lowercased()
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == "/" { path = "" }
            return (host, path, (components.percentEncodedQuery ?? "").lowercased())
        }

        var rest = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "//"] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        var query = ""
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = String(rest[rest.startIndex..<mark])
        }
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[rest.startIndex..<hash]) }
        let slash = rest.firstIndex(of: "/")
        let rawHost = slash.map { String(rest[rest.startIndex..<$0]) } ?? rest
        var path = slash.map { String(rest[$0...]) } ?? ""
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        return (normalizeHost(rawHost), path, query)
    }

    // MARK: - Keyword matching

    /// How specific a keyword is. Lower wins, so a path-scoped keyword always
    /// beats a bare host keyword even when the host keyword is longer.
    private enum Specificity: Int, Comparable {
        case pathOrWildcard = 0
        case hostLike = 1
        case bareSubstring = 2

        static func < (lhs: Specificity, rhs: Specificity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct CompiledKeyword {
        let keyword: String        // canonical form
        let label: String
        let specificity: Specificity
        let hasWildcard: Bool
        let matchesQuery: Bool     // keyword carries a "?" so it must see the query
    }

    /// The developer's tags, canonicalised once per change to the tag table
    /// rather than once per URL.
    private static func keywords() -> [CompiledKeyword] {
        if let compiled = compiledKeywords { return compiled }
        let compiled: [CompiledKeyword] = SwiftyDebug._tags.compactMap { raw, label in
            let keyword = canonicalKeyword(raw)
            guard !keyword.isEmpty else { return nil }
            let hasWildcard = keyword.contains("*")
            let specificity = classify(keyword, hasWildcard: hasWildcard)
            return CompiledKeyword(keyword: keyword,
                                   label: label,
                                   specificity: specificity,
                                   hasWildcard: hasWildcard,
                                   matchesQuery: keyword.contains("?"))
        }
        compiledKeywords = compiled
        return compiled
    }

    /// The longest `SwiftyDebug.urls` entry that this request sits under.
    /// Path-boundary matched and query-tolerant, like every other comparison here.
    private static func bestAllowListEntry(hostPath: String) -> String? {
        var best: String?
        for raw in SwiftyDebug.urlsForTagging {
            let candidate = canonicalKeyword(raw)
            guard !candidate.isEmpty, boundaryPrefix(hostPath, candidate) else { continue }
            if best == nil || candidate.count > best!.count
                || (candidate.count == best!.count && candidate < best!) {
                best = candidate
            }
        }
        return best
    }

    /// Which matcher a keyword gets.
    ///
    /// Punctuation alone is not enough. `algolia.net` and `config.json` both have
    /// a dot and no slash, but only the first denotes a host — and treating the
    /// second as one made it match nothing at all, silently. Likewise
    /// `api.shop.com/v1` is a host+path that must be anchored, while
    /// `/v1/checkout` has no host to anchor to and can only ever be the substring
    /// match `addTag` documents.
    ///
    /// So the question asked is "does this keyword name a host?", and a keyword
    /// that does not falls through to the documented substring behaviour — which
    /// is what shipped before this type existed. (See TAGS-FILTER.)
    private static func classify(_ keyword: String, hasWildcard: Bool) -> Specificity {
        if let slash = keyword.firstIndex(of: "/") {
            let hostPart = String(keyword[keyword.startIndex..<slash])
            // "/v1/checkout" (empty host part) and "orders/v1" are path fragments.
            return looksLikeHostname(hostPart) ? .pathOrWildcard : .bareSubstring
        }
        if hasWildcard { return .pathOrWildcard }
        return looksLikeHostname(keyword) ? .hostLike : .bareSubstring
    }

    /// True when `value` reads as a hostname: dotted, with a final label that is
    /// a plausible TLD. Deliberately a heuristic — a miss costs a keyword the
    /// stricter host semantics and leaves it matching as a substring, never the
    /// other way round.
    static func looksLikeHostname(_ value: String) -> Bool {
        guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        guard let last = value.components(separatedBy: ".").last, !last.isEmpty else { return false }
        if last.count == 2, last.allSatisfy({ $0.isLetter }) { return true }   // any ccTLD
        return commonTopLevelDomains.contains(last)
    }

    private static let commonTopLevelDomains: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "info", "biz", "name", "pro",
        "io", "dev", "app", "ai", "co", "me", "tv", "cc", "ly", "sh", "gg", "gl",
        "cloud", "online", "site", "store", "tech", "xyz", "shop", "live", "news",
        "blog", "space", "world", "link", "click", "media", "network", "systems",
        "solutions", "digital", "agency", "studio", "design", "email", "today",
        "life", "one", "run", "page", "web", "wiki", "zone", "team", "works",
        "software", "services", "support", "center", "global", "group", "host",
        "press", "pub", "rocks", "social", "tools", "top", "vip", "fun", "mobi",
        "asia", "travel", "jobs", "aero", "coop", "museum", "cat", "post", "tel",
    ]

    private static func bestUserKeyword(hostPath: String,
                                        full: String,
                                        host: String) -> (keyword: String, label: String)? {
        var best: (candidate: CompiledKeyword, tier: MatchTier)?
        for candidate in keywords() {
            guard let tier = matchTier(candidate, hostPath: hostPath, full: full, host: host) else { continue }
            guard let current = best else { best = (candidate, tier); continue }
            if isMoreSpecific((candidate, tier), than: current) { best = (candidate, tier) }
        }
        guard let best else { return nil }
        return (best.candidate.keyword, best.candidate.label)
    }

    /// How a keyword matched. A structured match (host, path prefix, glob) always
    /// beats a plain substring hit.
    private enum MatchTier: Int, Comparable {
        case structured = 0
        case substring = 1

        static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Deterministic ordering: specificity, then length, then the keyword itself.
    /// The final tie-break is what stops the answer depending on dictionary
    /// iteration order — the defect that made the same URL show different pills
    /// on different launches.
    private static func isMoreSpecific(_ lhs: (candidate: CompiledKeyword, tier: MatchTier),
                                       than rhs: (candidate: CompiledKeyword, tier: MatchTier)) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.candidate.specificity != rhs.candidate.specificity {
            return lhs.candidate.specificity < rhs.candidate.specificity
        }
        if lhs.candidate.keyword.count != rhs.candidate.keyword.count {
            return lhs.candidate.keyword.count > rhs.candidate.keyword.count
        }
        return lhs.candidate.keyword < rhs.candidate.keyword
    }

    /// How `candidate` matches this request, or nil when it does not.
    ///
    /// The structured tests come first, and a plain `contains` is the fallback —
    /// because `addTag(keyword:label:)` is DOCUMENTED as "a case-insensitive
    /// substring to match against request URLs", and that is what shipped. A
    /// keyword like `/v1/checkout` or `config.json` looks path- or host-shaped to
    /// the classifier, fails the anchored test, and would otherwise match nothing
    /// at all — silently breaking an integration that worked before.
    private static func matchTier(_ candidate: CompiledKeyword,
                                  hostPath: String,
                                  full: String,
                                  host: String) -> MatchTier? {
        let subject = candidate.matchesQuery ? full : hostPath
        switch candidate.specificity {
        case .pathOrWildcard:
            if candidate.hasWildcard {
                if wildcardMatches(pattern: candidate.keyword, subject: subject) { return .structured }
                return nil   // a glob is never a literal substring
            }
            if boundaryPrefix(subject, candidate.keyword) { return .structured }
        case .hostLike:
            // A host keyword matches the host and its subdomains, never a host
            // that merely ends with the same letters: `algolia.net` must not
            // claim `notalgolia.net`.
            if host == candidate.keyword || host.hasSuffix("." + candidate.keyword) { return .structured }
        case .bareSubstring:
            // The documented behaviour since day one, and the reason "algolia"
            // tags every Algolia host — and now also what a path fragment like
            // "/v1/checkout" gets, because it has no host to anchor to.
            return full.contains(candidate.keyword) ? .structured : nil
        }
        // A keyword that NAMES a host is matched by host rules only. Falling back
        // to `contains` here would let "algolia.net" claim "notalgolia.net" and
        // "/1/index" claim "/1/indexes" — the boundary failures this engine
        // exists to remove.
        return nil
    }

    /// `subject == prefix`, or `subject` continues after `prefix` at a path
    /// boundary. Plain `hasPrefix` would let `/1/index` claim `/1/indexes`.
    private static func boundaryPrefix(_ subject: String, _ prefix: String) -> Bool {
        if subject == prefix { return true }
        guard subject.hasPrefix(prefix) else { return false }
        let next = subject[subject.index(subject.startIndex, offsetBy: prefix.count)]
        return next == "/" || next == "?"
    }

    /// Anchored glob match, segment-aware.
    ///
    /// `*` stands for exactly one path segment and `**` for any number of them —
    /// the same convention `JSONPathPattern` already uses for body paths, so the
    /// SDK has one wildcard language rather than two. Anchored at the start, and
    /// at a path boundary at the end unless the pattern ends in a wildcard:
    /// `api.x.dev/1/indexes/*/recommendations` matches
    /// `…/indexes/products/recommendations` but not `…/indexes/a/b/recommendations`
    /// (that needs `**`) and not `…/recommendations-v2`.
    static func wildcardMatches(pattern: String, subject: String) -> Bool {
        guard let regex = wildcardRegex(for: pattern) else {
            // An un-compilable pattern must not silently tag everything.
            return false
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return regex.firstMatch(in: subject, options: [], range: range) != nil
    }

    /// Translates a glob keyword to an anchored regular expression, compiled once
    /// and reused — a keyword is matched against every captured URL, so building
    /// the pattern per comparison would put regex compilation in the list's
    /// scroll path.
    private static func wildcardRegex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }

        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    expression += ".*"                 // `**` — any depth
                    index = pattern.index(after: next)
                } else {
                    expression += "[^/]*"              // `*` — one segment
                    index = next
                }
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index = pattern.index(after: index)
            }
        }
        // End anchor: a trailing wildcard already consumed the rest, otherwise the
        // match has to stop on a path boundary so `/1/index` cannot claim
        // `/1/indexes`.
        expression += pattern.hasSuffix("*") ? "" : "(?:$|[/?])"

        let compiled = try? NSRegularExpression(pattern: expression, options: [])
        regexCache[pattern] = compiled
        return compiled
    }

    /// Guarded by the same lock as `cache`; cleared with it when tags change.
    private static var regexCache: [String: NSRegularExpression?] = [:]

    // MARK: - Derived labels

    /// The registrable domain of `host`: the brand label plus its public suffix.
    ///
    /// `algolia.mahally.com` -> `mahally.com`, `salla.com.sa` -> `salla.com.sa`,
    /// `localhost` and IP literals unchanged. This is the identity an untagged
    /// request is grouped under.
    static func registrableDomain(forHost host: String) -> String {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return host }

        let labels = normalized.components(separatedBy: ".")
        guard labels.count > 2 else { return normalized }    // "mahally.com", "localhost"

        // An IP literal has no registrable domain to extract.
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return normalized }

        // Two-part public suffixes ("com.sa", "co.uk") take one label more.
        let lastTwo = labels[(labels.count - 2)...].joined(separator: ".")
        if Self.multiPartSuffixes.contains(lastTwo) {
            return labels.count > 3 ? labels[(labels.count - 3)...].joined(separator: ".") : normalized
        }
        return labels[(labels.count - 2)...].joined(separator: ".")
    }

    /// A readable name for a host nobody tagged: the brand label, so
    /// `api.salla.dev` reads as "salla".
    ///
    /// A pure function of the host — no listing context, no collision pass — so
    /// the same request always produces the same label everywhere it is shown.
    static func derivedLabel(forHost host: String) -> String {
        let domain = registrableDomain(forHost: host)
        let labels = domain.components(separatedBy: ".")
        guard labels.count >= 2 else { return domain }

        // An IP literal is its own name.
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return domain }

        if labels.count >= 3 {
            let lastTwo = labels[(labels.count - 2)...].joined(separator: ".")
            if Self.multiPartSuffixes.contains(lastTwo) { return labels[labels.count - 3] }
        }
        return labels[labels.count - 2]
    }

    /// The two-part public suffixes common enough to matter. Not the full Public
    /// Suffix List — this only has to make a derived *display name* read well,
    /// and a miss degrades to a slightly odd label, never to a wrong match.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "sch.uk",
        "com.sa", "net.sa", "org.sa", "gov.sa", "edu.sa", "med.sa", "sch.sa",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp", "lg.jp",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "co.in", "net.in", "org.in", "gov.in", "ac.in", "edu.in",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.mx", "com.ar", "com.co", "com.pe", "com.ve", "com.ec", "com.uy",
        "com.bo", "com.py", "com.do", "com.gt", "com.sv", "com.hn", "com.ni",
        "com.pa", "com.cr", "com.pr",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "com.eg", "net.eg", "org.eg", "gov.eg", "edu.eg",
        "com.ng", "com.gh", "com.ke", "co.ke", "co.tz", "co.ug",
        "com.pk", "com.bd", "com.np", "com.lk",
        "com.my", "com.sg", "com.ph", "com.vn", "co.th", "in.th", "co.id",
        "com.hk", "com.tw", "com.mo", "co.kr", "or.kr", "ne.kr", "go.kr",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.il", "org.il", "net.il", "gov.il", "ac.il",
        "com.ua", "com.ru", "com.pl", "com.ro", "com.gr", "com.cy",
        "com.kw", "com.qa", "com.bh", "com.om", "com.jo", "com.lb",
        "com.ae", "net.ae", "org.ae", "gov.ae", "ac.ae",
        "com.iq", "com.ye", "com.sy", "com.ly", "com.tn", "com.dz", "co.ma",
    ]

    // MARK: - Cache

    private struct CacheEntry {
        let tag: NetworkTag?
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static var cacheGeneration: UInt64 = .max
    private static var compiledKeywords: [CompiledKeyword]?
    private static let cacheCeiling = 5000

    /// Drops everything resolved so far. Called when the tag table changes.
    static func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        regexCache.removeAll(keepingCapacity: false)
        compiledKeywords = nil
        cacheGeneration = SwiftyDebug.tagGeneration
        lock.unlock()
    }
}
