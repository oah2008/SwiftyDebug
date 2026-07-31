//
//  HeaderSuggestionStore.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Accumulates the header **names** seen across all captured requests, plus a
/// seed list of well-known HTTP headers, so the intercept-rule and replay
/// editors can offer autocomplete suggestions.
///
/// Persisted to disk so **clearing captured requests does not erase the
/// suggestions** (a requirement of INTERCEPT-UX). Header names are stored
/// case-insensitively but preserve the first-seen canonical casing.
///
/// ## What is NOT kept, anywhere
///
/// This store used to keep the most-recent **value** of every header it saw —
/// in memory *and* verbatim in a JSON file in Caches, uncapped, for the life of
/// the install. `Authorization: Bearer …` and `Cookie: …` included. This SDK is
/// embedded in other people's apps and is not `#if DEBUG`-gated, so a host app
/// that forgets to guard `SwiftyDebug.enable()` shipped a live credential dump
/// to every user's device.
///
/// Nothing consumed those values — the only reader, `lastValue(forHeader:)`,
/// was called from nowhere — so they are gone entirely rather than merely
/// redacted at rest: `record(headers:)` never looks at a value, and there is no
/// API on this type that can return one. Header VALUE suggestions come from
/// `RequestMetadataStore` / `HTTPHeaderCatalog`, which redact credentials before
/// writing.
///
/// A file left behind by an older build still holds those secrets, so
/// `loadFromDisk()` detects the old format, keeps only the names, and rewrites
/// the file immediately — an existing install is cleaned up on first launch
/// rather than left leaking.
///
/// Everything learned is bounded (see `Limits`) and `clear()` throws it away,
/// disk included. Reachable from App ▸ Actions ▸ "Clear Remembered Headers".
final class HeaderSuggestionStore {

    static let shared = HeaderSuggestionStore()

    /// Hard ceilings. Nothing here expires on its own and the file lives in
    /// Caches across launches, so every dimension it can grow along is capped.
    enum Limits {
        /// Distinct names learned from traffic, on top of the built-in catalog.
        static let maxLearnedNames = 400
        /// Longest name remembered. A header name is a token; anything longer is
        /// junk that would only ever bloat the file.
        static let maxNameLength = 128
    }

    /// Marks the value-free file format. A file without it is the old
    /// name+value format and must be rewritten on sight.
    static let formatVersion = 2

    private let lock = NSLock()

    /// lowercased name → canonical casing, from the built-in catalog. Never
    /// persisted (the catalog ships in the binary) and never cleared.
    private var seeded: [String: String] = [:]
    /// lowercased name → canonical casing, learned from captured traffic. This
    /// is the only part that is written to disk and the only part `clear()`
    /// removes.
    private var learned: [String: String] = [:]

    private init() {
        seedWellKnown()
        loadFromDisk()
    }

    // MARK: - Recording

    /// Records header **names** from a captured request's header dictionary.
    /// Values are never read. Cheap; safe to call at capture time.
    ///
    /// NO-OP ON PURPOSE for a new name once `Limits.maxLearnedNames` is reached:
    /// refusing an unseen name keeps everything already learned intact, which is
    /// the better trade for a suggestion list.
    func record(headers dict: NSDictionary?) {
        guard SwiftyDebugRuntime.isActive else { return }
        guard let dict = dict as? [String: Any], !dict.isEmpty else { return }
        lock.lock()
        var changed = false
        for key in dict.keys {
            if Self.insert(name: key, into: &learned, alreadyKnown: seeded) { changed = true }
        }
        lock.unlock()
        if changed { scheduleSave() }
    }

    /// The name-only merge, with no instance state — `static` so the cap and the
    /// casing rule can be tested without a singleton or a Caches directory.
    /// - Returns: true when a NEW name was inserted.
    @discardableResult
    static func insert(name: String,
                       into bucket: inout [String: String],
                       alreadyKnown: [String: String] = [:]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Limits.maxNameLength else { return false }
        let lower = trimmed.lowercased()
        guard alreadyKnown[lower] == nil, bucket[lower] == nil else { return false }
        guard bucket.count < Limits.maxLearnedNames else { return false }
        bucket[lower] = trimmed
        return true
    }

    // MARK: - Suggestions

    /// Returns canonical header names whose lowercase form contains the query,
    /// excluding the given (lowercased) keys already present. Prefix matches rank
    /// first. Capped for UI.
    func suggestions(matching query: String, excluding present: Set<String>, limit: Int = 12) -> [String] {
        lock.lock()
        var all = seeded
        for (lower, name) in learned where all[lower] == nil { all[lower] = name }
        lock.unlock()

        let q = query.lowercased()
        var prefix: [String] = []
        var contains: [String] = []
        for (lower, name) in all {
            if present.contains(lower) { continue }
            if q.isEmpty {
                contains.append(name)
            } else if lower.hasPrefix(q) {
                prefix.append(name)
            } else if lower.contains(q) {
                contains.append(name)
            }
        }
        prefix.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        contains.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Array((prefix + contains).prefix(limit))
    }

    /// Header names learned from this app's own traffic, for display. The
    /// built-in catalog is not counted: it is not "remembered", it ships in the
    /// binary and `clear()` does not touch it.
    var rememberedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return learned.count
    }

    // MARK: - Clearing

    /// Forgets every learned name and deletes the file.
    ///
    /// The store had no reset path at all: it survived Clear, survived
    /// `fullStop()`, and outlived the requests it was learned from — while the
    /// button that promised to wipe it only ever cleared `RequestMetadataStore`.
    /// The built-in catalog is deliberately kept, so autocomplete still works
    /// afterwards.
    func clear() {
        lock.lock()
        learned.removeAll()
        lock.unlock()
        // A save may already be queued; with nothing learned it deletes the file
        // too, so there is nothing to cancel.
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Seed

    private func seedWellKnown() {
        for name in HTTPHeaderCatalog.allHeaderNames {
            seeded[name.lowercased()] = name
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

    /// Exactly what goes on disk: names, a format marker, and nothing else.
    /// The single choke point for "what ends up at rest", so a value can never
    /// be reintroduced by accident somewhere else.
    static func encodePayload(names: [String]) -> [String: Any] {
        ["version": formatVersion, "names": names.sorted()]
    }

    /// Reads either format back.
    ///
    /// The v1 format was `{lowercasedName: {"name": …, "value": …}}` and the
    /// value was a live credential often enough to matter. Only names survive
    /// this function; `holdsLegacyValues` tells the caller the file on disk is
    /// still leaking and has to be rewritten now.
    static func decodePayload(_ root: Any?) -> (names: [String], holdsLegacyValues: Bool) {
        // v2: names only.
        if let dict = root as? [String: Any], let raw = dict["names"] as? [String] {
            return (raw, false)
        }
        // v1: lowercased key → ["name": …, "value": …]. Anything with a
        // non-empty value is a secret sitting in Caches right now.
        if let dict = root as? [String: [String: String]] {
            var names: [String] = []
            var leaking = false
            for (_, entry) in dict {
                if let name = entry["name"], !name.isEmpty { names.append(name) }
                if let value = entry["value"], !value.isEmpty { leaking = true }
            }
            // A v1 file with no values left is still the wrong shape; rewriting
            // it is how it stops being read by this branch forever.
            return (names, leaking || !names.isEmpty)
        }
        return ([], false)
    }

    private func saveToDisk() {
        lock.lock()
        let names = Array(learned.values)
        lock.unlock()
        guard !names.isEmpty else {
            // Nothing learned: leave no file at all rather than an empty one, so
            // `clear()` followed by a queued save cannot resurrect the file.
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: Self.encodePayload(names: names)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) else { return }

        let decoded = Self.decodePayload(root)
        lock.lock()
        for name in decoded.names {
            Self.insert(name: name, into: &learned, alreadyKnown: seeded)
        }
        lock.unlock()

        // A file written by a build that predates this still holds live bearer
        // tokens and cookies. Rewrite it NOW — names only — rather than waiting
        // for the next captured request to happen to trigger a save. Off the
        // caller's thread (this runs from `init`, which can be reached from a
        // capture callback), but not on the 2-second debounce: the point is that
        // the secrets stop existing.
        guard decoded.holdsLegacyValues else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveToDisk()
        }
    }
}
