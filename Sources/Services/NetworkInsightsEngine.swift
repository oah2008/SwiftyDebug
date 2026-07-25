//
//  NetworkInsightsEngine.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Aggregation engine behind the Insights dashboard.
///
/// This file is deliberately **UIKit-free and side-effect-free**: it takes a
/// plain array of `NetworkTransaction` and returns an immutable
/// `InsightsSnapshot`. That keeps it unit-testable and — more importantly —
/// safe to run on a background queue, which is mandatory: the store can hold
/// hundreds of transactions and aggregating them on the main thread would
/// stutter the debugger UI.
///
/// **Disk safety**: nothing here ever touches `requestData` / `responseData`.
/// Those properties are disk-backed (every read is a file read). Only the
/// in-memory scalars (`requestDataSize`, `responseDataSize`, timings, status)
/// and the precomputed `searchIndex` are used.

// MARK: - Scope

/// Which slice of the captured traffic the dashboard is describing.
enum InsightsScope: Int, CaseIterable {
    case all = 0
    case app = 1
    case web = 2

    var title: String {
        switch self {
        case .all: return "All"
        case .app: return "App"
        case .web: return "Web"
        }
    }

    func includes(_ model: NetworkTransaction) -> Bool {
        switch self {
        case .all: return true
        case .app: return !model.isWebViewRequest
        case .web: return model.isWebViewRequest
        }
    }
}

// MARK: - Status classification

/// Status classes used by the breakdown bar. `failed` covers transport-level
/// failures (no response at all) and anything with an error description.
enum InsightsStatusBucket: Int, CaseIterable {
    case success = 0      // 2xx
    case redirect = 1     // 3xx
    case clientError = 2  // 4xx
    case serverError = 3  // 5xx
    case failed = 4       // no response / transport error

    var title: String {
        switch self {
        case .success:     return "2xx"
        case .redirect:    return "3xx"
        case .clientError: return "4xx"
        case .serverError: return "5xx"
        case .failed:      return "Failed"
        }
    }

    /// Everything that counts toward the error rate.
    var isError: Bool {
        switch self {
        case .success, .redirect: return false
        case .clientError, .serverError, .failed: return true
        }
    }

    static func classify(_ model: NetworkTransaction) -> InsightsStatusBucket {
        if let err = model.errorDescription, !err.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failed
        }
        if let err = model.errorLocalizedDescription, !err.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failed
        }
        let raw = (model.statusCode ?? "").trimmingCharacters(in: .whitespaces)
        guard let code = Int(raw), code > 0 else { return .failed }
        switch code {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default:        return code < 200 ? .failed : .serverError
        }
    }
}

// MARK: - Snapshot value types

/// One request, flattened to just what the dashboard lists render.
struct InsightsRequestStat {
    let method: String
    let host: String
    /// Original path (what actually went over the wire).
    let path: String
    let statusCode: String
    let bucket: InsightsStatusBucket
    let durationMs: Double
    let responseBytes: UInt64
}

struct InsightsEndpointStat {
    /// Normalized path (ids collapsed to `{id}`) when available.
    let path: String
    let count: Int
    let errorCount: Int
    let p50DurationMs: Double
    let p95DurationMs: Double
    let averageResponseBytes: Double

    var errorRate: Double { count > 0 ? Double(errorCount) / Double(count) : 0 }
}

struct InsightsHostStat {
    let host: String
    let count: Int
    let errorCount: Int
    let p95DurationMs: Double
    let totalBytes: UInt64
    /// Per-host endpoint breakdown, precomputed so expanding a row costs nothing.
    let topEndpoints: [InsightsEndpointStat]

    var errorRate: Double { count > 0 ? Double(errorCount) / Double(count) : 0 }
}

struct InsightsStatusSlice {
    let bucket: InsightsStatusBucket
    let count: Int
    /// 0…1 share of the total.
    let fraction: Double
}

struct InsightsOverview {
    var totalRequests: Int = 0
    var errorCount: Int = 0
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    /// Wall-clock span between the first request start and the last request end.
    var sessionDuration: TimeInterval = 0
    var averageDurationMs: Double = 0
    var p50DurationMs: Double = 0
    var p95DurationMs: Double = 0

    var errorRate: Double { totalRequests > 0 ? Double(errorCount) / Double(totalRequests) : 0 }
}

/// The immutable result of one aggregation pass. Built off the main thread,
/// applied on it.
struct InsightsSnapshot {
    let scope: InsightsScope
    let overview: InsightsOverview
    /// Sorted by request count, descending.
    let hosts: [InsightsHostStat]
    /// Sorted by request count, descending (full list — the UI decides how many to show).
    let endpoints: [InsightsEndpointStat]
    /// Top 10 by duration, descending.
    let slowest: [InsightsRequestStat]
    /// Top 10 by response size, descending.
    let largest: [InsightsRequestStat]
    /// One slice per status class, in `InsightsStatusBucket.allCases` order.
    let statusSlices: [InsightsStatusSlice]

    var isEmpty: Bool { overview.totalRequests == 0 }

    static func empty(scope: InsightsScope) -> InsightsSnapshot {
        InsightsSnapshot(scope: scope,
                         overview: InsightsOverview(),
                         hosts: [],
                         endpoints: [],
                         slowest: [],
                         largest: [],
                         statusSlices: [])
    }
}

// MARK: - Engine

enum NetworkInsightsEngine {

    /// How many endpoints are kept per host for the expandable host breakdown.
    static let endpointsPerHost = 6
    /// How many rows the "slowest" / "largest" lists carry.
    static let topRequestCount = 10

    // MARK: Public entry point

    /// Aggregates `transactions` into a snapshot. **Call off the main thread.**
    ///
    /// - Parameters:
    ///   - transactions: a *snapshot* of the store (take the array on the main
    ///     thread, aggregate here) — the store mutates from network threads.
    ///   - scope: All / App / Web.
    static func snapshot(from transactions: [NetworkTransaction],
                         scope: InsightsScope) -> InsightsSnapshot {

        var durations: [Double] = []
        durations.reserveCapacity(transactions.count)

        var overview = InsightsOverview()
        var bucketCounts = [Int](repeating: 0, count: InsightsStatusBucket.allCases.count)

        var minStart = Double.greatestFiniteMagnitude
        var maxEnd = -Double.greatestFiniteMagnitude

        var hostAcc: [String: HostAccumulator] = [:]
        var endpointAcc: [String: EndpointAccumulator] = [:]
        var flattened: [InsightsRequestStat] = []
        flattened.reserveCapacity(transactions.count)

        for model in transactions where scope.includes(model) {
            let index = model.searchIndex
            let url = model.url as URL?

            var host = index?.host ?? ""
            if host.isEmpty { host = (url?.host ?? "").lowercased() }
            if host.isEmpty { host = "(unknown host)" }

            let rawPath = index?.path ?? url?.path ?? ""
            var endpointPath = index?.normalizedPath ?? ""
            if endpointPath.isEmpty { endpointPath = rawPath }
            if endpointPath.isEmpty { endpointPath = "/" }

            let bucket = InsightsStatusBucket.classify(model)
            let duration = durationMs(for: model)
            let sent = UInt64(model.requestDataSize)
            let received = UInt64(model.responseDataSize)
            let method = (index?.method ?? model.method ?? "").uppercased()

            // --- Overview ---
            overview.totalRequests += 1
            if bucket.isError { overview.errorCount += 1 }
            overview.bytesSent &+= sent
            overview.bytesReceived &+= received
            bucketCounts[bucket.rawValue] += 1
            if let duration { durations.append(duration) }

            if let start = timestamp(model.startTime), start > 0 {
                minStart = Swift.min(minStart, start)
                if let end = timestamp(model.endTime), end > 0 {
                    maxEnd = Swift.max(maxEnd, end)
                } else {
                    maxEnd = Swift.max(maxEnd, start)
                }
            }

            // --- Per host ---
            var h = hostAcc[host] ?? HostAccumulator()
            h.count += 1
            if bucket.isError { h.errorCount += 1 }
            h.totalBytes &+= (sent &+ received)
            if let duration { h.durations.append(duration) }
            var he = h.endpoints[endpointPath] ?? EndpointAccumulator()
            he.absorb(bucket: bucket, duration: duration, responseBytes: received)
            h.endpoints[endpointPath] = he
            hostAcc[host] = h

            // --- Per endpoint (global) ---
            var e = endpointAcc[endpointPath] ?? EndpointAccumulator()
            e.absorb(bucket: bucket, duration: duration, responseBytes: received)
            endpointAcc[endpointPath] = e

            flattened.append(InsightsRequestStat(
                method: method.isEmpty ? "—" : method,
                host: host,
                path: rawPath.isEmpty ? endpointPath : rawPath,
                statusCode: displayStatus(model, bucket: bucket),
                bucket: bucket,
                durationMs: duration ?? 0,
                responseBytes: received))
        }

        guard overview.totalRequests > 0 else { return .empty(scope: scope) }

        // --- Percentiles / averages ---
        durations.sort()
        if !durations.isEmpty {
            overview.averageDurationMs = durations.reduce(0, +) / Double(durations.count)
            overview.p50DurationMs = percentile(sorted: durations, 0.50)
            overview.p95DurationMs = percentile(sorted: durations, 0.95)
        }
        if minStart < Double.greatestFiniteMagnitude, maxEnd > minStart {
            overview.sessionDuration = maxEnd - minStart
        }

        // --- Status slices ---
        let total = Double(overview.totalRequests)
        let slices = InsightsStatusBucket.allCases.map { bucket -> InsightsStatusSlice in
            let count = bucketCounts[bucket.rawValue]
            return InsightsStatusSlice(bucket: bucket,
                                       count: count,
                                       fraction: total > 0 ? Double(count) / total : 0)
        }

        // --- Hosts ---
        // Built with explicit loops rather than chained map/sorted: the chained
        // form pushed the type-checker past its budget in this function.
        var hosts: [InsightsHostStat] = []
        hosts.reserveCapacity(hostAcc.count)
        for (hostKey, acc) in hostAcc {
            hosts.append(acc.finish(host: hostKey))
        }
        hosts.sort(by: hostOrder)

        // --- Endpoints ---
        var endpoints: [InsightsEndpointStat] = []
        endpoints.reserveCapacity(endpointAcc.count)
        for (path, acc) in endpointAcc {
            endpoints.append(acc.finish(path: path))
        }
        endpoints.sort(by: endpointOrder)

        // --- Top lists ---
        let slowest = Array(flattened
            .filter { $0.durationMs > 0 }
            .sorted { $0.durationMs > $1.durationMs }
            .prefix(topRequestCount))

        let largest = Array(flattened
            .filter { $0.responseBytes > 0 }
            .sorted { $0.responseBytes > $1.responseBytes }
            .prefix(topRequestCount))

        return InsightsSnapshot(scope: scope,
                                overview: overview,
                                hosts: hosts,
                                endpoints: endpoints,
                                slowest: slowest,
                                largest: largest,
                                statusSlices: slices)
    }

    // MARK: Percentiles

    /// Linear-interpolated percentile over an **already sorted ascending** sample
    /// array. Deliberately hand-rolled — no stats dependency.
    ///
    /// - Parameter p: 0…1 (0.95 = p95). Values outside the range are clamped.
    static func percentile(sorted samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        guard samples.count > 1 else { return samples[0] }
        let clamped = Swift.min(Swift.max(p, 0), 1)
        let rank = clamped * Double(samples.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return samples[lower] }
        let weight = rank - Double(lower)
        return samples[lower] * (1 - weight) + samples[upper] * weight
    }

    /// Convenience for callers holding an unsorted sample set.
    static func percentile(of samples: [Double], _ p: Double) -> Double {
        percentile(sorted: samples.sorted(), p)
    }

    // MARK: Duration parsing

    /// Duration in **milliseconds**, or nil when the transaction carries no
    /// usable timing (still in flight, or a restored pin with missing fields).
    ///
    /// `startTime` / `endTime` are strings holding seconds-since-1970 in both
    /// capture paths (URLProtocol and the WKWebView bridge), so they are the
    /// primary source. `totalDuration` is a *display* string whose format
    /// differs per path ("0.123000 (s)" vs "84 ms") and is only a fallback.
    static func durationMs(for model: NetworkTransaction) -> Double? {
        if let start = timestamp(model.startTime), let end = timestamp(model.endTime),
           start > 0, end >= start {
            let ms = (end - start) * 1000
            if ms.isFinite, ms >= 0 { return ms }
        }
        guard let raw = model.totalDuration?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        let numeric = lower
            .replacingOccurrences(of: "(s)", with: "")
            .replacingOccurrences(of: "ms", with: "")
            .replacingOccurrences(of: "s", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(numeric), value.isFinite, value >= 0 else { return nil }
        return lower.contains("ms") ? value : value * 1000
    }

    /// Parses one of the `startTime` / `endTime` strings (seconds since 1970).
    static func timestamp(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = (raw as NSString).doubleValue
        return value.isFinite && value > 0 ? value : nil
    }

    // MARK: Private helpers

    private static func displayStatus(_ model: NetworkTransaction,
                                      bucket: InsightsStatusBucket) -> String {
        let raw = (model.statusCode ?? "").trimmingCharacters(in: .whitespaces)
        if bucket == .failed, raw.isEmpty || raw == "0" { return "ERR" }
        return raw.isEmpty ? "—" : raw
    }

    /// Most requests first; ties broken alphabetically so the order is stable
    /// across passes (dictionary iteration order is not).
    private static func endpointOrder(_ lhs: InsightsEndpointStat,
                                      _ rhs: InsightsEndpointStat) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.path < rhs.path
    }

    private static func hostOrder(_ lhs: InsightsHostStat,
                                  _ rhs: InsightsHostStat) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.host < rhs.host
    }

    // MARK: Accumulators

    private struct EndpointAccumulator {
        var count = 0
        var errorCount = 0
        var totalResponseBytes: UInt64 = 0
        var durations: [Double] = []

        mutating func absorb(bucket: InsightsStatusBucket, duration: Double?, responseBytes: UInt64) {
            count += 1
            if bucket.isError { errorCount += 1 }
            totalResponseBytes &+= responseBytes
            if let duration { durations.append(duration) }
        }

        func finish(path: String) -> InsightsEndpointStat {
            let sorted = durations.sorted()
            return InsightsEndpointStat(
                path: path,
                count: count,
                errorCount: errorCount,
                p50DurationMs: NetworkInsightsEngine.percentile(sorted: sorted, 0.50),
                p95DurationMs: NetworkInsightsEngine.percentile(sorted: sorted, 0.95),
                averageResponseBytes: count > 0 ? Double(totalResponseBytes) / Double(count) : 0)
        }
    }

    private struct HostAccumulator {
        var count = 0
        var errorCount = 0
        var totalBytes: UInt64 = 0
        var durations: [Double] = []
        var endpoints: [String: EndpointAccumulator] = [:]

        func finish(host: String) -> InsightsHostStat {
            let sortedDurations = durations.sorted()
            let p95 = NetworkInsightsEngine.percentile(sorted: sortedDurations, 0.95)

            var endpointStats: [InsightsEndpointStat] = []
            endpointStats.reserveCapacity(endpoints.count)
            for (path, acc) in endpoints {
                endpointStats.append(acc.finish(path: path))
            }
            endpointStats.sort(by: NetworkInsightsEngine.endpointOrder)
            let top = Array(endpointStats.prefix(NetworkInsightsEngine.endpointsPerHost))

            return InsightsHostStat(host: host,
                                    count: count,
                                    errorCount: errorCount,
                                    p95DurationMs: p95,
                                    totalBytes: totalBytes,
                                    topEndpoints: top)
        }
    }
}

// MARK: - Formatting

/// Display formatting shared by the insights cells. Kept next to the engine so
/// units stay consistent (durations are milliseconds everywhere internally).
enum InsightsFormat {

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 bytes" }
        return byteFormatter.string(fromByteCount: Int64(value.rounded()))
    }

    /// Millisecond duration, switching to seconds once it gets long.
    static func duration(ms: Double) -> String {
        guard ms.isFinite, ms > 0 else { return "—" }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        if ms < 60_000 { return String(format: "%.2f s", ms / 1000) }
        return elapsed(seconds: ms / 1000)
    }

    /// Wall-clock span, e.g. "42s" / "3m 12s" / "1h 04m".
    static func elapsed(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return String(format: "%dm %02ds", minutes, secs)
    }

    /// Rate given as 0…1.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        if fraction < 0.001 { return "<0.1%" }
        let pct = fraction * 100
        return pct >= 10 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
