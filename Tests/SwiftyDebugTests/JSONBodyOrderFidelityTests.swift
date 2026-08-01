//
//  JSONBodyOrderFidelityTests.swift
//  SwiftyDebugTests
//
//  Observed on device: "when I copy a JSON body it does not copy it in the same
//  order as I can preview it. This applies to all JSON in the app."
//
//  `Data.dataToPrettyPrintString()` is the canonical pretty-printer behind every
//  body preview and every body copy in the SDK. It used to round-trip through
//  `JSONSerialization.jsonObject` -> `JSONSerialization.data`, and a Swift
//  dictionary is unordered: the server's key order was destroyed and the writer
//  emitted hash order. Same for the number spelling — `1250.00` came back
//  `1250`, `19.99` came back `19.989999999999998`.
//
//  Every assertion here is on the WHOLE rendered body, at every nesting level,
//  because "the value is present" stayed true through the whole bug.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONBodyOrderFidelityTests: XCTestCase {

    // MARK: - Fixtures

    /// Deliberately NOT alphabetical at any level. Alphabetised, the top level
    /// would read: active, amount, avatarUrl, count, createdAt, currency, id,
    /// items, notes, status, total — nothing like the order below.
    private let serverBody = #"""
    {"status":"ok","id":90071992547409931,"total":19.99,"amount":1250.00,"currency":"GBP","avatarUrl":"https://cdn.example.com/a/ada.png","createdAt":"2026-07-27T08:15:00Z","items":[{"sku":"WIDGET-1","qty":2,"price":9.99},{"qty":1,"sku":"WIDGET-2","price":1.50}],"count":2,"active":true,"notes":null}
    """#

    private let serverTopLevelOrder = ["status", "id", "total", "amount", "currency",
                                       "avatarUrl", "createdAt", "items", "count",
                                       "active", "notes"]

    // MARK: - Helpers

    /// The keys of the object at one indentation level, in the order the text
    /// prints them. Level 1 is the top-level object's own keys.
    private func keys(in pretty: String, atLevel level: Int) -> [String] {
        let indent = String(repeating: "  ", count: level)
        return pretty.split(separator: "\n").compactMap { line -> String? in
            let text = String(line)
            guard text.hasPrefix(indent + "\"") else { return nil }
            // Reject a deeper level, whose indent also starts with this one.
            guard !text.hasPrefix(indent + "  ") else { return nil }
            let after = text.dropFirst(indent.count + 1)
            guard let end = after.firstIndex(of: "\"") else { return nil }
            return String(after[..<end])
        }
    }

    /// Every key in the text, in printed order, at every depth. Catches a nested
    /// object that was alphabetised while the top level happened to survive.
    private func allKeysInPrintedOrder(_ pretty: String) -> [String] {
        pretty.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.hasPrefix("\"") else { return nil }
            let after = trimmed.dropFirst()
            guard let end = after.firstIndex(of: "\"") else { return nil }
            // A quoted array element is not a key; a key is followed by a colon.
            let rest = after[after.index(after: end)...].drop(while: { $0 == " " })
            guard rest.hasPrefix(":") else { return nil }
            return String(after[..<end])
        }
    }

    private func parses(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private func makeTransaction(response: Data?, request: Data? = nil) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com/v1/orders/42")
        model.method = "POST"
        model.statusCode = "200"
        model.mineType = "application/json"
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = String(format: "%f", Date().timeIntervalSince1970 + 0.25)
        model.requestData = request
        model.responseData = response
        return model
    }

    private func sections(for model: NetworkTransaction) -> [NetworkDetailSection] {
        let vc = NetworkDetailViewController()
        vc.httpModel = model
        vc.httpModels = [model]
        vc.setupModels()
        return vc.detailModels
    }

    private func section(_ title: String, in models: [NetworkDetailSection]) -> NetworkDetailSection? {
        models.first { $0.title == title }
    }

    // MARK: - 1. The canonical pretty-printer

    /// The headline defect: preview text in the server's order, at every level.
    func testPrettyPrintPreservesServerKeyOrderAtEveryLevel() throws {
        let pretty = try XCTUnwrap(Data(serverBody.utf8).dataToPrettyPrintString())

        XCTAssertEqual(keys(in: pretty, atLevel: 1), serverTopLevelOrder,
                       "Top-level keys must print in the order the server sent them.")

        // Both array elements disagree on key order with each other; both must
        // keep their OWN order rather than being normalised to one shape.
        XCTAssertEqual(allKeysInPrintedOrder(pretty),
                       serverTopLevelOrder.flatMap { key -> [String] in
                           key == "items" ? ["items", "sku", "qty", "price", "qty", "sku", "price"] : [key]
                       },
                       "Nested objects must each keep their own key order.")
    }

    /// The text on screen and the text the copy button reads have to be the
    /// same bytes, and both have to be what the canonical printer produced.
    /// A second rendering anywhere in between is how they drifted apart.
    func testPreviewTextAndCopySourceAreTheSameBytes() throws {
        let data = Data(serverBody.utf8)
        let canonical = try XCTUnwrap(data.dataToPrettyPrintString())
        let response = try XCTUnwrap(section("RESPONSE", in: sections(for: makeTransaction(response: data))))
        XCTAssertEqual(response.content, canonical, "The preview must be the canonical rendering.")
        XCTAssertEqual(response.rawContent, canonical, "Copy must read the same bytes the preview shows.")
        XCTAssertTrue(parses(canonical))
    }

    /// A number is part of the payload's order fidelity too: `1250.00` is what
    /// the server wrote, and a developer diffing a copy against the real
    /// response should not see it rewritten.
    func testPrettyPrintPreservesNumberSpelling() throws {
        let pretty = try XCTUnwrap(Data(serverBody.utf8).dataToPrettyPrintString())
        XCTAssertTrue(pretty.contains("19.99"), "19.99 must not become 19.989999999999998")
        XCTAssertTrue(pretty.contains("1250.00"), "1250.00 must keep the server's spelling")
        XCTAssertTrue(pretty.contains("1.50"), "1.50 must keep the server's spelling")
        XCTAssertTrue(pretty.contains("90071992547409931"),
                      "A 64-bit id must not be rounded through a Double.")
    }

    /// "when copied it should be valid full JSON without leading or trailing
    /// space" — the maintainer's words.
    func testPrettyPrintHasNoSurroundingWhitespaceAndParses() throws {
        let pretty = try XCTUnwrap(Data(serverBody.utf8).dataToPrettyPrintString())
        XCTAssertEqual(pretty, pretty.trimmingCharacters(in: .whitespacesAndNewlines),
                       "No leading or trailing whitespace on a rendered body.")
        XCTAssertTrue(pretty.hasPrefix("{"))
        XCTAssertTrue(pretty.hasSuffix("}"))
        XCTAssertTrue(parses(pretty))
    }

    func testPrettyPrintLeavesSlashesUnescaped() throws {
        let pretty = try XCTUnwrap(Data(serverBody.utf8).dataToPrettyPrintString())
        XCTAssertTrue(pretty.contains("https://cdn.example.com/a/ada.png"))
        XCTAssertFalse(pretty.contains("\\/"))
    }

    func testPrettyPrintPreservesOrderInsideATopLevelArray() throws {
        let body = #"[{"z":1,"a":2},{"m":3,"b":4}]"#
        let pretty = try XCTUnwrap(Data(body.utf8).dataToPrettyPrintString())
        XCTAssertEqual(allKeysInPrintedOrder(pretty), ["z", "a", "m", "b"])
        XCTAssertTrue(parses(pretty))
    }

    /// Non-JSON must still come back verbatim — the helper is used for every
    /// body, not only JSON ones.
    func testPrettyPrintFallsBackToRawTextForNonJSON() {
        XCTAssertEqual(Data("not json at all".utf8).dataToPrettyPrintString(), "not json at all")
        XCTAssertEqual(Data("<html><body>hi</body></html>".utf8).dataToPrettyPrintString(),
                       "<html><body>hi</body></html>")
    }

    private func arrayBody(rows: Int) -> Data {
        var out: [String] = []
        out.reserveCapacity(rows)
        for i in 0..<rows {
            out.append(#"{"sku":"S-\#(i)","qty":\#(i),"price":19.99}"#)
        }
        return Data(("[" + out.joined(separator: ",") + "]").utf8)
    }

    /// The order-preserving path runs while a detail screen is being built, so
    /// it needs a ceiling. Above it the helper still returns valid JSON
    /// promptly; it simply stops promising source order.
    func testOversizedBodyStillRendersValidJSONPromptly() throws {
        let body = arrayBody(rows: 60_000)
        XCTAssertGreaterThan(body.count, 2 * 1024 * 1024, "Fixture must exceed the ceiling.")

        let start = Date()
        let pretty = try XCTUnwrap(body.dataToPrettyPrintString())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(parses(pretty))
        XCTAssertEqual(pretty, pretty.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertLessThan(elapsed, 5.0, "An oversized body must not freeze the preview path.")
    }

    /// The largest body that DOES take the order-preserving path — the one that
    /// decides whether the ceiling is set somewhere survivable.
    func testLargestOrderPreservingBodyRendersInOrderAndInTime() throws {
        let body = arrayBody(rows: 40_000)
        XCTAssertLessThan(body.count, 2 * 1024 * 1024, "Fixture must sit under the ceiling.")

        let start = Date()
        let pretty = try XCTUnwrap(body.dataToPrettyPrintString())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(parses(pretty))
        XCTAssertTrue(pretty.contains("\"sku\" : \"S-39999\""), "Nothing may be dropped.")
        XCTAssertEqual(Array(allKeysInPrintedOrder(pretty).prefix(6)),
                       ["sku", "qty", "price", "sku", "qty", "price"])
        // ~1.0s measured for this fixture, which is the worst shape there is at
        // the ceiling: 40k array elements means 160k separate index records.
        XCTAssertLessThan(elapsed, 3.0, "The order-preserving path must stay usable at the ceiling.")
    }

    // MARK: - 2. The detail screen — preview text

    func testResponseSectionPreservesServerKeyOrder() throws {
        let model = makeTransaction(response: Data(serverBody.utf8))
        let response = try XCTUnwrap(section("RESPONSE", in: sections(for: model)))
        let content = try XCTUnwrap(response.content)
        XCTAssertEqual(keys(in: content, atLevel: 1), serverTopLevelOrder)
        XCTAssertTrue(parses(content))
    }

    func testRequestSectionPreservesServerKeyOrder() throws {
        let requestBody = #"{"sku":"WIDGET-1","quantity":2,"currency":"GBP","couponCode":"SUMMER","address":{"line2":"","line1":"1 Main St","postcode":"NW1 6XE","country":"GB"},"gift":true,"notes":null}"#
        let model = makeTransaction(response: Data(serverBody.utf8), request: Data(requestBody.utf8))
        let request = try XCTUnwrap(section("REQUEST", in: sections(for: model)))
        let content = try XCTUnwrap(request.content)
        XCTAssertEqual(allKeysInPrintedOrder(content),
                       ["sku", "quantity", "currency", "couponCode", "address",
                        "line2", "line1", "postcode", "country", "gift", "notes"])
        XCTAssertTrue(parses(content))
    }

    // MARK: - 3. The detail screen — what COPY reads

    /// The copy button reads `rawContent`. A body big enough to be shown as a
    /// truncated preview must still put the COMPLETE, ordered, parseable body
    /// there — "not redacted at all", in the maintainer's words.
    func testCopySourceIsTheCompleteBodyNotTheTruncatedPreview() throws {
        var rows: [String] = []
        for i in 0..<400 {
            rows.append(#"{"sku":"WIDGET-\#(i)","qty":\#(i),"price":19.99,"label":"row number \#(i)"}"#)
        }
        // The same top-level shape as `serverBody`, so the order assertion below
        // cannot pass by hash-order coincidence on a three-key object.
        let big = #"{"status":"ok","id":90071992547409931,"total":19.99,"amount":1250.00,"currency":"GBP","avatarUrl":"https://cdn.example.com/a/ada.png","createdAt":"2026-07-27T08:15:00Z","items":["#
            + rows.joined(separator: ",")
            + #"],"count":400,"active":true,"notes":null}"#
        let model = makeTransaction(response: Data(big.utf8))
        let response = try XCTUnwrap(section("RESPONSE", in: sections(for: model)))

        XCTAssertTrue(response.mustInPreview, "Fixture must be large enough to be previewed truncated.")
        let raw = try XCTUnwrap(response.rawContent)
        XCTAssertGreaterThan(raw.count, 10_000)
        XCTAssertTrue(parses(raw), "The copied body must parse as JSON.")
        XCTAssertEqual(raw, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(keys(in: raw, atLevel: 1), serverTopLevelOrder)
        XCTAssertTrue(raw.contains("WIDGET-399"), "The last row must survive into the copy.")
        XCTAssertFalse(raw.hasSuffix("..."), "The copy must not be the truncated preview string.")
    }

    /// The export/share path writes a file from the already-rendered body. It
    /// must not re-serialise it — that is where the server's order was thrown
    /// away a second time, after the preview had got it right.
    func testExportTextKeepsRenderedOrderAndTrims() throws {
        let pretty = try XCTUnwrap(Data(serverBody.utf8).dataToPrettyPrintString())
        let exported = NetworkDetailViewController.exportText(for: "\n  " + pretty + "\n\n")
        XCTAssertEqual(exported, pretty, "Export must ship the rendered bytes, trimmed — not a re-serialisation.")
        XCTAssertEqual(keys(in: exported, atLevel: 1), serverTopLevelOrder)
        XCTAssertTrue(parses(exported))
    }

    func testExportTextKeepsNonJSONVerbatim() {
        XCTAssertEqual(NetworkDetailViewController.exportText(for: "  plain text  "), "plain text")
    }

    // MARK: - 4. The detail screen — the other JSON it renders

    /// A JWT's claims are JSON the server minted, so the same rule applies.
    func testJWTSectionPreservesClaimOrder() throws {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header  = #"{"typ":"JWT","alg":"HS256","kid":"k1"}"#
        let payload = #"{"sub":"user-1","iss":"https://auth.example.com","exp":4102444800,"aud":"app","name":"Ada"}"#
        let token = segment(header) + "." + segment(payload) + ".sig"

        let model = makeTransaction(response: Data(serverBody.utf8))
        model.requestHeaderFields = ["Authorization": "Bearer \(token)"] as NSDictionary

        let jwt = try XCTUnwrap(section("JWT TOKEN", in: sections(for: model)))
        let content = try XCTUnwrap(jwt.content)
        XCTAssertEqual(allKeysInPrintedOrder(content),
                       ["typ", "alg", "kid", "sub", "iss", "exp", "aud", "name"],
                       "JWT header and payload claims must print in the token's own order.")
    }

    /// A form body has a wire order too. Rendering it through a Swift dictionary
    /// gave hash order — not even stable between runs.
    func testFormBodyRendersInWireOrder() throws {
        let model = makeTransaction(response: Data(serverBody.utf8),
                                    request: Data("zeta=1&alpha=2&mike=3&bravo=4".utf8))
        model.requestSerializer = .form
        let request = try XCTUnwrap(section("REQUEST", in: sections(for: model)))
        let content = try XCTUnwrap(request.content)
        XCTAssertEqual(allKeysInPrintedOrder(content), ["zeta", "alpha", "mike", "bravo"])
        XCTAssertTrue(parses(content))
    }

    /// Query parameters are shown as JSON as well, and the URL states an order.
    func testRequestParametersRenderInURLOrder() throws {
        let model = makeTransaction(response: Data(serverBody.utf8))
        model.url = NSURL(string: "https://api.example.com/v1/search?zeta=1&alpha=2&mike=3&bravo=4")
        let params = try XCTUnwrap(section("REQUEST PARAMETERS", in: sections(for: model)))
        let content = try XCTUnwrap(params.content)
        XCTAssertEqual(allKeysInPrintedOrder(content), ["zeta", "alpha", "mike", "bravo"])
        XCTAssertTrue(parses(content))
    }
}
