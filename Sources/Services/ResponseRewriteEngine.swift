//
//  ResponseRewriteEngine.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import Foundation

/// What a run of the rewrite engine actually did.
///
/// Every rewrite that ran gets an entry, including the ones that matched
/// nothing — a rule that quietly does nothing is the failure mode this feature
/// has to avoid, so "matched 0" is a reported result, not an absence.
struct RewriteReport: Equatable {

    struct Entry: Equatable {
        let rewriteId: String
        /// Paths the pattern matched.
        let matched: Int
        /// Values that are actually different afterwards.
        let changed: Int
        /// Why nothing (or not everything) changed, e.g. "value is not a URL".
        let error: String?

        init(rewriteId: String, matched: Int, changed: Int, error: String? = nil) {
            self.rewriteId = rewriteId
            self.matched = matched
            self.changed = changed
            self.error = error
        }
    }

    var entries: [Entry]
    var didChange: Bool
    var changedCount: Int
    /// Set when the engine never even looked at the rewrites: body not JSON, body
    /// over `ResponseRewriteEngine.maxBodyBytes`, nothing enabled. The UI shows
    /// this verbatim so "my rewrite did nothing" always has an answer.
    var skippedReason: String?

    init(entries: [Entry] = [], didChange: Bool = false, changedCount: Int = 0, skippedReason: String? = nil) {
        self.entries = entries
        self.didChange = didChange
        self.changedCount = changedCount
        self.skippedReason = skippedReason
    }

    /// True when at least one rewrite ran but matched nothing at all.
    var hasEmptyMatch: Bool { entries.contains { $0.matched == 0 } }

    var errors: [String] { entries.compactMap { $0.error } }
}

/// Applies `ResponseRewrite`s to a JSON response body.
///
/// Pure and allocation-light: it runs on every response that a rule with
/// rewrites matches, on the networking thread, so it bails out before parsing
/// whenever it can and hands back the *original* `Data` — byte for byte — if
/// nothing changed.
enum ResponseRewriteEngine {

    /// Bodies larger than this are left alone. Rewriting means parsing the whole
    /// document into Foundation objects and re-serializing it; doing that to a
    /// multi-megabyte payload on every response is not worth it, and a silent
    /// stall would look exactly like a network hang.
    static let maxBodyBytes = 2 * 1024 * 1024

    // MARK: - Apply

    /// Applies enabled rewrites in order. Returns the original data untouched
    /// when nothing matched or the body is not JSON.
    static func apply(_ rewrites: [ResponseRewrite], to data: Data) -> (data: Data, report: RewriteReport) {
        let enabled = rewrites.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            return (data, RewriteReport(skippedReason: rewrites.isEmpty ? nil : "No rewrite is enabled."))
        }
        guard !data.isEmpty else {
            return (data, RewriteReport(skippedReason: "The response body is empty."))
        }
        guard data.count <= maxBodyBytes else {
            let limit = maxBodyBytes / 1024 / 1024
            return (data, RewriteReport(
                skippedReason: "The response body is larger than \(limit) MB, so rewrites were skipped."))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (data, RewriteReport(skippedReason: "The response body is not JSON, so rewrites were skipped."))
        }

        let document = JSONDocument(root: root)
        var entries: [RewriteReport.Entry] = []
        var changedCount = 0

        // In order: a later rewrite sees what an earlier one wrote.
        for rewrite in enabled {
            let entry = applyOne(rewrite, to: document)
            entries.append(entry)
            changedCount += entry.changed
        }

        guard changedCount > 0 else {
            return (data, RewriteReport(entries: entries, didChange: false, changedCount: 0))
        }
        guard let rewritten = document.data() else {
            return (data, RewriteReport(entries: entries, didChange: false, changedCount: 0,
                                        skippedReason: "The rewritten body could not be re-encoded, so the original was delivered."))
        }
        return (rewritten, RewriteReport(entries: entries, didChange: true, changedCount: changedCount))
    }

    private static func applyOne(_ rewrite: ResponseRewrite, to document: JSONDocument) -> RewriteReport.Entry {
        guard let pattern = JSONPathPattern(rewrite.pattern) else {
            let shown = rewrite.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(rewriteId: rewrite.id, matched: 0, changed: 0,
                         error: shown.isEmpty ? "No path pattern set" : "\"\(shown)\" is not a valid path pattern")
        }

        let paths = pattern.matches(in: document.root)
        guard !paths.isEmpty else {
            // Not an error — but `matched: 0` is the thing the UI must show.
            return .init(rewriteId: rewrite.id, matched: 0, changed: 0)
        }

        // Everything that can fail for the whole rewrite (empty target, bad
        // regex) fails once, here, instead of once per matched value.
        var regex: NSRegularExpression?
        switch prepare(rewrite.action) {
        case .failure(let message):
            return .init(rewriteId: rewrite.id, matched: paths.count, changed: 0, error: message)
        case .ready(let compiled):
            regex = compiled
        }

        // Removing shifts array indices, so deletions run back to front.
        let ordered: [JSONPath] = rewrite.action == .removeKey ? paths.reversed() : paths

        var changed = 0
        var errors: [String] = []

        for path in ordered {
            guard let current = document.value(at: path) else { continue }
            switch outcome(of: rewrite.action, on: current, regex: regex) {
            case .remove:
                if path.isEmpty {
                    errors.append("the whole document cannot be removed")
                } else if document.remove(at: path) {
                    changed += 1
                } else {
                    errors.append("could not remove \(path.display)")
                }
            case .newValue(let value):
                if !isSameJSON(value, current), document.setValue(value, at: path) { changed += 1 }
            case .unchanged:
                break
            case .failed(let message):
                errors.append(message)
            }
        }

        return .init(rewriteId: rewrite.id, matched: paths.count, changed: changed,
                     error: summarize(errors))
    }

    /// One message for the report entry: the first problem, plus how many values
    /// hit it. Callers show this next to "matched N".
    private static func summarize(_ errors: [String]) -> String? {
        guard let first = errors.first else { return nil }
        return errors.count == 1 ? first : "\(first) (\(errors.count) values)"
    }

    // MARK: - Preview

    /// Before/after pairs for the editor's live preview, in document order.
    /// Rows whose value cannot be rewritten are still listed, with the reason in
    /// `after` — an empty result means the pattern matched nothing at all.
    static func preview(_ rewrite: ResponseRewrite, on data: Data,
                        limit: Int) -> [(path: String, before: String, after: String)] {
        guard limit > 0, !data.isEmpty, data.count <= maxBodyBytes,
              let pattern = JSONPathPattern(rewrite.pattern),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }

        let paths = pattern.matches(in: root, limit: limit)
        guard !paths.isEmpty else { return [] }

        var regex: NSRegularExpression?
        var preparationError: String?
        switch prepare(rewrite.action) {
        case .failure(let message): preparationError = message
        case .ready(let compiled):  regex = compiled
        }

        let document = JSONDocument(root: root)
        var rows: [(path: String, before: String, after: String)] = []

        for path in paths {
            guard let current = document.value(at: path) else { continue }
            let before = displayText(for: current)
            let after: String
            if let message = preparationError {
                after = "(unchanged — \(message))"
            } else {
                switch outcome(of: rewrite.action, on: current, regex: regex) {
                case .remove:              after = "(removed)"
                case .newValue(let value): after = isSameJSON(value, current) ? before : displayText(for: value)
                case .unchanged:           after = before
                case .failed(let message): after = "(unchanged — \(message))"
                }
            }
            rows.append((path: path.display, before: before, after: after))
        }
        return rows
    }

    // MARK: - One value, one action

    /// What an action does to a single value. No mutation happens here, so
    /// `apply` and `preview` can never disagree about the result.
    enum ValueOutcome {
        case newValue(Any)
        case remove
        case unchanged
        case failed(String)
    }

    private enum Preparation {
        case ready(NSRegularExpression?)
        case failure(String)
    }

    /// Whole-rewrite validation, done once before touching any value.
    private static func prepare(_ action: RewriteAction) -> Preparation {
        switch action {
        case .replaceHost(let target), .replaceHostAndPath(let target):
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .failure("no replacement host set") : .ready(nil)

        case .findReplace(let find, _, let isRegex) where !isRegex:
            return find.isEmpty ? .failure("nothing to find") : .ready(nil)

        case .findReplace(let find, let replace, _):
            guard !find.isEmpty else { return .failure("nothing to find") }
            guard let regex = try? NSRegularExpression(pattern: find) else {
                return .failure("\"\(find)\" is not a valid regular expression")
            }
            // A template referring to a group that does not exist is a silent
            // empty replacement at best and a raised exception at worst.
            if let missing = missingTemplateGroup(replace, captureGroups: regex.numberOfCaptureGroups) {
                return .failure("the replacement uses $\(missing) but the pattern has "
                                + (regex.numberOfCaptureGroups == 0
                                   ? "no capture groups" : "only \(regex.numberOfCaptureGroups)"))
            }
            return .ready(regex)

        case .setValue, .removeKey:
            return .ready(nil)
        }
    }

    static func outcome(of action: RewriteAction, on value: Any,
                        regex: NSRegularExpression?) -> ValueOutcome {
        switch action {
        case .replaceHost(let target), .replaceHostAndPath(let target):
            guard let mode = action.redirectMode else { return .unchanged }
            guard let text = value as? String else { return .failed("value is not a URL") }
            guard let rewritten = rewrittenURLString(text, mode: mode, target: target),
                  !rewritten.isEmpty else { return .failed("value is not a URL") }
            return rewritten == text ? .unchanged : .newValue(rewritten)

        case .setValue(let text):
            return coerced(text, matchingTypeOf: value)

        case .findReplace(let find, let replace, let isRegex):
            guard let text = value as? String else { return .failed("value is not text") }
            let out: String
            if isRegex {
                guard let regex = regex else { return .failed("invalid regular expression") }
                out = regex.stringByReplacingMatches(in: text,
                                                     range: NSRange(text.startIndex..., in: text),
                                                     withTemplate: replace)
            } else {
                out = text.replacingOccurrences(of: find, with: replace)
            }
            return out == text ? .unchanged : .newValue(out)

        case .removeKey:
            return .remove
        }
    }

    // MARK: - URL rewriting

    /// Rewrites a URL **string** found in a body, reusing the exact logic that
    /// redirects a request (`InterceptRule.rewritingURL`) so the two can never
    /// drift apart. Returns nil when the value is not a URL at all — the caller
    /// reports that and leaves the value alone; a half-rewritten or empty URL is
    /// worse than no rewrite.
    static func rewrittenURLString(_ raw: String, mode: RedirectMode, target: String) -> String? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        guard let comps = URLComponents(string: text) else { return nil }

        // 1. A normal absolute URL: https://google.com/path?x=1
        if comps.scheme != nil, comps.host != nil, let url = URL(string: text) {
            return InterceptRule.rewritingURL(url, mode: mode, target: target)?.absoluteString
        }

        // 2. Protocol-relative: //cdn.google.com/img.png
        if comps.scheme == nil, comps.host != nil, let url = URL(string: "http:" + text) {
            guard let rewritten = InterceptRule.rewritingURL(url, mode: mode, target: target)?.absoluteString
            else { return nil }
            if targetHasScheme(target) { return rewritten }
            return rewritten.hasPrefix("http:") ? String(rewritten.dropFirst("http:".count)) : rewritten
        }

        // 3. Schemeless: google.com/path?x=1 — parse with a stand-in scheme so the
        //    same rewriter runs, then hand it back the way we found it.
        if comps.scheme == nil, comps.host == nil, looksHostPrefixed(text),
           let url = URL(string: "http://" + text) {
            guard let rewritten = InterceptRule.rewritingURL(url, mode: mode, target: target)?.absoluteString
            else { return nil }
            if targetHasScheme(target) { return rewritten }
            return rewritten.hasPrefix("http://") ? String(rewritten.dropFirst("http://".count)) : rewritten
        }

        return nil
    }

    private static func targetHasScheme(_ target: String) -> Bool {
        let lower = target.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// True when a schemeless string starts with something host-shaped, so that
    /// "google.com/a" is rewritten but "3.14", "/relative/path" and "hello" are
    /// reported as not-a-URL instead of being turned into one.
    private static func looksHostPrefixed(_ text: String) -> Bool {
        guard let first = text.first, first != "/", first != "?", first != "#", first != "." else { return false }
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard head.contains("."), !head.hasSuffix(".") else { return false }
        // The last label has to look like a TLD, otherwise "3.14" is a "host".
        guard let tld = head.split(separator: ".").last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }

    // MARK: - Values

    /// Text -> value, keeping the type that is already there.
    ///
    /// Coercion itself is `JSONInlineValueCoder`'s job — the same rules the
    /// editors use, so a value cannot come back a different type depending on
    /// which code path touched it. The one thing added here is refusing the
    /// coder's "unparseable number becomes 0" fallback: that is right for a
    /// typed field in the UI and silent data corruption in an automated rewrite.
    private static func coerced(_ text: String, matchingTypeOf value: Any) -> ValueOutcome {
        switch JSONValueKind.of(value) {
        case .string:
            return .newValue(JSONInlineValueCoder.value(from: text, kind: .string))

        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Int(trimmed) != nil || Double(trimmed) != nil else {
                // Not a number: keep the user's text rather than writing 0.
                return .newValue(text)
            }
            return .newValue(JSONInlineValueCoder.value(from: text, kind: .number))

        case .bool:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let known = ["true", "false", "1", "0", "yes", "no", "on", "off"]
            guard known.contains(trimmed) else { return .newValue(text) }
            return .newValue(JSONInlineValueCoder.value(from: text, kind: .bool))

        case .null:
            // Null has no type to preserve; empty text leaves it null.
            return text.isEmpty ? .unchanged : .newValue(text)

        case .object, .array:
            guard let parsed = JSONDocument(text: text)?.root else {
                return .failed("value is a container — the replacement must be JSON")
            }
            return .newValue(parsed)
        }
    }

    /// JSON-value equality, used to count what actually changed. The kind check
    /// comes first because `NSNumber(true).isEqual(NSNumber(1))` is true, and
    /// turning `true` into `1` is very much a change.
    static func isSameJSON(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default: break
        }
        guard let a = a, let b = b else { return false }
        guard JSONValueKind.of(a) == JSONValueKind.of(b) else { return false }
        return (a as AnyObject).isEqual(b as AnyObject)
    }

    /// Compact one-line text for a value, for preview rows.
    static func displayText(for value: Any?, limit: Int = 200) -> String {
        guard let value = value else { return "" }
        let text: String
        switch JSONValueKind.of(value) {
        case .null:
            text = "null"
        case .object, .array:
            let data = try? JSONSerialization.data(withJSONObject: value,
                                                   options: [.withoutEscapingSlashes, .fragmentsAllowed])
            text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default:
            text = JSONInlineValueCoder.text(for: value)
        }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// The first `$n` in a replacement template that the pattern has no group
    /// for, or nil when the template is safe.
    private static func missingTemplateGroup(_ template: String, captureGroups: Int) -> Int? {
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }          // escaped, not a reference
            guard chars[i] == "$" else { i += 1; continue }
            var j = i + 1
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if let n = Int(digits), n > captureGroups { return n }
            i = digits.isEmpty ? i + 1 : j
        }
        return nil
    }
}
