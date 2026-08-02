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
    ///
    /// Shares one implementation with the preview — `Data.prettyPrintedJSONString()`
    /// — for three reasons, all of which were live defects on the copy button:
    ///
    ///  • ORDER. A Swift dictionary is unordered, so a `JSONSerialization`
    ///    round-trip re-emits the server's keys in hash order and respells its
    ///    numbers. The preview and the clipboard then disagreed about the same
    ///    body. `JSONDocument` keeps a source index of the original key order and
    ///    number spelling and writes through it.
    ///  • A CRASH. This function read with `.fragmentsAllowed` and wrote WITHOUT
    ///    it, so a top-level fragment — a body of `"OK"` or `42` or `true` —
    ///    parsed and then raised `NSInvalidArgumentException` ("Invalid top-level
    ///    type in JSON write"). That is an ObjC exception, so `try?` does not
    ///    catch it: tapping COPY terminated the host app.
    ///  • AGREEMENT AT SCALE. Calling `JSONDocument` here directly, with no
    ///    ceiling, made the clipboard contradict the screen for exactly the
    ///    bodies that most need copying. COPY is handed the RENDERED text
    ///    (`NetworkDetailCell` copies `rawContent`, which is the preview), and
    ///    indenting inflates it: a 1.83 MB response renders as 2.51 MB, which is
    ///    over `JSONDocument`'s 2 MB indexing cap, so the writer had no recorded
    ///    order and emitted `keys.sorted()`. The screen said
    ///    `zulu, alpha, mike, bravo`; the clipboard said `alpha, bravo, mike, zulu`.
    ///    It also spent 1.8 s of main thread on a 10 MB body doing it.
    ///
    /// So: re-print while re-printing is affordable AND order-preserving;
    /// otherwise ship the bytes we were given. Above the ceiling those bytes are
    /// already valid JSON in the server's order — they are the preview — and
    /// returning them is both instant and, by construction, identical to what is
    /// on screen. The only thing given up is re-indenting a body that came in
    /// minified and over the ceiling; it is still copied as valid JSON.
    static func prettyJSONString(from data: Data) -> String? {
        // NO minified shortcut here any more. Copy is the feature the maintainer
        // cares about most, and returning the un-formatted original above a
        // ceiling meant a big body copied differently from the small one beside
        // it, silently. The cost is real, so `ClipboardFormatter` moves it off the
        // main thread behind an overlay that says what is happening — which is
        // the honest trade, rather than quietly copying less than was asked for.
        //
        // Callers that must NOT block (a preview being rendered, a cell) go
        // through `Data.dataToPrettyPrintString()`, which keeps its own ceiling.
        // Everything else, including the one case the branch above cannot serve:
        // JSON that is not UTF-8 at all. A UTF-16 body is valid JSON that only
        // Foundation's parser can read, and returning nil for it was a copy that
        // silently did nothing.
        return data.prettyPrintedJSONString(ignoringSizeCeiling: true)
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
