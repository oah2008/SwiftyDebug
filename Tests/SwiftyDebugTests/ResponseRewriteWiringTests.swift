//
//  ResponseRewriteWiringTests.swift
//  SwiftyDebugTests
//
//  Covers the wiring that makes response rewrites actually run, as opposed to
//  the engine that performs them (ResponseRewriteEngineTests).
//
//  Every previous body-editing feature in this file's neighbourhood — mocks,
//  breakpoints — shipped completely inert because `resolvedRule(forURL:)` never
//  copied it into the composite rule. Nothing about that failure is visible: the
//  editor saves, the list shows the rule, and the wire is untouched. These tests
//  exist so that cannot happen a third time.
//

import XCTest
@testable import SwiftyDebug

final class ResponseRewriteWiringTests: XCTestCase {

    private let url = URL(string: "https://api.example.com/api/orders")!

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    private func rule(_ path: String = "/api/orders",
                      rewrites: [ResponseRewrite],
                      isEnabled: Bool = true,
                      order: Int = 0) -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: path, matchMode: .exact)
        rule.responseRewrites = rewrites
        rule.isEnabled = isEnabled
        rule.order = order
        return rule
    }

    // MARK: - The composite must carry the rewrites

    func testResolvedRuleCarriesResponseRewrites() {
        let rewrite = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [rewrite]))

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)

        XCTAssertEqual(resolved?.responseRewrites.count, 1)
        XCTAssertEqual(resolved?.responseRewrites.first?.pattern, "data.url")
        XCTAssertEqual(resolved?.responseRewrites.first?.action, .replaceHost("salla.com"))
        XCTAssertEqual(resolved?.hasActiveResponseRewrites, true)
    }

    func testResolvedRuleWithNoRewritesHasNone() {
        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: []))
        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)
        XCTAssertEqual(resolved?.responseRewrites.isEmpty, true)
        XCTAssertEqual(resolved?.hasActiveResponseRewrites, false)
    }

    // MARK: - A disabled rule contributes nothing

    func testDisabledRuleContributesNoRewrites() {
        let live = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        let dead = ResponseRewrite(pattern: "data.token", action: .setValue("nope"))

        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [live], isEnabled: true, order: 0))
        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [dead], isEnabled: false, order: 1))

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)

        XCTAssertEqual(resolved?.responseRewrites.count, 1)
        XCTAssertEqual(resolved?.responseRewrites.first?.pattern, "data.url")
        XCTAssertFalse(resolved?.responseRewrites.contains { $0.pattern == "data.token" } ?? true)
    }

    func testAllRulesDisabledResolvesToNil() {
        let rewrite = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [rewrite], isEnabled: false))
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: url))
    }

    // MARK: - Several rules compose rather than overwrite

    func testRewritesFromSeveralRulesAccumulateInRuleOrder() {
        // Unlike mock/breakpoint (last-wins), two rules each have something to
        // say about the body and BOTH have to survive composition.
        let first  = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        let second = ResponseRewrite(pattern: "data.token", action: .setValue("test-token"))

        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [first], order: 0))
        InterceptRuleStore.shared.addOrUpdate(rule(rewrites: [second], order: 1))

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)

        XCTAssertEqual(resolved?.responseRewrites.count, 2)
        XCTAssertEqual(resolved?.responseRewrites.map { $0.pattern }, ["data.url", "data.token"])
    }

    func testGlobalAndEndpointRulesBothContribute() {
        var global = InterceptRule(matchEndpoint: "global", matchMode: .global)
        global.responseRewrites = [ResponseRewrite(pattern: "**.url", action: .replaceHost("salla.com"))]
        global.isEnabled = true

        InterceptRuleStore.shared.addOrUpdate(global)
        InterceptRuleStore.shared.addOrUpdate(
            rule(rewrites: [ResponseRewrite(pattern: "data.token", action: .removeKey)]))

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)
        XCTAssertEqual(resolved?.responseRewrites.count, 2)
    }

    /// The whole point of composition: the composite the protocol hands to the
    /// engine produces the same bytes as the rules did individually.
    func testCompositeRewritesActuallyApplyToABody() {
        InterceptRuleStore.shared.addOrUpdate(
            rule(rewrites: [ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))]))

        let resolved = InterceptRuleStore.shared.resolvedRule(forURL: url)
        let body = #"{"data":{"url":"https://google.com/path/to/a"}}"#.data(using: .utf8)!

        let (out, report) = ResponseRewriteEngine.apply(resolved?.responseRewrites ?? [], to: body)

        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.changedCount, 1)
        XCTAssertEqual(String(data: out, encoding: .utf8)?.contains("salla.com"), true)
        XCTAssertEqual(String(data: out, encoding: .utf8)?.contains("google.com"), false)
    }

    // MARK: - The pre-flight filter in CustomHTTPProtocol

    func testMimeTypeFilterAcceptsJSONAndTextAndUnknown() {
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON("application/json"))
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON("application/problem+json"))
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON("Application/JSON"))
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON("text/plain"))
        // No Content-Type at all: let the engine's JSON parse be the judge
        // rather than skipping a body that may well be JSON.
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON(nil))
        XCTAssertTrue(CustomHTTPProtocol.mimeTypeCanBeJSON(""))
    }

    func testMimeTypeFilterRejectsBinaryPayloads() {
        XCTAssertFalse(CustomHTTPProtocol.mimeTypeCanBeJSON("image/png"))
        XCTAssertFalse(CustomHTTPProtocol.mimeTypeCanBeJSON("video/mp4"))
        XCTAssertFalse(CustomHTTPProtocol.mimeTypeCanBeJSON("application/octet-stream"))
        XCTAssertFalse(CustomHTTPProtocol.mimeTypeCanBeJSON("application/pdf"))
    }

    // MARK: - What the transaction records

    func testTransactionRecordsMatchedAndChangedCounts() {
        let rewrite = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        let body = #"{"data":{"url":"https://google.com/a"}}"#.data(using: .utf8)!
        let (_, report) = ResponseRewriteEngine.apply([rewrite], to: body)

        let tx = NetworkTransaction()
        tx.recordRewriteReport(report, rewrites: [rewrite])

        XCTAssertTrue(tx.isResponseRewritten)
        XCTAssertEqual(tx.rewrittenValueCount, 1)
        XCTAssertEqual(tx.rewriteNotes.count, 1)
        XCTAssertTrue(tx.rewriteNotes[0].contains("data.url -> salla.com"))
        XCTAssertTrue(tx.rewriteNotes[0].contains("matched 1, changed 1"))
        XCTAssertTrue(tx.hasRewriteInfo)
    }

    /// A rewrite that matched nothing must SAY it matched nothing.
    func testTransactionSpellsOutAZeroMatch() {
        let rewrite = ResponseRewrite(pattern: "data.nothing.here", action: .replaceHost("salla.com"))
        let body = #"{"data":{"url":"https://google.com/a"}}"#.data(using: .utf8)!
        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: body)

        XCTAssertEqual(out, body, "a zero-match rewrite must not touch a single byte")

        let tx = NetworkTransaction()
        tx.recordRewriteReport(report, rewrites: [rewrite])

        XCTAssertFalse(tx.isResponseRewritten)
        XCTAssertEqual(tx.rewrittenValueCount, 0)
        XCTAssertTrue(tx.hasRewriteInfo, "a no-op rewrite still has to be reported")
        XCTAssertTrue(tx.rewriteNotes[0].contains("matched 0"))
        XCTAssertTrue(tx.rewriteNotes[0].contains("no values matched this path"))
    }

    func testTransactionSurfacesEngineErrors() {
        // A number is not a URL — the engine reports it instead of mangling it.
        let rewrite = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        let body = #"{"data":{"url":3.14}}"#.data(using: .utf8)!
        let (_, report) = ResponseRewriteEngine.apply([rewrite], to: body)

        let tx = NetworkTransaction()
        tx.recordRewriteReport(report, rewrites: [rewrite])

        XCTAssertFalse(tx.isResponseRewritten)
        XCTAssertTrue(tx.rewriteNotes[0].contains("matched 1, changed 0"))
        XCTAssertTrue(tx.rewriteNotes[0].contains("not a URL"))
    }

    func testTransactionSurfacesSkippedReason() {
        let tx = NetworkTransaction()
        tx.recordRewriteReport(RewriteReport(skippedReason: "not JSON"), rewrites: [])

        XCTAssertFalse(tx.isResponseRewritten)
        XCTAssertEqual(tx.rewriteSkippedReason, "not JSON")
        XCTAssertTrue(tx.hasRewriteInfo)
    }

    func testTransactionWithoutRewritesReportsNothing() {
        let tx = NetworkTransaction()
        XCTAssertFalse(tx.hasRewriteInfo)
        XCTAssertFalse(tx.isResponseRewritten)
    }

    // MARK: - The badge survives a pin

    func testPinnedTransactionKeepsTheRewriteBadge() {
        let rewrite = ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        let body = #"{"data":{"url":"https://google.com/a"}}"#.data(using: .utf8)!
        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: body)

        let tx = NetworkTransaction()
        tx.requestId = "rewrite-pin-test-\(UUID().uuidString)"
        tx.url = NSURL(string: "https://api.example.com/api/orders")
        tx.responseData = out
        tx.recordRewriteReport(report, rewrites: [rewrite])
        tx.savePinToDisk()
        defer { tx.removePinFromDisk() }

        let loaded = NetworkTransaction.loadPinnedFromDisk()
            .first { $0.requestId == tx.requestId }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.isResponseRewritten, true)
        XCTAssertEqual(loaded?.rewrittenValueCount, 1)
        XCTAssertEqual(loaded?.rewriteNotes, tx.rewriteNotes)
    }

    // MARK: - Mock and rewrite on the same rule

    func testMockAndRewriteCanBothBeArmedOnOneRule() {
        // They CAN coexist, and the mock wins — it replaces the whole response,
        // so a rewrite never sees a body. The combination must therefore be
        // reported rather than silently ignored: CustomHTTPProtocol.deliverMock
        // records a skippedReason, and the rule editor's footer warns up front.
        var rule = InterceptRule(matchEndpoint: "/api/users")
        rule.mock = MockResponse(isEnabled: true, statusCode: 200, body: "{}")
        rule.responseRewrites = [
            ResponseRewrite(pattern: "data.url", action: .replaceHost("salla.com"))
        ]
        InterceptRuleStore.shared.addOrUpdate(rule)
        defer { InterceptRuleStore.shared.remove(id: rule.id) }

        let resolved = InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://api.example.com/api/users")!)

        XCTAssertEqual(resolved?.mock.isEnabled, true)
        XCTAssertTrue(resolved?.hasActiveResponseRewrites == true,
                      "Both survive composition — the skip has to be reported at delivery, "
                      + "not hidden by dropping one of them here")
    }

    func testSkippedReasonSurvivesOntoTheTransaction() {
        // The path that makes "my rewrite did nothing" answerable.
        let report = RewriteReport(skippedReason: "This response came from a mock.")
        let model = NetworkTransaction()
        model.recordRewriteReport(report, rewrites: [])

        XCTAssertFalse(model.isResponseRewritten)
        XCTAssertTrue(model.hasRewriteInfo,
                      "A skip must still show a section explaining itself")
        XCTAssertEqual(model.rewriteSkippedReason, "This response came from a mock.")
    }
}
