//
//  InterceptRuleQueryEncodingTests.swift
//  SwiftyDebugTests
//
//  Pins the fix for the signed-URL corruption in `CustomHTTPProtocol`.
//
//  The rule-application block used to round-trip every matched request's URL
//  through `URLComponents.queryItems`, guarded only by "some rule matched".
//  That re-encodes the WHOLE query with Foundation's rules, so
//
//      in : ...?X-Amz-Signature=ab%2Bcd%2Fef%3D%3D
//      out: ...?X-Amz-Signature=ab+cd/ef%3D%3D
//
//  One enabled rule with a single HEADER override was therefore enough to break
//  every signed URL it matched, surfacing as a backend 403 SignatureDoesNotMatch
//  that looks like a server problem.
//
//  Two guarantees are pinned here:
//    1. A rule that edits no query parameters leaves the URL BYTE-IDENTICAL.
//    2. When a parameter IS edited, every other parameter keeps its exact
//       original percent-encoding.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleQueryEncodingTests: XCTestCase {

    // MARK: - Fixtures

    /// A realistic AWS SigV4 presigned URL: the signature contains `+`, `/` and
    /// `=` escaped as `%2B`, `%2F` and `%3D`, which is exactly what naive
    /// re-encoding destroys.
    private let signedURLString =
        "https://bucket.s3.amazonaws.com/report.pdf"
        + "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
        + "&X-Amz-Credential=AKIA%2F20260727%2Fus-east-1%2Fs3%2Faws4_request"
        + "&X-Amz-Date=20260727T101500Z"
        + "&X-Amz-Expires=900"
        + "&X-Amz-SignedHeaders=host"
        + "&X-Amz-Signature=ab%2Bcd%2Fef%3D%3D"

    private var signedURL: URL { URL(string: signedURLString)! }

    private func rule() -> InterceptRule {
        InterceptRule(matchEndpoint: "/report.pdf", matchMode: .exact)
    }

    /// Mirrors the call site: nil means "leave the URL completely alone".
    private func applied(_ rule: InterceptRule, to url: URL) -> URL {
        CustomHTTPProtocol.urlApplyingQueryEdits(of: rule, to: url) ?? url
    }

    // MARK: - 1. No query edits => the URL is never touched

    func testHeaderOnlyRuleReturnsNilSoTheURLIsNeverTouched() {
        var r = rule()
        r.headerOverrides = [KVPair(key: "Authorization", value: "Bearer staging")]

        XCTAssertNil(CustomHTTPProtocol.urlApplyingQueryEdits(of: r, to: signedURL),
                     "A rule with no query-parameter edits must not produce a new URL at all — "
                     + "returning one means the caller reassigns the request's URL for no reason.")
    }

    func testHeaderOnlyRuleLeavesASignedURLByteIdentical() {
        var r = rule()
        r.headerOverrides = [KVPair(key: "Authorization", value: "Bearer staging")]
        r.removedHeaderKeys = ["Cookie"]

        XCTAssertEqual(applied(r, to: signedURL).absoluteString, signedURLString,
                       "The signature's %2B / %2F escapes must survive verbatim.")
    }

    func testHeaderOnlyRuleDoesNotTurnPercent2BIntoPlus() {
        var r = rule()
        r.headerOverrides = [KVPair(key: "X-Env", value: "staging")]

        let out = applied(r, to: signedURL).absoluteString
        XCTAssertTrue(out.contains("X-Amz-Signature=ab%2Bcd%2Fef%3D%3D"))
        XCTAssertFalse(out.contains("ab+cd"), "%2B must not decay to '+' (which means space).")
        XCTAssertFalse(out.contains("cd/ef"), "%2F must not decay to '/'.")
    }

    func testRedirectOnlyRuleLeavesTheQueryUntouched() {
        // Redirect rewriting is a separate step; the query block must still no-op.
        var r = rule()
        r.redirectMode = .host
        r.redirectTarget = "beta.example.com"

        XCTAssertNil(CustomHTTPProtocol.urlApplyingQueryEdits(of: r, to: signedURL))
    }

    func testCompletelyEmptyRuleLeavesTheURLAlone() {
        XCTAssertNil(CustomHTTPProtocol.urlApplyingQueryEdits(of: rule(), to: signedURL))
    }

    func testURLWithNoQueryIsUntouchedByAHeaderOnlyRule() {
        var r = rule()
        r.headerOverrides = [KVPair(key: "A", value: "b")]
        let plain = URL(string: "https://example.com/a/b")!

        XCTAssertNil(CustomHTTPProtocol.urlApplyingQueryEdits(of: r, to: plain))
    }

    // MARK: - 2. Editing one parameter leaves the others' encoding untouched

    func testOverridingOneParamLeavesTheSignatureEncodingIntact() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "X-Amz-Expires", value: "60")]

        let out = applied(r, to: signedURL).absoluteString
        XCTAssertTrue(out.contains("X-Amz-Expires=60"), "The edit itself must land. Got: \(out)")
        XCTAssertTrue(out.contains("X-Amz-Signature=ab%2Bcd%2Fef%3D%3D"),
                      "An untouched parameter must keep its exact bytes. Got: \(out)")
        XCTAssertTrue(out.contains("X-Amz-Credential=AKIA%2F20260727%2Fus-east-1%2Fs3%2Faws4_request"),
                      "An untouched parameter must keep its exact bytes. Got: \(out)")
    }

    func testRemovingOneParamLeavesTheOthersEncodingIntact() {
        var r = rule()
        r.removedQueryParamKeys = ["X-Amz-Expires"]

        let out = applied(r, to: signedURL).absoluteString
        XCTAssertFalse(out.contains("X-Amz-Expires"))
        XCTAssertTrue(out.contains("X-Amz-Signature=ab%2Bcd%2Fef%3D%3D"))
        XCTAssertTrue(out.contains("X-Amz-Credential=AKIA%2F20260727%2Fus-east-1%2Fs3%2Faws4_request"))
    }

    func testAddingANewParamAppendsItAndLeavesTheRestIntact() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "debug", value: "1")]

        let out = applied(r, to: signedURL).absoluteString
        XCTAssertTrue(out.contains("debug=1"))
        XCTAssertTrue(out.contains("X-Amz-Signature=ab%2Bcd%2Fef%3D%3D"))
        XCTAssertTrue(out.hasPrefix("https://bucket.s3.amazonaws.com/report.pdf?X-Amz-Algorithm="),
                      "Existing parameters keep their order; the new one is appended. Got: \(out)")
    }

    func testOnlyTheNamedParameterChanges() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "b", value: "NEW")]
        let url = URL(string: "https://example.com/x?a=1%2B1&b=old&c=%7Bbrace%7D")!

        XCTAssertEqual(applied(r, to: url).absoluteString,
                       "https://example.com/x?a=1%2B1&b=NEW&c=%7Bbrace%7D")
    }

    // MARK: - Values SwiftyDebug writes are encoded safely

    func testAnOverrideValueContainingPlusIsEscapedNotSentRaw() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "token", value: "a+b")]
        let url = URL(string: "https://example.com/x?token=old")!

        let out = applied(r, to: url).absoluteString
        XCTAssertTrue(out.contains("token=a%2Bb"),
                      "A literal '+' must go out as %2B, otherwise the server reads a space. Got: \(out)")
    }

    func testAnOverrideValueContainingAmpersandCannotSplitIntoTwoParameters() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "q", value: "a&b=c")]
        let url = URL(string: "https://example.com/x?q=old")!

        let out = applied(r, to: url).absoluteString
        XCTAssertEqual(out, "https://example.com/x?q=a%26b%3Dc")
    }

    func testAnOverrideValueContainingSlashAndSpaceIsEscaped() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "path", value: "a/b c")]
        let url = URL(string: "https://example.com/x")!

        let out = applied(r, to: url).absoluteString
        XCTAssertTrue(out.contains("path=a%2Fb%20c"), "Got: \(out)")
    }

    func testEncoderRoundTripsBackToTheOriginalString() {
        for raw in ["a+b", "a&b", "a=b", "a/b", "a b", "ünïcode", "100%", "a?b#c", "plain"] {
            let encoded = CustomHTTPProtocol.percentEncodedQueryComponent(raw)
            XCTAssertEqual(encoded.removingPercentEncoding, raw,
                           "\(raw) did not survive the encode/decode round trip (got \(encoded)).")
        }
    }

    // MARK: - Percent-encoded parameter NAMES

    func testAnEncodedNameIsMatchedByItsDecodedKey() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "a b", value: "2")]
        let url = URL(string: "https://example.com/x?a%20b=1")!

        let out = applied(r, to: url).absoluteString
        XCTAssertEqual(out, "https://example.com/x?a%20b=2",
                       "The override must replace the existing parameter, not append a second one.")
    }

    func testRemovalMatchesAnEncodedName() {
        var r = rule()
        r.removedQueryParamKeys = ["a b"]
        let url = URL(string: "https://example.com/x?a%20b=1&keep=2")!

        XCTAssertEqual(applied(r, to: url).absoluteString, "https://example.com/x?keep=2")
    }

    // MARK: - Degenerate queries

    func testRemovingTheOnlyParameterDropsTheQueryEntirely() {
        var r = rule()
        r.removedQueryParamKeys = ["only"]
        let url = URL(string: "https://example.com/x?only=1")!

        XCTAssertEqual(applied(r, to: url).absoluteString, "https://example.com/x")
    }

    func testAValuelessFlagParameterIsPreserved() {
        var r = rule()
        r.queryParamOverrides = [KVPair(key: "other", value: "1")]
        let url = URL(string: "https://example.com/x?flag&other=0")!

        let out = applied(r, to: url).absoluteString
        XCTAssertTrue(out.contains("flag"), "A bare `?flag` must not be turned into `flag=`. Got: \(out)")
        XCTAssertTrue(out.contains("other=1"), "Got: \(out)")
    }

    func testRemovalThenOverrideOfTheSameKeyLeavesTheOverride() {
        // `InterceptRuleStore` already subtracts overridden keys from the removal
        // set, but the URL rewriter must not depend on that to behave sanely.
        var r = rule()
        r.removedQueryParamKeys = ["x"]
        r.queryParamOverrides = [KVPair(key: "x", value: "9")]
        let url = URL(string: "https://example.com/p?x=1&y=2")!

        let out = applied(r, to: url).absoluteString
        XCTAssertTrue(out.contains("x=9"), "Got: \(out)")
        XCTAssertTrue(out.contains("y=2"), "Got: \(out)")
    }
}
