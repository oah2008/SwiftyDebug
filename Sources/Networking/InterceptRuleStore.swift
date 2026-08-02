//
//  InterceptRuleStore.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

extension Notification.Name {
    static let interceptRulesDidChange = Notification.Name("com.swiftydebug.interceptRulesDidChange")
}

/// Thread-safe singleton that stores interception rules in memory and persists them to disk.
/// Supports multiple rules per endpoint — rules are applied in `order` ascending,
/// with later rules overriding earlier ones for the same keys.
///
/// Rules are bucketed by `InterceptRule.storageKey`, which folds in the match
/// **mode** and (for endpoint rules) the **host pin** as well as the endpoint
/// itself. Lookup builds the same keys from the incoming URL, so a handful of
/// dictionary probes answers every request — no scan over all rules except for
/// `.host` rules, which are prefix patterns and cannot be hashed.
///
/// That key is derived, never persisted: `rules.json` is a flat array of rules,
/// so the bucketing is pure in-memory state and this scheme needed no on-disk
/// migration. What DOES get repaired on load is a rule whose fields disagree
/// with its own mode — see `InterceptRule.canonicalized()`.
class InterceptRuleStore {

    static let shared = InterceptRuleStore()

    /// In-memory cache keyed by `InterceptRule.storageKey`.
    /// Each key maps to an array of rules ordered by `order`.
    private var rules: [String: [InterceptRule]] = [:]

    /// Every host an endpoint rule is currently pinned to.
    ///
    /// Derived from `rules` and rebuilt on every mutation. Exists only so
    /// `matchingRules(forPath:)` — which is handed a path with no host attached —
    /// can still find host-pinned rules without walking every bucket. Typically
    /// zero or one entry.
    private var pinnedEndpointHosts: Set<String> = []

    /// What went wrong the last time `rules.json` was read, if anything.
    ///
    /// Losing rules silently is the worst outcome here — they are invisible
    /// state that changes how the host app's network behaves — so a lossy load
    /// is recorded, the original bytes are copied aside, and the UI says so.
    struct LoadIssue: Equatable {
        /// Rules that decoded and are now live.
        let recovered: Int
        /// Rules that were present but unreadable and had to be skipped.
        /// Zero when the file could not be parsed as a list at all.
        let skipped: Int
        /// True when the file itself was not decodable as a rule list.
        let fileUnreadable: Bool
        /// Where the untouched original bytes were copied, if the copy worked.
        let backupURL: URL?
    }

    private var loadIssue: LoadIssue?

    /// Set only when the file on disk existed, was non-empty and yielded ZERO
    /// rules. While it is set, an EMPTY rule set is never written back — see
    /// `saveToDisk()`.
    private var refusesEmptyOverwrite = false

    private init() {
        loadFromDisk()
    }

    /// Returns the last load problem **once**, then forgets it, so the UI
    /// reports it a single time per launch instead of on every appearance.
    /// Returns nil — a no-op for the caller — when the load was clean.
    func takeLoadIssue() -> LoadIssue? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        let issue = loadIssue
        loadIssue = nil
        return issue
    }

    // MARK: - Lookup

    /// Returns all rules that match the given URL (path-based + host-based + global).
    ///
    /// Runs on **every request**, so it stays a fixed number of dictionary probes
    /// (global + four endpoint keys) plus a walk of the `.host` buckets, which
    /// are prefix patterns and genuinely cannot be hashed.
    /// The one ordering used everywhere rules are compared.
    ///
    /// It must be a TOTAL order. `order` alone is not: two rules created in
    /// different buckets both start at 0, so a request matched by both resolved
    /// in whatever sequence the `rules` dictionary happened to enumerate — which
    /// changes between app launches. The header that reached the wire was
    /// therefore random per launch, and so were the RULE #n labels in the list.
    /// `createdAt` breaks nearly every tie; `id` makes it total.
    static func precedes(_ lhs: InterceptRule, _ rhs: InterceptRule) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    func matchingRules(forURL url: URL) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let path = url.path
        let normalized = EndpointNormalizer.normalize(path)
        let host = InterceptRule.canonicalHost(url.host ?? "")
        var result: [InterceptRule] = []

        // Global rules — match every request
        if let list = rules["global"] {
            result.append(contentsOf: list.filter { $0.matchMode == .global })
        }

        // Endpoint rules. Two probes per mode: the any-host rules (everything
        // written before host pinning existed) and, when the URL has a host, the
        // rules pinned to exactly that host. A rule pinned to a DIFFERENT host
        // hashes to a different key and is never even looked at — which is the
        // whole point: "/cart on a.com" must not fire on b.com.
        for mode in [EndpointMatchMode.exact, .normalized] {
            let endpoint = (mode == .exact) ? path : normalized
            var keys = [InterceptRule.endpointKey(mode: mode, host: "", endpoint: endpoint)]
            if !host.isEmpty {
                keys.append(InterceptRule.endpointKey(mode: mode, host: host, endpoint: endpoint))
            }
            for key in keys {
                guard let list = rules[key] else { continue }
                result.append(contentsOf: list.filter { $0.matchMode == mode })
            }
        }

        // Host-match rules — URL prefix matching against stripped URLs
        for (key, list) in rules where key.hasPrefix("host:") {
            for rule in list where rule.matchMode == .host {
                if rule.matchHosts.contains(where: { Self.urlMatchesPattern(url, pattern: $0) }) {
                    result.append(rule)
                }
            }
        }

        return result.sorted(by: Self.precedes)
    }

    /// Checks if a URL matches a host-rule pattern (stripped URL prefix).
    /// Pattern examples: "api.example.com", "api.example.com/v1"
    /// A pattern "api.example.com/v1" matches "https://api.example.com/v1/users/123" but not "https://api.example.com/v2/users".
    /// A pattern "api.example.com" matches any URL on that host.
    static func urlMatchesPattern(_ url: URL, pattern: String) -> Bool {
        var stripped = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] {
            if stripped.hasPrefix(prefix) {
                stripped = String(stripped.dropFirst(prefix.count))
                break
            }
        }
        // Remove query string and fragment for comparison
        if let qIndex = stripped.firstIndex(of: "?") {
            stripped = String(stripped[..<qIndex])
        }
        if let fIndex = stripped.firstIndex(of: "#") {
            stripped = String(stripped[..<fIndex])
        }
        if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }

        var p = pattern.lowercased()
        if p.hasSuffix("/") { p = String(p.dropLast()) }

        return stripped == p || stripped.hasPrefix(p + "/")
    }

    /// Convenience: match by path only (no host matching).
    ///
    /// The caller has a path and no URL, so a host pin cannot be evaluated.
    /// Host-pinned rules for the same path are returned ANYWAY — deliberately
    /// over-inclusive, because this feeds a rule list and a "this endpoint has
    /// rules" indicator, and hiding a rule the user created is worse than
    /// showing one that would not have fired on this particular host.
    /// `matchingRules(forURL:)` is the authority for what actually fires.
    func matchingRules(forPath path: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let normalized = EndpointNormalizer.normalize(path)
        var result: [InterceptRule] = []

        for mode in [EndpointMatchMode.exact, .normalized] {
            let endpoint = (mode == .exact) ? path : normalized
            var keys = [InterceptRule.endpointKey(mode: mode, host: "", endpoint: endpoint)]
            keys.append(contentsOf: pinnedEndpointHosts.map {
                InterceptRule.endpointKey(mode: mode, host: $0, endpoint: endpoint)
            })
            for key in keys {
                guard let list = rules[key] else { continue }
                result.append(contentsOf: list.filter { $0.matchMode == mode })
            }
        }

        return result.sorted(by: Self.precedes)
    }

    /// Returns every rule whose `matchEndpoint` is this string, sorted by order.
    ///
    /// This is a **semantic** lookup, not a bucket lookup: `matchEndpoint` no
    /// longer identifies a bucket on its own (mode and host pin are part of
    /// `storageKey`), so `/cart` here returns the exact rule, the pattern rule
    /// and every host-pinned variant. Callers that want one of them filter on
    /// `matchMode` / `matchHost` themselves.
    func rules(for matchEndpoint: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return rules.values.flatMap { $0 }
            .filter { $0.matchEndpoint == matchEndpoint }
            .sorted(by: Self.precedes)
    }

    /// Returns every rule filed under one exact `InterceptRule.storageKey`.
    /// The precise counterpart of `rules(for:)` when you have a whole rule in
    /// hand and want its siblings.
    func rules(forStorageKey key: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return (rules[key] ?? []).sorted(by: Self.precedes)
    }

    /// Returns `true` if at least one **enabled** rule matches the given URL.
    func hasRule(forURL url: URL) -> Bool {
        return matchingRules(forURL: url).contains { $0.isEnabled }
    }

    /// Returns `true` if at least one **enabled** rule matches the given path (no host check).
    func hasRule(forPath path: String) -> Bool {
        return matchingRules(forPath: path).contains { $0.isEnabled }
    }

    /// Merges all enabled matching rules for the URL into a single composite rule.
    /// Called from `CustomHTTPProtocol.startLoading()` on every request.
    /// Returns `nil` if no enabled rules match.
    func resolvedRule(forURL url: URL) -> InterceptRule? {
        let allMatching = matchingRules(forURL: url)
        let enabled = allMatching.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return nil }

        // Built with the real scope of the request it was resolved for, so the
        // composite never claims to be an any-host pattern rule it is not.
        var composite = InterceptRule.endpointRule(path: url.path, mode: .exact, host: url.host)
        // Names of the rules that actually contributed. The composite is what
        // `CustomHTTPProtocol` holds while a request is being changed, so when a
        // request comes back mocked/blocked/rewritten this is the only place that
        // can say WHICH rules did it. Dropping it here would be the same mistake
        // `mock` and `breakpointMode` shipped with below.
        composite.name = enabled.map { $0.displayName }.joined(separator: " + ")

        for rule in enabled {
            if rule.isBlocked {
                composite.isBlocked = true
            }
            // Redirect: the last enabled rule (highest order) that defines one wins.
            if rule.redirectMode != .none, !rule.redirectTarget.isEmpty {
                composite.redirectMode = rule.redirectMode
                composite.redirectTarget = rule.redirectTarget
            }
            // Mock: last enabled rule with a mock wins. WITHOUT this the
            // composite kept its default (disabled) mock and mocks never fired.
            if rule.mock.isEnabled {
                composite.mock = rule.mock
            }
            // Breakpoint: last enabled rule that arms one wins. Same bug class —
            // omitting this silently dropped every breakpoint.
            if rule.breakpointMode != .off {
                composite.breakpointMode = rule.breakpointMode
            }
            // Response rewrites: ACCUMULATE, unlike everything above. Two rules
            // that both match (say a global one and an endpoint one) each have
            // something to say about the body, and last-wins would throw one
            // away. `enabled` is already sorted by `order`, so the rewrites come
            // out in rule order and a later one sees what an earlier one wrote.
            //
            // Copying this through is not optional: `mock` and `breakpointMode`
            // above BOTH shipped completely inert because the composite dropped
            // them, and a rewrite dropped here would look exactly the same —
            // armed in the editor, doing nothing on the wire.
            composite.responseRewrites.append(contentsOf: rule.responseRewrites)
            for pair in rule.headerOverrides {
                if let idx = composite.headerOverrides.firstIndex(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                    composite.headerOverrides[idx] = pair
                } else {
                    composite.headerOverrides.append(pair)
                }
            }
            composite.removedHeaderKeys.formUnion(rule.removedHeaderKeys)

            for pair in rule.queryParamOverrides {
                if let idx = composite.queryParamOverrides.firstIndex(where: { $0.key == pair.key }) {
                    composite.queryParamOverrides[idx] = pair
                } else {
                    composite.queryParamOverrides.append(pair)
                }
            }
            composite.removedQueryParamKeys.formUnion(rule.removedQueryParamKeys)
        }

        // An override wins over a removal for the same key.
        //
        // Both sides must be compared case-insensitively. Removal keys arrive
        // verbatim from an imported rules.json, so a teammate's document written
        // with canonical HTTP casing ("Authorization") did not match the
        // lower-cased override set — and the header was stripped from the wire
        // entirely: not the old value, not the new one, with the editor still
        // showing the override armed and checked.
        let overriddenHeaderKeys = Set(composite.headerOverrides.map { $0.key.lowercased() })
        composite.removedHeaderKeys = composite.removedHeaderKeys.filter {
            !overriddenHeaderKeys.contains($0.lowercased())
        }

        let overriddenParamKeys = Set(composite.queryParamOverrides.map { $0.key })
        composite.removedQueryParamKeys.subtract(overriddenParamKeys)

        return composite
    }

    /// Returns all host-based rules that match a given URL (by stripped URL prefix).
    func hostRules(forURL url: URL) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        var result: [InterceptRule] = []
        for (key, list) in rules where key.hasPrefix("host:") {
            for rule in list where rule.matchMode == .host {
                if rule.matchHosts.contains(where: { Self.urlMatchesPattern(url, pattern: $0) }) {
                    result.append(rule)
                }
            }
        }
        return result.sorted(by: Self.precedes)
    }

    // MARK: - Mutation

    /// Adds a new rule or updates an existing one (matched by `id`).
    ///
    /// RE-KEYS. A rule's scope is editable — its path, its mode and its host pin
    /// are all `var` — so the rule handed in may belong in a different bucket
    /// from the copy already stored. Any existing copy is removed from wherever
    /// it is *first*, then the rule is filed under its current
    /// `storageKey`. Without that step, changing a rule's scope left the old copy
    /// behind and the app ran BOTH: the same edit reported twice, and the "exact
    /// rules override each other" the user hit.
    func addOrUpdate(_ rule: InterceptRule) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        // Repair mode/endpoint/host disagreements before deriving the key, so a
        // rule can never be filed somewhere lookup will not probe.
        var incoming = rule.canonicalized()
        let key = incoming.storageKey

        let previousKey = removeLocked(id: incoming.id)

        var list = rules[key] ?? []
        if previousKey == key {
            // Same bucket: keep the caller's `order`, which is what an in-place
            // edit or an explicit reorder relies on.
            list.append(incoming)
            list.sort(by: Self.precedes)
        } else {
            // New bucket (new rule, or a re-keyed one): it goes last, and its old
            // `order` meant a position in a bucket it no longer lives in.
            incoming.order = list.count
            list.append(incoming)
        }
        rules[key] = list
        rebuildIndexes()
        saveToDisk()
    }

    /// Updates a single rule's properties (e.g., toggling `isEnabled`).
    func update(_ rule: InterceptRule) {
        addOrUpdate(rule)
    }

    /// Removes a single rule by its id.
    func remove(id: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard removeLocked(id: id) != nil else { return }
        rebuildIndexes()
        saveToDisk()
    }

    /// Drops every copy of `id` from every bucket, re-packing the `order` of the
    /// rules left behind. Returns the key it was found under, or nil.
    ///
    /// Caller must already hold the lock and is responsible for
    /// `rebuildIndexes()` / `saveToDisk()` — this is the shared half of
    /// `remove(id:)` and the re-key step in `addOrUpdate`.
    @discardableResult
    private func removeLocked(id: String) -> String? {
        var foundKey: String?
        for (key, var list) in rules {
            guard list.contains(where: { $0.id == id }) else { continue }
            foundKey = key
            list.removeAll { $0.id == id }
            for i in list.indices { list[i].order = i }
            if list.isEmpty {
                rules.removeValue(forKey: key)
            } else {
                rules[key] = list
            }
        }
        return foundKey
    }

    /// Removes every rule whose `matchEndpoint` is this string.
    ///
    /// Endpoint-wide, not bucket-wide: `matchEndpoint` no longer identifies a
    /// single bucket, so `/cart` here removes the exact rule, the pattern rule
    /// and every host-pinned variant. Use `remove(id:)` to remove exactly one.
    func remove(matchEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        var removed = false
        for (key, var list) in rules {
            let before = list.count
            list.removeAll { $0.matchEndpoint == matchEndpoint }
            guard list.count != before else { continue }
            removed = true
            for i in list.indices { list[i].order = i }
            if list.isEmpty {
                rules.removeValue(forKey: key)
            } else {
                rules[key] = list
            }
        }
        guard removed else { return }
        rebuildIndexes()
        saveToDisk()
    }

    /// Reorders rules by the given ordered list of rule IDs.
    ///
    /// `matchEndpoint` names the group the UI reordered. It is only a hint: the
    /// ids are authoritative and are re-ordered wherever they live, because one
    /// endpoint's rules can now sit in several buckets (exact vs pattern, one per
    /// host pin) while the list screen still shows them as a single group.
    /// Ids that no longer exist are skipped rather than silently dropping
    /// anything.
    func reorder(ids: [String], for matchEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        var position: [String: Int] = [:]
        for (i, id) in ids.enumerated() { position[id] = i }
        guard !position.isEmpty else { return }

        var changed = false
        for (key, var list) in rules {
            var touched = false
            for i in list.indices {
                guard let p = position[list[i].id] else { continue }
                if list[i].order != p { list[i].order = p; touched = true }
            }
            guard touched else { continue }
            // Rules not named in `ids` keep their relative place after the named
            // ones — same rule the old implementation used.
            list.sort(by: Self.precedes)
            rules[key] = list
            changed = true
        }
        guard changed else { return }
        saveToDisk()
    }

    func removeAll() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules.removeAll()
        pinnedEndpointHosts.removeAll()
        // An explicit wipe is honored even after an unreadable load: the user
        // asked for empty, and the original bytes are already backed up.
        refusesEmptyOverwrite = false
        saveToDisk()
    }

    /// Rebuilds the derived host index. Caller must hold the lock.
    private func rebuildIndexes() {
        var hosts = Set<String>()
        for list in rules.values {
            for rule in list where rule.matchMode == .exact || rule.matchMode == .normalized {
                let pin = InterceptRule.canonicalHost(rule.matchHost)
                if !pin.isEmpty { hosts.insert(pin) }
            }
        }
        pinnedEndpointHosts = hosts
    }

    func allRules() -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return rules.values.flatMap { $0 }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Persistence

    private static let directoryName = "InterceptRules"
    private static let fileName = "rules.json"

    private var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SwiftyDebug/\(Self.directoryName)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.fileName)
    }

    private func saveToDisk() {
        let allRules = rules.values.flatMap { $0 }

        // NO-OP ON PURPOSE. If the file on disk existed but produced no rules at
        // all, we do not know what is in it — only that we could not read it.
        // Writing our empty in-memory state over it is exactly the sequence that
        // destroyed every rule on the device: one unreadable rule -> empty
        // memory -> first `addOrUpdate` overwrites the file. The original bytes
        // are already copied aside by `loadFromDisk()`, and the flag clears the
        // moment there is real content to write (or on an explicit `removeAll`).
        if allRules.isEmpty && refusesEmptyOverwrite {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .interceptRulesDidChange, object: nil)
            }
            return
        }

        do {
            let data = try JSONEncoder().encode(allRules)
            try data.write(to: fileURL, options: .atomic)
            refusesEmptyOverwrite = false
        } catch {
            // Silent failure — debug tool, not critical path
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .interceptRulesDidChange, object: nil)
        }
    }

    /// Serializes all enabled rules to a JSON string consumable by the WKWebView JS interceptor.
    func rulesAsJSONString() -> String {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let enabled = rules.values.flatMap { $0 }.filter { $0.isEnabled }
        var jsRules: [[String: Any]] = []
        for rule in enabled {
            let dict: [String: Any] = [
                "matchEndpoint": rule.matchEndpoint,
                "matchMode": rule.matchMode.rawValue,
                "matchHosts": rule.matchHosts,
                // NOTE FOR THE JS MATCHER: `matchHost` is the host an endpoint
                // rule is pinned to; empty means any host. The injected matcher
                // currently compares `matchEndpoint` to the path alone, so until
                // it also checks this field a host-pinned rule will fire on every
                // host inside a WKWebView. Shipped here first so that check has
                // something to read.
                "matchHost": rule.matchHost,
                "name": rule.displayName,
                "isBlocked": rule.isBlocked,
                "order": rule.order,
                "headerOverrides": rule.headerOverrides.map { ["key": $0.key, "value": $0.value] },
                "queryParamOverrides": rule.queryParamOverrides.map { ["key": $0.key, "value": $0.value] },
                "removedHeaderKeys": Array(rule.removedHeaderKeys),
                "removedQueryParamKeys": Array(rule.removedQueryParamKeys),
                "redirectMode": rule.redirectMode.rawValue,
                "redirectTarget": rule.redirectTarget
            ]
            jsRules.append(dict)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsRules, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    /// Decodes the on-disk rule list, keeping every rule it can.
    ///
    /// Split out and `static` so the recovery behaviour is testable without a
    /// singleton or a Caches directory.
    /// - Returns: the rules that decoded, and how many were present but
    ///   unreadable. `total == nil` means the payload was not a rule list at
    ///   all (not even an array), which is a different failure from "an array
    ///   with a bad element in it".
    static func decodeRules(from data: Data) -> (rules: [InterceptRule], total: Int?) {
        // Per ELEMENT, not per file: one rule this build cannot make sense of —
        // an enum case added by a newer version, a hand-edited export — used to
        // make `try?` swallow the ENTIRE array and hand back nil.
        let decoder = JSONDecoder()
        // Our own file: keep everything readable rather than reporting what is
        // not. (An imported file wants the opposite — see the key's docs.)
        decoder.userInfo[.swiftyDebugLenientRuleDecoding] = true
        guard let wrapped = try? decoder.decode([LenientElement<InterceptRule>].self, from: data) else {
            return ([], nil)
        }
        return (wrapped.compactMap { $0.value }, wrapped.count)
    }

    private static let backupPrefix = "rules-unreadable-"
    /// A file that will not parse tends not to start parsing, so this would
    /// otherwise leave one copy per launch in the user's Caches forever.
    private static let maxBackups = 3

    /// Copies bytes we could not fully read next to the live file, so a lossy
    /// load is recoverable by hand. Returns nil if even the copy failed.
    private func backUpUnreadable(_ data: Data) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(Self.backupPrefix)\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(Self.backupPrefix) }
            .sorted()
        for stale in existing.dropLast(Self.maxBackups) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale))
        }
        return url
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }

        let (loaded, total) = Self.decodeRules(from: data)
        let skipped = (total ?? 0) - loaded.count
        if total == nil || skipped > 0 {
            // Preserve the original before anything can write over it, and
            // remember to tell someone.
            let backup = backUpUnreadable(data)
            loadIssue = LoadIssue(recovered: loaded.count,
                                  skipped: max(skipped, 0),
                                  fileUnreadable: total == nil,
                                  backupURL: backup)
            refusesEmptyOverwrite = loaded.isEmpty
        }

        // MIGRATION. The file is a flat array of rules and always has been, so
        // nothing on disk has to change for the new bucketing — the key is
        // derived here, at load. `canonicalized()` is what actually migrates:
        // it makes each rule's endpoint/hosts/host-pin agree with its own mode,
        // which un-orphans rules an older editor filed under a key that lookup
        // never probed. Rules with no `matchHost` (i.e. every rule already on a
        // device) canonicalize to "any host" and keep matching exactly what they
        // matched before.
        for rule in loaded {
            let canonical = rule.canonicalized()
            rules[canonical.storageKey, default: []].append(canonical)
        }
        for (key, list) in rules {
            rules[key] = list.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt < $1.createdAt
            }
        }
        rebuildIndexes()
    }
}
