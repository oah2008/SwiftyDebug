//
//  Foundation+Serialization.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

extension String {
    ///JSON/Form format conversion
    func formStringToDictionary() -> [String: Any]? {
        var dictionary = [String: Any]()
        let array = self.components(separatedBy: "&")

        for str in array {
            let arr = str.components(separatedBy: "=")
            if arr.count == 2 {
                dictionary.updateValue(arr[1], forKey: arr[0])
            } else {
                return nil
            }
        }
        if dictionary.count > 0 {
            return dictionary
        }
        return nil
    }
}

extension Data {
    func dataToDictionary() -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: self, options: []) as? [String : Any]
        } catch {
        }
        return nil
    }
}

extension Dictionary {
    func dictionaryToData() -> Data? {
        // `isValidJSONObject` FIRST. `data(withJSONObject:)` raises
        // `NSInvalidArgumentException` — an ObjC exception, which `do/catch`
        // does not catch — for a value JSON cannot express (a non-finite
        // number, a non-string key, any other object). That does not throw,
        // it terminates the host app. The pre-check is the only way to refuse.
        guard JSONSerialization.isValidJSONObject(self) else { return nil }
        do {
            return try JSONSerialization.data(withJSONObject: self, options: .prettyPrinted)
        } catch {
        }
        return nil
    }
}

extension Data {
    func dataToString() -> String? {
        return String(bytes: self, encoding: .utf8)
    }
}

extension String {
    func stringToData() -> Data? {
        return self.data(using: .utf8)
    }
}

extension String {
    func stringToDictionary() -> [String: Any]? {
        return self.stringToData()?.dataToDictionary()
    }
}

extension Dictionary {
    func dictionaryToString() -> String? {
        return self.dictionaryToData()?.dataToString()
    }
}

extension String {
    func formStringToJsonString() -> String? {
        return self.formStringToDictionary()?.dictionaryToString()
    }
}

extension Data {
    /// Try to parse as any valid JSON (dictionary OR array) and return it.
    func dataToJSONObject() -> Any? {
        do {
            return try JSONSerialization.jsonObject(with: self, options: [])
        } catch {}
        return nil
    }

    /// True when these bytes are valid JSON — including a top-level fragment
    /// (`"OK"`, `42`, `true`, `null`), which RFC 8259 allows and which real
    /// endpoints really do return. Parse only: nothing is built from the result,
    /// so this answers "may I call this JSON?" without paying to re-print it.
    var isJSONPayload: Bool {
        (try? JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed])) != nil
    }

    /// Above this many bytes the order-preserving path is skipped. It is the
    /// same ceiling `JSONDocument` stops indexing source order at
    /// (`maxIndexedSourceBytes`), so past it there is no recorded order left to
    /// preserve — worse, `JSONTextWriter` then falls back to `keys.sorted()`
    /// and ALPHABETISES a body no server ever sent. Foundation's writer is the
    /// cheaper way to get an equally unordered answer.
    ///
    /// Not private: `JSONExporter` makes the same call on the same bytes, and
    /// the clipboard is only guaranteed to match the screen while both use one
    /// ceiling. (See COPY.)
    static let maxOrderPreservingBytes = 2 * 1024 * 1024

    /// …and above this many *structural separators*. Bytes alone are the wrong
    /// axis: the order-preserving writer costs ~1 µs per JSON node and almost
    /// nothing per byte, so two 2 MB bodies are 13x apart. Measured on this
    /// machine, order-preserving vs. Foundation:
    ///
    ///     shape                bytes    separators     ordered   Foundation
    ///     object per 13 B    2.10 MB       599,167     1084 ms        87 ms
    ///     50k flat keys      1.63 MB        99,999       84 ms        21 ms
    ///     20k row objects    1.54 MB       219,999      239 ms        38 ms
    ///     150k bare ints     0.94 MB       149,999      326 ms        22 ms
    ///
    /// A byte ceiling of 2 MB therefore admits a 1.1-second freeze while a
    /// detail screen is being built, or while a COPY tap is being handled — both
    /// on the main thread. Bounding nodes instead caps the worst measured shape
    /// near a third of a second and leaves ordinary payloads (a 10k-key object,
    /// a 5k-row array) on the order-preserving path where they belong.
    /// Measured on a FLAT shape. A nested body costs 17-23x Foundation for the
    /// same separator count — 580 KB of `[{"a":{"b":[1,2,3]}}, ...]` sits just
    /// under the old ceiling and still froze the main thread for ~350 ms on a
    /// Mac, several times that on a phone. So the ceiling is lowered to a value
    /// that bounds the WORST shape rather than the average one; ordinary
    /// payloads (a few thousand rows) stay on the order-preserving path.
    static let maxOrderPreservingNodes = 40_000

    /// Nesting is what makes the writer expensive, and the separator count alone
    /// cannot see it. Bracket depth is one more byte-pass and it is what
    /// distinguishes `[{"a":{"b":[1,2,3]}}, ...]` from a flat 10k-key object.
    static let maxOrderPreservingDepth = 24

    /// A count of `,` and `:` bytes — one per array element and two per object
    /// entry, near enough. Deliberately naive: it counts separators inside
    /// string literals too, so it can only ever OVER-estimate, and an
    /// over-estimate costs order preservation, never correctness. One linear
    /// pass, stopped early at the limit; under 0.01 ms at the byte ceiling,
    /// against the hundreds of ms it decides whether to spend.
    /// Deepest bracket nesting, in one linear pass. Strings are not parsed, so a
    /// bracket inside a string literal over-estimates — which costs order
    /// preservation, never correctness, exactly like the separator count.
    private func exceedsOrderPreservingDepth() -> Bool {
        let limit = Self.maxOrderPreservingDepth
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var depth = 0
            var inString = false
            var escaped = false
            for byte in raw {
                if inString {
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { inString = false }
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = true; continue }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                    if depth > limit { return true }
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                }
            }
            return false
        }
    }

    private func exceedsOrderPreservingNodeLimit() -> Bool {
        let limit = Self.maxOrderPreservingNodes
        var seen = 0
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            // Skip string literals. Counting separators INSIDE them meant one
            // long prose value could exceed the limit on its own — a 320 KB body
            // with three real nodes lost the server's key order for no reason.
            var inString = false
            var escaped = false
            for byte in raw {
                if inString {
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { inString = false }
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = true; continue }
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ":") {
                    seen += 1
                    if seen > limit { return true }
                }
            }
            return false
        }
    }

    /// True while re-printing these bytes in the server's own key order is
    /// affordable on the main thread. Both entry points below ask this one
    /// question, so the preview and the clipboard always take the same branch.
    var canPrettyPrintInSourceOrder: Bool {
        count <= Self.maxOrderPreservingBytes
            && !exceedsOrderPreservingNodeLimit()
            && !exceedsOrderPreservingDepth()
    }

    /// Pretty JSON for bytes that ARE JSON; nil for bytes that are not.
    ///
    /// The single implementation behind both the preview and COPY. It returns
    /// JSON or nothing — never a fragment of one, never non-JSON text — so a
    /// caller that needs "valid JSON or say so" can trust the nil.
    /// `ignoringSizeCeiling` is for the COPY path only. The ceiling exists to
    /// protect the MAIN THREAD; copy now runs off it behind a blocking overlay,
    /// so the ceiling would only make a large body copy in a different key order
    /// from the small one beside it — which is the defect, not the protection.
    /// The preview path leaves it at the default and stays bounded.
    func prettyPrintedJSONString(ignoringSizeCeiling: Bool = false) -> String? {
        //1.pretty json in the order the SERVER sent, with every number spelled
        //  the way the server spelled it.
        //
        //  `JSONSerialization.jsonObject` -> `JSONSerialization.data` used to
        //  live here. A Swift dictionary is unordered, so that round-trip threw
        //  the key order away and Foundation's writer re-emitted the keys in
        //  hash order — a body that read nothing like the response, differently
        //  in the preview and in the copy, and differently again between runs.
        //  It also reprinted `1250.00` as `1250` and `19.99` as
        //  `19.989999999999998`. `JSONDocument` keeps a source index of both and
        //  writes through it. (See JSONDocument / JSONTextWriter.)
        //
        //  One parse per call, no caching: the callers are one-shot (building a
        //  detail screen, a copy tap, an export tap), never per-cell and never
        //  per-keystroke.
        if ignoringSizeCeiling || canPrettyPrintInSourceOrder,
           let document = JSONDocument(data: self) {
            // Lifting the printer's ceiling without lifting the DOCUMENT's index
            // ceiling would still hand back sorted keys — the two must move
            // together, which is what the coupling test pins.
            document.indexesSourceRegardlessOfSize = ignoringSizeCeiling
            let text = document.prettyText()
            // `prettyText()` yields "" for a document it cannot represent;
            // fall through rather than shipping an empty body.
            if !text.isEmpty { return text }
        }
        //2.over the ceiling, not UTF-8, or unrepresentable: Foundation's writer.
        //  NOTE: this re-serialises, so it emits Foundation's key order, not the
        //  server's. That is a KNOWN divergence above the ceiling and it is why
        //  COPY passes `ignoringSizeCeiling: true` — the clipboard is the path
        //  the maintainer requires to be faithful at every size, and it now has
        //  an overlay to pay for it. The bounded preview keeps this fallback.
        guard let jsonObject = self.dataToJSONObject() else { return nil }
        //  `isValidJSONObject` FIRST, and not as a formality.
        //
        //  Apple's PARSER accepts a negative literal that overflows a Double —
        //  `[1,-1e999]`, `{"balance":-2e308}` — and hands back `-inf`. Apple's
        //  WRITER then raises `NSInvalidArgumentException` ("Invalid number
        //  value (infinite) in JSON write"), an ObjC exception that `try?` does
        //  not catch, and the host app is killed. Reaching here at all means
        //  step 1 already declined the body, and refusing a non-finite number is
        //  exactly why it declines — so this branch is where such a body lands.
        //  Verified: `isValidJSONObject` is false for `-inf` and `nan`.
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let str = String(data: prettyData, encoding: .utf8) else { return nil }
        return str
    }

    /// The ONE pretty-printer behind every JSON preview in the SDK, and — via
    /// `JSONExporter` — behind every JSON copy. Whatever it returns is what the
    /// user reads on screen AND what lands on the clipboard, so the two can
    /// never disagree.
    ///
    /// Adds one thing to `prettyPrintedJSONString()`: a body that is not JSON at
    /// all (HTML, XML, a plain-text error, a truncated payload) is shown as the
    /// text it is, never dropped and never replaced.
    func dataToPrettyPrintString() -> String? {
        //3.not JSON, or JSON no writer will accept: the original text, verbatim.
        return prettyPrintedJSONString() ?? String(data: self, encoding: .utf8)
    }
}

/// Builds JSON text from key/value pairs that HAVE an order — query items, form
/// fields, multipart parts.
///
/// Putting them in a `[String: Any]` first and asking `JSONSerialization` to
/// print it is what made the rendered body arrive in hash order: `?zeta=1&alpha=2`
/// displayed as `alpha` then `zeta`, or worse, in a different order on the next
/// launch. The pairs are written in the order they were read instead.
enum OrderedJSON {

    /// Pretty JSON for `pairs`, in the given order. A repeated key keeps the
    /// position of its first appearance and the value of its last, which is
    /// exactly what a dictionary did — with the order added back.
    /// Nil when there is nothing to render.
    static func text(from pairs: [(key: String, value: String)]) -> String? {
        var order: [String] = []
        var values: [String: String] = [:]
        order.reserveCapacity(pairs.count)
        for pair in pairs {
            // `updateValue` returns nil the first time a key is seen, which is
            // the appearance whose position is kept.
            if values.updateValue(pair.value, forKey: pair.key) == nil {
                order.append(pair.key)
            }
        }
        guard !order.isEmpty else { return nil }

        var body = ""
        for key in order {
            guard let quotedKey = quoted(key), let quotedValue = quoted(values[key] ?? "") else {
                return nil
            }
            if !body.isEmpty { body += "," }
            body += quotedKey + ":" + quotedValue
        }
        // Back through the canonical printer, so an ordered form body is spaced
        // and indented identically to every other body on the screen.
        return Data(("{" + body + "}").utf8).dataToPrettyPrintString()
    }

    /// A JSON string literal for `text`, escaped by Foundation itself so the
    /// rules match every other body the app renders. Wrapping in an array is
    /// what lets `JSONSerialization` encode a bare string on every OS version.
    private static func quoted(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text],
                                                     options: [.withoutEscapingSlashes]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2 else { return nil }
        return String(wrapped.dropFirst().dropLast())   // strip the array's [ ]
    }
}
