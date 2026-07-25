//
//  ResponseBodySearch.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

// MARK: - Which side of the transaction matched

/// Which body a hit came from. Surfaced in the UI as a badge so the user knows
/// whether the term was found in what the app *sent* or what the server *returned*.
enum BodySearchSide: String {
    case request = "REQUEST"
    case response = "RESPONSE"
}

// MARK: - One hit

/// A single body hit, with just enough context to render a row without ever
/// touching the disk again.
///
/// Deliberately holds **no reference** to the `NetworkTransaction` — matches are
/// cached across scans, and holding the models would keep evicted/cleared
/// requests (and their disk files) alive. Callers map `transactionId` back to a
/// model via `ResponseBodySearch.identifier(for:)`.
struct BodySearchMatch {
    /// Stable per-transaction key (see `ResponseBodySearch.identifier(for:)`).
    let transactionId: String
    /// Whether the request or the response body matched.
    let side: BodySearchSide
    /// Whitespace-collapsed excerpt around the first hit, e.g. `…"user_id": 8842, "na…`.
    let snippet: String
    /// UTF-16 range of the matched term **inside `snippet`**, for highlighting.
    let highlightRange: NSRange
    /// Number of occurrences found in the scanned window (capped, see `Options.maxOccurrenceCount`).
    let occurrences: Int
    /// `true` when the body was larger than the byte cap and only its head was scanned.
    let isTruncatedScan: Bool
    /// Byte offset (within the scanned window) where the first hit starts.
    let byteOffset: Int
}

// MARK: - Cancellation

/// Thread-safe one-shot cancellation flag handed to a running scan.
///
/// The scan polls this between transactions, so cancelling takes at most one
/// body read (bounded by the byte cap) to take effect.
final class BodySearchCancellationToken {

    private var _isCancelled = false
    private let lock = NSLock()

    init() {}

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock(); _isCancelled = true; lock.unlock()
    }
}

// MARK: - Result cache

/// A previously computed answer for one (query, transaction) pair. `match` is
/// nil when the body was scanned and simply did not contain the term — a
/// negative result worth caching, because it also saves a disk read.
struct CachedBodySearchResult {
    let match: BodySearchMatch?
}

/// Per-(query, transaction) memo of body-scan results, so re-running the same
/// query is instant instead of re-reading every body from disk.
///
/// The cache self-invalidates on `.allLogsCleared`, since transaction ids (and
/// the disk files behind them) are no longer valid after a clear.
final class BodySearchCache {

    static let shared = BodySearchCache()

    /// queryKey -> (transactionId -> result)
    private var buckets: [String: [String: CachedBodySearchResult]] = [:]
    /// LRU order of query keys (oldest first).
    private var queryOrder: [String] = []
    private let lock = NSLock()
    private let maxQueries = 6
    private var clearObserver: NSObjectProtocol?

    init(observesClear: Bool = true) {
        guard observesClear else { return }
        clearObserver = NotificationCenter.default.addObserver(
            forName: .allLogsCleared, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidateAll()
        }
    }

    deinit {
        if let observer = clearObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Returns the memo for this (query, id) pair, or nil when it still needs
    /// scanning.
    func cachedResult(query: String, id: String) -> CachedBodySearchResult? {
        lock.lock(); defer { lock.unlock() }
        return buckets[query]?[id]
    }

    func record(query: String, id: String, match: BodySearchMatch?) {
        lock.lock(); defer { lock.unlock() }
        if buckets[query] == nil {
            buckets[query] = [:]
            queryOrder.append(query)
            while queryOrder.count > maxQueries {
                let evicted = queryOrder.removeFirst()
                buckets[evicted] = nil
            }
        } else if let idx = queryOrder.firstIndex(of: query) {
            queryOrder.remove(at: idx)
            queryOrder.append(query)
        }
        buckets[query]?[id] = CachedBodySearchResult(match: match)
    }

    /// Drops everything. Called automatically when the capture store is cleared,
    /// because transaction ids (and their disk files) are no longer valid.
    func invalidateAll() {
        lock.lock(); buckets.removeAll(); queryOrder.removeAll(); lock.unlock()
    }

    /// Drops the memo for a single query (e.g. to force a rescan).
    func invalidate(query: String) {
        lock.lock()
        buckets[query] = nil
        if let idx = queryOrder.firstIndex(of: query) { queryOrder.remove(at: idx) }
        lock.unlock()
    }
}

// MARK: - Engine

/// Opt-in, background, cancellable **body** search over captured transactions.
///
/// The normal list search is index-backed (`RequestSearchIndex`) and never
/// touches bodies on purpose: `requestData`/`responseData` are disk-backed, so
/// every access is a file read. Searching them per keystroke would be fatal.
/// This engine is the explicit escape hatch — the user opts in, submits a query,
/// and we read each body **once** on a background queue, with:
///
/// - a hard byte cap per body (`Options.byteCap`, default 2 MB),
/// - media/binary bodies skipped entirely (no read at all when the size is 0),
/// - a determinate progress callback,
/// - a cancellation token polled between transactions,
/// - a (query, transaction) result cache so a repeat query is instant.
///
/// `run(...)` is synchronous and dependency-free (no UIKit, no dispatch) so it
/// can be unit-tested directly; `scan(...)` is the async wrapper the UI uses.
enum ResponseBodySearch {

    /// Bytes of each body actually scanned. Anything past this is ignored and the
    /// hit is flagged `isTruncatedScan`.
    static let defaultByteCap = 2 * 1024 * 1024   // 2 MB

    /// Human-readable form of the cap, for the UI info line.
    static var byteCapDescription: String { "2 MB" }

    // MARK: Options

    struct Options {
        /// Max bytes scanned per body.
        var byteCap: Int = ResponseBodySearch.defaultByteCap
        /// Scan response bodies.
        var searchResponseBodies: Bool = true
        /// Scan request bodies (checked only when the response didn't match, so a
        /// hit costs at most one extra disk read).
        var searchRequestBodies: Bool = true
        /// Default is case-insensitive substring matching.
        var caseSensitive: Bool = false
        /// Characters of context kept either side of the hit in the snippet.
        var snippetContext: Int = 48
        /// Upper bound on occurrence counting per body (counting is O(hits)).
        var maxOccurrenceCount: Int = 200
        /// Extra skip predicate — the UI passes `NetworkViewController.isMediaTransaction`
        /// so the engine stays UIKit-free while still honouring the list's media rules.
        var skipTransaction: ((NetworkTransaction) -> Bool)?

        init() {}

        /// Cache namespace: results are only reusable for identical options.
        func cacheKey(for query: String) -> String {
            let normalized = caseSensitive ? query : query.lowercased()
            return [
                normalized,
                "cap\(byteCap)",
                searchResponseBodies ? "res1" : "res0",
                searchRequestBodies ? "req1" : "req0",
                caseSensitive ? "cs1" : "cs0",
                "ctx\(snippetContext)",
            ].joined(separator: "\u{1}")
        }
    }

    // MARK: Outcome

    struct Outcome {
        let query: String
        /// Hits in the same order as the input transactions.
        let matches: [BodySearchMatch]
        /// Transactions considered.
        let totalCount: Int
        /// Bodies actually read from disk during this scan.
        let scannedCount: Int
        /// Answered from the cache without any disk read.
        let cacheHitCount: Int
        /// Skipped as media / binary / empty.
        let skippedCount: Int
        /// Hits whose body exceeded the byte cap.
        let truncatedCount: Int
        let wasCancelled: Bool
    }

    // MARK: Identity

    /// Stable key for a transaction. `requestId` when present (survives list
    /// re-reads), object identity otherwise.
    static func identifier(for model: NetworkTransaction) -> String {
        if let rid = model.requestId, !rid.isEmpty { return rid }
        return "ptr-" + String(UInt(bitPattern: ObjectIdentifier(model).hashValue), radix: 16)
    }

    // MARK: Async entry point

    private static let queue = DispatchQueue(label: "com.swiftydebug.bodysearch", qos: .utility)

    /// Runs `run(...)` off the main thread. `progress` and `completion` are always
    /// delivered on the main queue. Progress is throttled so a fast scan doesn't
    /// flood the main queue.
    static func scan(
        transactions: [NetworkTransaction],
        query: String,
        options: Options = Options(),
        token: BodySearchCancellationToken,
        cache: BodySearchCache? = .shared,
        progress: @escaping (_ completed: Int, _ total: Int) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        let total = transactions.count
        queue.async {
            var lastReported = -1
            let outcome = run(
                transactions: transactions,
                query: query,
                options: options,
                token: token,
                cache: cache,
                progress: { done, total in
                    // Throttle: every 8 items, plus the final one.
                    guard done == total || done - lastReported >= 8 else { return }
                    lastReported = done
                    DispatchQueue.main.async { progress(done, total) }
                }
            )
            DispatchQueue.main.async {
                progress(total, total)
                completion(outcome)
            }
        }
    }

    // MARK: Synchronous core (pure, testable)

    /// Scans `transactions` for `query`, reading each body at most once.
    ///
    /// Safe to call from any thread; calls `progress` synchronously on the
    /// calling thread after every transaction.
    static func run(
        transactions: [NetworkTransaction],
        query rawQuery: String,
        options: Options = Options(),
        token: BodySearchCancellationToken = BodySearchCancellationToken(),
        cache: BodySearchCache? = nil,
        progress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) -> Outcome {

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = transactions.count

        guard !query.isEmpty else {
            return Outcome(query: rawQuery, matches: [], totalCount: total, scannedCount: 0,
                           cacheHitCount: 0, skippedCount: total, truncatedCount: 0, wasCancelled: false)
        }

        let cacheKey = options.cacheKey(for: query)

        var matches: [BodySearchMatch] = []
        var scanned = 0
        var cacheHits = 0
        var skipped = 0
        var truncated = 0
        var cancelled = false

        for (offset, model) in transactions.enumerated() {
            if token.isCancelled { cancelled = true; break }

            autoreleasepool {
                let id = identifier(for: model)

                // 1. Cache — covers hits *and* misses, both save a disk read.
                if let entry = cache?.cachedResult(query: cacheKey, id: id) {
                    cacheHits += 1
                    if let match = entry.match {
                        matches.append(match)
                        if match.isTruncatedScan { truncated += 1 }
                    }
                    progress(offset + 1, total)
                    return
                }

                // 2. Cheap skips — no disk read at all.
                if shouldSkip(model, options: options) {
                    skipped += 1
                    cache?.record(query: cacheKey, id: id, match: nil)
                    progress(offset + 1, total)
                    return
                }

                // 3. Read the bodies (response first: a hit there avoids the
                //    second read entirely).
                var match: BodySearchMatch?
                var didRead = false

                if options.searchResponseBodies, model.responseDataSize > 0,
                   let data = model.responseData, !data.isEmpty {
                    didRead = true
                    match = findMatch(in: data, query: query, id: id, side: .response, options: options)
                }
                if match == nil, options.searchRequestBodies, model.requestDataSize > 0,
                   let data = model.requestData, !data.isEmpty {
                    didRead = true
                    match = findMatch(in: data, query: query, id: id, side: .request, options: options)
                }

                if didRead { scanned += 1 } else { skipped += 1 }
                cache?.record(query: cacheKey, id: id, match: match)
                if let match {
                    matches.append(match)
                    if match.isTruncatedScan { truncated += 1 }
                }
                progress(offset + 1, total)
            }
        }

        return Outcome(
            query: query,
            matches: matches,
            totalCount: total,
            scannedCount: scanned,
            cacheHitCount: cacheHits,
            skippedCount: skipped,
            truncatedCount: truncated,
            wasCancelled: cancelled
        )
    }

    // MARK: - Skipping

    /// MIME types whose bodies are never worth decoding as text.
    private static let binaryMimeFragments = [
        "image/", "video/", "audio/", "font/",
        "application/octet-stream", "application/zip", "application/gzip",
        "application/pdf", "application/x-protobuf", "application/protobuf",
        "application/wasm", "application/x-font",
    ]

    /// `true` when a transaction should never be read from disk: caller-supplied
    /// media rule, media/binary MIME, or an empty pair of bodies.
    static func shouldSkip(_ model: NetworkTransaction, options: Options) -> Bool {
        if let custom = options.skipTransaction, custom(model) { return true }
        if model.isImage { return true }

        if let mime = model.mineType?.lowercased(), !mime.isEmpty {
            for fragment in binaryMimeFragments where mime.contains(fragment) {
                return true
            }
        }

        let hasResponse = options.searchResponseBodies && model.responseDataSize > 0
        let hasRequest = options.searchRequestBodies && model.requestDataSize > 0
        return !hasResponse && !hasRequest
    }

    /// Sniffs the head of a body for NUL bytes — no textual payload (JSON, XML,
    /// HTML, form, plain text) contains them, so this catches binaries the
    /// Content-Type lied about.
    static func isLikelyBinary(_ data: Data) -> Bool {
        let probe = data.prefix(512)
        return probe.contains(0)
    }

    // MARK: - Matching

    /// Finds the first occurrence of `query` in the (capped) body and builds a
    /// display-ready snippet. Returns nil when the body is binary or has no hit.
    static func findMatch(
        in data: Data,
        query: String,
        id: String,
        side: BodySearchSide,
        options: Options
    ) -> BodySearchMatch? {

        let isTruncated = data.count > options.byteCap
        let window = isTruncated ? data.prefix(options.byteCap) : data.prefix(data.count)

        if isLikelyBinary(window) { return nil }

        // `String(decoding:)` never fails — invalid bytes (including a codepoint
        // cut in half by the cap) become replacement characters.
        let text: String
        if let utf8 = String(data: window, encoding: .utf8) {
            text = utf8
        } else {
            text = String(decoding: window, as: UTF8.self)
        }
        guard !text.isEmpty else { return nil }

        let compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        guard let first = text.range(of: query, options: compareOptions) else { return nil }

        // Occurrence count (bounded).
        var occurrences = 1
        var cursor = first.upperBound
        while occurrences < options.maxOccurrenceCount,
              let next = text.range(of: query, options: compareOptions, range: cursor..<text.endIndex) {
            occurrences += 1
            cursor = next.upperBound
        }

        let (snippet, range) = makeSnippet(text: text, match: first, context: options.snippetContext)
        let byteOffset = text[text.startIndex..<first.lowerBound].utf8.count

        return BodySearchMatch(
            transactionId: id,
            side: side,
            snippet: snippet,
            highlightRange: range,
            occurrences: occurrences,
            isTruncatedScan: isTruncated,
            byteOffset: byteOffset
        )
    }

    /// Builds `…prefix<match>suffix…` with whitespace collapsed, plus the UTF-16
    /// range of `<match>` inside the produced string.
    ///
    /// The three pieces are sanitized independently so collapsing newlines can
    /// never shift the highlight off the matched term.
    static func makeSnippet(
        text: String,
        match: Range<String.Index>,
        context: Int
    ) -> (snippet: String, range: NSRange) {

        let lower = text.index(match.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(match.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex

        let prefix = collapseWhitespace(String(text[lower..<match.lowerBound]))
        let matched = collapseWhitespace(String(text[match]))
        let suffix = collapseWhitespace(String(text[match.upperBound..<upper]))

        let leadingEllipsis = lower > text.startIndex ? "…" : ""
        let trailingEllipsis = upper < text.endIndex ? "…" : ""

        let head = leadingEllipsis + prefix
        let snippet = head + matched + suffix + trailingEllipsis
        let range = NSRange(location: (head as NSString).length, length: (matched as NSString).length)
        return (snippet, range)
    }

    /// Newlines/tabs/control characters become spaces and runs of spaces collapse,
    /// so a snippet is always one readable line.
    static func collapseWhitespace(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        var lastWasSpace = false
        for scalar in input.unicodeScalars {
            let isSpace = scalar == " " || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isSpace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }
}
