//
//  RequestDiffTests.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import XCTest
@testable import SwiftyDebug

final class RequestDiffTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ raw: String) -> Data {
        return raw.data(using: .utf8)!
    }

    private func snapshot(url: String = "https://api.example.com/v1/users?page=1",
                          method: String = "GET",
                          status: String = "200",
                          requestHeaders: [(name: String, value: String)] = [],
                          responseHeaders: [(name: String, value: String)] = [],
                          requestBody: Data? = nil,
                          responseBody: Data? = nil) -> RequestSnapshot {
        var snapshot = RequestSnapshot()
        snapshot.urlString = url
        snapshot.method = method
        snapshot.statusCode = status
        snapshot.host = URL(string: url)?.host ?? ""
        snapshot.path = URL(string: url)?.path ?? ""
        if let components = URLComponents(string: url), let items = components.queryItems {
            snapshot.queryItems = items.map { ($0.name, $0.value ?? "") }
        }
        snapshot.requestHeaders = requestHeaders
        snapshot.responseHeaders = responseHeaders
        snapshot.requestBody = requestBody
        snapshot.responseBody = responseBody
        snapshot.startTime = "1700000000.000"
        snapshot.endTime = "1700000000.250"
        snapshot.requestSize = UInt(requestBody?.count ?? 0)
        snapshot.responseSize = UInt(responseBody?.count ?? 0)
        return snapshot
    }

    private func rows(_ result: RequestDiffResult, section title: String) -> [RequestDiffRow] {
        return result.sections.first { $0.title == title }?.rows ?? []
    }

    private func row(_ rows: [RequestDiffRow], label: String) -> RequestDiffRow? {
        return rows.first { $0.label == label }
    }

    // MARK: - Identical requests

    func testIdenticalRequestsProduceNoChanges() {
        let body = json("{\"a\":1,\"b\":[{\"c\":\"x\"}]}")
        let left = snapshot(requestHeaders: [("Authorization", "Bearer abc")],
                            responseHeaders: [("Content-Type", "application/json")],
                            requestBody: body,
                            responseBody: body)
        let right = snapshot(requestHeaders: [("Authorization", "Bearer abc")],
                             responseHeaders: [("Content-Type", "application/json")],
                             requestBody: body,
                             responseBody: body)

        let result = RequestDiff.compare(left, right)
        XCTAssertEqual(result.changeCount, 0)
        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(result.sections(changesOnly: true).isEmpty)
        // The unfiltered view still has every section for context.
        XCTAssertEqual(result.sections.count, 7)
    }

    func testIdenticalRequestsHaveNoNonSameRows() {
        let left = snapshot(requestHeaders: [("Accept", "*/*")])
        let right = snapshot(requestHeaders: [("Accept", "*/*")])
        let result = RequestDiff.compare(left, right)

        for section in result.sections {
            for row in section.rows where !row.isNote {
                XCTAssertEqual(row.change, .same, "\(section.title) / \(row.label) should be unchanged")
            }
        }
    }

    // MARK: - JSON path diffing

    func testChangedValueInsideArrayOfObjectsIsReportedAtItsPath() {
        let old = json("{\"items\":[{\"id\":1,\"price\":10},{\"id\":2,\"price\":20}]}")
        let new = json("{\"items\":[{\"id\":1,\"price\":10},{\"id\":2,\"price\":25}]}")

        let rows = RequestDiff.diffBodies(old, new)
        let changed = rows.filter { $0.change != .same }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.label, "items[1].price")
        XCTAssertEqual(changed.first?.oldValue, "20")
        XCTAssertEqual(changed.first?.newValue, "25")
    }

    func testDeeplyNestedPathUsesDotAndBracketNotation() {
        let old = json("{\"a\":{\"b\":[{\"c\":\"one\"}]}}")
        let new = json("{\"a\":{\"b\":[{\"c\":\"two\"}]}}")

        let changed = RequestDiff.diffBodies(old, new).filter { $0.change != .same }
        XCTAssertEqual(changed.map(\.label), ["a.b[0].c"])
        XCTAssertEqual(changed.first?.oldValue, "\"one\"")
        XCTAssertEqual(changed.first?.newValue, "\"two\"")
    }

    func testKeyMissingOnOneSideIsAddedOrRemovedNotChanged() {
        let old = json("{\"keep\":1,\"gone\":\"bye\"}")
        let new = json("{\"keep\":1,\"fresh\":\"hi\"}")

        let rows = RequestDiff.diffBodies(old, new)
        XCTAssertEqual(row(rows, label: "keep")?.change, .same)

        let removed = row(rows, label: "gone")
        XCTAssertEqual(removed?.change, .removed)
        XCTAssertEqual(removed?.oldValue, "\"bye\"")
        XCTAssertNil(removed?.newValue)

        let added = row(rows, label: "fresh")
        XCTAssertEqual(added?.change, .added)
        XCTAssertEqual(added?.newValue, "\"hi\"")
        XCTAssertNil(added?.oldValue)
    }

    func testArrayElementRemovalReportsTrailingPaths() {
        let old = json("{\"list\":[\"a\",\"b\",\"c\"]}")
        let new = json("{\"list\":[\"a\",\"b\"]}")

        let rows = RequestDiff.diffBodies(old, new)
        XCTAssertEqual(row(rows, label: "list[2]")?.change, .removed)
        XCTAssertEqual(row(rows, label: "list[0]")?.change, .same)
    }

    func testTypeChangeIsReportedAsChanged() {
        let old = json("{\"count\":\"1\"}")
        let new = json("{\"count\":1}")

        let changed = RequestDiff.diffBodies(old, new).filter { $0.change != .same }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.oldValue, "\"1\"")
        XCTAssertEqual(changed.first?.newValue, "1")
    }

    func testBooleansAndNullRenderAsJSONLiterals() {
        let pairs = RequestDiff.flattenJSON(try! JSONSerialization.jsonObject(
            with: json("{\"ok\":true,\"off\":false,\"none\":null,\"n\":3}")))
        let rendered = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value) })
        XCTAssertEqual(rendered["ok"], "true")
        XCTAssertEqual(rendered["off"], "false")
        XCTAssertEqual(rendered["none"], "null")
        XCTAssertEqual(rendered["n"], "3")
    }

    func testEmptyContainersAreFlattenedToPlaceholders() {
        let pairs = RequestDiff.flattenJSON(try! JSONSerialization.jsonObject(
            with: json("{\"obj\":{},\"arr\":[]}")))
        let rendered = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value) })
        XCTAssertEqual(rendered["obj"], "{}")
        XCTAssertEqual(rendered["arr"], "[]")
    }

    func testTopLevelArrayOfObjectsDiffsPerElement() {
        let old = json("[{\"n\":1},{\"n\":2}]")
        let new = json("[{\"n\":1},{\"n\":9}]")

        let changed = RequestDiff.diffBodies(old, new).filter { $0.change != .same }
        XCTAssertEqual(changed.map(\.label), ["[1].n"])
    }

    func testEmptyBodyVersusJSONBodyMarksEverythingAdded() {
        let rows = RequestDiff.diffBodies(Data(), json("{\"a\":1,\"b\":2}"))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.change == .added })
    }

    func testBothBodiesEmptyProducesNoRows() {
        XCTAssertTrue(RequestDiff.diffBodies(nil, nil).isEmpty)
    }

    // MARK: - Form and text bodies

    func testFormEncodedBodiesDiffByKey() {
        let old = "user=bob&role=admin".data(using: .utf8)!
        let new = "user=bob&role=guest".data(using: .utf8)!

        let rows = RequestDiff.diffBodies(old, new)
        XCTAssertEqual(row(rows, label: "user")?.change, .same)
        let role = row(rows, label: "role")
        XCTAssertEqual(role?.change, .changed)
        XCTAssertEqual(role?.oldValue, "admin")
        XCTAssertEqual(role?.newValue, "guest")
    }

    func testBase64LikePayloadIsNotTreatedAsFormBody() {
        XCTAssertNil(RequestDiff.formPairs("aGVsbG8="))
    }

    func testPlainTextBodiesDiffByLine() {
        let old = "one\ntwo\nthree".data(using: .utf8)!
        let new = "one\ntwo point five\nthree".data(using: .utf8)!

        let rows = RequestDiff.diffBodies(old, new)
        XCTAssertEqual(rows.filter { $0.change == .removed }.map(\.oldValue), ["two"])
        XCTAssertEqual(rows.filter { $0.change == .added }.map(\.newValue), ["two point five"])
        XCTAssertEqual(rows.filter { $0.change == .same }.count, 2)
    }

    // MARK: - Headers

    func testHeaderNamesAreMatchedCaseInsensitively() {
        let left = snapshot(requestHeaders: [("Authorization", "Bearer old")])
        let right = snapshot(requestHeaders: [("authorization", "Bearer new")])

        let headerRows = rows(RequestDiff.compare(left, right), section: "REQUEST HEADERS")
        XCTAssertEqual(headerRows.count, 1)
        XCTAssertEqual(headerRows.first?.change, .changed)
        // The old side's casing wins so a case flip is not read as add + remove.
        XCTAssertEqual(headerRows.first?.label, "Authorization")
    }

    func testMissingHeaderIsRemoved() {
        let left = snapshot(requestHeaders: [("Accept", "*/*"), ("X-Trace", "abc")])
        let right = snapshot(requestHeaders: [("Accept", "*/*")])

        let headerRows = rows(RequestDiff.compare(left, right), section: "REQUEST HEADERS")
        XCTAssertEqual(row(headerRows, label: "X-Trace")?.change, .removed)
        XCTAssertEqual(row(headerRows, label: "Accept")?.change, .same)
    }

    // MARK: - Query params

    func testQueryParamChangeIsIsolatedToItsOwnRow() {
        let left = snapshot(url: "https://api.example.com/v1/users?page=1&sort=asc")
        let right = snapshot(url: "https://api.example.com/v1/users?page=2&sort=asc")

        let queryRows = rows(RequestDiff.compare(left, right), section: "QUERY PARAMS")
        XCTAssertEqual(row(queryRows, label: "page")?.change, .changed)
        XCTAssertEqual(row(queryRows, label: "page")?.oldValue, "1")
        XCTAssertEqual(row(queryRows, label: "page")?.newValue, "2")
        XCTAssertEqual(row(queryRows, label: "sort")?.change, .same)
    }

    func testRepeatedQueryNamesAreComparedPositionally() {
        let old: [(name: String, value: String)] = [("tag", "a"), ("tag", "b")]
        let new: [(name: String, value: String)] = [("tag", "a"), ("tag", "z")]

        let rows = RequestDiff.diffPairs(old: old, new: new)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].change, .same)
        XCTAssertEqual(rows[1].change, .changed)
        XCTAssertEqual(rows[1].label, "tag #2")
    }

    // MARK: - Overview / timing

    func testStatusAndMethodChangesLandInTheOverviewSection() {
        let left = snapshot(method: "GET", status: "200")
        let right = snapshot(method: "POST", status: "401")

        let overview = rows(RequestDiff.compare(left, right), section: "REQUEST")
        XCTAssertEqual(row(overview, label: "Method")?.change, .changed)
        XCTAssertEqual(row(overview, label: "Status")?.oldValue, "200")
        XCTAssertEqual(row(overview, label: "Status")?.newValue, "401")
        XCTAssertEqual(row(overview, label: "Host")?.change, .same)
    }

    func testTimestampNoteNeverCountsAsAChange() {
        var left = snapshot()
        var right = snapshot()
        left.startTime = "1700000000.000"
        left.endTime = "1700000000.100"
        right.startTime = "1700009999.000"
        right.endTime = "1700009999.100"

        let result = RequestDiff.compare(left, right)
        let timing = result.sections.first { $0.title == "TIMING & SIZE" }
        XCTAssertNotNil(timing)
        XCTAssertEqual(timing?.changeCount, 0)
        XCTAssertEqual(row(timing!.rows, label: "Started")?.isNote, true)
        XCTAssertEqual(result.changeCount, 0)
    }

    func testTruncatedBodyAddsAWarningNote() {
        let section = RequestDiff.bodySection(title: "RESPONSE BODY",
                                              oldBody: json("{\"a\":1}"),
                                              newBody: json("{\"a\":1}"),
                                              oldTruncated: false,
                                              newTruncated: true)
        XCTAssertEqual(section.rows.first?.isNote, true)
        XCTAssertEqual(section.changeCount, 0)
    }

    // MARK: - Filtering

    func testChangesOnlyFilterDropsUnchangedRowsButKeepsNotes() {
        let section = RequestDiffSection(title: "T", rows: [
            RequestDiffRow(label: "a", oldValue: "1", newValue: "1", change: .same),
            RequestDiffRow(label: "b", oldValue: "1", newValue: "2", change: .changed),
            RequestDiffRow(label: "note", oldValue: "x", newValue: nil, change: .same, isNote: true),
        ])
        XCTAssertEqual(section.changeCount, 1)
        XCTAssertEqual(section.rows(changesOnly: true).map(\.label), ["b", "note"])
        XCTAssertEqual(section.rows(changesOnly: false).count, 3)
    }

    // MARK: - Value shortening

    func testOversizedValuesAreShortenedForDisplayButStillCompared() {
        let long = String(repeating: "x", count: RequestDiff.maxDisplayLength + 50)
        let other = String(repeating: "x", count: RequestDiff.maxDisplayLength + 49) + "y"

        let rows = RequestDiff.diffPairs(old: [("blob", long)], new: [("blob", other)])
        XCTAssertEqual(rows.first?.change, .changed)
        XCTAssertTrue(rows.first!.oldValue!.count < long.count)
        XCTAssertTrue(rows.first!.oldValue!.hasSuffix("chars)"))
    }

    // MARK: - Export

    func testPlainTextUsesDiffMarkers() {
        let left = snapshot(requestHeaders: [("X-Token", "old")])
        let right = snapshot(requestHeaders: [("X-Token", "new")])
        let text = RequestDiff.plainText(RequestDiff.compare(left, right), changesOnly: true)

        XCTAssertTrue(text.contains("## REQUEST HEADERS"))
        XCTAssertTrue(text.contains("~ X-Token"))
        XCTAssertTrue(text.contains("- old"))
        XCTAssertTrue(text.contains("+ new"))
    }

    // MARK: - Ordering primitives

    func testMergedOrderKeepsSharedKeysInPlaceAndInterleavesTheRest() {
        let merged = RequestDiff.mergedOrder(["a", "b", "c"], ["a", "x", "c"])
        XCTAssertEqual(merged, ["a", "b", "x", "c"])
    }

    func testMergedOrderNeverRepeatsAKey() {
        let merged = RequestDiff.mergedOrder(["a", "b"], ["b", "a"])
        XCTAssertEqual(Set(merged), Set(["a", "b"]))
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - NetworkTransaction bridging

    func testSnapshotReadsDiskBackedBodiesAndHeaders() {
        let transaction = NetworkTransaction()
        transaction.url = NSURL(string: "https://api.example.com/v1/orders?page=3")
        transaction.method = "post"
        transaction.statusCode = "201"
        transaction.requestHeaderFields = ["Content-Type": "application/json"] as NSDictionary
        transaction.requestData = json("{\"id\":7}")

        let snapshot = RequestSnapshot(transaction: transaction)
        XCTAssertEqual(snapshot.method, "POST")
        XCTAssertEqual(snapshot.host, "api.example.com")
        XCTAssertEqual(snapshot.path, "/v1/orders")
        XCTAssertEqual(snapshot.queryItems.map(\.name), ["page"])
        XCTAssertEqual(snapshot.requestHeaders.map(\.name), ["Content-Type"])
        XCTAssertEqual(snapshot.requestBody, json("{\"id\":7}"))
        XCTAssertEqual(snapshot.displayTitle, "POST /v1/orders")
    }

    func testCompareOnTransactionsFindsARotatedToken() {
        let old = NetworkTransaction()
        old.url = NSURL(string: "https://api.example.com/v1/me")
        old.method = "GET"
        old.statusCode = "200"
        old.requestHeaderFields = ["Authorization": "Bearer OLD"] as NSDictionary

        let new = NetworkTransaction()
        new.url = NSURL(string: "https://api.example.com/v1/me")
        new.method = "GET"
        new.statusCode = "401"
        new.requestHeaderFields = ["Authorization": "Bearer NEW"] as NSDictionary

        let result = RequestDiff.compare(old, new)
        XCTAssertEqual(result.changeCount, 2) // status + authorization
        let headerRows = rows(result, section: "REQUEST HEADERS")
        XCTAssertEqual(row(headerRows, label: "Authorization")?.change, .changed)
    }
}
