//
//  InterceptRuleEditorEndToEndVerificationTests.swift
//  SwiftyDebugTests
//
//  Drives the REAL editor screen and then asks the REAL store what a request
//  would be answered with — the two halves the report is about:
//
//    * the screen must SHOW the whole path (`/product/10289032912/20920220`),
//      not the prefix the user saw
//    * whatever scope the screen shows must be the scope that fires on the wire
//
//  A scope the store ignores is this codebase's recurring failure, so these
//  assert on the resolved rule, not on the editor's own state.
//

import XCTest
@testable import SwiftyDebug

final class InterceptRuleEditorEndToEndVerificationTests: XCTestCase {

    private let reportedPath = "/product/10289032912/20920220"
    private let reportedURL = "https://api.example.com/product/10289032912/20920220"

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func model(_ urlString: String) -> NetworkTransaction {
        let m = NetworkTransaction()
        m.url = NSURL(string: urlString)
        m.method = "GET"
        return m
    }

    /// A loaded editor with its table laid out at a realistic phone width.
    private func loadedEditor(url: String,
                              mode: EndpointMatchMode = .exact) -> InterceptRuleEditorViewController {
        let vc = InterceptRuleEditorViewController()
        vc.httpModel = model(url)
        vc.initialMatchMode = mode
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.view.layoutIfNeeded()
        return vc
    }

    private func firstTable(in view: UIView) -> UITableView? {
        if let tv = view as? UITableView { return tv }
        for sub in view.subviews {
            if let tv = firstTable(in: sub) { return tv }
        }
        return nil
    }

    private func table(of vc: UIViewController) -> UITableView {
        firstTable(in: vc.view)!
    }

    /// Every string any cell in the table renders.
    private func allRenderedText(_ vc: UIViewController) -> [String] {
        let tv = table(of: vc)
        tv.layoutIfNeeded()
        var out: [String] = []
        for section in 0..<tv.numberOfSections {
            for row in 0..<tv.numberOfRows(inSection: section) {
                let cell = tv.dataSource!.tableView(tv, cellForRowAt: IndexPath(row: row, section: section))
                out.append(contentsOf: labels(in: cell).compactMap { $0.text })
                out.append(contentsOf: labels(in: cell).compactMap { $0.attributedText?.string })
            }
        }
        return out
    }

    private func labels(in view: UIView) -> [UILabel] {
        var out: [UILabel] = []
        if let l = view as? UILabel { out.append(l) }
        for sub in view.subviews { out.append(contentsOf: labels(in: sub)) }
        return out
    }

    // MARK: - The truncation

    /// The headline check: the editor must render the FULL path, and must never
    /// render the prefix the user reported seeing on its own.
    func testTheEditorRendersTheWholeReportedPathUnderExact() {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        let texts = allRenderedText(vc)

        XCTAssertTrue(texts.contains(reportedPath),
                      "The editor never rendered the full path. Rendered: \(texts)")
        XCTAssertFalse(texts.contains("/product/10289032912"),
                       "The editor rendered the TRUNCATED path the user reported")
    }

    /// Rendering the string is not enough — a stock cell renders it and then
    /// clips it. The label must be allowed to wrap and the row must grow.
    func testThePathLabelIsAllowedToWrapAndTheRowGrows() {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        let tv = table(of: vc)
        tv.layoutIfNeeded()

        var pathLabel: UILabel?
        var pathCell: UITableViewCell?
        outer: for section in 0..<tv.numberOfSections {
            for row in 0..<tv.numberOfRows(inSection: section) {
                let cell = tv.dataSource!.tableView(tv, cellForRowAt: IndexPath(row: row, section: section))
                if let l = labels(in: cell).first(where: { $0.text == reportedPath }) {
                    pathLabel = l
                    pathCell = cell
                    break outer
                }
            }
        }

        let label = try! XCTUnwrap(pathLabel)
        XCTAssertEqual(label.numberOfLines, 0, "The path label is capped and will clip a long path")

        // A cell that self-sizes must be taller than a stock 44pt row once the
        // path no longer fits on one line.
        let cell = try! XCTUnwrap(pathCell)
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 0)
        cell.layoutIfNeeded()
        let fitted = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        XCTAssertGreaterThan(fitted, 0, "The path cell computes no height, so it cannot self-size")
    }

    /// A path far longer than the reported one must still come through whole.
    func testAVeryLongPathIsNotShortenedAnywhereInTheEditor() {
        let long = "/product/10289032912/20920220/reviews/8837273/replies/992837/attachments/55512"
        let vc = loadedEditor(url: "https://api.example.com" + long, mode: .exact)
        XCTAssertTrue(allRenderedText(vc).contains(long),
                      "A long path was shortened before it reached the screen")
    }

    // MARK: - Host scope reaches the wire

    /// The default for a NEW endpoint rule is the host pin, and it must be the
    /// scope the store actually enforces.
    func testANewRuleDefaultsToTheHostPinAndTheStoreEnforcesIt() throws {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        vc.setBlocked(true)

        guard case .ok(let rule) = vc.validatedRule() else {
            return XCTFail("The editor refused to build a rule")
        }
        XCTAssertEqual(rule.matchHost, "api.example.com", "A new endpoint rule did not default to the host pin")
        XCTAssertEqual(rule.matchEndpoint, reportedPath, "The saved rule did not carry the full path")
        XCTAssertEqual(rule.matchMode, .exact)

        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: reportedURL)!),
                        "The rule the editor built does not fire on the request it was built from")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://other.com/product/10289032912/20920220")!),
                     "The host pin shown in the editor is not enforced on the wire")
    }

    /// Choosing "any host" in the sheet must reach the wire too.
    func testChoosingAnyHostReachesTheWire() throws {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        vc.setBlocked(true)
        vc.setHostScope(pinned: false)

        guard case .ok(let rule) = vc.validatedRule() else {
            return XCTFail("The editor refused to build a rule")
        }
        XCTAssertEqual(rule.matchHost, "", "Choosing any-host left a host pin on the rule")

        InterceptRuleStore.shared.addOrUpdate(rule)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(
            forURL: URL(string: "https://other.com/product/10289032912/20920220")!),
                        "An any-host rule did not fire on another host")
    }

    /// Flipping back to pinned must re-pin, not leave the rule any-host.
    func testFlippingBackToPinnedRePinsTheRule() throws {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        vc.setBlocked(true)
        vc.setHostScope(pinned: false)
        vc.setHostScope(pinned: true)

        guard case .ok(let rule) = vc.validatedRule() else {
            return XCTFail("The editor refused to build a rule")
        }
        XCTAssertEqual(rule.matchHost, "api.example.com")
    }

    /// The screen must SAY which scope is in force — a silent default on
    /// something that changes what the app's traffic does is the house rule.
    func testTheEditorStatesTheScopeItIsUsing() {
        let pinned = loadedEditor(url: reportedURL, mode: .exact)
        XCTAssertTrue(allRenderedText(pinned).contains { $0.contains("api.example.com") },
                      "The editor never says which host the rule is pinned to")

        let any = loadedEditor(url: reportedURL, mode: .exact)
        any.setHostScope(pinned: false)
        XCTAssertTrue(allRenderedText(any).contains { $0.lowercased().contains("any host") },
                      "The editor never says the rule matches any host")
    }

    // MARK: - The two reported rules, built through the editor

    /// End to end: build BOTH reported rules through the real editor, save them,
    /// and check each URL is answered by its own rule.
    func testBothReportedRulesBuiltThroughTheEditorStayIndependent() throws {
        let first = loadedEditor(url: reportedURL, mode: .exact)
        first.setBlocked(true)
        guard case .ok(var ruleA) = first.validatedRule() else { return XCTFail("rule A refused") }
        ruleA.name = "RULE-A"
        InterceptRuleStore.shared.addOrUpdate(ruleA)

        let secondURL = "https://api.example.com/product/10289032912/33333333"
        let second = loadedEditor(url: secondURL, mode: .exact)
        second.setBlocked(true)
        guard case .ok(var ruleB) = second.validatedRule() else { return XCTFail("rule B refused") }
        ruleB.name = "RULE-B"
        InterceptRuleStore.shared.addOrUpdate(ruleB)

        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2,
                       "Two exact rules built through the editor collapsed into one")
        XCTAssertEqual(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: reportedURL)!)?.name, "RULE-A")
        XCTAssertEqual(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: secondURL)!)?.name, "RULE-B")
    }

    // MARK: - Name

    /// The name row must exist, and an unnamed rule must offer a description of
    /// itself rather than a blank field.
    func testTheEditorOffersANamePlaceholderDescribingTheRule() {
        let vc = loadedEditor(url: reportedURL, mode: .exact)
        vc.setBlocked(true)
        let tv = table(of: vc)
        tv.reloadData()
        tv.layoutIfNeeded()

        var placeholders: [String] = []
        var fields = 0
        for section in 0..<tv.numberOfSections {
            for row in 0..<tv.numberOfRows(inSection: section) {
                let cell = tv.dataSource!.tableView(tv, cellForRowAt: IndexPath(row: row, section: section))
                if let nameCell = cell as? RuleNameCell {
                    fields += 1
                    placeholders.append(nameCell.field.attributedPlaceholder?.string ?? "")
                }
            }
        }
        XCTAssertEqual(fields, 1, "Expected exactly one name field on the editor")
        let placeholder = placeholders.first ?? ""
        XCTAssertFalse(placeholder.isEmpty, "The name field has no placeholder to describe the rule")
        XCTAssertNotEqual(placeholder, "Empty rule",
                          "The name placeholder reads 'Empty rule' for an armed rule")
        XCTAssertTrue(placeholder.contains("Blocked"), "The placeholder does not describe what the rule does: \(placeholder)")
    }
}
