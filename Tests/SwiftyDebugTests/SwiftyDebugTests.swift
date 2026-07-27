//
//  SwiftyDebugTests.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import XCTest
@testable import SwiftyDebug

final class SwiftyDebugTests: XCTestCase {

    func testSettingsSharedInstance() {
        let settings = Settings.shared
        XCTAssertNotNil(settings)
    }

    func testFullStopOnDisableDefaultsFalse() {
        // The kill-switch defaults to false: shake only hides the overlay unless
        // the user opts in. (See SDK-DISABLE.)
        UserDefaults.standard.removeObject(forKey: SettingsKey.fullStopOnDisable.rawValue)
        XCTAssertFalse(Settings.shared.fullStopOnDisable || UserDefaults.standard.bool(forKey: SettingsKey.fullStopOnDisable.rawValue))
    }

    func testNetworkConditionerDefaultsOff() {
        XCTAssertEqual(NetworkConditionerPreset(rawValue: "off"), .off)
        XCTAssertFalse(NetworkConditionerPreset.off.isActive)
        XCTAssertTrue(NetworkConditionerPreset.threeG.isActive)
        XCTAssertTrue(NetworkConditionerPreset.hundredPercentLoss.dropsAllRequests)
    }

    func testJSONExporterProducesValidJSON() {
        // Objects, arrays and slash-containing values all copy as valid JSON with
        // unescaped slashes. (See COPY.)
        let input = "{\"url\":\"https://a.com/b\",\"n\":1}"
        let out = JSONExporter.clipboardString(from: input)
        XCTAssertTrue(out.contains("https://a.com/b"))
        XCTAssertFalse(out.contains("\\/"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)))

        let arr = "[1,2,3]"
        XCTAssertNotNil(JSONExporter.prettyJSONString(from: arr))

        // Non-JSON is preserved verbatim (trimmed), not indented.
        let plain = "  hello world  "
        XCTAssertEqual(JSONExporter.clipboardString(from: plain), "hello world")
    }

    // MARK: - Breakpoint response delivery

    func testEditedBodyHeadersAreCorrected() {
        // Delivering an edited body behind the ORIGINAL headers is what stopped
        // the app seeing edited data: Content-Length truncated it back to the old
        // length, and a stale Content-Encoding made the client try to gunzip
        // plain text.
        let original: [AnyHashable: Any] = [
            "Content-Length": "12",
            "Content-Encoding": "gzip",
            "Transfer-Encoding": "chunked",
            "Content-Type": "application/json",
            "X-Custom": "keep-me",
        ]
        let edited = CustomHTTPProtocol.headersForEditedBody(original: original, bodyLength: 4096)

        XCTAssertEqual(edited["Content-Length"], "4096")     // corrected
        XCTAssertNil(edited["Content-Encoding"])             // body is already decoded
        XCTAssertNil(edited["Transfer-Encoding"])
        XCTAssertEqual(edited["Content-Type"], "application/json")  // preserved
        XCTAssertEqual(edited["X-Custom"], "keep-me")               // preserved
    }

    func testEditedBodyHeaderMatchingIsCaseInsensitive() {
        // Servers send these in any casing; a case-sensitive check would leave a
        // stale content-length behind and truncate the edited body.
        let original: [AnyHashable: Any] = [
            "content-length": "9999",
            "CONTENT-ENCODING": "br",
        ]
        let edited = CustomHTTPProtocol.headersForEditedBody(original: original, bodyLength: 10)
        XCTAssertEqual(edited["Content-Length"], "10")
        XCTAssertEqual(edited.keys.filter { $0.lowercased() == "content-length" }.count, 1)
        XCTAssertTrue(edited.keys.allSatisfy { $0.lowercased() != "content-encoding" })
    }

    func testResponseForEditedBodyRebuildsStatusAndHeaders() {
        let url = URL(string: "https://a.com/x")!
        let original = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "1", "Content-Type": "application/json"])!
        let rebuilt = CustomHTTPProtocol.responseForEditedBody(original: original, bodyLength: 250)
        XCTAssertEqual(rebuilt?.statusCode, 201)
        XCTAssertEqual(rebuilt?.url, url)
        let len = (rebuilt?.allHeaderFields["Content-Length"] as? String)
            ?? (rebuilt?.allHeaderFields["content-length"] as? String)
        XCTAssertEqual(len, "250")
    }

    func testPausedResponseBodyTextFallsBackToPlainText() {
        // Returning "" for non-JSON was the second reason the app saw no data:
        // the editor seeded an empty string and then delivered it.
        let html = "<html><body>hi</body></html>"
        let paused = BreakpointCenter.PausedRequest(
            stage: .afterResponse,
            request: URLRequest(url: URL(string: "https://a.com")!),
            responseBody: html.data(using: .utf8),
            resume: { _ in }, abort: {})
        XCTAssertEqual(paused.responseBodyText, html)
        XCTAssertFalse(paused.isResponseBodyBinary)
    }

    func testPausedBinaryResponseBodyIsFlagged() {
        let binary = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])   // JPEG header
        let paused = BreakpointCenter.PausedRequest(
            stage: .afterResponse,
            request: URLRequest(url: URL(string: "https://a.com/x.jpg")!),
            responseBody: binary,
            resume: { _ in }, abort: {})
        XCTAssertTrue(paused.isResponseBodyBinary)
    }

    func testExpireRemovesPausedRequestWithoutResumingIt() {
        // The app timed out while the request sat on hold: neither handler may run.
        var resumed = false, aborted = false
        let paused = BreakpointCenter.PausedRequest(
            stage: .afterResponse,
            request: URLRequest(url: URL(string: "https://a.com")!),
            resume: { _ in resumed = true }, abort: { aborted = true })

        BreakpointCenter.shared.park(paused)
        XCTAssertTrue(BreakpointCenter.shared.pausedRequests.contains { $0 === paused })

        BreakpointCenter.shared.expire(paused)
        XCTAssertFalse(BreakpointCenter.shared.pausedRequests.contains { $0 === paused })
        XCTAssertTrue(paused.isSettled)
        XCTAssertFalse(resumed)
        XCTAssertFalse(aborted)

        // An expired request can never be delivered afterwards.
        BreakpointCenter.shared.resume(paused)
        XCTAssertFalse(resumed)
    }

    // MARK: - Rule composition (mock / breakpoint must survive)

    func testResolvedRuleCarriesMockAndBreakpoint() {
        let store = InterceptRuleStore.shared
        store.removeAll()
        defer { store.removeAll() }

        let url = URL(string: "https://compose-test.example.com/api/items/42")!
        var rule = InterceptRule(matchEndpoint: EndpointNormalizer.normalize(url.path), matchMode: .normalized)
        rule.mock = MockResponse(isEnabled: true, statusCode: 418, body: "{\"a\":1}", headers: [], delay: 0)
        rule.breakpointMode = .afterResponse
        rule.isEnabled = true
        store.addOrUpdate(rule)

        // The composite is a NEW InterceptRule — mock/breakpoint were previously
        // dropped here, which silently disabled both features entirely.
        guard let composite = store.resolvedRule(forURL: url) else {
            return XCTFail("rule should match")
        }
        XCTAssertTrue(composite.mock.isEnabled)
        XCTAssertEqual(composite.mock.statusCode, 418)
        XCTAssertEqual(composite.mock.body, "{\"a\":1}")
        XCTAssertEqual(composite.breakpointMode, .afterResponse)
    }

    func testDisabledRuleContributesNoMockOrBreakpoint() {
        let store = InterceptRuleStore.shared
        store.removeAll()
        defer { store.removeAll() }

        let url = URL(string: "https://compose-off.example.com/api/x")!
        var rule = InterceptRule(matchEndpoint: EndpointNormalizer.normalize(url.path), matchMode: .normalized)
        rule.mock = MockResponse(isEnabled: true, statusCode: 500, body: "", headers: [], delay: 0)
        rule.breakpointMode = .beforeSend
        rule.isEnabled = false          // disabled → must not apply
        store.addOrUpdate(rule)

        XCTAssertNil(store.resolvedRule(forURL: url))
    }

    // MARK: - JSON editor engine

    private func makeDoc() -> JSONDocument {
        JSONDocument(text: """
        {"name":"a","count":2,"ok":true,"items":[{"id":1,"title":"x"},{"id":2,"title":"y"}],"nested":{"deep":{"v":"z"}}}
        """)!
    }

    func testJSONReadByPath() {
        let doc = makeDoc()
        XCTAssertEqual(doc.value(at: [.key("name")]) as? String, "a")
        XCTAssertEqual(doc.value(at: [.key("items"), .index(1), .key("title")]) as? String, "y")
        XCTAssertEqual(doc.value(at: [.key("nested"), .key("deep"), .key("v")]) as? String, "z")
        XCTAssertNil(doc.value(at: [.key("items"), .index(9)]))
        XCTAssertNil(doc.value(at: [.key("nope")]))
    }

    func testJSONKindDetectionDistinguishesBoolFromNumber() {
        let doc = makeDoc()
        XCTAssertEqual(doc.kind(at: [.key("ok")]), .bool)      // must NOT be .number
        XCTAssertEqual(doc.kind(at: [.key("count")]), .number)
        XCTAssertEqual(doc.kind(at: [.key("items")]), .array)
        XCTAssertEqual(doc.kind(at: [.key("nested")]), .object)
    }

    func testJSONSetValueDeepAndUndo() {
        let doc = makeDoc()
        XCTAssertTrue(doc.setValue("CHANGED", at: [.key("items"), .index(0), .key("title")]))
        XCTAssertEqual(doc.value(at: [.key("items"), .index(0), .key("title")]) as? String, "CHANGED")
        // Sibling untouched.
        XCTAssertEqual(doc.value(at: [.key("items"), .index(1), .key("title")]) as? String, "y")
        doc.undo()
        XCTAssertEqual(doc.value(at: [.key("items"), .index(0), .key("title")]) as? String, "x")
        doc.redo()
        XCTAssertEqual(doc.value(at: [.key("items"), .index(0), .key("title")]) as? String, "CHANGED")
    }

    func testJSONDuplicateArrayElementInsertsAfter() {
        let doc = makeDoc()
        XCTAssertTrue(doc.duplicateElement(at: [.key("items"), .index(0)]))
        let items = doc.value(at: [.key("items")]) as? [Any]
        XCTAssertEqual(items?.count, 3)
        XCTAssertEqual(doc.value(at: [.key("items"), .index(1), .key("title")]) as? String, "x")
        XCTAssertEqual(doc.value(at: [.key("items"), .index(2), .key("title")]) as? String, "y")
    }

    func testJSONTemplateElementUnionsSiblingKeys() {
        // "Add item" on an array of objects should produce the right shape.
        let doc = JSONDocument(text: #"{"items":[{"id":1,"title":"x"},{"id":2,"extra":true}]}"#)!
        let template = doc.templateElement(forArrayAt: [.key("items")]) as? [String: Any]
        XCTAssertNotNil(template)
        XCTAssertEqual(Set(template!.keys), ["id", "title", "extra"])
        XCTAssertEqual(template?["id"] as? NSNumber, 0)
        XCTAssertEqual(template?["title"] as? String, "")
        XCTAssertEqual(template?["extra"] as? Bool, false)
    }

    func testJSONRenameKeyRefusesToClobber() {
        let doc = makeDoc()
        XCTAssertFalse(doc.renameKey(at: [.key("name")], to: "count"))   // exists
        XCTAssertTrue(doc.renameKey(at: [.key("name")], to: "label"))
        XCTAssertEqual(doc.value(at: [.key("label")]) as? String, "a")
        XCTAssertNil(doc.value(at: [.key("name")]))
    }

    func testJSONRemoveAndAdd() {
        let doc = makeDoc()
        XCTAssertTrue(doc.remove(at: [.key("items"), .index(0)]))
        XCTAssertEqual((doc.value(at: [.key("items")]) as? [Any])?.count, 1)
        XCTAssertTrue(doc.addKey("newKey", value: "v", toObjectAt: []))
        XCTAssertEqual(doc.value(at: [.key("newKey")]) as? String, "v")
        XCTAssertFalse(doc.addKey("newKey", value: "z", toObjectAt: []))  // duplicate
    }

    func testJSONMoveElement() {
        let doc = makeDoc()
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("items")], from: 0, to: 1))
        XCTAssertEqual(doc.value(at: [.key("items"), .index(0), .key("id")] ) as? NSNumber, 2)
    }

    func testJSONChangeKindConverts() {
        let doc = JSONDocument(text: #"{"a":"42","b":true,"c":"x"}"#)!
        doc.changeKind(at: [.key("a")], to: .number)
        XCTAssertEqual(doc.value(at: [.key("a")]) as? NSNumber, 42)
        doc.changeKind(at: [.key("b")], to: .string)
        XCTAssertEqual(doc.value(at: [.key("b")]) as? String, "true")
        doc.changeKind(at: [.key("c")], to: .array)
        XCTAssertEqual((doc.value(at: [.key("c")]) as? [Any])?.count, 1)
    }

    func testJSONSerializationRoundTripAndSlashes() {
        let doc = JSONDocument(text: #"{"url":"https://a.com/b"}"#)!
        let text = doc.prettyText()
        XCTAssertTrue(text.contains("https://a.com/b"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertNotNil(JSONDocument(text: text))
    }

    func testJSONValidateReportsErrors() {
        XCTAssertTrue(JSONDocument.validate(#"{"a":1}"#).isValid)
        XCTAssertTrue(JSONDocument.validate("[1,2]").isValid)
        XCTAssertFalse(JSONDocument.validate("{oops").isValid)
        XCTAssertNotNil(JSONDocument.validate("{oops").error)
    }

    func testJSONTopLevelArrayDocument() {
        // Arrays of objects are the headline use case — must work at the root.
        let doc = JSONDocument(text: #"[{"id":1},{"id":2}]"#)!
        XCTAssertEqual(doc.kind(at: []), .array)
        XCTAssertTrue(doc.duplicateElement(at: [.index(0)]))
        XCTAssertEqual((doc.root as? [Any])?.count, 3)
        XCTAssertTrue(doc.setValue(99, at: [.index(2), .key("id")]))
        XCTAssertEqual(doc.value(at: [.index(2), .key("id")]) as? NSNumber, 99)
    }

    // MARK: - Inspector scoping

    func testSDKOwnedKeysAreIdentified() {
        // SwiftyDebug's own settings live in the HOST APP's defaults domain, so
        // the UserDefaults inspector must be able to exclude them.
        XCTAssertTrue(SettingsKey.isSDKOwned(SettingsKey.monitorMedia.rawValue))
        XCTAssertTrue(SettingsKey.isSDKOwned(SettingsKey.fullStopOnDisable.rawValue))
        XCTAssertTrue(SettingsKey.isSDKOwned("anything_SwiftyDebug"))
        // The host app's own keys must survive.
        XCTAssertFalse(SettingsKey.isSDKOwned("user_token"))
        XCTAssertFalse(SettingsKey.isSDKOwned("mahaly.lastCheckout"))
        XCTAssertFalse(SettingsKey.isSDKOwned("hasSeenOnboarding"))
    }

    func testEverySettingsKeyIsRecognisedAsSDKOwned() {
        // Guards against a future key that doesn't follow the suffix convention
        // silently leaking into the host app's list.
        let allKeys: [SettingsKey] = [
            .shakeGestureEnabled, .debugUIVisible, .bubbleVisible,
            .networkRequestsEnabled, .webNetworkRequestsEnabled, .consoleLogsEnabled,
            .webLogsEnabled, .monitorAllRequests, .monitorMedia,
            .fullStopOnDisable, .networkConditionerPreset,
        ]
        for key in allKeys {
            XCTAssertTrue(SettingsKey.isSDKOwned(key.rawValue), "\(key.rawValue) should be SDK-owned")
        }
    }

    // MARK: - Redirect (Phase 3)

    func testRedirectHostOnlyKeepsPathAndQuery() {
        var rule = InterceptRule(matchEndpoint: "/checkout/{id}")
        rule.redirectMode = .host
        rule.redirectTarget = "mahaly_beta.com"
        let url = URL(string: "https://mahaly.com/checkout/ahsjkjajkdjkajdahdakj?paramter1=alala")!
        let out = rule.redirectedURL(for: url)
        XCTAssertEqual(out?.host, "mahaly_beta.com")
        XCTAssertEqual(out?.path, "/checkout/ahsjkjajkdjkajdahdakj")
        XCTAssertEqual(out?.query, "paramter1=alala")
        XCTAssertEqual(out?.scheme, "https")
    }

    func testRedirectHostAndPathReplacesPathPreservesQuery() {
        // The exact example from the spec.
        var rule = InterceptRule(matchEndpoint: "/checkout/{id}")
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "mahaly_btea.com/checkout/soposopps"
        let url = URL(string: "https://mahaly.com/checkout/kskslklksklslksl?paramter1=alala")!
        let out = rule.redirectedURL(for: url)
        XCTAssertEqual(out?.host, "mahaly_btea.com")
        XCTAssertEqual(out?.path, "/checkout/soposopps")
        XCTAssertEqual(out?.query, "paramter1=alala")
        // Applies to any request sharing the endpoint pattern, not just one id.
        let other = URL(string: "https://mahaly.com/checkout/ZZZZ?paramter1=alala")!
        XCTAssertEqual(rule.redirectedURL(for: other)?.absoluteString,
                       "https://mahaly_btea.com/checkout/soposopps?paramter1=alala")
    }

    func testRedirectHonorsSchemeAndPortAndIgnoresTargetQuery() {
        var rule = InterceptRule(matchEndpoint: "/x")
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "http://localhost:8080/mock/x?ignored=1"
        let url = URL(string: "https://api.example.com/x?keep=1")!
        let out = rule.redirectedURL(for: url)
        XCTAssertEqual(out?.scheme, "http")
        XCTAssertEqual(out?.host, "localhost")
        XCTAssertEqual(out?.port, 8080)
        XCTAssertEqual(out?.path, "/mock/x")
        XCTAssertEqual(out?.query, "keep=1")   // target's ?ignored=1 dropped
    }

    func testRedirectNoneReturnsNil() {
        let rule = InterceptRule(matchEndpoint: "/x")
        XCTAssertNil(rule.redirectedURL(for: URL(string: "https://a.com/x")!))
    }

    func testMediaExtractorDetectsImages() {
        let json = "{\"image\":\"https://cdn.example.com/pic\",\"thumb\":\"https://x.com/a.png\",\"name\":\"n\"}"
        let result = MediaMetadataExtractor.scan(data: Data(json.utf8), requestURL: nil)
        // Both the extensionless key-based URL and the .png URL are detected.
        XCTAssertEqual(result.imageURLs.count, 2)
        XCTAssertTrue(result.topLevelKeys.contains("image"))
    }

    func testDefaultMonitorAllUrlsIsFalse() {
        XCTAssertFalse(SwiftyDebug.monitorAllUrls)
    }

    func testDefaultEnableConsoleLogIsTrue() {
        XCTAssertTrue(SwiftyDebug.enableConsoleLog)
    }

    func testUrlsDefaultEmpty() {
        XCTAssertTrue(SwiftyDebug.urls.isEmpty)
    }
}
