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
///
/// ## What is NOT written to disk
///
/// This SDK is embedded in other people's apps and is not `#if DEBUG`-gated, so
/// a host app that forgets to guard `SwiftyDebug.enable()` ships whatever this
/// file contains. It used to contain every `Authorization: Bearer …` and
/// `Cookie` the app had ever sent, verbatim, in Caches, forever. The **name**
/// of a credential header is still remembered (that is what the suggestion
/// list needs); its **value** is kept in memory for the current session only
/// and is written out empty. See `isSensitiveName(_:)`.
///
/// Everything here is also bounded — see `Limits` — and `clear()` throws the
/// whole thing away, disk included.
final class RequestMetadataStore {

    static let shared = RequestMetadataStore()

    /// One remembered key/value pair.
    struct Entry: Equatable {
        let name: String       // canonical casing as first seen
        var value: String      // most recent non-empty value seen
    }

    /// Hard ceilings. Nothing here expires on its own and the file lives in
    /// Caches across launches, so every dimension it can grow along is capped.
    enum Limits {
        /// Longer values are truncated before being remembered.
        static let maxValueLength = 512
        /// Distinct names remembered per bucket.
        static let maxNamesPerBucket = 60
        /// Hosts tracked; least-recently-seen is evicted first.
        static let maxHosts = 40
        /// Normalized endpoints tracked; least-recently-seen is evicted first.
        static let maxEndpoints = 120
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

    /// Least-recently-seen first. Drives eviction of whole host/endpoint buckets.
    private var hostOrder: [String] = []
    private var endpointOrder: [String] = []

    /// Number of remembered names across every bucket. Maintained rather than
    /// counted so the UI can show it from `cellForRowAt` without walking the
    /// whole store.
    private var entryCount = 0

    private init() {
        loadFromDisk()
    }

    /// Total remembered names, for display. O(1).
    var rememberedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entryCount
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
        if !host.isEmpty {
            for dead in Self.evictionsAfterTouching(&hostOrder, host, cap: Limits.maxHosts) {
                drop(&headersByHost, dead)
                drop(&paramsByHost, dead)
            }
        }
        if !endpoint.isEmpty {
            for dead in Self.evictionsAfterTouching(&endpointOrder, endpoint, cap: Limits.maxEndpoints) {
                drop(&headersByEndpoint, dead)
                drop(&paramsByEndpoint, dead)
            }
        }
        for (k, v) in headerPairs {
            let v = Self.bounded(v)
            merge(&globalHeaders, k, v)
            if !host.isEmpty { merge(&headersByHost[host, default: [:]], k, v) }
            if !endpoint.isEmpty { merge(&headersByEndpoint[endpoint, default: [:]], k, v) }
        }
        for (k, v) in paramPairs {
            let v = Self.bounded(v)
            merge(&globalParams, k, v)
            if !host.isEmpty { merge(&paramsByHost[host, default: [:]], k, v) }
            if !endpoint.isEmpty { merge(&paramsByEndpoint[endpoint, default: [:]], k, v) }
        }
        lock.unlock()
        scheduleSave()
    }

    /// Keeps first-seen canonical casing, updates to the most recent non-empty value.
    ///
    /// NO-OP ON PURPOSE when the bucket is full and the name is new: refusing an
    /// unseen name keeps everything already learned intact, which is the better
    /// trade for a suggestion list. Values of names already present keep
    /// updating regardless.
    private func merge(_ bucket: inout [String: Entry], _ name: String, _ value: String) {
        if Self.mergeEntry(into: &bucket, name: name, value: value) { entryCount += 1 }
    }

    /// The bucket merge itself, with no instance state — `static` so the cap and
    /// the casing rule can be tested without a singleton or a Caches directory.
    /// - Returns: true when a NEW name was inserted (the caller's count changes).
    @discardableResult
    static func mergeEntry(into bucket: inout [String: Entry], name: String, value: String) -> Bool {
        let key = name.lowercased()
        if var existing = bucket[key] {
            if !value.isEmpty { existing.value = value; bucket[key] = existing }
            return false
        }
        guard bucket.count < Limits.maxNamesPerBucket else { return false }
        bucket[key] = Entry(name: name, value: value)
        return true
    }

    /// Truncates a value to `Limits.maxValueLength`.
    static func bounded(_ value: String) -> String {
        value.count <= Limits.maxValueLength ? value : String(value.prefix(Limits.maxValueLength))
    }

    /// Moves `key` to the most-recently-seen end of `order` and returns whatever
    /// had to be evicted to stay under `cap`.
    static func evictionsAfterTouching(_ order: inout [String], _ key: String, cap: Int) -> [String] {
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        var evicted: [String] = []
        while order.count > cap { evicted.append(order.removeFirst()) }
        return evicted
    }

    /// Removes a whole host/endpoint bucket, keeping `entryCount` honest.
    private func drop(_ map: inout [String: [String: Entry]], _ key: String) {
        if let removed = map.removeValue(forKey: key) { entryCount -= removed.count }
    }

    // MARK: - Redaction

    /// True when a header or query-parameter NAME identifies a credential, i.e.
    /// something whose value must never be written to disk.
    ///
    /// Deliberately errs toward redacting: a false positive costs one
    /// pre-filled suggestion, a false negative writes a live bearer token into
    /// Caches on a stranger's phone.
    static func isSensitiveName(_ rawName: String) -> Bool {
        let name = rawName.lowercased()
        // Unambiguous wherever they appear inside the name.
        for needle in ["authorization", "authentication", "cookie", "token",
                       "secret", "password", "passwd", "credential", "signature",
                       "apikey", "api-key", "api_key", "session", "bearer"] {
            if name.contains(needle) { return true }
        }
        // Too short or too common to match as substrings — "key" would redact
        // `Keyboard-Locale`, "sig" would redact `X-Design-Id` — so these only
        // count as a whole `-`/`_`/`.`-separated component.
        let sensitiveComponents: Set<String> = [
            "auth", "key", "keys", "sig", "pwd", "pass", "jwt", "otp",
            "csrf", "xsrf", "nonce", "assertion", "code",
        ]
        return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { sensitiveComponents.contains(String($0)) }
    }

    // MARK: - Clearing

    /// Forgets every remembered name and value and deletes the file.
    ///
    /// The store had no reset path at all: it survived Clear, survived
    /// `fullStop()`, and outlived the requests it was learned from. Reachable
    /// from App ▸ Actions ▸ "Clear Remembered Headers".
    func clear() {
        lock.lock()
        globalHeaders.removeAll()
        globalParams.removeAll()
        headersByHost.removeAll()
        paramsByHost.removeAll()
        headersByEndpoint.removeAll()
        paramsByEndpoint.removeAll()
        hostOrder.removeAll()
        endpointOrder.removeAll()
        entryCount = 0
        lock.unlock()
        // A save may already be queued; it would simply write the empty state
        // back out, so there is nothing to cancel.
        try? FileManager.default.removeItem(at: fileURL)
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

    /// Serializes a bucket, **dropping the value of anything credential-shaped**.
    ///
    /// The name still goes out, because that is what the suggestion list is
    /// built from; only the secret itself is withheld. Nothing else in this
    /// class writes to the file, so this is the single choke point for
    /// "what ends up at rest".
    private func encode(_ bucket: [String: Entry]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        out.reserveCapacity(bucket.count)
        for (key, entry) in bucket {
            out[key] = Self.persistedPair(for: entry)
        }
        return out
    }

    /// Exactly what one entry looks like on disk: the name always, the value
    /// only when it is not a credential.
    static func persistedPair(for entry: Entry) -> [String] {
        [entry.name, isSensitiveName(entry.name) ? "" : entry.value]
    }

    /// Reads a bucket back, applying the same caps as the live path so a file
    /// written by an older, unbounded build cannot reintroduce unbounded state.
    /// Returns nil values dropped and the bucket truncated to the cap.
    private func decode(_ raw: [String: [String]]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for k in raw.keys.sorted() {
            guard out.count < Limits.maxNamesPerBucket,
                  let arr = raw[k], arr.count == 2 else { continue }
            out[k] = Entry(name: arr[0], value: Self.bounded(arr[1]))
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
        /// Caps the number of host/endpoint buckets too. Which ones survive is
        /// arbitrary (the file records no recency), so it is at least stable.
        func nested(_ key: String, cap: Int) -> [String: [String: Entry]] {
            guard let raw = root[key] as? [String: [String: [String]]] else { return [:] }
            var out: [String: [String: Entry]] = [:]
            for k in raw.keys.sorted() {
                guard out.count < cap, let inner = raw[k] else { continue }
                out[k] = decode(inner)
            }
            return out
        }
        globalHeaders = bucket("globalHeaders")
        globalParams = bucket("globalParams")
        headersByHost = nested("headersByHost", cap: Limits.maxHosts)
        paramsByHost = nested("paramsByHost", cap: Limits.maxHosts)
        headersByEndpoint = nested("headersByEndpoint", cap: Limits.maxEndpoints)
        paramsByEndpoint = nested("paramsByEndpoint", cap: Limits.maxEndpoints)

        hostOrder = Array(Set(headersByHost.keys).union(paramsByHost.keys)).sorted()
        endpointOrder = Array(Set(headersByEndpoint.keys).union(paramsByEndpoint.keys)).sorted()

        entryCount = globalHeaders.count + globalParams.count
            + headersByHost.values.reduce(0) { $0 + $1.count }
            + paramsByHost.values.reduce(0) { $0 + $1.count }
            + headersByEndpoint.values.reduce(0) { $0 + $1.count }
            + paramsByEndpoint.values.reduce(0) { $0 + $1.count }

        // A file written by a build that predates redaction still holds live
        // bearer tokens and cookies. Rewrite it now — redacted, by `encode` —
        // instead of waiting for the next request to happen to trigger a save.
        // The values stay in memory for this session; only the disk copy loses
        // them.
        var allBuckets: [[String: Entry]] = [globalHeaders, globalParams]
        allBuckets.append(contentsOf: headersByHost.values)
        allBuckets.append(contentsOf: paramsByHost.values)
        allBuckets.append(contentsOf: headersByEndpoint.values)
        allBuckets.append(contentsOf: paramsByEndpoint.values)
        let hasLegacySecretsAtRest = allBuckets.contains { bucket in
            bucket.values.contains { !$0.value.isEmpty && Self.isSensitiveName($0.name) }
        }
        if hasLegacySecretsAtRest { scheduleSave() }
    }
}
