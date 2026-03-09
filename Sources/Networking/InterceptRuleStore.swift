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
/// Rules are keyed by `matchEndpoint`. At lookup time both the exact path and normalized
/// path are checked so that exact-match and normalized-match rules can coexist.
class InterceptRuleStore {

    static let shared = InterceptRuleStore()

    /// In-memory cache keyed by `matchEndpoint`. Each key maps to an ordered array of rules.
    private var rules: [String: [InterceptRule]] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Lookup

    /// Returns all rules that match the given request path (both exact and normalized matches).
    func matchingRules(forPath path: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let normalized = EndpointNormalizer.normalize(path)
        var result: [InterceptRule] = []

        // Exact-match rules stored under the literal path
        if let list = rules[path] {
            result.append(contentsOf: list.filter { $0.matchMode == .exact })
        }
        // Normalized-match rules stored under the normalized path
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

    /// Returns `true` if at least one rule matches the given request path.
    func hasRule(forPath path: String) -> Bool {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let normalized = EndpointNormalizer.normalize(path)

        if let list = rules[path], list.contains(where: { $0.matchMode == .exact }) {
            return true
        }
        if let list = rules[normalized], list.contains(where: { $0.matchMode == .normalized }) {
            return true
        }
        return false
    }

    /// Merges all enabled matching rules for the request path into a single composite rule.
    /// Called from `CustomHTTPProtocol.startLoading()` on every request.
    /// Returns `nil` if no enabled rules match.
    func resolvedRule(forPath path: String) -> InterceptRule? {
        let allMatching = matchingRules(forPath: path)

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let enabled = allMatching.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return nil }

        var composite = InterceptRule(matchEndpoint: path)

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
