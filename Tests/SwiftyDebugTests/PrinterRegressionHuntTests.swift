//
//  PrinterRegressionHuntTests.swift
//  SwiftyDebugTests
//
//  An adversarial audit of the round that moved the canonical pretty-printer off
//  `JSONSerialization` and onto `JSONDocument`. Not the happy path — that is
//  already covered by JSONBodyOrderFidelityTests / ClipboardJSONFidelityTests.
//  These are the inputs a real API actually emits and the inputs written to break
//  a parser, driven through the real functions and the real screen builder.
//
//  Two of them are REGRESSION GUARDS and pass. Three of them are DEFECTS found by
//  this audit; they are wrapped in `XCTExpectFailure` so the suite stays honest
//  and green while naming what is wrong. Fixing any of them turns the test into
//  an "unexpectedly passed" failure — which is the signal to delete the
//  expectation, not the test.
//
//  Defects live in files this audit does not own. See the report.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class PrinterRegressionHuntTests: XCTestCase {

    // MARK: - 1. GUARD: no overflowing literal may reach Foundation's writer

    /// Apple's JSON *parser* accepts a negative literal that overflows a Double
    /// and hands back `-inf`; Apple's JSON *writer* then raises
    /// `NSInvalidArgumentException`, an ObjC exception `try?` cannot catch, and
    /// the host app dies. (Positive overflow is refused at parse time — the
    /// asymmetry is Foundation's, and it is why this only ever showed up on a
    /// negative number.)
    ///
    /// Every entry point has to decline such a body rather than re-print it.
    /// Reproduced before the guard existed: `Data("{\"a\":-1e999}".utf8)
    /// .dataToPrettyPrintString()` terminated the process inside
    /// `+[NSJSONSerialization dataWithJSONObject:options:error:]`.
    func testNoOverflowingLiteralEverReachesFoundationsWriter() throws {
        let bodies = [
            #"{"a":-1e999}"#,
            #"{"balance":-2e308,"currency":"USD"}"#,     // a money field, one exponent too far
            #"[1,-1e999]"#,
            #"{"a":{"b":[-1e400]}}"#,                    // nested, so a shallow check would miss it
            #"{"a": -1e999 }"#,                          // spaced, as a pretty-printer would emit it
            #"-1e999"#,                                  // top-level fragment
        ]

        for body in bodies {
            let data = Data(body.utf8)

            // The premise, checked on THIS OS rather than assumed: the parser
            // really does produce a non-finite number for these bytes.
            let parsed = try XCTUnwrap(
                try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                "\(body): Foundation refused to parse it, so this case no longer tests anything")
            XCTAssertFalse(JSONSerialization.isValidJSONObject(parsed) && Self.isFinite(parsed),
                           "\(body): expected a non-finite number in the parsed tree")

            // Nothing re-prints it …
            XCTAssertNil(data.prettyPrintedJSONString(),
                         "\(body): the JSON printer must decline a body it cannot write")
            XCTAssertNil(JSONExporter.prettyJSONString(from: body),
                         "\(body): COPY must decline it rather than hand it to Foundation")

            // … and every caller still gets the bytes the server sent.
            XCTAssertEqual(data.dataToPrettyPrintString(), body,
                           "\(body): the preview must fall back to the raw text")
            XCTAssertEqual(JSONExporter.clipboardString(from: body), body,
                           "\(body): the clipboard must still carry valid JSON — the original")
        }
    }

    /// True when every number in the tree is finite.
    private static func isFinite(_ value: Any) -> Bool {
        switch value {
        case let dict as [String: Any]: return dict.values.allSatisfy(isFinite)
        case let array as [Any]:        return array.allSatisfy(isFinite)
        case let number as NSNumber:    return number.doubleValue.isFinite
        default:                        return true
        }
    }

    // MARK: - 2. GUARD: the screen and the clipboard say the same thing

    /// COPY is handed the RENDERED text (`NetworkDetailCell` copies
    /// `rawContent`, which is what the preview put on screen), so the clipboard
    /// has to be a no-op on it — at every size, on both sides of both ceilings.
    /// Indenting inflates a body past the byte ceiling on its own, which is
    /// exactly how the two used to end up on different branches.
    func testTheClipboardIsANoOpOnWhateverThePreviewRendered() throws {
        for (label, raw) in [("small", Self.orderedBody(rows: 1)),
                             ("mid", Self.orderedBody(rows: 2_000)),
                             ("over the node ceiling", Self.bareIntBody(count: 160_000))] {
            let data = Data(raw.utf8)
            let preview = try XCTUnwrap(data.dataToPrettyPrintString(), label)
            XCTAssertEqual(JSONExporter.clipboardString(from: preview), preview,
                           "\(label): copying what is on screen changed it")
            // And whatever branch it took, the bytes are still JSON.
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(preview.utf8),
                                                             options: [.fragmentsAllowed]),
                            "\(label): the preview is not valid JSON")
        }
    }

    // MARK: - 3. DEFECT: a long string value costs the body its key order

    /// `Data.exceedsOrderPreservingNodeLimit()` counts every `,` and `:` byte in
    /// the payload, *including the ones inside string literals*. A body whose
    /// structure is three keys, but one of whose values is a long CSV report — or
    /// a double-encoded JSON blob, or an HTML fragment, all of which real
    /// endpoints return — is therefore judged too complex to print in order, and
    /// falls through to Foundation, which alphabetises it.
    ///
    /// The comment on the counter says an over-estimate "costs order
    /// preservation, never correctness". Order preservation IS the correctness
    /// this round was about: the body below renders `report, alpha, zulu` where
    /// the server sent `report, zulu, alpha`.
    func testSeparatorsInsideAStringLiteralShouldNotCostTheBodyItsKeyOrder() throws {
        // 320 KB of payload; exactly three JSON nodes.
        let report = String(repeating: "a,", count: 160_000)
        let body = #"{"report":""# + report + #"","zulu":1,"alpha":2}"#
        let data = Data(body.utf8)

        // Ground truth, outside the expectation: this really is a three-key body
        // and it really is under the byte ceiling.
        let tree = try XCTUnwrap(data.dataToJSONObject() as? [String: Any])
        XCTAssertEqual(tree.count, 3)
        XCTAssertLessThan(data.count, Data.maxOrderPreservingBytes)

        // Fixed: both byte scanners now skip string literals, so a long prose
        // value no longer costs the body its source key order.
        do {
            XCTAssertTrue(data.canPrettyPrintInSourceOrder,
                          "a 3-node body is not too complex to print in order")

            let pretty = data.dataToPrettyPrintString() ?? ""
            let zulu = pretty.range(of: "\"zulu\"")?.lowerBound
            let alpha = pretty.range(of: "\"alpha\"")?.lowerBound
            if let zulu, let alpha {
                XCTAssertLessThan(zulu, alpha,
                                  "the server sent zulu before alpha; the screen shows the alphabet")
            } else {
                XCTFail("neither key survived the render")
            }
        }
    }

    // MARK: - 4. DEFECT: the log detail screen lost its plain-text formatting

    /// `JsonViewController` switched its JSON branch to `dataToPrettyPrintString()`,
    /// whose last resort is `String(data:encoding:.utf8)` — never nil for text
    /// that came from a `String` in the first place. So the `else` branch that
    /// calls `formatPlainContent` (red ERROR/FAULT keywords, orange warnings,
    /// underlined URLs, coloured numbers) is now unreachable, and every non-JSON
    /// log line is rendered by `highlightJSON` in flat grey.
    ///
    /// Drives the real builder the screen uses.
    func testAPlainTextLogStillGetsItsErrorKeywordHighlighting() throws {
        let line = "ERROR: upload failed for https://api.example.com/v1/assets after 3 retries"
        let model = LogRecord(content: line, color: nil, fileInfo: "NSLog",
                              isTag: false, type: .none)
        model.content = line

        let rendered = JsonViewController.buildLogDetailAttributedString(model: model)
        let text = rendered.string as NSString

        // The premise: the printer really does swallow this line, so the screen's
        // JSON branch is the one that runs.
        XCTAssertNotNil(Data(line.utf8).dataToPrettyPrintString(),
                        "the printer would have to return nil for the plain-text branch to run")
        XCTAssertNil(Data(line.utf8).prettyPrintedJSONString(),
                     "this line is not JSON — the screen has a way to know that")

        let errorRange = text.range(of: "ERROR", options: .backwards)
        XCTAssertNotEqual(errorRange.location, NSNotFound, "the log line is not on screen at all")

        XCTExpectFailure("""
            DEFECT: JsonViewController's plain-text branch is unreachable, so a \
            non-JSON log line loses its keyword, URL and number highlighting.
            """) {
            let colour = rendered.attribute(.foregroundColor, at: errorRange.location,
                                            effectiveRange: nil) as? UIColor
            XCTAssertEqual(colour, .systemRed, "ERROR should still be red")

            let urlRange = text.range(of: "https://api.example.com/v1/assets")
            if urlRange.location != NSNotFound {
                let underline = rendered.attribute(.underlineStyle, at: urlRange.location,
                                                   effectiveRange: nil)
                XCTAssertNotNil(underline, "the URL should still be underlined")
            }
        }
    }

    // MARK: - 5. DEFECT: "number (decimal)" produces an integer

    /// `JSONArrayShapeReader.shape(_:from:depth:)` goes out of its way to hand
    /// back `NSNumber(value: 0.0)` for a column of prices and `NSNumber(value: 0)`
    /// for a column of ids — "a column of prices must not hand back an integer 0
    /// and re-type itself". But `JSONTextWriter.integerText(for:)` prints any
    /// double that is exactly an integer without its fraction, and
    /// `JSONInlineValueCoder.text(for:)` shows `stringValue`, which is "0" for
    /// both. The two branches are indistinguishable in the document, on the wire
    /// and in the value editor: only the menu subtitle differs.
    func testAddingAnItemToAColumnOfPricesProducesADecimal() throws {
        let prices = try XCTUnwrap(JSONDocument(data: Data(#"{"c":[19.99,5.00]}"#.utf8)))
        let ids = try XCTUnwrap(JSONDocument(data: Data(#"{"c":[1,2]}"#.utf8)))

        let priceTemplate = prices.arrayElementTemplate(forArrayAt: [.key("c")])
        let idTemplate = ids.arrayElementTemplate(forArrayAt: [.key("c")])

        // The premise: the reader really does believe it is looking at decimals.
        XCTAssertTrue(priceTemplate.summary.contains("decimal"), priceTemplate.summary)
        XCTAssertFalse(idTemplate.summary.contains("decimal"), idTemplate.summary)

        prices.appendElement(priceTemplate.value, toArrayAt: [.key("c")])
        ids.appendElement(idTemplate.value, toArrayAt: [.key("c")])

        XCTExpectFailure("""
            DEFECT: the decimal/integer split in the array-shape reader is inert — \
            both templates render as `0` in the document and as "0" in the editor.
            """) {
            XCTAssertNotEqual(prices.minifiedText(), #"{"c":[19.99,5.00,0]}"#,
                              "a price column gained an integer element")
            XCTAssertNotEqual(
                (priceTemplate.value as? NSNumber)?.stringValue,
                (idTemplate.value as? NSNumber)?.stringValue,
                "the editor shows the same text for both, so the distinction is invisible")
        }
    }

    // MARK: - Fixtures

    /// Keys deliberately neither alphabetical nor hash-ordered.
    private static func orderedBody(rows: Int) -> String {
        let items = (0..<rows).map {
            "{\"zulu\":\($0),\"alpha\":\"row-\($0)\",\"mike\":\(Double($0) + 0.25),\"bravo\":true}"
        }
        return "{\"items\":[" + items.joined(separator: ",") + "],\"zebra\":1,\"apple\":2}"
    }

    /// Small bytes, huge node count — the shape the node ceiling exists for.
    private static func bareIntBody(count: Int) -> String {
        "{\"zulu\":1,\"alpha\":2,\"nums\":[" + (0..<count).map(String.init).joined(separator: ",") + "]}"
    }
}
