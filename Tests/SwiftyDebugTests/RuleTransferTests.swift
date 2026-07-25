//
//  RuleTransferTests.swift
//  SwiftyDebugTests
//
//  Created by Omar Hariri on 25/07/2026.
//

import XCTest
@testable import SwiftyDebug

final class RuleTransferTests: XCTestCase {

    // MARK: - Fixtures

    private func makePatternRule(endpoint: String = "/api/users/{id}/orders") -> InterceptRule {
        var rule = InterceptRule(matchEndpoint: endpoint, matchMode: .normalized)
        rule.headerOverrides = [
            KVPair(key: "Authorization", value: "Bearer staging-token"),
            KVPair(key: "X-Env", value: "staging"),
        ]
        rule.queryParamOverrides = [KVPair(key: "debug", value: "1")]
        rule.removedHeaderKeys = ["cookie", "x-trace-id"]
        rule.removedQueryParamKeys = ["utm_source", "utm_medium"]
        rule.isEnabled = false
        rule.order = 3
        return rule
    }

    private func makeHostRule() -> InterceptRule {
        var rule = InterceptRule.hostRule(hosts: ["api.staging.example.com", "cdn.example.com"])
        rule.headerOverrides = [KVPair(key: "X-Tenant", value: "acme")]
        rule.order = 1
        return rule
    }

    private func makeBlockingGlobalRule() -> InterceptRule {
        var rule = InterceptRule.globalRule()
        rule.isBlocked = true
        rule.order = 7
        return rule
    }

    private let app = RuleTransferDocument.AppDescriptor(
        name: "Acme", bundleId: "com.acme.app", version: "2.1.0", build: "471"
    )

    private func roundTrip(_ rules: [InterceptRule], exportedAt: Date = Date()) throws -> RuleTransferDocument {
        let document = RuleExporter.makeDocument(from: rules, app: app, exportedAt: exportedAt)
        return try RuleTransferDocument.decode(document.jsonData())
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryKnownField() throws {
        let pattern = makePatternRule()
        let host = makeHostRule()
        let blocking = makeBlockingGlobalRule()
        let exportedAt = Date()

        let decoded = try roundTrip([pattern, host, blocking], exportedAt: exportedAt)

        XCTAssertEqual(decoded.schemaVersion, RuleTransferDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.app, app)
        XCTAssertEqual(decoded.exportedAt.timeIntervalSince1970, exportedAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(decoded.rules.count, 3)

        let restored = decoded.rules[0].rule
        XCTAssertEqual(restored.id, pattern.id)
        XCTAssertEqual(restored.matchEndpoint, pattern.matchEndpoint)
        XCTAssertEqual(restored.matchMode, pattern.matchMode)
        XCTAssertEqual(restored.matchHosts, pattern.matchHosts)
        XCTAssertEqual(restored.isBlocked, pattern.isBlocked)
        XCTAssertEqual(restored.isEnabled, pattern.isEnabled)
        XCTAssertEqual(restored.order, pattern.order)
        XCTAssertEqual(restored.removedHeaderKeys, pattern.removedHeaderKeys)
        XCTAssertEqual(restored.removedQueryParamKeys, pattern.removedQueryParamKeys)
        XCTAssertEqual(restored.headerOverrides.map { [$0.id, $0.key, $0.value] },
                       pattern.headerOverrides.map { [$0.id, $0.key, $0.value] })
        XCTAssertEqual(restored.queryParamOverrides.map { [$0.id, $0.key, $0.value] },
                       pattern.queryParamOverrides.map { [$0.id, $0.key, $0.value] })
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, pattern.createdAt.timeIntervalSince1970, accuracy: 0.01)

        let restoredHost = decoded.rules[1].rule
        XCTAssertEqual(restoredHost.matchMode, .host)
        XCTAssertEqual(restoredHost.matchHosts, host.matchHosts)
        XCTAssertEqual(restoredHost.matchEndpoint, host.matchEndpoint)

        let restoredGlobal = decoded.rules[2].rule
        XCTAssertEqual(restoredGlobal.matchMode, .global)
        XCTAssertTrue(restoredGlobal.isBlocked)
        XCTAssertEqual(restoredGlobal.order, 7)
    }

    /// Fields a *newer* SwiftyDebug writes (redirect / mock / breakpointMode) and whole sections it
    /// may add (mock profiles) must survive a trip through this build rather than being dropped.
    func testRoundTripPreservesFieldsThisBuildDoesNotKnow() throws {
        let exported = RuleExporter.makeDocument(from: [makePatternRule()], app: app)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported.jsonData()) as? [String: Any]
        )
        var ruleObjects = try XCTUnwrap(root["rules"] as? [[String: Any]])
        ruleObjects[0]["redirect"] = ["url": "https://api.staging.example.com/v2/users"]
        ruleObjects[0]["mock"] = ["statusCode": 503, "body": "{\"error\":\"down\"}", "delay": 1.5]
        ruleObjects[0]["breakpointMode"] = "requestAndResponse"
        root["rules"] = ruleObjects
        root["mockProfiles"] = [["id": "p1", "name": "Staging"]]

        let data = try JSONSerialization.data(withJSONObject: root)
        let decoded = try RuleTransferDocument.decode(data)

        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules[0].rule.removedHeaderKeys, ["cookie", "x-trace-id"])
        XCTAssertNotNil(decoded.unknownSections["mockProfiles"])
        XCTAssertTrue(decoded.warnings.contains { $0.contains("mockProfiles") })

        // Re-export: unknown rule fields and unknown sections are still there.
        let reEncoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: decoded.jsonData()) as? [String: Any]
        )
        let reEncodedRule = try XCTUnwrap((reEncoded["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual((reEncodedRule["redirect"] as? [String: Any])?["url"] as? String,
                       "https://api.staging.example.com/v2/users")
        XCTAssertEqual((reEncodedRule["mock"] as? [String: Any])?["statusCode"] as? Int, 503)
        XCTAssertEqual((reEncodedRule["mock"] as? [String: Any])?["delay"] as? Double, 1.5)
        XCTAssertEqual(reEncodedRule["breakpointMode"] as? String, "requestAndResponse")
        XCTAssertEqual((reEncoded["mockProfiles"] as? [[String: Any]])?.first?["name"] as? String, "Staging")
    }

    func testDocumentIsSelfDescribing() throws {
        let data = try RuleExporter.makeDocument(from: [makePatternRule()], app: app).jsonData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["format"] as? String, RuleTransferDocument.formatIdentifier)
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual((root["app"] as? [String: Any])?["bundleId"] as? String, "com.acme.app")
        XCTAssertNotNil(root["exportedAt"] as? String)
        // Pretty printed so the file is reviewable in a pull request.
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\n") == true)
    }

    /// The store persists a bare array (`rules.json`); pasting that straight in should work.
    func testBareRuleArrayIsAcceptedWithAWarning() throws {
        let rule = makePatternRule()
        let data = try JSONEncoder().encode([rule])

        let decoded = try RuleTransferDocument.decode(data)

        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules[0].rule.id, rule.id)
        XCTAssertEqual(decoded.rules[0].rule.createdAt.timeIntervalSince1970,
                       rule.createdAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(decoded.warnings.contains { $0.contains("header") })
    }

    func testNewerSchemaVersionIsReadWithAWarning() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RuleExporter.makeDocument(from: [makePatternRule()], app: app).jsonData()) as? [String: Any]
        )
        root["schemaVersion"] = 99

        let decoded = try RuleTransferDocument.decode(try JSONSerialization.data(withJSONObject: root))

        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.schemaVersion, 99)
        XCTAssertTrue(decoded.warnings.contains { $0.contains("newer") })
    }

    // MARK: - Rejection

    func testGarbageIsRejectedWithAUsefulError() {
        let data = Data("this is definitely not json".utf8)

        XCTAssertThrowsError(try RuleTransferDocument.decode(data)) { error in
            guard case RuleTransferError.notJSON = error else {
                return XCTFail("Expected .notJSON, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("not valid JSON"))
        }
    }

    func testEmptyInputIsRejected() {
        XCTAssertThrowsError(try RuleTransferDocument.decode(Data())) { error in
            guard case RuleTransferError.notJSON = error else {
                return XCTFail("Expected .notJSON, got \(error)")
            }
        }
        XCTAssertThrowsError(try RuleTransferDocument.decode("   \n  ")) { error in
            guard case RuleTransferError.notJSON = error else {
                return XCTFail("Expected .notJSON, got \(error)")
            }
        }
    }

    func testDocumentWithoutRulesSectionIsRejected() {
        let data = Data(#"{"schemaVersion": 1, "app": {"bundleId": "com.acme.app"}}"#.utf8)

        XCTAssertThrowsError(try RuleTransferDocument.decode(data)) { error in
            guard case RuleTransferError.missingRules = error else {
                return XCTFail("Expected .missingRules, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("rules"))
        }
    }

    func testNonObjectRootIsRejected() {
        XCTAssertThrowsError(try RuleTransferDocument.decode(Data("42".utf8))) { error in
            guard case RuleTransferError.unsupportedRoot = error else {
                return XCTFail("Expected .unsupportedRoot, got \(error)")
            }
        }
    }

    func testEmptyRuleListIsRejected() {
        XCTAssertThrowsError(try RuleTransferDocument.decode(Data(#"{"rules": []}"#.utf8))) { error in
            guard case RuleTransferError.noValidRules = error else {
                return XCTFail("Expected .noValidRules, got \(error)")
            }
        }
    }

    func testRuleWithMissingFieldsNamesTheOffendingField() {
        let data = Data(#"{"rules": [{"id": "abc", "matchEndpoint": "/api/x"}]}"#.utf8)

        XCTAssertThrowsError(try RuleTransferDocument.decode(data)) { error in
            guard case RuleTransferError.noValidRules(let reasons) = error else {
                return XCTFail("Expected .noValidRules, got \(error)")
            }
            XCTAssertTrue(reasons.first?.contains("Rule #1") == true, "got \(reasons)")
            XCTAssertTrue(reasons.first?.contains("missing") == true, "got \(reasons)")
        }
    }

    func testHostRuleWithoutHostsIsRejected() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RuleExporter.makeDocument(from: [makeHostRule()], app: app).jsonData()) as? [String: Any]
        )
        var ruleObjects = try XCTUnwrap(root["rules"] as? [[String: Any]])
        ruleObjects[0]["matchHosts"] = [String]()
        root["rules"] = ruleObjects

        XCTAssertThrowsError(try RuleTransferDocument.decode(try JSONSerialization.data(withJSONObject: root))) { error in
            guard case RuleTransferError.noValidRules(let reasons) = error else {
                return XCTFail("Expected .noValidRules, got \(error)")
            }
            XCTAssertTrue(reasons.first?.contains("no hosts") == true, "got \(reasons)")
        }
    }

    /// One broken rule must not cost the user the other nine.
    func testUnreadableRuleIsSkippedNotFatal() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RuleExporter.makeDocument(from: [makePatternRule()], app: app).jsonData()) as? [String: Any]
        )
        var ruleObjects = try XCTUnwrap(root["rules"] as? [[String: Any]])
        ruleObjects.insert(["id": "broken"], at: 0)
        root["rules"] = ruleObjects

        let decoded = try RuleTransferDocument.decode(try JSONSerialization.data(withJSONObject: root))

        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertTrue(decoded.warnings.contains { $0.contains("Skipped 1") })
    }

    // MARK: - Merge

    func testMergeSkipsAnIdenticalRule() throws {
        let rule = makePatternRule()
        let document = try roundTrip([rule])

        let plan = RuleImporter.plan(document, existing: [rule])
        let outcome = RuleImporter.resolve(plan, strategy: .merge)

        XCTAssertEqual(plan.duplicates.count, 1)
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertFalse(outcome.clearedExisting)
    }

    /// Same rule, rebuilt from scratch: different rule id, different pair ids, different
    /// `createdAt`, different `order` — still the same rule, so merge must not duplicate it.
    func testMergeSkipsAContentIdenticalRuleWithADifferentId() throws {
        let mine = makePatternRule()
        var theirs = makePatternRule()
        theirs.order = 42
        XCTAssertNotEqual(mine.id, theirs.id)

        let plan = RuleImporter.plan(try roundTrip([theirs]), existing: [mine])

        XCTAssertEqual(plan.duplicates.count, 1)
        XCTAssertTrue(RuleImporter.resolve(plan, strategy: .merge).added.isEmpty)
    }

    /// The collision policy: a shared id never overwrites a different rule — the incoming one is
    /// added under a fresh id and both survive.
    func testMergeReIdentifiesARuleWhoseIdIsTakenByADifferentRule() throws {
        let mine = makePatternRule()
        var theirs = mine            // struct copy keeps the id
        theirs.isBlocked = true
        theirs.headerOverrides = [KVPair(key: "Authorization", value: "Bearer production-token")]

        let plan = RuleImporter.plan(try roundTrip([theirs]), existing: [mine])
        let outcome = RuleImporter.resolve(plan, strategy: .merge)

        XCTAssertEqual(plan.idCollisions.count, 1)
        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.reIdentified, 1)
        let imported = try XCTUnwrap(outcome.added.first)
        XCTAssertNotEqual(imported.id, mine.id, "an existing rule must never be overwritten")
        XCTAssertTrue(imported.isBlocked)
        XCTAssertEqual(imported.headerOverrides.first?.value, "Bearer production-token")
        XCTAssertEqual(imported.matchEndpoint, mine.matchEndpoint)
    }

    func testMergeAddsBrandNewRulesUnchanged() throws {
        let existing = makePatternRule(endpoint: "/api/a")
        let incoming = makePatternRule(endpoint: "/api/b")

        let plan = RuleImporter.plan(try roundTrip([incoming]), existing: [existing])
        let outcome = RuleImporter.resolve(plan, strategy: .merge)

        XCTAssertEqual(plan.newRules.count, 1)
        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.added.first?.id, incoming.id)
        XCTAssertEqual(outcome.reIdentified, 0)
        XCTAssertEqual(outcome.skipped, 0)
    }

    func testImportingTheSameFileTwiceIsANoOp() throws {
        let rules = [makePatternRule(), makeHostRule(), makeBlockingGlobalRule()]
        let document = try roundTrip(rules)

        let first = RuleImporter.resolve(RuleImporter.plan(document, existing: []), strategy: .merge)
        XCTAssertEqual(first.added.count, 3)

        let second = RuleImporter.resolve(RuleImporter.plan(document, existing: first.added), strategy: .merge)
        XCTAssertTrue(second.added.isEmpty)
        XCTAssertEqual(second.skipped, 3)
    }

    func testDuplicatesInsideOneDocumentCollapse() throws {
        let rule = makePatternRule()
        let document = try roundTrip([rule, rule])

        let outcome = RuleImporter.resolve(RuleImporter.plan(document, existing: []), strategy: .merge)

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.skipped, 1)
    }

    func testTwoDifferentRulesSharingAnIdInsideOneDocumentBothLand() throws {
        let first = makePatternRule(endpoint: "/api/a")
        var second = first
        second.isBlocked = true

        let outcome = RuleImporter.resolve(
            RuleImporter.plan(try roundTrip([first, second]), existing: []),
            strategy: .merge
        )

        XCTAssertEqual(outcome.added.count, 2)
        XCTAssertEqual(outcome.reIdentified, 1)
        XCTAssertEqual(Set(outcome.added.map { $0.id }).count, 2)
    }

    // MARK: - Replace

    func testReplaceClearsExistingAndKeepsDocumentIds() throws {
        let rules = [makePatternRule(), makeHostRule()]
        let document = try roundTrip(rules)

        let plan = RuleImporter.plan(document, existing: [makePatternRule(endpoint: "/api/legacy")])
        let outcome = RuleImporter.resolve(plan, strategy: .replace)

        XCTAssertTrue(outcome.clearedExisting)
        XCTAssertEqual(outcome.added.map { $0.id }, rules.map { $0.id })
        XCTAssertEqual(outcome.reIdentified, 0)
    }

    // MARK: - Storage keying

    /// A hand-edited global rule keyed under a path would never fire, because lookup only probes
    /// `"global"`. Import re-keys it instead of importing something that silently does nothing.
    func testGlobalRuleIsReKeyedOnImport() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RuleExporter.makeDocument(from: [makeBlockingGlobalRule()], app: app).jsonData()) as? [String: Any]
        )
        var ruleObjects = try XCTUnwrap(root["rules"] as? [[String: Any]])
        ruleObjects[0]["matchEndpoint"] = "/api/typo"
        root["rules"] = ruleObjects

        let document = try RuleTransferDocument.decode(try JSONSerialization.data(withJSONObject: root))
        let plan = RuleImporter.plan(document, existing: [])

        XCTAssertEqual(plan.planned.first?.transferRule.rule.matchEndpoint, "global")
    }

    func testHostRuleKeyIsRebuiltFromItsHosts() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RuleExporter.makeDocument(from: [makeHostRule()], app: app).jsonData()) as? [String: Any]
        )
        var ruleObjects = try XCTUnwrap(root["rules"] as? [[String: Any]])
        ruleObjects[0]["matchEndpoint"] = "host:stale"
        ruleObjects[0]["matchHosts"] = ["B.example.com", "a.example.com"]
        root["rules"] = ruleObjects

        let document = try RuleTransferDocument.decode(try JSONSerialization.data(withJSONObject: root))
        let imported = try XCTUnwrap(RuleImporter.plan(document, existing: []).planned.first?.transferRule.rule)

        XCTAssertEqual(imported.matchHosts, ["a.example.com", "b.example.com"])
        XCTAssertEqual(imported.matchEndpoint, "host:a.example.com,b.example.com")
    }

    // MARK: - File output

    func testExportFileNameUsesTheBundleId() {
        XCTAssertEqual(RuleExporter.fileName(bundleId: "com.acme.app"), "SwiftyDebug-Rules-com.acme.app.json")
        XCTAssertEqual(RuleExporter.fileName(bundleId: "com acme/app"), "SwiftyDebug-Rules-com-acme-app.json")
        XCTAssertEqual(RuleExporter.fileName(bundleId: ""), "SwiftyDebug-Rules-app.json")
    }

    func testWrittenFileDecodesBack() throws {
        let rule = makePatternRule()
        let document = RuleExporter.makeDocument(from: [rule], app: app)

        let url = try RuleExporter.writeToTemporaryFile(document)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "SwiftyDebug-Rules-com.acme.app.json")
        let decoded = try RuleTransferDocument.decode(Data(contentsOf: url))
        XCTAssertEqual(decoded.rules.first?.rule.id, rule.id)
    }

    func testPlanSummaryReadsLikeASentence() throws {
        let mine = makePatternRule()
        let unrelated = makePatternRule(endpoint: "/api/other")
        var sameIdDifferentBody = mine
        sameIdDifferentBody.isBlocked = true

        let document = try roundTrip([mine, unrelated, sameIdDifferentBody])
        let plan = RuleImporter.plan(document, existing: [mine])

        XCTAssertEqual(plan.summary, "3 rules · 1 already exists · 1 id conflict")
    }
}
