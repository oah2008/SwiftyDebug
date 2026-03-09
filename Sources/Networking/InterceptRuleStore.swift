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
class InterceptRuleStore {

    static let shared = InterceptRuleStore()

    /// In-memory cache keyed by normalizedEndpoint. Each endpoint maps to an ordered array of rules.
    private var rules: [String: [InterceptRule]] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Lookup

    /// Returns all rules for the given endpoint, sorted by `order` ascending.
    func rules(for normalizedEndpoint: String) -> [InterceptRule] {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return (rules[normalizedEndpoint] ?? []).sorted { $0.order < $1.order }
    }

    /// Returns `true` if at least one rule exists for the endpoint.
    func hasRule(for normalizedEndpoint: String) -> Bool {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return !(rules[normalizedEndpoint] ?? []).isEmpty
    }

    /// Merges all enabled rules for the endpoint into a single composite rule.
    /// Called from `CustomHTTPProtocol.startLoading()` on every request.
    /// Returns `nil` if no enabled rules exist.
    func resolvedRule(for normalizedEndpoint: String) -> InterceptRule? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let list = rules[normalizedEndpoint] else { return nil }
        let enabled = list.filter { $0.isEnabled }.sorted { $0.order < $1.order }
        guard !enabled.isEmpty else { return nil }

        var composite = InterceptRule(normalizedEndpoint: normalizedEndpoint)

        for rule in enabled {
            if rule.isBlocked {
                composite.isBlocked = true
            }
            // Later overrides win for the same key
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

        var list = rules[rule.normalizedEndpoint] ?? []
        if let idx = list.firstIndex(where: { $0.id == rule.id }) {
            list[idx] = rule
        } else {
            var newRule = rule
            newRule.order = list.count
            list.append(newRule)
        }
        rules[rule.normalizedEndpoint] = list
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
                // Re-index order
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

    /// Removes all rules for the given endpoint.
    func remove(normalizedEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules.removeValue(forKey: normalizedEndpoint)
        saveToDisk()
    }

    /// Reorders rules for an endpoint by the given ordered list of rule IDs.
    func reorder(ids: [String], for normalizedEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard var list = rules[normalizedEndpoint] else { return }
        var reordered: [InterceptRule] = []
        for (i, id) in ids.enumerated() {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                var rule = list[idx]
                rule.order = i
                reordered.append(rule)
            }
        }
        // Append any rules not in the id list (shouldn't happen, but safe)
        for rule in list where !ids.contains(rule.id) {
            var r = rule
            r.order = reordered.count
            reordered.append(r)
        }
        rules[normalizedEndpoint] = reordered
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
        // Group by endpoint
        for rule in loaded {
            var list = rules[rule.normalizedEndpoint] ?? []
            list.append(rule)
            rules[rule.normalizedEndpoint] = list
        }
        // Sort each list by order, then createdAt as tiebreaker
        for (endpoint, list) in rules {
            rules[endpoint] = list.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt < $1.createdAt
            }
        }
    }
}
