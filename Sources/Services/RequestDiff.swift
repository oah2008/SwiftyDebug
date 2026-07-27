//
//  RequestDiff.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import Foundation

// MARK: - Model

enum RequestDiffChange {
    case same
    case added
    case removed
    case changed
}

/// One comparable line: a header, a query param, a JSON key path or a body line.
struct RequestDiffRow {

    let label: String
    let oldValue: String?
    let newValue: String?
    let change: RequestDiffChange

    /// Context rows (timestamps, truncation warnings). They stay visible in
    /// "changes only" mode and never count towards the change total, because
    /// they always differ and would otherwise drown the real signal.
    let isNote: Bool

    init(label: String,
         oldValue: String?,
         newValue: String?,
         change: RequestDiffChange,
         isNote: Bool = false) {
        self.label = label
        self.oldValue = oldValue
        self.newValue = newValue
        self.change = change
        self.isNote = isNote
    }
}

struct RequestDiffSection {

    let title: String
    let rows: [RequestDiffRow]

    var changeCount: Int {
        rows.reduce(0) { $0 + (($1.isNote || $1.change == .same) ? 0 : 1) }
    }

    func rows(changesOnly: Bool) -> [RequestDiffRow] {
        guard changesOnly else { return rows }
        return rows.filter { $0.isNote || $0.change != .same }
    }
}

struct RequestDiffResult {

    let sections: [RequestDiffSection]

    var changeCount: Int { sections.reduce(0) { $0 + $1.changeCount } }
    var hasChanges: Bool { changeCount > 0 }

    /// Sections that still have something to show under the current filter.
    func sections(changesOnly: Bool) -> [RequestDiffSection] {
        guard changesOnly else { return sections }
        return sections.filter { $0.changeCount > 0 }
    }
}

// MARK: - Snapshot

/// A flattened copy of everything the diff needs from a NetworkTransaction.
///
/// NetworkTransaction bodies are disk-backed — every `requestData` / `responseData`
/// access is a file read — so the snapshot pulls each body exactly once and the
/// diff engine never touches the transaction again.
struct RequestSnapshot {

    var displayTitle: String = ""
    var method: String = ""
    var urlString: String = ""
    var scheme: String = ""
    var host: String = ""
    var port: String = ""
    var path: String = ""
    var statusCode: String = ""
    var mimeType: String = ""
    var errorDescription: String = ""

    var queryItems: [(name: String, value: String)] = []
    var requestHeaders: [(name: String, value: String)] = []
    var responseHeaders: [(name: String, value: String)] = []

    var requestBody: Data?
    var responseBody: Data?
    var isRequestBodyTruncated: Bool = false
    var isResponseBodyTruncated: Bool = false

    var startTime: String = ""
    var endTime: String = ""
    var requestSize: UInt = 0
    var responseSize: UInt = 0

    init() {}

    init(transaction: NetworkTransaction) {
        // Single read per body — see the type comment.
        requestBody = transaction.requestData
        responseBody = transaction.responseData

        method = (transaction.method ?? "").uppercased()
        urlString = transaction.url?.absoluteString ?? ""
        scheme = transaction.url?.scheme ?? ""
        host = transaction.url?.host ?? ""
        // NSURL.host excludes the port, so it has to be captured separately.
        port = transaction.url?.port.map { "\($0)" } ?? ""
        path = transaction.url?.path ?? ""
        statusCode = transaction.statusCode ?? ""
        mimeType = transaction.mineType ?? ""
        errorDescription = transaction.errorLocalizedDescription ?? transaction.errorDescription ?? ""

        if let components = URLComponents(string: urlString), let items = components.queryItems {
            queryItems = items.map { ($0.name, $0.value ?? "") }
        }
        requestHeaders = RequestDiff.headerPairs(transaction.requestHeaderFields)
        responseHeaders = RequestDiff.headerPairs(transaction.responseHeaderFields)

        isRequestBodyTruncated = transaction.isRequestBodyTruncated
        isResponseBodyTruncated = transaction.isResponseTruncated

        startTime = transaction.startTime ?? ""
        endTime = transaction.endTime ?? ""
        requestSize = transaction.requestDataSize
        responseSize = transaction.responseDataSize

        let shortPath = path.isEmpty ? "/" : path
        displayTitle = method.isEmpty ? shortPath : "\(method) \(shortPath)"
    }
}

// MARK: - Engine

enum RequestDiff {

    /// Values longer than this are shortened for display only — comparison always
    /// runs on the full value, so a change past the cut-off is still detected.
    static let maxDisplayLength = 1200

    /// The LCS table is O(n*m); past this many entries per side we fall back to a
    /// cheaper ordering so a 20k-line HTML response cannot freeze the UI.
    static let lcsLimit = 600

    // MARK: Public entry points

    static func compare(_ old: NetworkTransaction, _ new: NetworkTransaction) -> RequestDiffResult {
        return compare(RequestSnapshot(transaction: old), RequestSnapshot(transaction: new))
    }

    static func compare(_ old: RequestSnapshot, _ new: RequestSnapshot) -> RequestDiffResult {
        var sections: [RequestDiffSection] = []

        sections.append(overviewSection(old, new))
        sections.append(RequestDiffSection(
            title: "QUERY PARAMS",
            rows: fill(diffPairs(old: old.queryItems, new: new.queryItems))
        ))
        sections.append(RequestDiffSection(
            title: "REQUEST HEADERS",
            rows: fill(diffPairs(old: old.requestHeaders, new: new.requestHeaders, caseInsensitiveNames: true))
        ))
        sections.append(bodySection(
            title: "REQUEST BODY",
            oldBody: old.requestBody, newBody: new.requestBody,
            oldTruncated: old.isRequestBodyTruncated, newTruncated: new.isRequestBodyTruncated
        ))
        sections.append(RequestDiffSection(
            title: "RESPONSE HEADERS",
            rows: fill(diffPairs(old: old.responseHeaders, new: new.responseHeaders, caseInsensitiveNames: true))
        ))
        sections.append(bodySection(
            title: "RESPONSE BODY",
            oldBody: old.responseBody, newBody: new.responseBody,
            oldTruncated: old.isResponseBodyTruncated, newTruncated: new.isResponseBodyTruncated
        ))
        sections.append(timingSection(old, new))

        return RequestDiffResult(sections: sections)
    }

    // MARK: Sections

    private static func overviewSection(_ old: RequestSnapshot, _ new: RequestSnapshot) -> RequestDiffSection {
        var rows: [RequestDiffRow] = []
        rows.append(scalarRow("Method", old.method, new.method))
        rows.append(scalarRow("Status", old.statusCode, new.statusCode))
        // Scheme and port matter as much as the host — a request that silently
        // dropped to http, or moved to another port, would otherwise be reported
        // as "identical", which is the one answer this screen must never give.
        rows.append(scalarRow("Scheme", old.scheme, new.scheme))
        rows.append(scalarRow("Host", old.host, new.host))
        if !old.port.isEmpty || !new.port.isEmpty {
            rows.append(scalarRow("Port", old.port, new.port))
        }
        rows.append(scalarRow("Path", old.path, new.path))
        if !old.errorDescription.isEmpty || !new.errorDescription.isEmpty {
            rows.append(scalarRow("Error", old.errorDescription, new.errorDescription))
        }
        return RequestDiffSection(title: "REQUEST", rows: rows)
    }

    private static func timingSection(_ old: RequestSnapshot, _ new: RequestSnapshot) -> RequestDiffSection {
        var rows: [RequestDiffRow] = []
        rows.append(scalarRow("Duration",
                              durationText(start: old.startTime, end: old.endTime),
                              durationText(start: new.startTime, end: new.endTime)))
        rows.append(scalarRow("Request size", byteText(old.requestSize), byteText(new.requestSize)))
        rows.append(scalarRow("Response size", byteText(old.responseSize), byteText(new.responseSize)))
        if !old.mimeType.isEmpty || !new.mimeType.isEmpty {
            rows.append(scalarRow("Content type", old.mimeType, new.mimeType))
        }
        // Timestamps always differ; kept as context so they never inflate the count.
        rows.append(RequestDiffRow(label: "Started",
                                   oldValue: timeText(old.startTime),
                                   newValue: timeText(new.startTime),
                                   change: .changed,
                                   isNote: true))
        return RequestDiffSection(title: "TIMING & SIZE", rows: rows)
    }

    static func bodySection(title: String,
                            oldBody: Data?,
                            newBody: Data?,
                            oldTruncated: Bool = false,
                            newTruncated: Bool = false) -> RequestDiffSection {
        var rows = diffBodies(oldBody, newBody)
        if oldTruncated || newTruncated {
            let which: String
            if oldTruncated && newTruncated { which = "Both bodies were truncated on capture" }
            else if oldTruncated { which = "Body A was truncated on capture" }
            else { which = "Body B was truncated on capture" }
            rows.insert(RequestDiffRow(label: "⚠︎ Partial data",
                                       oldValue: which,
                                       newValue: nil,
                                       change: .same,
                                       isNote: true), at: 0)
        }
        return RequestDiffSection(title: title, rows: fill(rows))
    }

    /// Structured diff when both sides parse (JSON by key path, form bodies by key),
    /// line diff otherwise.
    static func diffBodies(_ oldBody: Data?, _ newBody: Data?) -> [RequestDiffRow] {
        let old = oldBody ?? Data()
        let new = newBody ?? Data()
        if old.isEmpty && new.isEmpty { return [] }

        let oldJSON = jsonPairs(old)
        let newJSON = jsonPairs(new)
        if (oldJSON != nil || old.isEmpty), (newJSON != nil || new.isEmpty) {
            return diffPairs(old: oldJSON ?? [], new: newJSON ?? [], emptyPathLabel: "(root)")
        }

        let oldText = String(data: old, encoding: .utf8) ?? ""
        let newText = String(data: new, encoding: .utf8) ?? ""

        let oldForm = formPairs(oldText)
        let newForm = formPairs(newText)
        if (oldForm != nil || old.isEmpty), (newForm != nil || new.isEmpty) {
            return diffPairs(old: oldForm ?? [], new: newForm ?? [])
        }

        if oldText.isEmpty && newText.isEmpty {
            // Binary payloads: nothing readable to line up, compare the bytes.
            return [RequestDiffRow(label: "(binary)",
                                   oldValue: byteText(UInt(old.count)),
                                   newValue: byteText(UInt(new.count)),
                                   change: old == new ? .same : .changed)]
        }
        return diffText(oldText, newText)
    }

    // MARK: Keyed diff

    /// Diffs two ordered name/value lists. Names present on one side only become
    /// `.added` / `.removed`; names on both sides are `.same` or `.changed`.
    static func diffPairs(old: [(name: String, value: String)],
                          new: [(name: String, value: String)],
                          caseInsensitiveNames: Bool = false,
                          emptyPathLabel: String = "(value)") -> [RequestDiffRow] {

        let oldIndex = index(old, caseInsensitiveNames: caseInsensitiveNames)
        let newIndex = index(new, caseInsensitiveNames: caseInsensitiveNames)

        var rows: [RequestDiffRow] = []
        for key in mergedOrder(oldIndex.order, newIndex.order) {
            let oldValue = oldIndex.values[key]
            let newValue = newIndex.values[key]
            // Prefer the old side's original casing so a renamed-case header does
            // not look like a brand new one.
            let rawLabel = oldIndex.labels[key] ?? newIndex.labels[key] ?? key
            let label = rawLabel.isEmpty ? emptyPathLabel : rawLabel

            switch (oldValue, newValue) {
            case let (.some(o), .some(n)):
                rows.append(RequestDiffRow(label: label,
                                           oldValue: display(o),
                                           newValue: display(n),
                                           change: o == n ? .same : .changed))
            case let (.some(o), .none):
                rows.append(RequestDiffRow(label: label, oldValue: display(o), newValue: nil, change: .removed))
            case let (.none, .some(n)):
                rows.append(RequestDiffRow(label: label, oldValue: nil, newValue: display(n), change: .added))
            case (.none, .none):
                continue
            }
        }
        return rows
    }

    /// Assigns each pair a lookup key, disambiguating repeats (`tag`, `tag#2`)
    /// so `?tag=a&tag=b` diffs positionally instead of collapsing.
    private static func index(_ pairs: [(name: String, value: String)],
                              caseInsensitiveNames: Bool)
    -> (order: [String], values: [String: String], labels: [String: String]) {

        var order: [String] = []
        var values: [String: String] = [:]
        var labels: [String: String] = [:]
        var seen: [String: Int] = [:]

        for pair in pairs {
            let base = caseInsensitiveNames ? pair.name.lowercased() : pair.name
            let occurrence = (seen[base] ?? 0) + 1
            seen[base] = occurrence
            let key = occurrence == 1 ? base : "\(base)#\(occurrence)"
            order.append(key)
            values[key] = pair.value
            labels[key] = occurrence == 1 ? pair.name : "\(pair.name) #\(occurrence)"
        }
        return (order, values, labels)
    }

    // MARK: Text diff

    static func diffText(_ oldText: String, _ newText: String) -> [RequestDiffRow] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")

        guard oldLines.count <= lcsLimit, newLines.count <= lcsLimit else {
            return [RequestDiffRow(label: "(body)",
                                   oldValue: display(oldText),
                                   newValue: display(newText),
                                   change: oldText == newText ? .same : .changed)]
        }

        var rows: [RequestDiffRow] = []
        for operation in lcsOperations(oldLines, newLines) {
            switch operation {
            case let .common(oldIdx, _):
                rows.append(RequestDiffRow(label: "line \(oldIdx + 1)",
                                           oldValue: display(oldLines[oldIdx]),
                                           newValue: display(oldLines[oldIdx]),
                                           change: .same))
            case let .removed(oldIdx):
                rows.append(RequestDiffRow(label: "line \(oldIdx + 1)",
                                           oldValue: display(oldLines[oldIdx]),
                                           newValue: nil,
                                           change: .removed))
            case let .added(newIdx):
                rows.append(RequestDiffRow(label: "line \(newIdx + 1)",
                                           oldValue: nil,
                                           newValue: display(newLines[newIdx]),
                                           change: .added))
            }
        }
        return rows
    }

    // MARK: JSON flattening

    /// Flattens JSON into `path -> scalar` pairs using the `a.b[0].c` path form,
    /// so arrays of objects diff element by element instead of as one blob.
    static func flattenJSON(_ object: Any) -> [(name: String, value: String)] {
        var output: [(name: String, value: String)] = []
        flatten(object, path: "", into: &output)
        return output
    }

    private static func flatten(_ object: Any, path: String, into output: inout [(name: String, value: String)]) {
        if let dictionary = object as? [String: Any] {
            if dictionary.isEmpty {
                output.append((path, "{}"))
                return
            }
            // Sorted so two captures of the same payload always line up.
            for key in dictionary.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                flatten(dictionary[key] ?? NSNull(), path: childPath, into: &output)
            }
            return
        }
        if let array = object as? [Any] {
            if array.isEmpty {
                output.append((path, "[]"))
                return
            }
            for (offset, element) in array.enumerated() {
                flatten(element, path: "\(path)[\(offset)]", into: &output)
            }
            return
        }
        output.append((path, scalarDescription(object)))
    }

    /// JSON-ish rendering so a type flip (`"1"` → `1`) reads as a change.
    static func scalarDescription(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if let number = value as? NSNumber {
            // NSNumber bridges booleans and numbers alike; only CFBoolean is a real bool.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return String(describing: value)
    }

    static func jsonPairs(_ data: Data) -> [(name: String, value: String)]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              object is [String: Any] || object is [Any] else { return nil }
        return flattenJSON(object)
    }

    static func formPairs(_ text: String) -> [(name: String, value: String)]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains("="),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        var pairs: [(name: String, value: String)] = []
        for component in trimmed.components(separatedBy: "&") {
            let parts = component.components(separatedBy: "=")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            pairs.append((parts[0].removingPercentEncoding ?? parts[0],
                          parts[1].removingPercentEncoding ?? parts[1]))
        }
        // A lone `key=` is far more likely base64 padding than a form body.
        if pairs.count == 1 && pairs[0].value.isEmpty { return nil }
        return pairs.isEmpty ? nil : pairs
    }

    // MARK: Ordering

    enum LCSOperation {
        case common(Int, Int)
        case removed(Int)
        case added(Int)
    }

    /// Interleaves two key orders so shared keys keep their relative position and
    /// side-specific keys land next to the key they followed.
    static func mergedOrder(_ oldKeys: [String], _ newKeys: [String]) -> [String] {
        guard oldKeys.count <= lcsLimit, newKeys.count <= lcsLimit else {
            var merged = oldKeys
            var seen = Set(oldKeys)
            for key in newKeys where seen.insert(key).inserted { merged.append(key) }
            return merged
        }

        var merged: [String] = []
        var seen = Set<String>()
        for operation in lcsOperations(oldKeys, newKeys) {
            let key: String
            switch operation {
            case let .common(oldIdx, _): key = oldKeys[oldIdx]
            case let .removed(oldIdx):   key = oldKeys[oldIdx]
            case let .added(newIdx):     key = newKeys[newIdx]
            }
            // A key can surface twice when an array element moved; keep the first slot.
            if seen.insert(key).inserted { merged.append(key) }
        }
        return merged
    }

    static func lcsOperations(_ old: [String], _ new: [String]) -> [LCSOperation] {
        let oldCount = old.count
        let newCount = new.count
        if oldCount == 0 { return (0..<newCount).map { .added($0) } }
        if newCount == 0 { return (0..<oldCount).map { .removed($0) } }

        var table = [[Int]](repeating: [Int](repeating: 0, count: newCount + 1), count: oldCount + 1)
        for i in stride(from: oldCount - 1, through: 0, by: -1) {
            for j in stride(from: newCount - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var operations: [LCSOperation] = []
        var i = 0
        var j = 0
        while i < oldCount && j < newCount {
            if old[i] == new[j] {
                operations.append(.common(i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                operations.append(.removed(i))
                i += 1
            } else {
                operations.append(.added(j))
                j += 1
            }
        }
        while i < oldCount { operations.append(.removed(i)); i += 1 }
        while j < newCount { operations.append(.added(j)); j += 1 }
        return operations
    }

    // MARK: Formatting helpers

    static func headerPairs(_ headers: NSDictionary?) -> [(name: String, value: String)] {
        guard let headers = headers as? [String: Any] else { return [] }
        return headers.keys.sorted { $0.lowercased() < $1.lowercased() }.map { key in
            (key, String(describing: headers[key] ?? ""))
        }
    }

    static func durationText(start: String?, end: String?) -> String {
        guard let start = start, let end = end else { return "--" }
        let startValue = (start as NSString).doubleValue
        let endValue = (end as NSString).doubleValue
        guard startValue > 0, endValue > 0 else { return "--" }

        let duration = endValue - startValue
        if duration < 0.001 { return "<1ms" }
        if duration < 1.0 { return "\(Int(duration * 1000))ms" }
        return String(format: "%.1fs", duration)
    }

    static func byteText(_ bytes: UInt) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024)
    }

    static func timeText(_ epoch: String) -> String {
        let value = (epoch as NSString).doubleValue
        guard value > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }

    private static func scalarRow(_ label: String, _ old: String, _ new: String) -> RequestDiffRow {
        if old.isEmpty && new.isEmpty {
            return RequestDiffRow(label: label, oldValue: "--", newValue: "--", change: .same)
        }
        if old.isEmpty { return RequestDiffRow(label: label, oldValue: nil, newValue: display(new), change: .added) }
        if new.isEmpty { return RequestDiffRow(label: label, oldValue: display(old), newValue: nil, change: .removed) }
        return RequestDiffRow(label: label,
                              oldValue: display(old),
                              newValue: display(new),
                              change: old == new ? .same : .changed)
    }

    /// Placeholder so an all-empty section still renders when the filter is off.
    private static func fill(_ rows: [RequestDiffRow]) -> [RequestDiffRow] {
        guard rows.isEmpty else { return rows }
        return [RequestDiffRow(label: "(none)", oldValue: nil, newValue: nil, change: .same)]
    }

    static func display(_ value: String) -> String {
        guard value.count > maxDisplayLength else { return value }
        return String(value.prefix(maxDisplayLength)) + "… (\(value.count) chars)"
    }

    // MARK: Export

    static func plainText(_ result: RequestDiffResult, changesOnly: Bool = false) -> String {
        var lines: [String] = []
        for section in result.sections(changesOnly: changesOnly) {
            lines.append("## \(section.title)  [\(section.changeCount) change\(section.changeCount == 1 ? "" : "s")]")
            for row in section.rows(changesOnly: changesOnly) {
                switch row.change {
                case .same:
                    lines.append("  = \(row.label): \(row.newValue ?? row.oldValue ?? "")")
                case .added:
                    lines.append("  + \(row.label): \(row.newValue ?? "")")
                case .removed:
                    lines.append("  - \(row.label): \(row.oldValue ?? "")")
                case .changed:
                    lines.append("  ~ \(row.label)")
                    lines.append("      - \(row.oldValue ?? "")")
                    lines.append("      + \(row.newValue ?? "")")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
