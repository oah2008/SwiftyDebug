//
//  ReplayDiffSecurityAuditFixTests.swift
//  SwiftyDebugTests
//
//  An audit of the replay / diff / auth screens found several places where the
//  SDK quietly changed the thing it was supposed to reproduce: the replayed
//  query string, the value a diff row copies, and the bucket a captured status
//  code lands in. All of those are invisible on screen — the UI shows the
//  decoded, shortened, re-labelled version either way — so they are pinned here.
//

import XCTest
@testable import SwiftyDebug

final class ReplayDiffSecurityAuditFixTests: XCTestCase {

    // MARK: - Replay: query fidelity (finding 47)

    private func components(_ string: String) -> URLComponents {
        return URLComponents(string: string)!
    }

    /// `queryItems` re-encodes against `urlQueryAllowed`, which permits `+`, `/`
    /// and `,` — so an untouched query must be restored from the captured bytes
    /// rather than rebuilt from the decoded rows the table shows.
    func testUntouchedQueryReplaysByteForByte() {
        let original = "cursor=eyJhIjoxfQ%3D%3D&sig=ab%2Fcd%2Bef&tag=a%2Cb&flag"
        var comps = components("https://api.example.com/v1/feed")
        RequestReplayViewController.applyQuery(
            to: &comps,
            params: [(name: "cursor", value: "eyJhIjoxfQ=="),
                     (name: "sig", value: "ab/cd+ef"),
                     (name: "tag", value: "a,b"),
                     (name: "flag", value: "")],
            originalPercentEncodedQuery: original,
            paramsWereEdited: false)

        XCTAssertEqual(comps.percentEncodedQuery, original)
        XCTAssertEqual(comps.url?.absoluteString, "https://api.example.com/v1/feed?" + original)
    }

    func testEditedQueryIsRebuiltFromTheRows() {
        var comps = components("https://api.example.com/v1/feed")
        RequestReplayViewController.applyQuery(
            to: &comps,
            params: [(name: "page", value: "2")],
            originalPercentEncodedQuery: "page=1",
            paramsWereEdited: true)

        XCTAssertEqual(comps.percentEncodedQuery, "page=2")
    }

    func testEditingAwayEveryParamClearsTheQuery() {
        var comps = components("https://api.example.com/v1/feed")
        RequestReplayViewController.applyQuery(
            to: &comps,
            params: [],
            originalPercentEncodedQuery: "page=1",
            paramsWereEdited: true)

        XCTAssertNil(comps.percentEncodedQuery)
        XCTAssertEqual(comps.url?.absoluteString, "https://api.example.com/v1/feed")
    }

    /// A URL that never had a query falls through to the rebuild path, so an
    /// added param still reaches the wire.
    func testQueryAddedToAQuerylessURLIsSent() {
        var comps = components("https://api.example.com/v1/feed")
        RequestReplayViewController.applyQuery(
            to: &comps,
            params: [(name: "debug", value: "1"), (name: "", value: "ignored")],
            originalPercentEncodedQuery: nil,
            paramsWereEdited: false)

        XCTAssertEqual(comps.percentEncodedQuery, "debug=1")
    }

    // MARK: - Replay: method / body agreement (finding 86)

    /// The method picker's subtitle and the BODY section read the same rule; a
    /// second hardcoded list once told the user DELETE drops the body while the
    /// editor showed and sent one.
    func testDeleteSupportsABody() {
        XCTAssertTrue(RequestReplayViewController.supportsBody("DELETE"))
        XCTAssertTrue(RequestReplayViewController.supportsBody("POST"))
        XCTAssertTrue(RequestReplayViewController.supportsBody("PUT"))
        XCTAssertTrue(RequestReplayViewController.supportsBody("PATCH"))
        XCTAssertFalse(RequestReplayViewController.supportsBody("GET"))
        XCTAssertFalse(RequestReplayViewController.supportsBody("HEAD"))
    }

    // MARK: - Diff: rows keep the full value (finding 48)

    func testDiffRowsCarryTheUntruncatedValue() {
        let long = String(repeating: "x", count: RequestDiff.maxDisplayLength + 500)
        let other = String(repeating: "x", count: RequestDiff.maxDisplayLength + 499) + "y"

        let rows = RequestDiff.diffPairs(old: [("authorization", long)], new: [("authorization", other)])
        XCTAssertEqual(rows.first?.change, .changed)
        // The row is the copy source, so it must hold every byte.
        XCTAssertEqual(rows.first?.oldValue, long)
        XCTAssertEqual(rows.first?.newValue, other)
        // Shortening still exists — it just happens when the value becomes pixels.
        XCTAssertTrue(RequestDiff.display(long).hasSuffix("chars)"))
        XCTAssertTrue(RequestDiff.display(long).count < long.count)
    }

    func testAddedAndRemovedRowsAlsoCarryTheUntruncatedValue() {
        let long = String(repeating: "j", count: RequestDiff.maxDisplayLength + 42)

        let added = RequestDiff.diffPairs(old: [], new: [("token", long)])
        XCTAssertEqual(added.first?.newValue, long)
        let removed = RequestDiff.diffPairs(old: [("token", long)], new: [])
        XCTAssertEqual(removed.first?.oldValue, long)
    }

    /// The whole-diff export shortens on its own, so it stays readable now that
    /// the rows no longer arrive pre-cut.
    func testPlainTextExportStaysBounded() {
        let long = String(repeating: "z", count: RequestDiff.maxDisplayLength + 300)
        let section = RequestDiffSection(title: "REQUEST HEADERS", rows: [
            RequestDiffRow(label: "X-Token", oldValue: long, newValue: nil, change: .removed),
        ])
        let text = RequestDiff.plainText(RequestDiffResult(sections: [section]))

        XCTAssertTrue(text.contains("chars)"))
        XCTAssertLessThan(text.count, long.count)
    }

    // MARK: - Diff: the truncation warning survives the filter (finding 49)

    /// Two bodies cut off at capture compare as identical, so the section scores
    /// no change — and used to be filtered away along with the one row saying the
    /// comparison was made on partial data.
    func testTruncationWarningSurvivesTheChangesOnlyFilter() {
        let body = "{\"a\":1}".data(using: .utf8)!
        let section = RequestDiff.bodySection(title: "REQUEST BODY",
                                              oldBody: body,
                                              newBody: body,
                                              oldTruncated: true,
                                              newTruncated: true)
        XCTAssertEqual(section.changeCount, 0)
        XCTAssertEqual(section.rows.first?.isWarning, true)

        let visible = RequestDiffResult(sections: [section]).sections(changesOnly: true)
        XCTAssertEqual(visible.map(\.title), ["REQUEST BODY"])
        XCTAssertEqual(visible.first?.rows(changesOnly: true).first?.label, "⚠︎ Partial data")
    }

    func testTruncatedComparisonKeepsTheBodySectionEndToEnd() {
        let body = "AAAA".data(using: .utf8)!
        var left = RequestSnapshot()
        left.requestBody = body
        left.isRequestBodyTruncated = true
        var right = left
        right.requestBody = body
        right.isRequestBodyTruncated = true

        let visible = RequestDiff.compare(left, right).sections(changesOnly: true)
        XCTAssertTrue(visible.contains { $0.title == "REQUEST BODY" })
    }

    /// A plain note must not resurrect an empty section: TIMING & SIZE always
    /// carries the "Started" row, and keying the filter off `isNote` would make
    /// that section permanently visible and the empty state unreachable.
    func testUnchangedDiffWithoutTruncationStillShowsNothing() {
        var left = RequestSnapshot()
        left.urlString = "https://api.example.com/v1/users"
        left.method = "GET"
        left.statusCode = "200"
        left.startTime = "1700000000.000"
        left.endTime = "1700000000.100"
        var right = left
        right.startTime = "1700009999.000"
        right.endTime = "1700009999.100"

        XCTAssertTrue(RequestDiff.compare(left, right).sections(changesOnly: true).isEmpty)
    }

    // MARK: - Diff: nothing to copy (finding 87)

    /// The "(none)" placeholder is selectable like any other row, and copying its
    /// empty value would overwrite whatever the developer had on the pasteboard.
    /// `didSelectRowAt` bails on an empty string; this pins the precondition.
    func testPlaceholderRowHasNothingToCopy() {
        let left = RequestSnapshot()
        let right = RequestSnapshot()
        let params = RequestDiff.compare(left, right).sections.first { $0.title == "QUERY PARAMS" }

        XCTAssertEqual(params?.rows.first?.label, "(none)")
        XCTAssertNil(params?.rows.first?.oldValue)
        XCTAssertNil(params?.rows.first?.newValue)
    }

    // MARK: - Insights: status buckets (finding 50)

    private func transaction(status: String?, error: String? = nil, localized: String? = nil) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.statusCode = status
        model.errorDescription = error
        model.errorLocalizedDescription = localized
        return model
    }

    /// `handleError` fills `errorDescription` with prose for every non-2xx
    /// response even though the transport succeeded, so the status code has to
    /// decide the bucket first — otherwise 3xx/4xx/5xx never render and a cached
    /// 304 is counted into the error rate.
    func testStatusCodeDecidesTheBucketDespiteTheErrorProse() {
        XCTAssertEqual(InsightsStatusBucket.classify(
            transaction(status: "301", error: "Redirection :\nMoved Permanently", localized: "Moved Permanently")), .redirect)
        XCTAssertEqual(InsightsStatusBucket.classify(
            transaction(status: "404", error: "Client Error :\nNot found", localized: "Not Found")), .clientError)
        XCTAssertEqual(InsightsStatusBucket.classify(
            transaction(status: "500", error: "Server Error", localized: "Internal Server Error")), .serverError)
        XCTAssertEqual(InsightsStatusBucket.classify(transaction(status: "200")), .success)
    }

    func testRedirectsDoNotCountAsErrors() {
        XCTAssertFalse(InsightsStatusBucket.redirect.isError)
        XCTAssertEqual(InsightsStatusBucket.classify(transaction(status: "304", localized: "Not Modified")), .redirect)
    }

    /// `handleError` writes nothing for 2xx, so a 2xx that still carries an error
    /// description really did fail mid-body and must stay `.failed`.
    func testTransportFailuresStillClassifyAsFailed() {
        XCTAssertEqual(InsightsStatusBucket.classify(
            transaction(status: "200", localized: "The network connection was lost.")), .failed)
        XCTAssertEqual(InsightsStatusBucket.classify(
            transaction(status: "0", localized: "Could not connect to the server.")), .failed)
        XCTAssertEqual(InsightsStatusBucket.classify(transaction(status: nil)), .failed)
        XCTAssertEqual(InsightsStatusBucket.classify(transaction(status: "")), .failed)
    }

    // MARK: - Auth: absolute dates (finding 89)

    /// A fixed format string with no locale renders in the device's calendar, so
    /// `exp` came out as year 1448 on a Hijri device while the raw epoch beside it
    /// said 2026.
    func testJWTAbsoluteDatesRenderInTheGregorianCalendar() {
        let date = Date(timeIntervalSince1970: 1_758_326_400)

        let posix = DateFormatter()
        posix.dateFormat = "yyyy-MM-dd HH:mm:ss"
        posix.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(DebugJWT.absolute(date), posix.string(from: date))

        let hijri = DateFormatter()
        hijri.dateFormat = "yyyy-MM-dd HH:mm:ss"
        hijri.locale = Locale(identifier: "ar_SA@calendar=islamic-umalqura")
        XCTAssertNotEqual(DebugJWT.absolute(date), hijri.string(from: date))
    }
}
