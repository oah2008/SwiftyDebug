//
//  JSONPathPattern.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import Foundation

/// A path expression that can match many concrete `JSONPath`s.
///
///   "data.url"              exact
///   "data.items[*].url"     every element of an array
///   "**.url"                a key named url ANYWHERE in the tree
///   "data.items[0].url"     a specific index
///   "data.*.url"            any key one level under data
///   "data[\"a.b\"].url"     a key that itself contains a dot
///
/// A pattern is parsed once and matched many times: it is the addressing half of
/// a response rewrite, and the engine runs it on every matching response, so it
/// never allocates a regex and never walks more of the tree than it has to.
///
/// Matching is **deterministic**: arrays are walked in index order and object
/// keys in sorted order. Foundation's JSON objects are `[String: Any]`, which has
/// no key order to preserve, so "document order" is defined as sorted-key order
/// rather than left to hashing — otherwise two runs over the same body could
/// report matches in a different order.
struct JSONPathPattern: Equatable {

    /// One step of the expression.
    enum Token: Equatable {
        case key(String)   // literal object key
        case anyKey        // *   — any key at this level
        case index(Int)    // [n] — one array element
        case anyIndex      // [*] — every array element
        case anyDepth      // **  — zero or more levels, any container
    }

    /// The normalized expression text (trimmed, `root.` / `$.` prefixes removed).
    let text: String
    let tokens: [Token]

    /// Pathological input (a `**` over a deeply nested body) must not hang the
    /// networking thread. The walk stops once it has visited this many nodes and
    /// returns what it found so far.
    static let maxVisitedNodes = 50_000
    /// Upper bound on returned paths, for the same reason.
    static let maxMatches = 2_000

    /// Returns nil when the text is not a usable pattern. There is deliberately
    /// no "empty pattern matches everything" fallback: a rewrite whose pattern
    /// does not parse must be reported as broken, not silently applied to the
    /// whole document.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Self.parse(trimmed), !parsed.isEmpty else { return nil }
        self.text = Self.normalizedText(trimmed)
        self.tokens = parsed
    }

    // MARK: - Parsing

    private static func normalizedText(_ trimmed: String) -> String {
        if trimmed.hasPrefix("root.") { return String(trimmed.dropFirst(5)) }
        if trimmed.hasPrefix("$.")    { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    private static func parse(_ raw: String) -> [Token]? {
        guard !raw.isEmpty else { return nil }
        // The tree editor shows paths as "root.data.url" and JSONPath tools write
        // "$.data.url" — accept both rather than making the user retype.
        let body = normalizedText(raw)
        // The root itself addresses no value, so it cannot be a rewrite target.
        guard !body.isEmpty, body != "root", body != "$" else { return nil }

        let chars = Array(body)
        var tokens: [Token] = []
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "." {
                guard !tokens.isEmpty else { return nil }        // leading "."
                i += 1
                guard i < chars.count, chars[i] != "." else { return nil }  // ".." or trailing "."
                continue
            }

            if c == "[" {
                var j = i + 1
                guard j < chars.count else { return nil }

                // ["quoted key"] — the escape hatch for keys containing . [ ] or *
                if chars[j] == "\"" || chars[j] == "'" {
                    let quote = chars[j]
                    j += 1
                    var key = ""
                    var closed = false
                    while j < chars.count {
                        if chars[j] == "\\", j + 1 < chars.count {
                            key.append(chars[j + 1]); j += 2; continue
                        }
                        if chars[j] == quote { closed = true; j += 1; break }
                        key.append(chars[j]); j += 1
                    }
                    guard closed, j < chars.count, chars[j] == "]", !key.isEmpty else { return nil }
                    tokens.append(.key(key))
                    i = j + 1
                    continue
                }

                var inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                guard j < chars.count else { return nil }        // unterminated "["
                let t = inner.trimmingCharacters(in: .whitespaces)
                if t == "*" {
                    tokens.append(.anyIndex)
                } else if let n = Int(t), n >= 0 {
                    tokens.append(.index(n))
                } else {
                    return nil                                   // "[a]" / "[-1]" / "[]"
                }
                i = j + 1
                continue
            }

            var word = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                word.append(chars[i]); i += 1
            }
            guard !word.isEmpty, !word.contains("]") else { return nil }

            if word == "**" {
                // "**.**.url" would match the same node twice; collapse instead.
                if tokens.last != .anyDepth { tokens.append(.anyDepth) }
            } else if word == "*" {
                tokens.append(.anyKey)
            } else if word.contains("*") {
                // Partial globs ("us*r") are not supported. Refusing to parse is
                // the honest answer — quietly matching nothing is not.
                return nil
            } else {
                tokens.append(.key(word))
            }
        }

        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Matching

    /// Every concrete path this pattern matches inside `root`, in document order
    /// (arrays by index, object keys sorted). Capped by `limit` and by
    /// `maxVisitedNodes`; a truncated walk returns what it found rather than
    /// hanging or throwing.
    func matches(in root: Any, limit: Int = JSONPathPattern.maxMatches) -> [JSONPath] {
        guard limit > 0 else { return [] }
        var results: [JSONPath] = []
        var path: JSONPath = []
        var budget = Self.maxVisitedNodes
        walk(0, root, &path, &results, &budget, limit)

        // `**` in more than one position can reach the same node twice.
        guard results.count > 1 else { return results }
        var seen = Set<String>()
        var unique: [JSONPath] = []
        for p in results where seen.insert(p.display).inserted { unique.append(p) }
        return unique
    }

    /// True when the pattern can match more than one node — the UI uses this to
    /// warn that a rewrite is not surgical.
    var isBroad: Bool {
        tokens.contains { $0 == .anyDepth || $0 == .anyIndex || $0 == .anyKey }
    }

    private func walk(_ ti: Int, _ node: Any, _ path: inout JSONPath,
                      _ results: inout [JSONPath], _ budget: inout Int, _ limit: Int) {
        guard budget > 0, results.count < limit else { return }
        budget -= 1

        guard ti < tokens.count else {
            results.append(path)
            return
        }

        switch tokens[ti] {
        case .key(let k):
            guard let dict = node as? [String: Any], let child = dict[k] else { return }
            path.append(.key(k))
            walk(ti + 1, child, &path, &results, &budget, limit)
            path.removeLast()

        case .anyKey:
            guard let dict = node as? [String: Any] else { return }
            for k in dict.keys.sorted() {
                guard let child = dict[k] else { continue }
                path.append(.key(k))
                walk(ti + 1, child, &path, &results, &budget, limit)
                path.removeLast()
                if budget <= 0 || results.count >= limit { return }
            }

        case .index(let n):
            guard let arr = node as? [Any], n >= 0, n < arr.count else { return }
            path.append(.index(n))
            walk(ti + 1, arr[n], &path, &results, &budget, limit)
            path.removeLast()

        case .anyIndex:
            guard let arr = node as? [Any] else { return }
            for (idx, element) in arr.enumerated() {
                path.append(.index(idx))
                walk(ti + 1, element, &path, &results, &budget, limit)
                path.removeLast()
                if budget <= 0 || results.count >= limit { return }
            }

        case .anyDepth:
            // Zero levels first, so shallower matches come out before deeper ones.
            walk(ti + 1, node, &path, &results, &budget, limit)
            if budget <= 0 || results.count >= limit { return }

            switch node {
            case let dict as [String: Any]:
                for k in dict.keys.sorted() {
                    guard let child = dict[k] else { continue }
                    path.append(.key(k))
                    walk(ti, child, &path, &results, &budget, limit)
                    path.removeLast()
                    if budget <= 0 || results.count >= limit { return }
                }
            case let arr as [Any]:
                for (idx, element) in arr.enumerated() {
                    path.append(.index(idx))
                    walk(ti, element, &path, &results, &budget, limit)
                    path.removeLast()
                    if budget <= 0 || results.count >= limit { return }
                }
            default:
                break
            }
        }
    }

    // MARK: - Text for a concrete path

    /// Pattern text addressing exactly `path` — the inverse of `init?`.
    static func text(for path: JSONPath) -> String {
        render(path, wildcardIndices: false)
    }

    private static func render(_ path: JSONPath, wildcardIndices: Bool) -> String {
        var out = ""
        for component in path {
            switch component {
            case .key(let k):
                if needsQuoting(k) {
                    out += "[\"" + escaped(k) + "\"]"
                } else {
                    if !out.isEmpty { out += "." }
                    out += k
                }
            case .index(let i):
                out += wildcardIndices ? "[*]" : "[\(i)]"
            }
        }
        return out
    }

    private static func needsQuoting(_ key: String) -> Bool {
        key.isEmpty || key.contains(where: { ".[]*\"\\".contains($0) })
    }

    private static func escaped(_ key: String) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Given a concrete path the user tapped, the scope choices to offer, each
    /// with a human label:
    ///
    ///   "Just this one"          data.items[0].url
    ///   "Every item like it"     data.items[*].url
    ///   "Every \"url\" anywhere" **.url
    ///
    /// Returns an empty list for the root, which addresses no value.
    static func scopeOptions(for path: JSONPath) -> [(label: String, pattern: String)] {
        guard !path.isEmpty else { return [] }

        var options: [(label: String, pattern: String)] = []
        var seen = Set<String>()

        func add(_ label: String, _ pattern: String) {
            guard !pattern.isEmpty, JSONPathPattern(pattern) != nil,
                  seen.insert(pattern).inserted else { return }
            options.append((label, pattern))
        }

        add("Just this one", render(path, wildcardIndices: false))

        let hasIndex = path.contains { if case .index = $0 { return true } else { return false } }
        if hasIndex {
            add("Every item like it", render(path, wildcardIndices: true))
        }

        if case .key(let last)? = path.last {
            add("Every \"\(last)\" anywhere", "**." + render([.key(last)], wildcardIndices: false))
        }

        return options
    }
}
