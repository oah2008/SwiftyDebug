//
//  InterceptRuleStore.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

/// Thread-safe singleton that stores interception rules in memory and persists them to disk.
/// Supports multiple rules per endpoint — rules are applied in `order` ascending,
/// with later rules overriding earlier ones for the same keys.
///
/// Rules are keyed by `matchEndpoint`. At lookup time the exact path, normalized path,
/// and request host are all checked so that all three match modes can coexist.
class InterceptRuleStore {

    static let shared = InterceptRuleStore()

    /// In-memory cache keyed by `matchEndpoint`. Each key maps to an ordered array of rules.
    private var rules: [String: [InterceptRule]] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Lookup

    /// Returns all rules that match the given URL (path-based + host-based).
    func matchingRules(forURL url: URL) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let path = url.path
        let normalized = EndpointNormalizer.normalize(path)
        let host = url.host?.lowercased() ?? ""
        var result: [InterceptRule] = []

        // Exact-match rules
        if let list = rules[path] {
            result.append(contentsOf: list.filter { $0.matchMode == .exact })
        }
        // Normalized-match rules
        if let list = rules[normalized] {
            result.append(contentsOf: list.filter { $0.matchMode == .normalized })
        }
        // Host-match rules — scan all host-keyed entries
        if !host.isEmpty {
            for (key, list) in rules where key.hasPrefix("host:") {
                for rule in list where rule.matchMode == .host {
                    if rule.matchHosts.contains(host) {
                        result.append(rule)
                    }
                }
            }
        }

        return result.sorted { $0.order < $1.order }
    }

    /// Convenience: match by path only (no host matching).
    func matchingRules(forPath path: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let normalized = EndpointNormalizer.normalize(path)
        var result: [InterceptRule] = []

        if let list = rules[path] {
            result.append(contentsOf: list.filter { $0.matchMode == .exact })
        }
        if let list = rules[normalized] {
            result.append(contentsOf: list.filter { $0.matchMode == .normalized })
        }

        return result.sorted { $0.order < $1.order }
    }

    /// Returns all rules for a specific matchEndpoint key, sorted by order.
    func rules(for matchEndpoint: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return (rules[matchEndpoint] ?? []).sorted { $0.order < $1.order }
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

        var composite = InterceptRule(matchEndpoint: url.path)

        for rule in enabled {
            if rule.isBlocked {
                composite.isBlocked = true
            }
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

        // An override wins over a removal for the same key
        let overriddenHeaderKeys = Set(composite.headerOverrides.map { $0.key.lowercased() })
        composite.removedHeaderKeys.subtract(overriddenHeaderKeys)

        let overriddenParamKeys = Set(composite.queryParamOverrides.map { $0.key })
        composite.removedQueryParamKeys.subtract(overriddenParamKeys)

        return composite
    }

    /// Returns all host-based rules that match a given host.
    func hostRules(forHost host: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let h = host.lowercased()
        var result: [InterceptRule] = []
        for (key, list) in rules where key.hasPrefix("host:") {
            for rule in list where rule.matchMode == .host && rule.matchHosts.contains(h) {
                result.append(rule)
            }
        }
        return result.sorted { $0.order < $1.order }
    }

    // MARK: - Mutation

    /// Adds a new rule or updates an existing one (matched by `id`).
    func addOrUpdate(_ rule: InterceptRule) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        var list = rules[rule.matchEndpoint] ?? []
        if let idx = list.firstIndex(where: { $0.id == rule.id }) {
            list[idx] = rule
        } else {
            var newRule = rule
            newRule.order = list.count
            list.append(newRule)
        }
        rules[rule.matchEndpoint] = list
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

        for (endpoint, var list) in rules {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: idx)
                for i in 0..<list.count { list[i].order = i }
                if list.isEmpty {
                    rules.removeValue(forKey: endpoint)
                } else {
                    rules[endpoint] = list
                }
                saveToDisk()
                return
            }
        }
    }

    /// Removes all rules for the given matchEndpoint key.
    func remove(matchEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules.removeValue(forKey: matchEndpoint)
        saveToDisk()
    }

    /// Reorders rules for a matchEndpoint by the given ordered list of rule IDs.
    func reorder(ids: [String], for matchEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let list = rules[matchEndpoint] else { return }
        var reordered: [InterceptRule] = []
        for (i, id) in ids.enumerated() {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                var rule = list[idx]
                rule.order = i
                reordered.append(rule)
            }
        }
        for rule in list where !ids.contains(rule.id) {
            var r = rule
            r.order = reordered.count
            reordered.append(r)
        }
        rules[matchEndpoint] = reordered
        saveToDisk()
    }

    func removeAll() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules.removeAll()
        saveToDisk()
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
        do {
            let allRules = rules.values.flatMap { $0 }
            let data = try JSONEncoder().encode(allRules)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silent failure — debug tool, not critical path
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([InterceptRule].self, from: data) else {
            return
        }
        for rule in loaded {
            var list = rules[rule.matchEndpoint] ?? []
            list.append(rule)
            rules[rule.matchEndpoint] = list
        }
        for (endpoint, list) in rules {
            rules[endpoint] = list.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt < $1.createdAt
            }
        }
    }
}
