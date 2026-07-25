//
//  JSONExporter.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Single canonical producer of valid, copy/share-ready JSON, plus a temp-file
/// export helper. Backs both COPY (valid-JSON clipboard) and EXPORT-SHARE
/// (share as a `.json` file). Guarantees the output is byte-for-byte valid JSON
/// with no leading whitespace per line and slashes left unescaped.
enum JSONExporter {

    /// Returns a pretty-printed, valid JSON string for the given text if it
    /// parses as JSON (object OR array OR fragment). Returns nil if the text is
    /// not valid JSON. Never adds per-line leading whitespace beyond JSON's own
    /// indentation, and does not escape forward slashes.
    static func prettyJSONString(from text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        return prettyJSONString(from: data)
    }

    /// Pretty-prints JSON data if it parses; nil otherwise.
    static func prettyJSONString(from data: Data) -> String? {
        // `.fragmentsAllowed` lets top-level strings/numbers/bools through too.
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes]
        guard let pretty = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Returns a clipboard-ready string for arbitrary content: valid pretty JSON
    /// when the input is JSON, otherwise the original text trimmed of surrounding
    /// whitespace (so a JSON payload is always valid, and non-JSON is preserved
    /// verbatim without added indentation). This is the fix for the "copy JSON
    /// adds a leading space / is invalid" bug. (See COPY.)
    static func clipboardString(from text: String) -> String {
        if let json = prettyJSONString(from: text) { return json }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File export

    /// Writes `contents` to a temporary `.json` (or given extension) file and
    /// returns its URL, for sharing via `UIActivityViewController`. Uses a
    /// stable, sanitized filename so repeated exports overwrite rather than leak.
    static func writeTemporaryFile(contents: String, suggestedName: String, fileExtension: String = "json") -> URL? {
        let safeName = sanitizeFilename(suggestedName)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftyDebugExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(safeName).\(fileExtension)")
        do {
            try contents.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = trimmed.isEmpty ? "export" : trimmed
        return String(base.prefix(80))
    }
}
