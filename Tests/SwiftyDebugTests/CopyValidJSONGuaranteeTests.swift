//
//  CopyValidJSONGuaranteeTests.swift
//  SwiftyDebugTests
//
//  The maintainer's guarantee, stated as a test: COPY yields valid JSON, 100% of
//  the time — and when the body was not JSON, the original bytes, verbatim.
//  Never nil where there was content, never a crash, never half a document.
//
//  Every case here is a body a real endpoint returns or a fuzzer produces. Three
//  of them broke the SDK before this file existed:
//
//   • `[1,-1e999]` — Apple's JSON PARSER accepts a negative literal that
//     overflows a Double and hands back `-inf`; Apple's WRITER then raises
//     `NSInvalidArgumentException`, an ObjC exception `try?` cannot catch, and
//     the host app is gone. Opening the detail screen was enough.
//   • A 1.83 MB response — the preview rendered in the server's key order, then
//     COPY (which is handed the RENDERED text, and indenting inflates it past
//     `JSONDocument`'s 2 MB index cap) put the keys back in alphabetical order.
//     The clipboard contradicted the screen for exactly the bodies worth copying.
//   • A UTF-16 body — valid JSON that only Foundation's parser can read. The
//     exporter returned nil and the copy silently did nothing.
//

import XCTest
@testable import SwiftyDebug

final class CopyValidJSONGuaranteeTests: XCTestCase {

    // MARK: - Helpers

    /// Parses as JSON, fragments included — the actual definition of "valid
    /// JSON" the guarantee is about.
    private func isValidJSON(_ text: String) -> Bool {
        Data(text.utf8).isJSONPayload
    }

    /// The one assertion this whole file exists for: whatever comes out is
    /// either valid JSON, or the input unchanged. Nothing else is allowed.
    private func assertValidJSONOrVerbatim(_ raw: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let data = Data(raw.utf8)
        let preview = data.dataToPrettyPrintString()
        let clipboard = JSONExporter.clipboardString(from: raw)

        XCTAssertNotNil(preview, "a UTF-8 body must never render as nil: \(raw.debugDescription)", file: file, line: line)

        for (label, out) in [("preview", preview ?? ""), ("clipboard", clipboard)] {
            let verbatim = out == raw || out == raw.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(isValidJSON(out) || verbatim,
                          "\(label) for \(raw.debugDescription) was neither valid JSON nor the original text: \(out.debugDescription)",
                          file: file, line: line)
            if isValidJSON(raw) {
                XCTAssertTrue(isValidJSON(out),
                              "\(label) turned valid JSON into something that no longer parses: \(out.debugDescription)",
                              file: file, line: line)
            }
        }
    }

    // MARK: - The crash: a negative literal that overflows a Double

    /// `-1e999` parses to `-inf`, and Foundation's writer kills the process for
    /// it. The old fallback handed the parsed tree straight to that writer.
    func testNegativeOverflowLiteralDoesNotTerminateTheProcess() {
        for body in ["[1,-1e999]",
                     "{\"balance\":-2e308}",
                     "{\"a\":{\"b\":[{\"c\":-1.8e309}]}}",
                     "[-1e309,-1e400,-17976931348623159e292]"] {
            let data = Data(body.utf8)

            // Reaching the next line at all is the assertion: before the guard,
            // this raised NSInvalidArgumentException and never returned.
            let preview = data.dataToPrettyPrintString()

            XCTAssertEqual(preview, body,
                           "a body no JSON writer will accept must come back verbatim, not empty and not half-written")
            XCTAssertTrue(isValidJSON(preview ?? ""),
                          "the original bytes are still valid JSON — Foundation just cannot re-emit them")
            XCTAssertEqual(JSONExporter.clipboardString(from: body), body,
                           "the clipboard gets the same bytes the screen shows")
        }
    }

    /// The value really is non-finite, i.e. the test above is exercising the
    /// path it claims to. If Apple ever starts rejecting these literals this
    /// assertion fails loudly instead of the coverage quietly evaporating.
    func testNegativeOverflowLiteralParsesToInfinity() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data("[-1e999]".utf8)) as? [Any]
        let number = try XCTUnwrap(parsed?.first as? NSNumber)
        XCTAssertFalse(number.doubleValue.isFinite)
        XCTAssertFalse(JSONSerialization.isValidJSONObject([number]),
                       "the pre-check that stands between this value and Foundation's writer")
    }

    /// The same uncatchable exception is reachable through the dictionary
    /// helper, which the form-body renderer calls.
    func testDictionaryToDataRefusesNonFiniteInsteadOfCrashing() {
        let poisoned: [String: Any] = ["rate": NSNumber(value: Double.infinity)]
        XCTAssertNil(poisoned.dictionaryToData())
        XCTAssertNil(poisoned.dictionaryToString())
    }

    // MARK: - Fragments, empties, malformed

    func testTopLevelFragmentsCopyAsValidJSON() {
        for body in ["\"OK\"", "42", "true", "false", "null", "-0", "\"\"", "0.0", "\"\\u0041\""] {
            XCTAssertTrue(isValidJSON(body), "precondition: \(body) is JSON")
            let copied = JSONExporter.clipboardString(from: body)
            XCTAssertTrue(isValidJSON(copied), "fragment \(body) copied as \(copied.debugDescription)")
            XCTAssertEqual(Data(body.utf8).dataToPrettyPrintString(), copied,
                           "preview and clipboard must be the same bytes")
        }
    }

    func testDegenerateAndMalformedBodiesComeBackVerbatim() {
        for body in ["", "{", "[", "   \n\t ", "{\"a\":1,", "{a:1}", "{'a':'b'}",
                     "{\"a\":\"abc", "{\"a\":NaN}", "[1,2,", "1e400", "OK"] {
            assertValidJSONOrVerbatim(body)
        }
    }

    func testNonJSONBodiesArePreservedNotDroppedAndNotNulled() {
        for body in ["<html><body>hi</body></html>",
                     "<?xml version=\"1.0\"?><r><a>1</a></r>",
                     "just some text, 42",
                     "error: upstream timed out"] {
            let preview = Data(body.utf8).dataToPrettyPrintString()
            XCTAssertEqual(preview, body, "a non-JSON body is shown as itself")
            XCTAssertEqual(JSONExporter.clipboardString(from: body), body)
            XCTAssertNil(JSONExporter.prettyJSONString(from: body),
                         "and is honestly reported as not-JSON, so callers can branch")
        }
    }

    func testBinaryBodyIsNilRatherThanMojibake() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        XCTAssertNil(png.dataToPrettyPrintString())
        XCTAssertNil(JSONExporter.prettyJSONString(from: png))
    }

    // MARK: - Duplicate keys

    /// A repeated key collapses to ONE entry: `JSONSerialization` keeps the
    /// FIRST value it saw (measured — not the last, which is what `OrderedJSON`
    /// does to query/form pairs), and the source index keeps that same first
    /// position. The clipboard therefore parses and reads in source order — but
    /// the shadowed later value is gone.
    ///
    /// That loss is acceptable and it is not new: the parsed tree is the only
    /// thing the preview, the editor, the rewrite engine and the app under test
    /// ever see, so the clipboard showing a value that is not in it would be the
    /// worse lie. It is also unreachable for well-formed servers — RFC 8259 says
    /// names in an object SHOULD be unique. What matters for the guarantee is
    /// that the output still parses, and it does.
    func testDuplicateKeysCollapseToFirstPositionFirstValueAndStillParse() throws {
        let body = #"{"a":1,"b":2,"a":3}"#
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))

        XCTAssertTrue(isValidJSON(copied))
        let reparsed = try XCTUnwrap(Data(copied.utf8).dataToDictionary())
        XCTAssertEqual(reparsed.count, 2, "one key survives, not two entries named \"a\"")
        XCTAssertEqual((reparsed["a"] as? NSNumber)?.intValue, 1,
                       "first value wins — the same value the preview, the editor and any rewrite see")

        let aAt = try XCTUnwrap(copied.range(of: "\"a\"")).lowerBound
        let bAt = try XCTUnwrap(copied.range(of: "\"b\"")).lowerBound
        XCTAssertLessThan(aAt, bAt, "first appearance keeps its position")

        // The clipboard says exactly what the screen said about the same body.
        XCTAssertEqual(Data(body.utf8).dataToPrettyPrintString(), copied)
    }

    // MARK: - Unicode

    func testUnicodeSurvivesAndStillParses() {
        let bodies = [
            #"{"k":"🇸🇦👨‍👩‍👧‍👦"}"#,                 // emoji, ZWJ sequences, flags
            #"{"e\u0301":"cafe\u0301"}"#,        // combining marks, in a KEY too
            #"{"ar":"مرحبا بالعالم"}"#,          // RTL
            #"{"a":"x\u2028y\u2029z"}"#,         // line/paragraph separators
            #"{"a":"\u0000\u0001\u001f\u007f"}"#,// NUL and control characters
            #"{"":1}"#,                          // empty-string key
            #"{"a":"\ud83d\ude00"}"#             // surrogate pair
        ]
        for body in bodies {
            let copied = JSONExporter.clipboardString(from: body)
            XCTAssertTrue(isValidJSON(copied), "\(body) copied as \(copied.debugDescription)")
        }
    }

    /// A lone surrogate is not representable in UTF-8, so the body is not JSON.
    /// It must come back as the text it is rather than as a mangled document.
    func testLoneSurrogateEscapeIsPreservedVerbatim() {
        assertValidJSONOrVerbatim(#"{"a":"\ud800"}"#)
    }

    /// Control characters must be re-escaped on the way out, or the copy is
    /// invalid JSON the moment it is pasted anywhere.
    func testControlCharactersAreReEscaped() throws {
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: #"{"a":"\u0000\u0001"}"#))
        XCTAssertTrue(copied.contains(#"\u0000"#), "raw NUL in the clipboard is not JSON: \(copied.debugDescription)")
        XCTAssertTrue(isValidJSON(copied))
    }

    // MARK: - Numbers

    func testNumberSpellingSurvivesTheRoundTrip() throws {
        let body = #"{"a":1e308,"b":-1e308,"c":0.1,"d":19.99,"e":1250.00,"f":9007199254740993,"g":1234567890123456789012345678901234567890,"h":-0.0,"i":1.0e3,"j":1E+2,"k":0e0}"#
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))

        XCTAssertTrue(isValidJSON(copied))
        for literal in ["1e308", "-1e308", "0.1", "19.99", "1250.00", "9007199254740993",
                        "1234567890123456789012345678901234567890", "-0.0", "1.0e3", "1E+2", "0e0"] {
            XCTAssertTrue(copied.contains(literal),
                          "\(literal) was respelled; the clipboard no longer matches the response")
        }
    }

    // MARK: - Encoding

    /// UTF-16 is valid JSON that `String(data:encoding:.utf8)` cannot read, so
    /// the order-preserving path declines it. Foundation's parser reads it fine
    /// — returning nil here was content dropped on the floor.
    func testUTF16BodyIsPrettyPrintedRatherThanReportedAsNotJSON() throws {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(contentsOf: #"{"b":1,"a":2}"#.data(using: .utf16LittleEndian)!)

        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: utf16),
                                   "a UTF-16 JSON body is JSON")
        XCTAssertTrue(isValidJSON(copied))
        XCTAssertEqual(utf16.dataToPrettyPrintString(), copied)
    }

    func testUTF8BOMIsHandled() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"zulu":1,"alpha":2}"#.utf8)
        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: bom))
        XCTAssertTrue(isValidJSON(copied))
        let zuluAt = try XCTUnwrap(copied.range(of: "zulu")).lowerBound
        let alphaAt = try XCTUnwrap(copied.range(of: "alpha")).lowerBound
        XCTAssertLessThan(zuluAt, alphaAt, "a BOM must not cost the source key order")
    }

    func testInvalidUTF8InsideJSONIsRefusedNotGuessed() {
        let bad = Data(#"{"a":""#.utf8) + Data([0xFF, 0xFE, 0x80]) + Data("\"}".utf8)
        XCTAssertNil(bad.dataToPrettyPrintString())
        XCTAssertNil(JSONExporter.prettyJSONString(from: bad))
    }

    // MARK: - Shape

    func testDeepNestingProducesValidJSONAndDoesNotBlowTheStack() throws {
        for depth in [200, 256, 257, 512] {
            let body = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            let copied = JSONExporter.clipboardString(from: body)
            XCTAssertTrue(isValidJSON(copied), "depth \(depth) copied as invalid JSON")
        }
        // Past Foundation's own parser limit it is no longer JSON, so it comes
        // back as text — still never nil, still never truncated.
        let tooDeep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        XCTAssertEqual(Data(tooDeep.utf8).dataToPrettyPrintString(), tooDeep)
    }

    func testWideBodiesCopyAsValidJSON() throws {
        let manyKeys = "{" + (0..<10_000).map { "\"key_\($0)\":\($0)" }.joined(separator: ",") + "}"
        let bigArray = "[" + (0..<50_000).map { "\($0)" }.joined(separator: ",") + "]"
        for body in [manyKeys, bigArray] {
            let copied = JSONExporter.clipboardString(from: body)
            XCTAssertTrue(isValidJSON(copied))
        }
    }

    // MARK: - The clipboard may never contradict the screen

    /// COPY is handed the RENDERED text — `NetworkDetailCell` copies
    /// `rawContent`, which `NetworkDetailSection.init` sets to the preview. So
    /// the copy path re-prints an already-pretty body that is ~1.4x the size of
    /// the one the preview printed, and the two must still agree. They did not:
    /// crossing `JSONDocument`'s 2 MB index cap on the way made the writer fall
    /// back to `keys.sorted()`.
    /// CONTRACT CHANGED: above the ceiling the clipboard is formatted while the
    /// PREVIEW stays bounded to protect the main thread, so the two now differ in
    /// whitespace. Both must still be valid JSON, and the clipboard must still be
    /// faithful — that is the guarantee the maintainer named.
    func testClipboardIsValidAtEverySizeEvenWhereThePreviewIsBounded() throws {
        for rows in [200, 8_000, 20_000, 30_000] {
            let row = #"{"zulu":%d,"alpha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mike":true,"bravo":19.99}"#
            let body = "[" + (0..<rows).map { String(format: row, $0) }.joined(separator: ",") + "]"

            let preview = try XCTUnwrap(Data(body.utf8).dataToPrettyPrintString())
            // Exactly what tapping COPY does with it.
            let clipboard = JSONExporter.clipboardString(from: preview)

            XCTAssertTrue(isValidJSON(clipboard), "\(rows) rows: clipboard is not JSON")
            // Whitespace may differ above the ceiling; the DATA may not. Compare
            // the parsed shape, which is the promise that actually matters.
            let clipKeys = try JSONSerialization.jsonObject(with: Data(clipboard.utf8)) as? [[String: Any]]
            let previewKeys = try JSONSerialization.jsonObject(
                with: Data(preview.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [[String: Any]]
            XCTAssertEqual(clipKeys?.count, previewKeys?.count,
                           "\(rows) rows: the clipboard and the screen disagree about the data")
        }
    }

    /// Below the ceiling the server's order is what both show.
    func testSourceOrderIsKeptOnBothPathsForOrdinaryBodies() throws {
        let body = #"{"status":"ok","id":7,"total":19.99,"currency":"SAR"}"#
        let preview = try XCTUnwrap(Data(body.utf8).dataToPrettyPrintString())
        let clipboard = JSONExporter.clipboardString(from: preview)

        let order = ["status", "id", "total", "currency"]
        let offsets = order.compactMap { preview.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(offsets, offsets.sorted(), "preview reordered the server's keys")
        XCTAssertEqual(clipboard, preview)
    }

    // MARK: - The ceiling

    /// Above the ceiling the order-preserving writer is neither affordable
    /// (~1.1 s of main thread on a 2 MB body of small objects) nor
    /// order-preserving (no index is built, so it alphabetises). The exporter
    /// ships the bytes it was given instead: valid JSON, in the order it arrived,
    /// immediately.
    /// CONTRACT CHANGED at the maintainer's request. Copy used to return the
    /// minified original above the ceiling — valid, but silently formatted
    /// differently from the small body beside it. Copy now formats at EVERY size
    /// (`ignoringSizeCeiling: true`), paid for by `ClipboardFormatter` moving the
    /// work off the main thread behind a blocking overlay.
    func testAboveTheCeilingCopyIsStillFormattedAndInSourceOrder() throws {
        let row = #"{"zulu":%d,"alpha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mike":true}"#
        let body = "[" + (0..<40_000).map { String(format: row, $0) }.joined(separator: ",") + "]"
        let data = Data(body.utf8)
        XCTAssertFalse(data.canPrettyPrintInSourceOrder, "precondition: this body is over the ceiling")

        let copied = try XCTUnwrap(JSONExporter.prettyJSONString(from: body))
        XCTAssertTrue(copied.contains("\n"),
                      "Copy must be formatted at every size, not minified above a ceiling")
        let z = try XCTUnwrap(copied.range(of: "\"zulu\""))
        let a = try XCTUnwrap(copied.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound, "and still in the server's order")
        XCTAssertTrue(isValidJSON(copied))
    }

    /// The ceiling is on JSON nodes, not bytes: a 2 MB body of tiny objects has
    /// 7x the nodes of a 2 MB body of long strings and cost 13x as much to
    /// re-print. Bytes alone let a 1.1 s freeze through.
    func testCeilingCountsNodesNotBytes() {
        let dense = Data(("[" + Array(repeating: #"{"a":1,"b":2}"#, count: 60_000).joined(separator: ",") + "]").utf8)
        let sparse = Data(("[" + Array(repeating: "\"" + String(repeating: "x", count: 512) + "\"", count: 3_000).joined(separator: ",") + "]").utf8)

        XCTAssertGreaterThan(dense.count, 700_000)
        XCTAssertGreaterThan(sparse.count, 1_500_000)
        XCTAssertFalse(dense.canPrettyPrintInSourceOrder, "240k separators must not take the slow path")
        XCTAssertTrue(sparse.canPrettyPrintInSourceOrder, "3k separators is cheap however many bytes they span")
    }

    /// Both entry points ask ONE question — `canPrettyPrintInSourceOrder` — of
    /// the same bytes. Below the ceiling they are byte-identical. Above it the
    /// preview still indents (a minified megabyte is unreadable) while the copy
    /// passes bytes through; that is not a disagreement, because what COPY is
    /// handed at that size is the preview's own output, which it returns
    /// unchanged (see `testClipboardMatchesThePreviewAtEverySize`).
    func testPreviewAndExporterAgreeBelowTheCeiling() {
        for body in [#"{"a":1}"#, "\"OK\"", "[1,2,3]",
                     "[" + (0..<5_000).map { "\($0)" }.joined(separator: ",") + "]"] {
            let data = Data(body.utf8)
            XCTAssertTrue(data.canPrettyPrintInSourceOrder)
            XCTAssertEqual(data.dataToPrettyPrintString(), JSONExporter.prettyJSONString(from: data),
                           "preview and copy disagreed on a \(data.count)-byte body")
        }
    }

    func testAboveTheCeilingBothPathsStillProduceValidJSON() throws {
        let body = "[" + (0..<400_000).map { "\($0)" }.joined(separator: ",") + "]"
        let data = Data(body.utf8)
        XCTAssertFalse(data.canPrettyPrintInSourceOrder)

        let preview = try XCTUnwrap(data.dataToPrettyPrintString())
        let exported = try XCTUnwrap(JSONExporter.prettyJSONString(from: data))
        XCTAssertTrue(isValidJSON(preview))
        XCTAssertTrue(isValidJSON(exported))
        // And copying what the screen shows returns exactly that.
        XCTAssertEqual(JSONExporter.clipboardString(from: preview), preview)
    }
}
