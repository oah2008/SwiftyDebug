//
//  ResponseRewrite.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import Foundation

/// What a rewrite does to the value(s) its pattern matched.
///
/// These are exactly the edits people were making by hand at an
/// `.afterResponse` breakpoint — "point this URL at staging", "blank this
/// token", "drop this key" — so they can be armed once and applied to every
/// matching response without pausing anything.
enum RewriteAction: Codable, Equatable {
    /// Replace only the host (and optional port/scheme) of a URL value.
    /// `https://google.com/path/a?x=1` + `salla.com` → `https://salla.com/path/a?x=1`
    case replaceHost(String)
    /// Replace host **and** path, keeping the original query string.
    /// `https://google.com/path/a?x=1` + `salla.com/v2/thing`
    ///   → `https://salla.com/v2/thing?x=1`
    case replaceHostAndPath(String)
    /// Write a literal value, keeping the existing value's JSON type.
    case setValue(String)
    /// Substring or regex substitution inside a string value.
    case findReplace(find: String, replace: String, isRegex: Bool)
    /// Delete the matched key (or array element) entirely.
    case removeKey

    /// The redirect mode a host rewrite maps onto, or nil for the other actions.
    /// Both halves of the feature go through `InterceptRule.rewritingURL`, so a
    /// redirect and a rewrite can never disagree about what "change the host" means.
    var redirectMode: RedirectMode? {
        switch self {
        case .replaceHost:        return .host
        case .replaceHostAndPath: return .hostAndPath
        default:                  return nil
        }
    }

    /// The rewrite target for the URL actions ("salla.com", "salla.com/v2/thing").
    var target: String? {
        switch self {
        case .replaceHost(let t), .replaceHostAndPath(let t): return t
        default: return nil
        }
    }

    /// Short label for a picker row.
    var title: String {
        switch self {
        case .replaceHost:        return "Replace host"
        case .replaceHostAndPath: return "Replace host and path"
        case .setValue:           return "Set value"
        case .findReplace:        return "Find and replace"
        case .removeKey:          return "Remove key"
        }
    }

    // MARK: - Codable

    // Hand-written rather than synthesized: rules are exported as JSON that
    // people read and hand-edit (see RuleTransfer), and the synthesized form for
    // an enum with associated values is a nest of single-key objects.
    // This encodes flat: {"type":"replaceHost","value":"salla.com"}.
    private enum CodingKeys: String, CodingKey {
        case type, value, find, replace, isRegex
    }

    private enum Kind: String, Codable {
        case replaceHost, replaceHostAndPath, setValue, findReplace, removeKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown rewrite action \"\(raw)\"")
        }
        switch kind {
        case .replaceHost:
            self = .replaceHost(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case .replaceHostAndPath:
            self = .replaceHostAndPath(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case .setValue:
            self = .setValue(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case .findReplace:
            self = .findReplace(find: try c.decodeIfPresent(String.self, forKey: .find) ?? "",
                                replace: try c.decodeIfPresent(String.self, forKey: .replace) ?? "",
                                isRegex: try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false)
        case .removeKey:
            self = .removeKey
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .replaceHost(let v):
            try c.encode(Kind.replaceHost.rawValue, forKey: .type)
            try c.encode(v, forKey: .value)
        case .replaceHostAndPath(let v):
            try c.encode(Kind.replaceHostAndPath.rawValue, forKey: .type)
            try c.encode(v, forKey: .value)
        case .setValue(let v):
            try c.encode(Kind.setValue.rawValue, forKey: .type)
            try c.encode(v, forKey: .value)
        case .findReplace(let find, let replace, let isRegex):
            try c.encode(Kind.findReplace.rawValue, forKey: .type)
            try c.encode(find, forKey: .find)
            try c.encode(replace, forKey: .replace)
            try c.encode(isRegex, forKey: .isRegex)
        case .removeKey:
            try c.encode(Kind.removeKey.rawValue, forKey: .type)
        }
    }
}

/// One automated edit applied to a matching response body.
///
/// A rewrite is `pattern` (which values) + `action` (what to do to them). It is
/// stored on the `InterceptRule` that already decides *which requests* are
/// affected, so nothing here needs to know about URLs or matching.
struct ResponseRewrite: Codable, Equatable {
    let id: String
    var isEnabled: Bool
    /// A `JSONPathPattern`'s text, e.g. "data.url" or "data.items[*].image".
    var pattern: String
    var action: RewriteAction
    /// Optional user-given name. Empty means "describe yourself".
    var name: String

    init(pattern: String,
         action: RewriteAction,
         isEnabled: Bool = true,
         name: String = "",
         id: String = UUID().uuidString) {
        self.id = id
        self.isEnabled = isEnabled
        self.pattern = pattern
        self.action = action
        self.name = name
    }

    /// Auto-generated when the user does not name it: "data.url -> salla.com".
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }

        let path = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = path.isEmpty ? "(no path)" : path

        switch action {
        case .replaceHost(let target), .replaceHostAndPath(let target):
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "\(subject) -> (no target)" : "\(subject) -> \(t)"
        case .setValue(let value):
            return "\(subject) = \(Self.truncated(value))"
        case .findReplace(let find, let replace, let isRegex):
            let suffix = isRegex ? " (regex)" : ""
            return "\(subject): \"\(Self.truncated(find))\" -> \"\(Self.truncated(replace))\"\(suffix)"
        case .removeKey:
            return "Remove \(subject)"
        }
    }

    private static func truncated(_ text: String, limit: Int = 24) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, pattern, action, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        // An object written deliberately with no flag is armed — same reasoning
        // as MockResponse: the absent-rewrite case is the empty array.
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // Required: a rewrite with no action is not a rewrite. Throwing here lets
        // `Lenient` below drop this one element instead of the whole rule.
        action = try c.decode(RewriteAction.self, forKey: .action)
    }
}

extension ResponseRewrite {

    /// Decodes a list of rewrites, skipping any element this build cannot make
    /// sense of (an action added by a newer version, a hand-edited export).
    ///
    /// A single unknown element must not take the entire `InterceptRule` down
    /// with it — that is how a rule full of working overrides would vanish from
    /// the list after an import.
    struct Lenient: Decodable {
        let rewrite: ResponseRewrite?
        init(from decoder: Decoder) throws {
            rewrite = try? ResponseRewrite(from: decoder)
        }
    }
}
