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

    // MARK: - Regex budget

    /// A time budget for regular-expression matching, shared by every value one
    /// `apply`/`preview` run touches.
    ///
    /// The find/replace pattern is typed by a human and never validated for
    /// cost — only for syntax — and a perfectly ordinary-looking one such as
    /// `^https?://([\w.-]+)+$` backtracks catastrophically. Measured on this
    /// machine against `"https://" + "a"*n + "!"`: 21 chars 0.006 s, 25 chars
    /// 0.148 s, 29 chars 6.3 s, and it keeps multiplying by ~2.6 per character.
    /// That runs on the networking thread for every response a rule matches and
    /// on the main thread for every keystroke in the editor, so it has to be
    /// bounded — and the bound has to be *reported*, because a rewrite that
    /// quietly stopped halfway is exactly the failure this feature must not have.
    final class RegexBudget {

        /// Total matching time one run may spend across every value.
        static let defaultSeconds: TimeInterval = 0.25

        /// Values longer than this (UTF-16 units) are never handed to a regex.
        /// Even a well-behaved pattern is linear in the input, and a single JSON
        /// string inside a 2 MB body can be 2 MB long.
        static let maxInputLength = 20_000

        private var remaining: TimeInterval

        /// True once the budget is spent. Everything after that is refused with
        /// `regexTimeoutMessage` instead of being attempted.
        private(set) var isExhausted: Bool

        init(seconds: TimeInterval = RegexBudget.defaultSeconds) {
            remaining = seconds
            isExhausted = seconds <= 0
        }

        /// Wall-clock deadline for the next match run, or nil when nothing is
        /// left to spend.
        fileprivate func nextDeadline() -> CFAbsoluteTime? {
            guard !isExhausted else { return nil }
            return CFAbsoluteTimeGetCurrent() + remaining
        }

        fileprivate func charge(_ elapsed: TimeInterval, timedOut: Bool) {
            remaining -= elapsed
            if timedOut || remaining <= 0 { isExhausted = true }
        }
    }

    /// Said out loud in the report entry and in the editor's preview rows, so
    /// "it stopped early" can never look like "it matched nothing".
    static let regexTimeoutMessage =
        "the regular expression took too long on this response and was stopped, so the value was left alone"

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

        // `sourceText` is what lets the writer keep the server's original key
        // ORDER and number spelling. Without it, every rewritten response came
        // back alphabetised — a change the server never made.
        let document = JSONDocument(root: root, sourceText: String(data: data, encoding: .utf8))
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
        // One budget for the whole rewrite: a pattern that is slow on one value
        // is slow on all of them, and 500 matched values must not cost 500
        // timeouts on the networking thread.
        let budget = RegexBudget()

        for path in ordered {
            guard let current = document.value(at: path) else { continue }
            switch outcome(of: rewrite.action, on: current, regex: regex, budget: budget) {
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

        let document = JSONDocument(root: root, sourceText: String(data: data, encoding: .utf8))
        var rows: [(path: String, before: String, after: String)] = []
        // Same bound as `apply`, for the same reason — this one runs while the
        // user is typing the pattern, which is when a runaway pattern first
        // exists. See `computePreview()`'s caller: it must not run on the main
        // thread either.
        let budget = RegexBudget()

        for path in paths {
            guard let current = document.value(at: path) else { continue }
            let before = displayText(for: current)
            let after: String
            if let message = preparationError {
                after = "(unchanged — \(message))"
            } else {
                switch outcome(of: rewrite.action, on: current, regex: regex, budget: budget) {
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

    /// - Parameter budget: shared regex time budget for the run. Passing nil
    ///   gives this one value a fresh budget — never an unbounded one.
    static func outcome(of action: RewriteAction, on value: Any,
                        regex: NSRegularExpression?,
                        budget: RegexBudget? = nil) -> ValueOutcome {
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
                switch boundedReplacement(regex, in: text, template: replace,
                                          budget: budget ?? RegexBudget()) {
                case .replaced(let replaced): out = replaced
                case .refused(let message):   return .failed(message)
                }
            } else {
                out = text.replacingOccurrences(of: find, with: replace)
            }
            return out == text ? .unchanged : .newValue(out)

        case .removeKey:
            return .remove
        }
    }

    // MARK: - Bounded regex replacement

    private enum BoundedText {
        case replaced(String)
        case refused(String)
    }

    /// `stringByReplacingMatches`, with a wall-clock bound.
    ///
    /// `stringByReplacingMatches` cannot be interrupted: once ICU enters a
    /// backtracking blow-up it returns when it is finished and not before, which
    /// is the whole defect. `enumerateMatches` with `.reportProgress` *can* be —
    /// ICU calls the block periodically from inside the match loop, and setting
    /// `stop` there aborts mid-backtrack. Measured: the same 29-char input that
    /// takes 6.3 s unbounded returns in 0.250 s here, and 49 chars (which would
    /// take hours) also returns in 0.250 s.
    ///
    /// On a timeout the value is left EXACTLY as it was and the caller is told
    /// why. A partially substituted string is worse than no substitution.
    private static func boundedReplacement(_ regex: NSRegularExpression, in text: String,
                                           template: String, budget: RegexBudget) -> BoundedText {
        let ns = text as NSString
        guard ns.length <= RegexBudget.maxInputLength else {
            return .refused("this value is longer than \(RegexBudget.maxInputLength) characters, "
                            + "so the regular expression was not run on it")
        }
        guard let deadline = budget.nextDeadline() else { return .refused(regexTimeoutMessage) }

        var out = ""
        var cursor = 0
        var timedOut = false
        let started = CFAbsoluteTimeGetCurrent()

        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            if CFAbsoluteTimeGetCurrent() > deadline {
                timedOut = true
                stop.pointee = true
                return
            }
            // A progress-only callback carries no result; there is nothing to
            // copy for it, the deadline check above is its entire purpose.
            guard let result = result else { return }
            let range = result.range
            guard range.location != NSNotFound, range.location >= cursor else { return }
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += regex.replacementString(for: result, in: text, offset: 0, template: template)
            cursor = range.location + range.length
        }

        budget.charge(CFAbsoluteTimeGetCurrent() - started, timedOut: timedOut)
        guard !timedOut else { return .refused(regexTimeoutMessage) }
        out += ns.substring(from: cursor)
        return .replaced(out)
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
            // Double("inf") SUCCEEDS, so the old guard let infinity through and
            // the coercion below wrote 0 into the app's response body, reporting
            // changed=1 with no error. The coder rejects every non-finite spelling.
            guard JSONInlineValueCoder.number(from: trimmed) != nil else {
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
