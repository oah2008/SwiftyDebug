//
//  RuleTransfer.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import Foundation

// MARK: - JSON value

/// A minimal JSON tree used by the transfer layer.
///
/// The importer/exporter deliberately works on raw JSON instead of going straight through
/// `Codable`: a document written by a newer SwiftyDebug can carry rule fields (mock bodies,
/// redirects, breakpoints) and whole sections (mock profiles) that this build has never heard of.
/// Keeping the tree lets those survive a round-trip instead of being silently dropped.
indirect enum TransferJSON: Equatable {
    case object([String: TransferJSON])
    case array([TransferJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(any value: Any) {
        switch value {
        case let dict as [String: Any]:
            var result: [String: TransferJSON] = [:]
            for (key, item) in dict { result[key] = TransferJSON(any: item) }
            self = .object(result)
        case let list as [Any]:
            self = .array(list.map { TransferJSON(any: $0) })
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, item) in dict { result[key] = item.anyValue }
            return result
        case .array(let items): return items.map { $0.anyValue }
        case .string(let text): return text
        case .int(let value):   return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .bool(let value):  return NSNumber(value: value)
        case .null:             return NSNull()
        }
    }

    var objectValue: [String: TransferJSON]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var arrayValue: [TransferJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):    return value
        case .double(let value): return Int(value)
        default:                 return nil
        }
    }

    /// Recursively drops the given keys from every object in the tree.
    func removingKeys(_ keys: Set<String>) -> TransferJSON {
        switch self {
        case .object(let dict):
            var result: [String: TransferJSON] = [:]
            for (key, item) in dict where !keys.contains(key) {
                result[key] = item.removingKeys(keys)
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { $0.removingKeys(keys) })
        default:
            return self
        }
    }

    /// A deterministic textual form used to compare two rules for equality.
    /// Not valid JSON — only stability matters.
    var canonicalDescription: String {
        switch self {
        case .object(let dict):
            let body = dict.keys.sorted().map { key in
                "\(TransferJSON.escape(key)):\(dict[key]!.canonicalDescription)"
            }
            return "{" + body.joined(separator: ",") + "}"
        case .array(let items):
            let parts = items.map { $0.canonicalDescription }
            // `removedHeaderKeys` / `removedQueryParamKeys` are Swift Sets — their JSON order is
            // arbitrary, so a plain string array has to be sorted before it can be compared.
            let isStringSet = items.allSatisfy { if case .string = $0 { return true } else { return false } }
            return "[" + (isStringSet ? parts.sorted() : parts).joined(separator: ",") + "]"
        case .string(let text): return TransferJSON.escape(text)
        case .int(let value):   return String(value)
        case .double(let value): return String(value)
        case .bool(let value):  return value ? "true" : "false"
        case .null:             return "null"
        }
    }

    private static func escape(_ text: String) -> String {
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Errors

enum RuleTransferError: LocalizedError, Equatable {
    case notJSON(String)
    case unsupportedRoot
    case missingRules
    case noValidRules([String])
    case encodingFailed(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .notJSON(let detail):
            return "This is not valid JSON.\n\(detail)"
        case .unsupportedRoot:
            return "Expected a rules document (a JSON object) or a plain array of rules, but found something else."
        case .missingRules:
            return "No \"rules\" section in this document. It may be an export of something else."
        case .noValidRules(let reasons):
            let detail = reasons.prefix(3).joined(separator: "\n")
            return "No usable rules in this document.\n\(detail)"
        case .encodingFailed(let detail):
            return "Could not build the export file.\n\(detail)"
        case .fileWriteFailed(let detail):
            return "Could not write the export file.\n\(detail)"
        }
    }
}

// MARK: - Transfer rule

/// One rule plus the exact JSON object it came from.
struct TransferRule {

    let rule: InterceptRule
    let raw: TransferJSON

    init(rule: InterceptRule) throws {
        let data = try RuleTransferCoding.encoder.encode(rule)
        let object = try JSONSerialization.jsonObject(with: data)
        self.rule = rule
        self.raw = TransferJSON(any: object)
    }

    /// Decodes and sanity-checks one rule object. Throws a human-readable reason so the
    /// import preview can tell the user *which* rule is broken instead of failing wholesale.
    init(raw: TransferJSON, index: Int) throws {
        guard raw.objectValue != nil else {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1) is not a JSON object."])
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: raw.anyValue)
        } catch {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1) could not be read."])
        }
        let decoded: InterceptRule
        do {
            decoded = try RuleTransferCoding.decoder.decode(InterceptRule.self, from: data)
        } catch {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1): \(RuleTransferCoding.describe(error))"])
        }
        guard !decoded.id.isEmpty else {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1) has an empty id."])
        }
        guard !decoded.matchEndpoint.isEmpty else {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1) has an empty match endpoint."])
        }
        if decoded.matchMode == .host && decoded.matchHosts.isEmpty {
            throw RuleTransferError.noValidRules(["Rule #\(index + 1) is a host rule with no hosts."])
        }
        self.rule = decoded
        self.raw = raw
    }

    /// Identity of *what the rule does*, ignoring where it came from.
    ///
    /// `id`s (including the per-pair ids inside header/query overrides) are regenerated on every
    /// edit, and `createdAt` / `order` say when and where a rule sits rather than what it changes —
    /// so two rules that differ only in those are the same rule as far as importing is concerned.
    /// Everything else, including fields this build does not know about, takes part.
    var signature: String {
        var dict = raw.removingKeys(["id"]).objectValue ?? [:]
        dict.removeValue(forKey: "createdAt")
        dict.removeValue(forKey: "order")
        return TransferJSON.object(dict).canonicalDescription
    }

    /// A copy carrying a fresh id. Rewriting the raw JSON (rather than the struct) keeps any
    /// unknown fields attached, and `InterceptRule.id` is a `let` with no other way in.
    func withNewId() -> TransferRule {
        return replacing(["id": .string(UUID().uuidString)]) ?? self
    }

    /// The store keys rules by `matchEndpoint`, and lookup only ever probes `"global"` for global
    /// rules and `"host:<sorted hosts>"` for host rules. A hand-edited document can arrive with a
    /// mismatched key, which would import a rule that silently never fires — so re-key on the way in.
    func normalizedForStorage() -> TransferRule {
        switch rule.matchMode {
        case .global:
            guard rule.matchEndpoint != "global" else { return self }
            return replacing(["matchEndpoint": .string("global")]) ?? self
        case .host:
            let sorted = rule.matchHosts.map { $0.lowercased() }.sorted()
            let key = "host:" + sorted.joined(separator: ",")
            guard rule.matchEndpoint != key || rule.matchHosts != sorted else { return self }
            return replacing([
                "matchEndpoint": .string(key),
                "matchHosts": .array(sorted.map { .string($0) }),
            ]) ?? self
        case .exact, .normalized:
            return self
        }
    }

    private func replacing(_ fields: [String: TransferJSON]) -> TransferRule? {
        guard var dict = raw.objectValue else { return nil }
        for (key, value) in fields { dict[key] = value }
        return try? TransferRule(raw: .object(dict), index: 0)
    }
}

// MARK: - Coding helpers

enum RuleTransferCoding {

    /// Fractional-second ISO-8601 keeps the file readable while surviving a round-trip.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        return isoFormatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        return isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self), let parsed = date(from: text) {
                return parsed
            }
            // The store's own rules.json uses `.deferredToDate`, i.e. seconds since the reference
            // date — accept it so a raw rules.json can be pasted straight in.
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date")
        }
        return decoder
    }()

    /// Turns a `DecodingError` into something a developer can act on.
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context):
            return "wrong type for \"\(path(context))\""
        case .valueNotFound(_, let context):
            return "missing value for \"\(path(context))\""
        case .dataCorrupted(let context):
            let field = path(context)
            return field.isEmpty ? context.debugDescription : "bad value for \"\(field)\""
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        return context.codingPath.map { $0.stringValue }.joined(separator: ".")
    }
}

// MARK: - Document

/// A versioned, self-describing rules file.
///
/// Layout (schema 1):
/// ```
/// {
///   "schemaVersion": 1,
///   "format": "com.swiftydebug.rules",
///   "exportedAt": "2026-07-25T10:00:00.000Z",
///   "app": { "name": …, "bundleId": …, "version": …, "build": … },
///   "rules": [ … ]
/// }
/// ```
/// Sections are additive: a future build may write `"mockProfiles"` alongside `"rules"`, and this
/// build keeps it verbatim rather than choking on it or dropping it. `schemaVersion` is only bumped
/// for a *breaking* change, and even then a newer document is read on a best-effort basis with a
/// warning instead of being rejected.
struct RuleTransferDocument {

    struct AppDescriptor: Equatable {
        var name: String
        var bundleId: String
        var version: String
        var build: String

        static var current: AppDescriptor {
            let info = Bundle.main.infoDictionary ?? [:]
            return AppDescriptor(
                name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "App",
                bundleId: Bundle.main.bundleIdentifier ?? "unknown.bundle",
                version: (info["CFBundleShortVersionString"] as? String) ?? "",
                build: (info["CFBundleVersion"] as? String) ?? ""
            )
        }
    }

    static let currentSchemaVersion = 1
    static let formatIdentifier = "com.swiftydebug.rules"

    let schemaVersion: Int
    let exportedAt: Date
    let app: AppDescriptor
    let rules: [TransferRule]
    /// Sections this build does not understand, kept so re-exporting does not strip a teammate's data.
    let unknownSections: [String: TransferJSON]
    /// Non-fatal problems found while decoding — surfaced in the import preview.
    let warnings: [String]

    init(rules: [TransferRule],
         app: AppDescriptor = .current,
         exportedAt: Date = Date(),
         schemaVersion: Int = RuleTransferDocument.currentSchemaVersion,
         unknownSections: [String: TransferJSON] = [:],
         warnings: [String] = []) {
        self.rules = rules
        self.app = app
        self.exportedAt = exportedAt
        self.schemaVersion = schemaVersion
        self.unknownSections = unknownSections
        self.warnings = warnings
    }

    // MARK: Encoding

    func jsonObject() -> TransferJSON {
        var root: [String: TransferJSON] = unknownSections
        root["schemaVersion"] = .int(schemaVersion)
        root["format"] = .string(Self.formatIdentifier)
        root["exportedAt"] = .string(RuleTransferCoding.string(from: exportedAt))
        root["app"] = .object([
            "name": .string(app.name),
            "bundleId": .string(app.bundleId),
            "version": .string(app.version),
            "build": .string(app.build),
        ])
        root["rules"] = .array(rules.map { $0.raw })
        return .object(root)
    }

    /// Pretty-printed and key-sorted so the file diffs cleanly when checked into a repo.
    func jsonData() throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: jsonObject().anyValue,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw RuleTransferError.encodingFailed(error.localizedDescription)
        }
    }

    func jsonText() throws -> String {
        return String(data: try jsonData(), encoding: .utf8) ?? ""
    }

    // MARK: Decoding

    static func decode(_ text: String) throws -> RuleTransferDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuleTransferError.notJSON("The text is empty.") }
        guard let data = trimmed.data(using: .utf8) else {
            throw RuleTransferError.notJSON("The text is not UTF-8.")
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> RuleTransferDocument {
        guard !data.isEmpty else { throw RuleTransferError.notJSON("The file is empty.") }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw RuleTransferError.notJSON(error.localizedDescription)
        }

        let root = TransferJSON(any: parsed)
        var warnings: [String] = []
        let ruleObjects: [TransferJSON]
        var unknown: [String: TransferJSON] = [:]
        var schemaVersion = currentSchemaVersion
        var exportedAt = Date()
        var app = AppDescriptor(name: "Unknown", bundleId: "unknown.bundle", version: "", build: "")

        if let list = root.arrayValue {
            // Leniency: the store's own rules.json is a bare array. Accept it as a headerless document.
            ruleObjects = list
            warnings.append("No document header — read as a plain list of rules.")
        } else if let object = root.objectValue {
            guard let list = object["rules"]?.arrayValue else {
                throw RuleTransferError.missingRules
            }
            ruleObjects = list

            if let version = object["schemaVersion"]?.intValue {
                schemaVersion = version
                if version > currentSchemaVersion {
                    warnings.append("Written by a newer SwiftyDebug (schema \(version)). Unknown fields are kept but not applied.")
                }
            }
            if let text = object["exportedAt"]?.stringValue, let date = RuleTransferCoding.date(from: text) {
                exportedAt = date
            }
            if let appObject = object["app"]?.objectValue {
                app = AppDescriptor(
                    name: appObject["name"]?.stringValue ?? "Unknown",
                    bundleId: appObject["bundleId"]?.stringValue ?? "unknown.bundle",
                    version: appObject["version"]?.stringValue ?? "",
                    build: appObject["build"]?.stringValue ?? ""
                )
            }
            let known: Set<String> = ["schemaVersion", "format", "exportedAt", "app", "rules"]
            for (key, value) in object where !known.contains(key) {
                unknown[key] = value
            }
            if !unknown.isEmpty {
                warnings.append("Ignored section\(unknown.count == 1 ? "" : "s"): \(unknown.keys.sorted().joined(separator: ", ")).")
            }
        } else {
            throw RuleTransferError.unsupportedRoot
        }

        var rules: [TransferRule] = []
        var rejections: [String] = []
        for (index, object) in ruleObjects.enumerated() {
            do {
                rules.append(try TransferRule(raw: object, index: index))
            } catch let error as RuleTransferError {
                if case .noValidRules(let reasons) = error { rejections.append(contentsOf: reasons) }
            } catch {
                rejections.append("Rule #\(index + 1): \(error.localizedDescription)")
            }
        }

        guard !rules.isEmpty else {
            throw RuleTransferError.noValidRules(rejections.isEmpty ? ["The \"rules\" list is empty."] : rejections)
        }
        if !rejections.isEmpty {
            warnings.append("Skipped \(rejections.count) unreadable rule\(rejections.count == 1 ? "" : "s"): \(rejections.prefix(3).joined(separator: "; "))")
        }

        return RuleTransferDocument(
            rules: rules,
            app: app,
            exportedAt: exportedAt,
            schemaVersion: schemaVersion,
            unknownSections: unknown,
            warnings: warnings
        )
    }
}

// MARK: - Export

enum RuleExporter {

    /// Builds a document from live rules. Rules that somehow fail to encode are dropped rather
    /// than failing the whole export — a debug tool should still hand over the other nine.
    static func makeDocument(from rules: [InterceptRule],
                             app: RuleTransferDocument.AppDescriptor = .current,
                             exportedAt: Date = Date()) -> RuleTransferDocument {
        let transferRules = rules.compactMap { try? TransferRule(rule: $0) }
        return RuleTransferDocument(rules: transferRules, app: app, exportedAt: exportedAt)
    }

    /// Writes the document to a uniquely named temp folder and returns the file URL, ready to hand
    /// to `UIActivityViewController`. A fresh folder per export keeps the meaningful file name
    /// while avoiding collisions with a share still in flight.
    static func writeToTemporaryFile(_ document: RuleTransferDocument) throws -> URL {
        let data = try document.jsonData()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftyDebugRuleExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(fileName(for: document))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw RuleTransferError.fileWriteFailed(error.localizedDescription)
        }
    }

    static func fileName(for document: RuleTransferDocument) -> String {
        return fileName(bundleId: document.app.bundleId)
    }

    static func fileName(bundleId: String) -> String {
        return "SwiftyDebug-Rules-\(sanitize(bundleId)).json"
    }

    private static func sanitize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "app" : cleaned
    }
}

// MARK: - Import

enum RuleImportStrategy {
    /// Keep everything already on the device, add what is new, re-id anything that clashes.
    case merge
    /// Wipe the device's rules and install exactly what the document says.
    case replace
}

/// How a single incoming rule relates to what is already on the device.
enum RuleImportDisposition {
    /// Same rule, already present — merge skips it.
    case duplicate
    /// The id is taken by a *different* rule — merge adds this one under a fresh id.
    case idCollision
    /// Not seen before.
    case new
}

struct PlannedRule {
    let transferRule: TransferRule
    let disposition: RuleImportDisposition
}

/// What an import *would* do, computed before anything is written.
struct RuleImportPlan {

    let document: RuleTransferDocument
    let planned: [PlannedRule]
    let existingCount: Int

    var newRules: [PlannedRule] { planned.filter { $0.disposition == .new } }
    var duplicates: [PlannedRule] { planned.filter { $0.disposition == .duplicate } }
    var idCollisions: [PlannedRule] { planned.filter { $0.disposition == .idCollision } }

    /// e.g. "12 rules · 3 already exist · 1 id conflict"
    var summary: String {
        var parts = ["\(planned.count) rule\(planned.count == 1 ? "" : "s")"]
        if !duplicates.isEmpty { parts.append("\(duplicates.count) already exist\(duplicates.count == 1 ? "s" : "")") }
        if !idCollisions.isEmpty { parts.append("\(idCollisions.count) id conflict\(idCollisions.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// The concrete outcome of an import — returned by `resolve` before touching the store so the
/// result can be unit-tested and shown to the user.
struct RuleImportOutcome: Equatable {
    let clearedExisting: Bool
    let added: [InterceptRule]
    let skipped: Int
    let reIdentified: Int

    var message: String {
        var parts = ["Added \(added.count) rule\(added.count == 1 ? "" : "s")"]
        if skipped > 0 { parts.append("skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")") }
        if reIdentified > 0 { parts.append("re-numbered \(reIdentified) conflicting id\(reIdentified == 1 ? "" : "s")") }
        if clearedExisting { parts.append("replaced everything that was there") }
        return parts.joined(separator: ", ") + "."
    }

    static func == (lhs: RuleImportOutcome, rhs: RuleImportOutcome) -> Bool {
        return lhs.clearedExisting == rhs.clearedExisting
            && lhs.added.map { $0.id } == rhs.added.map { $0.id }
            && lhs.skipped == rhs.skipped
            && lhs.reIdentified == rhs.reIdentified
    }
}

/// Collision policy — an imported rule never overwrites a rule that is already on the device:
///
/// * identical content (whatever the id) → skipped, so re-importing the same file is a no-op;
/// * id already used by a *different* rule → imported under a freshly generated id, both survive;
/// * otherwise → added as-is, keeping its id so the same file imports identically everywhere.
///
/// Replace is the only destructive path and it is always confirmed by the user first.
enum RuleImporter {

    static func plan(_ document: RuleTransferDocument, existing: [InterceptRule]) -> RuleImportPlan {
        var takenIds = Set(existing.map { $0.id })
        var signatures = Set(existing.compactMap { try? TransferRule(rule: $0).signature })

        var planned: [PlannedRule] = []
        for transferRule in document.rules {
            let normalized = transferRule.normalizedForStorage()
            let disposition: RuleImportDisposition
            if signatures.contains(normalized.signature) {
                disposition = .duplicate
            } else if takenIds.contains(normalized.rule.id) {
                disposition = .idCollision
            } else {
                disposition = .new
            }
            // Track as we go so two rules inside one document collide with each other too.
            signatures.insert(normalized.signature)
            takenIds.insert(normalized.rule.id)
            planned.append(PlannedRule(transferRule: normalized, disposition: disposition))
        }

        return RuleImportPlan(document: document, planned: planned, existingCount: existing.count)
    }

    /// Pure: works out exactly which rules would be written, without touching the store.
    static func resolve(_ plan: RuleImportPlan, strategy: RuleImportStrategy) -> RuleImportOutcome {
        switch strategy {
        case .replace:
            // The document is the truth — ids and all — so the same file lands identically
            // on every device. Intra-document duplicates are still worth dropping.
            var seen = Set<String>()
            var added: [InterceptRule] = []
            var skipped = 0
            for item in plan.planned {
                guard seen.insert(item.transferRule.signature).inserted else {
                    skipped += 1
                    continue
                }
                added.append(item.transferRule.rule)
            }
            return RuleImportOutcome(clearedExisting: true, added: added, skipped: skipped, reIdentified: 0)

        case .merge:
            var added: [InterceptRule] = []
            var skipped = 0
            var reIdentified = 0
            for item in plan.planned {
                switch item.disposition {
                case .duplicate:
                    skipped += 1
                case .idCollision:
                    reIdentified += 1
                    added.append(item.transferRule.withNewId().rule)
                case .new:
                    added.append(item.transferRule.rule)
                }
            }
            return RuleImportOutcome(clearedExisting: false, added: added, skipped: skipped, reIdentified: reIdentified)
        }
    }

    /// Applies the plan to the shared store.
    @discardableResult
    static func apply(_ plan: RuleImportPlan, strategy: RuleImportStrategy) -> RuleImportOutcome {
        let outcome = resolve(plan, strategy: strategy)
        if outcome.clearedExisting {
            InterceptRuleStore.shared.removeAll()
        }
        // Sorted by the document's own ordering so rules keep their relative priority per endpoint.
        // Swift's sort is not stable and every fresh rule defaults to order 0, so
        // sorting on `order` alone would install same-endpoint rules in an
        // arbitrary sequence — and rule order decides which one wins on conflict.
        // The document's own sequence is the tiebreak.
        let ordered = outcome.added.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map { $0.element }
        for rule in ordered {
            InterceptRuleStore.shared.addOrUpdate(rule)
        }
        return outcome
    }
}
