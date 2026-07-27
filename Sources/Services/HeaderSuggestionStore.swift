//
//  HeaderSuggestionStore.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Accumulates header names (and their most-recent example values) seen across
/// all captured requests, plus a seed list of well-known HTTP headers, so the
/// intercept-rule editor can offer autocomplete suggestions.
///
/// Persisted to disk so **clearing captured requests does not erase the
/// suggestions** (a requirement of INTERCEPT-UX). Header names are stored
/// case-insensitively but preserve the first-seen canonical casing.
final class HeaderSuggestionStore {

    static let shared = HeaderSuggestionStore()

    private let lock = NSLock()
    /// lowercased name → (canonicalName, lastValue)
    private var headers: [String: (name: String, value: String)] = [:]

    private init() {
        seedWellKnown()
        loadFromDisk()
    }

    // MARK: - Recording

    /// Records header names/values from a captured request's header dictionary.
    /// Cheap; safe to call at capture time.
    func record(headers dict: NSDictionary?) {
        guard SwiftyDebugRuntime.isActive else { return }
        guard let dict = dict as? [String: Any], !dict.isEmpty else { return }
        lock.lock()
        var changed = false
        for (key, value) in dict {
            let lower = key.lowercased()
            let strValue = "\(value)"
            if headers[lower]?.value != strValue || headers[lower] == nil {
                headers[lower] = (name: key, value: strValue)
                changed = true
            }
        }
        lock.unlock()
        if changed { scheduleSave() }
    }

    // MARK: - Suggestions

    /// Returns canonical header names whose lowercase form contains the query,
    /// excluding the given (lowercased) keys already present. Prefix matches rank
    /// first. Capped for UI.
    func suggestions(matching query: String, excluding present: Set<String>, limit: Int = 12) -> [String] {
        lock.lock()
        let all = headers
        lock.unlock()

        let q = query.lowercased()
        var prefix: [String] = []
        var contains: [String] = []
        for (lower, entry) in all {
            if present.contains(lower) { continue }
            if q.isEmpty {
                contains.append(entry.name)
            } else if lower.hasPrefix(q) {
                prefix.append(entry.name)
            } else if lower.contains(q) {
                contains.append(entry.name)
            }
        }
        prefix.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        contains.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Array((prefix + contains).prefix(limit))
    }

    /// The most-recent example value seen for a header name (for prefilling).
    func lastValue(forHeader name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return headers[name.lowercased()]?.value
    }

    // MARK: - Seed

    private func seedWellKnown() {
        for name in HTTPHeaderCatalog.allHeaderNames {
            headers[name.lowercased()] = (name: name, value: "")
        }
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SwiftyDebug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("HeaderSuggestions.json")
    }

    private var saveScheduled = false
    private let saveLock = NSLock()
    private func scheduleSave() {
        saveLock.lock()
        if saveScheduled { saveLock.unlock(); return }
        saveScheduled = true
        saveLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.saveLock.lock()
            self.saveScheduled = false
            self.saveLock.unlock()
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        lock.lock()
        let snapshot = headers.mapValues { ["name": $0.name, "value": $0.value] }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
            return
        }
        lock.lock()
        for (lower, entry) in dict {
            if let name = entry["name"] {
                headers[lower] = (name: name, value: entry["value"] ?? "")
            }
        }
        lock.unlock()
    }
}
