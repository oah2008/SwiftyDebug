//
//  InterceptRuleStore.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

/// Thread-safe singleton that stores interception rules in memory and persists them to disk.
/// Lookup is O(1) by normalized endpoint path.
class InterceptRuleStore {

    static let shared = InterceptRuleStore()

    /// In-memory cache keyed by normalizedEndpoint for O(1) lookup.
    private var rules: [String: InterceptRule] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Fast O(1) lookup — called from CustomHTTPProtocol.startLoading() on every request.
    func rule(for normalizedEndpoint: String) -> InterceptRule? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return rules[normalizedEndpoint]
    }

    func hasRule(for normalizedEndpoint: String) -> Bool {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return rules[normalizedEndpoint] != nil
    }

    func addOrUpdate(_ rule: InterceptRule) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules[rule.normalizedEndpoint] = rule
        saveToDisk()
    }

    func remove(normalizedEndpoint: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        rules.removeValue(forKey: normalizedEndpoint)
        saveToDisk()
    }

    func remove(id: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if let key = rules.first(where: { $0.value.id == id })?.key {
            rules.removeValue(forKey: key)
            saveToDisk()
        }
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
        return Array(rules.values).sorted { $0.createdAt < $1.createdAt }
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
            let data = try JSONEncoder().encode(Array(rules.values))
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
            rules[rule.normalizedEndpoint] = rule
        }
    }
}
