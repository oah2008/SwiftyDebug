//
//  RequestMetadataStore.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Remembers every request header and query parameter the app has ever sent —
/// name **and** last-seen value — indexed by normalized endpoint, by host, and
/// globally.
///
/// This is deliberately independent of `NetworkRequestStore`: clearing the
/// captured request list must **not** erase this, so the intercept editor can
/// still offer (and pre-populate) real headers/params afterwards. Persisted to
/// disk so it also survives app restarts. (See INTERCEPT-UX.)
final class RequestMetadataStore {

    static let shared = RequestMetadataStore()

    /// One remembered key/value pair.
    struct Entry: Equatable {
        let name: String       // canonical casing as first seen
        var value: String      // most recent non-empty value seen
    }

    private let lock = NSLock()

    /// lowercased-name -> Entry, per bucket.
    private var globalHeaders: [String: Entry] = [:]
    private var globalParams: [String: Entry] = [:]
    /// host (lowercased) -> lowercased-name -> Entry
    private var headersByHost: [String: [String: Entry]] = [:]
    private var paramsByHost: [String: [String: Entry]] = [:]
    /// normalized endpoint path -> lowercased-name -> Entry
    private var headersByEndpoint: [String: [String: Entry]] = [:]
    private var paramsByEndpoint: [String: [String: Entry]] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Recording (called once per captured request)

    func record(_ model: NetworkTransaction) {
        guard SwiftyDebugRuntime.isActive else { return }
        guard let url = model.url as URL? else { return }

        let host = (url.host ?? "").lowercased()
        let endpoint = EndpointNormalizer.normalize(url.path)

        // Headers
        var headerPairs: [(String, String)] = []
        if let dict = model.requestHeaderFields as? [String: Any] {
            for (k, v) in dict { headerPairs.append((k, "\(v)")) }
        }
        // Query params
        var paramPairs: [(String, String)] = []
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items { paramPairs.append((item.name, item.value ?? "")) }
        }

        guard !headerPairs.isEmpty || !paramPairs.isEmpty else { return }

        lock.lock()
        for (k, v) in headerPairs {
            merge(&globalHeaders, k, v)
            if !host.isEmpty { merge(&headersByHost[host, default: [:]], k, v) }
            if !endpoint.isEmpty { merge(&headersByEndpoint[endpoint, default: [:]], k, v) }
        }
        for (k, v) in paramPairs {
            merge(&globalParams, k, v)
            if !host.isEmpty { merge(&paramsByHost[host, default: [:]], k, v) }
            if !endpoint.isEmpty { merge(&paramsByEndpoint[endpoint, default: [:]], k, v) }
        }
        lock.unlock()
        scheduleSave()
    }

    /// Keeps first-seen canonical casing, updates to the most recent non-empty value.
    private func merge(_ bucket: inout [String: Entry], _ name: String, _ value: String) {
        let key = name.lowercased()
        if var existing = bucket[key] {
            if !value.isEmpty { existing.value = value; bucket[key] = existing }
        } else {
            bucket[key] = Entry(name: name, value: value)
        }
    }

    // MARK: - Lookup

    /// Headers to offer for a rule scope. Ordering: most specific bucket first,
    /// then broader ones, de-duplicated by lowercased name.
    ///
    /// - `.exact` / `.normalized` → that endpoint's headers, then the host's, then global
    /// - `.host` → the selected hosts' headers, then global
    /// - `.global` → everything ever seen
    func headers(forMode mode: EndpointMatchMode, endpoint: String?, hosts: [String]) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var buckets: [[String: Entry]] = []

        switch mode {
        case .exact, .normalized:
            if let endpoint, let b = headersByEndpoint[EndpointNormalizer.normalize(endpoint)] { buckets.append(b) }
            for h in hosts { if let b = headersByHost[h.lowercased()] { buckets.append(b) } }
            buckets.append(globalHeaders)
        case .host:
            for h in hosts {
                let key = hostKey(from: h)
                if let b = headersByHost[key] { buckets.append(b) }
            }
            buckets.append(globalHeaders)
        case .global:
            buckets.append(globalHeaders)
        }
        return flatten(buckets)
    }

    /// Query params to offer for a rule scope (same precedence as `headers`).
    func params(forMode mode: EndpointMatchMode, endpoint: String?, hosts: [String]) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var buckets: [[String: Entry]] = []

        switch mode {
        case .exact, .normalized:
            if let endpoint, let b = paramsByEndpoint[EndpointNormalizer.normalize(endpoint)] { buckets.append(b) }
            for h in hosts { if let b = paramsByHost[h.lowercased()] { buckets.append(b) } }
            buckets.append(globalParams)
        case .host:
            for h in hosts {
                let key = hostKey(from: h)
                if let b = paramsByHost[key] { buckets.append(b) }
            }
            buckets.append(globalParams)
        case .global:
            buckets.append(globalParams)
        }
        return flatten(buckets)
    }

    /// A host rule pattern may be "api.example.com" or "api.example.com/v1" —
    /// the metadata buckets are keyed by bare host.
    private func hostKey(from pattern: String) -> String {
        var s = pattern.lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s.components(separatedBy: "/").first ?? s
    }

    private func flatten(_ buckets: [[String: Entry]]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for bucket in buckets {
            for key in bucket.keys.sorted() {
                guard let e = bucket[key], seen.insert(key).inserted else { continue }
                out.append(e)
            }
        }
        return out
    }

    /// All header names ever seen (for plain autocomplete).
    func allHeaderNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return globalHeaders.values.map { $0.name }
    }

    /// Most recent value seen for a header, anywhere.
    func lastValue(forHeader name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = globalHeaders[name.lowercased()]?.value
        return (v?.isEmpty == false) ? v : nil
    }

    /// Most recent value seen for a query param, anywhere.
    func lastValue(forParam name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = globalParams[name.lowercased()]?.value
        return (v?.isEmpty == false) ? v : nil
    }

    /// All values ever seen for a header name (most useful first).
    func values(forHeader name: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let key = name.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        func add(_ bucket: [String: Entry]) {
            if let v = bucket[key]?.value, !v.isEmpty, seen.insert(v).inserted { out.append(v) }
        }
        add(globalHeaders)
        for b in headersByEndpoint.values { add(b) }
        for b in headersByHost.values { add(b) }
        return out
    }

    /// All values ever seen for a param name.
    func values(forParam name: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let key = name.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        func add(_ bucket: [String: Entry]) {
            if let v = bucket[key]?.value, !v.isEmpty, seen.insert(v).inserted { out.append(v) }
        }
        add(globalParams)
        for b in paramsByEndpoint.values { add(b) }
        for b in paramsByHost.values { add(b) }
        return out
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SwiftyDebug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("RequestMetadata.json")
    }

    private var saveScheduled = false
    private let saveLock = NSLock()

    private func scheduleSave() {
        saveLock.lock()
        if saveScheduled { saveLock.unlock(); return }
        saveScheduled = true
        saveLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.saveLock.lock(); self.saveScheduled = false; self.saveLock.unlock()
            self.saveToDisk()
        }
    }

    private func encode(_ bucket: [String: Entry]) -> [String: [String]] {
        bucket.mapValues { [$0.name, $0.value] }
    }
    private func decode(_ raw: [String: [String]]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for (k, arr) in raw where arr.count == 2 {
            out[k] = Entry(name: arr[0], value: arr[1])
        }
        return out
    }

    private func saveToDisk() {
        lock.lock()
        let payload: [String: Any] = [
            "globalHeaders": encode(globalHeaders),
            "globalParams": encode(globalParams),
            "headersByHost": headersByHost.mapValues { encode($0) },
            "paramsByHost": paramsByHost.mapValues { encode($0) },
            "headersByEndpoint": headersByEndpoint.mapValues { encode($0) },
            "paramsByEndpoint": paramsByEndpoint.mapValues { encode($0) },
        ]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        func bucket(_ key: String) -> [String: Entry] {
            guard let raw = root[key] as? [String: [String]] else { return [:] }
            return decode(raw)
        }
        func nested(_ key: String) -> [String: [String: Entry]] {
            guard let raw = root[key] as? [String: [String: [String]]] else { return [:] }
            return raw.mapValues { decode($0) }
        }
        globalHeaders = bucket("globalHeaders")
        globalParams = bucket("globalParams")
        headersByHost = nested("headersByHost")
        paramsByHost = nested("paramsByHost")
        headersByEndpoint = nested("headersByEndpoint")
        paramsByEndpoint = nested("paramsByEndpoint")
    }
}
