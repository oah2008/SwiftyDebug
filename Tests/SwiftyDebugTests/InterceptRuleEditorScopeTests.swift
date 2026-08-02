//
//  InterceptRuleEditorScopeTests.swift
//  SwiftyDebugTests
//
//  Covers the three things the rule editor got wrong for the endpoint
//  `/product/10289032912/20920220`:
//
//    1. It SHOWED `/product/10289032912` — the row used a stock
//       `UITableViewCell` label, which does not self-size and clipped the path.
//       You could not tell which of two long paths a rule was on.
//    2. Editing a rule never re-assigned `matchEndpoint`, so switching
//       Pattern → Exact left the pattern in place. Every such rule was filed
//       under `/product/{id}/{id}`, which no request path can equal — they all
//       shared one dead key and overwrote each other.
//    3. An endpoint rule matched the PATH ONLY, on every host, with nothing on
//       screen saying so.
//
//  Plus the name: a rule with no name of its own has to describe itself, and
//  keep describing itself as the configuration changes.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class InterceptRuleEditorScopeTests: XCTestCase {

    private typealias Editor = InterceptRuleEditorViewController

    /// The reported path, in full.
    private let longPath = "/product/10289032912/20920220"
    private let host = "api.example.com"

    // MARK: - Helpers

    /// A captured request with nothing on it to pre-fill, so "nothing is armed"
    /// really is the starting state.
    private func model(path: String, host: String = "api.example.com") -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(host)\(path)")
        model.method = "GET"
        model.statusCode = "200"
        return model
    }

    /// A captured request carrying headers and a query, which a new endpoint
    /// rule pre-fills — already switched on.
    private func richModel(path: String, host: String = "api.example.com") -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(host)\(path)?page=2")
        model.method = "GET"
        model.statusCode = "200"
        model.requestHeaderFields = ["Authorization": "Bearer abc", "Accept": "application/json"]
        return model
    }

    /// A loaded editor for a brand-new rule on `path`.
    private func newRuleEditor(path: String,
                               host: String = "api.example.com",
                               mode: EndpointMatchMode = .normalized) -> Editor {
        let editor = Editor()
        editor.httpModel = model(path: path, host: host)
        editor.initialMatchMode = mode
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        editor.view.layoutIfNeeded()
        return editor
    }

    private func endpointCell(_ editor: Editor, row: Int) -> UITableViewCell {
        editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: row, section: 1))
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for sub in view.subviews { found.append(contentsOf: labels(in: sub)) }
        return found
    }

    private func segmentedControl(in view: UIView) -> UISegmentedControl? {
        if let seg = view as? UISegmentedControl { return seg }
        for sub in view.subviews {
            if let found = segmentedControl(in: sub) { return found }
        }
        return nil
    }

    /// Flips the Pattern/Exact control the way a tap does. `sendActions` is no
    /// use here — these tests have no host application to route target/action
    /// through — so the control is checked for what a tap could do and the
    /// editor is then driven through the same seam the action calls.
    private func selectExact(_ editor: Editor) {
        let cell = endpointCell(editor, row: 0)
        guard let seg = segmentedControl(in: cell.contentView) else {
            XCTFail("No Pattern/Exact control in the first ENDPOINT row")
            return
        }
        XCTAssertTrue(seg.isEnabledForSegment(at: 1), "Exact must be offered when there is a real path")
        editor.setMatchMode(.exact)
    }

    private func savedRule(_ editor: Editor,
                           file: StaticString = #filePath, line: UInt = #line) -> InterceptRule? {
        switch editor.validatedRule() {
        case .ok(let rule): return rule
        case .noHosts:      XCTFail("Refused: no hosts", file: file, line: line)
        case .noEndpoint:   XCTFail("Refused: no endpoint", file: file, line: line)
        case .noEffect:     XCTFail("Refused: nothing armed", file: file, line: line)
        }
        return nil
    }

    /// Arms something so the rule is saveable — the editor refuses inert rules.
    private func armBlock(_ editor: Editor) {
        let cell = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: 0, section: 2))
        guard cell.accessoryView is UISwitch else {
            XCTFail("The first ACTION row should carry the Block switch")
            return
        }
        editor.setBlocked(true)
    }

    // MARK: - 1. The path is shown in full

    func testExactRowShowsTheWholePathNotAPrefix() {
        let editor = newRuleEditor(path: longPath)
        selectExact(editor)

        let texts = labels(in: endpointCell(editor, row: 1)).compactMap { $0.text }
        XCTAssertTrue(texts.contains(longPath),
                      "The exact row must show \(longPath) verbatim, got \(texts)")
        // The reported symptom, asserted directly: never the truncated prefix.
        XCTAssertFalse(texts.contains("/product/10289032912"),
                       "The path must never be shown cut off at a component boundary")
    }

    func testPathLabelWrapsInsteadOfTruncating() {
        let editor = newRuleEditor(path: longPath)
        selectExact(editor)
        let cell = endpointCell(editor, row: 1)
        guard let label = labels(in: cell).first(where: { $0.text == longPath }) else {
            return XCTFail("No label carrying the path")
        }
        XCTAssertEqual(label.numberOfLines, 0, "A path must be allowed as many lines as it needs")
        XCTAssertNotEqual(label.lineBreakMode, .byTruncatingTail,
                          "Truncating the tail is exactly the bug being fixed")
        XCTAssertNotEqual(label.lineBreakMode, .byTruncatingMiddle)
        XCTAssertNotEqual(label.lineBreakMode, .byTruncatingHead)
    }

    /// The stock-cell defect showed up as a row that stayed the same height no
    /// matter how long the path was — the text past the first line was simply
    /// gone. A long path must make the row taller.
    func testALongPathMakesTheRowTaller() {
        func height(of path: String) -> CGFloat {
            let editor = newRuleEditor(path: path)
            selectExact(editor)
            let cell = endpointCell(editor, row: 1)
            cell.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            return cell.contentView.systemLayoutSizeFitting(
                CGSize(width: 390, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
        }

        let short = height(of: "/a")
        let twoLines = height(of: longPath + "/variant/9988776655/details/extended")
        let manyLines = height(of: longPath + String(repeating: "/segment/1234567890", count: 6))

        XCTAssertGreaterThan(twoLines, short + 10,
                             "A path too long for one line must wrap (short: \(short), long: \(twoLines))")
        XCTAssertGreaterThan(manyLines, twoLines + 20,
                             "Row height must keep growing with the path — clipping is what it looked like "
                                + "when it did not (\(twoLines) vs \(manyLines))")
    }

    // MARK: - 2. Exact rules are the full path, and never collide

    func testExactRuleSavesTheFullPath() {
        let editor = newRuleEditor(path: longPath)
        selectExact(editor)
        armBlock(editor)

        let rule = savedRule(editor)
        XCTAssertEqual(rule?.matchMode, .exact)
        XCTAssertEqual(rule?.matchEndpoint, longPath,
                       "The exact endpoint is the full path — not a prefix, not the pattern")
    }

    func testTwoExactRulesOnDifferentPathsGetDifferentKeys() {
        let first = newRuleEditor(path: longPath)
        selectExact(first); armBlock(first)
        let second = newRuleEditor(path: "/product/555/666")
        selectExact(second); armBlock(second)

        let a = savedRule(first)
        let b = savedRule(second)
        XCTAssertNotEqual(a?.storageKey, b?.storageKey,
                          "Two exact rules on different paths must never share a bucket")
    }

    /// The re-key. `rule = existingRule ?? InterceptRule(...)` meant the
    /// endpoint of an EDITED rule was never written, so Pattern → Exact kept
    /// `/product/{id}/{id}` — a key nothing can ever match.
    func testSwitchingAnExistingRuleToExactRewritesItsEndpoint() {
        var pattern = InterceptRule.endpointRule(path: "/product/{id}/{id}",
                                                 mode: .normalized, host: host)
        pattern.isBlocked = true
        let before = pattern.storageKey

        let editor = Editor()
        editor.httpModel = model(path: longPath, host: host)
        editor.ruleToEdit = pattern
        editor.loadViewIfNeeded()

        selectExact(editor)
        let rule = savedRule(editor)

        XCTAssertEqual(rule?.id, pattern.id, "It must stay the same rule, not become a second one")
        XCTAssertEqual(rule?.matchMode, .exact)
        XCTAssertEqual(rule?.matchEndpoint, longPath)
        XCTAssertNotEqual(rule?.storageKey, before, "A re-scoped rule has to be re-keyed")
        XCTAssertFalse(rule?.matchEndpoint.contains("{id}") ?? true,
                       "A pattern must never be saved as an exact path")
    }

    /// The seeding half of the same bug: the editor filled BOTH the Pattern and
    /// the Exact field with `rule.matchEndpoint`.
    func testEndpointSeedKeepsPatternAndExactApart() {
        let exactRule = InterceptRule.endpointRule(path: longPath, mode: .exact)
        let fromExact = Editor.endpointSeed(for: exactRule, capturedPath: longPath)
        XCTAssertEqual(fromExact.exact, longPath)
        XCTAssertEqual(fromExact.pattern, "/product/{id}/{id}")

        let patternRule = InterceptRule.endpointRule(path: "/product/{id}/{id}", mode: .normalized)
        let fromPattern = Editor.endpointSeed(for: patternRule, capturedPath: longPath)
        XCTAssertEqual(fromPattern.pattern, "/product/{id}/{id}")
        XCTAssertEqual(fromPattern.exact, longPath,
                       "A captured request that IS an instance of the pattern is the exact candidate")
    }

    func testEndpointSeedOffersNoExactPathWhenNothingConcreteIsKnown() {
        let patternRule = InterceptRule.endpointRule(path: "/product/{id}/{id}", mode: .normalized)
        // A captured request from a different endpoint is not an instance of it.
        let seed = Editor.endpointSeed(for: patternRule, capturedPath: "/cart")
        XCTAssertEqual(seed.pattern, "/product/{id}/{id}")
        XCTAssertTrue(seed.exact.isEmpty,
                      "With no real path, Exact must offer nothing rather than the pattern")
    }

    func testExactIsNotOfferedWithoutARealPath() {
        var pattern = InterceptRule.endpointRule(path: "/product/{id}/{id}", mode: .normalized)
        pattern.isBlocked = true
        let editor = Editor()
        editor.ruleToEdit = pattern          // no captured request behind it
        editor.loadViewIfNeeded()

        let cell = endpointCell(editor, row: 0)
        let seg = segmentedControl(in: cell.contentView)
        XCTAssertEqual(seg?.isEnabledForSegment(at: 1), false,
                       "Exact has no path to match here and must not be selectable")
    }

    // MARK: - 3. This host vs any host

    func testNewEndpointRuleIsPinnedToTheRequestHost() {
        let editor = newRuleEditor(path: longPath, host: host)
        armBlock(editor)
        let rule = savedRule(editor)
        XCTAssertEqual(rule?.matchHost, host,
                       "Matching one path on every host is the surprising answer — it must not be the default")
        XCTAssertFalse(rule?.appliesToAnyHost ?? true)
    }

    func testAnyHostIsStillAvailableAndClearsThePin() {
        let editor = newRuleEditor(path: longPath, host: host)
        armBlock(editor)
        editor.setHostScope(pinned: false)

        let rule = savedRule(editor)
        XCTAssertEqual(rule?.matchHost, "")
        XCTAssertTrue(rule?.appliesToAnyHost ?? false)

        editor.setHostScope(pinned: true)
        XCTAssertEqual(savedRule(editor)?.matchHost, host, "The pin must be recoverable")
    }

    func testExistingAnyHostRuleKeepsMatchingEveryHost() {
        // Every rule already on a device has no pin. Opening one and saving it
        // must not quietly narrow it to the host that happened to be on screen.
        var legacy = InterceptRule(matchEndpoint: longPath, matchMode: .exact)
        legacy.isBlocked = true
        let editor = Editor()
        editor.httpModel = model(path: longPath, host: host)
        editor.ruleToEdit = legacy
        editor.loadViewIfNeeded()

        XCTAssertEqual(savedRule(editor)?.matchHost, "",
                       "An existing any-host rule must survive a round trip through the editor unchanged")
    }

    func testTheHostScopeIsOnScreen() {
        let editor = newRuleEditor(path: longPath, host: host)
        let rows = editor.tableView(editor.tableView, numberOfRowsInSection: 1)
        XCTAssertEqual(rows, 3, "ENDPOINT is mode + path + host scope")

        let hostTexts = labels(in: endpointCell(editor, row: 2)).compactMap { $0.text }
        XCTAssertTrue(hostTexts.contains(host), "The row must name the host, got \(hostTexts)")

        editor.setHostScope(pinned: false)
        let anyTexts = labels(in: endpointCell(editor, row: 2)).compactMap { $0.text }
        XCTAssertTrue(anyTexts.contains("Any host"), "Any-host must say so, got \(anyTexts)")

        // ...and the path row says it too, so the scope is never ambiguous.
        let detail = labels(in: endpointCell(editor, row: 1)).compactMap { $0.text }.joined(separator: " ")
        XCTAssertTrue(detail.contains("ANY host"), "The endpoint row must state the host scope, got \(detail)")
    }

    func testHostRowIsHiddenWhenThereIsNoHostToPinTo() {
        var pattern = InterceptRule.endpointRule(path: "/product/{id}/{id}", mode: .normalized)
        pattern.isBlocked = true
        let editor = Editor()
        editor.ruleToEdit = pattern
        editor.loadViewIfNeeded()
        XCTAssertEqual(editor.tableView(editor.tableView, numberOfRowsInSection: 1), 2,
                       "With no host in context there is nothing to offer, so no row")
    }

    // MARK: - 4. Names

    func testAnUntouchedNameKeepsTrackingTheConfiguration() {
        let editor = newRuleEditor(path: longPath, host: host)
        armBlock(editor)

        let rule = savedRule(editor)
        XCTAssertEqual(rule?.name, "",
                       "Freezing the derived text into `name` stops it describing the rule")
        XCTAssertEqual(rule?.displayName, rule?.derivedName)
        XCTAssertTrue(rule?.displayName.contains("Blocked") ?? false,
                      "A blocked rule names itself, got \(rule?.displayName ?? "-")")
        XCTAssertNotEqual(rule?.displayName, "Empty rule")
    }

    func testTypedNameIsSavedAndWins() {
        let editor = newRuleEditor(path: longPath, host: host)
        armBlock(editor)

        let cell = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        guard let field = (cell as? RuleNameCell)?.field else {
            return XCTFail("The NAME row must carry a text field")
        }
        XCTAssertEqual(field.text ?? "", "", "The field starts empty — the derived name is a placeholder")
        XCTAssertEqual(field.attributedPlaceholder?.string, editor.derivedNamePreview)

        field.text = "  Kill product tracking  "
        // The editing-changed handler itself; `sendActions` cannot route without
        // a host application.
        editor.perform(NSSelectorFromString("nameFieldChanged:"), with: field)

        let rule = savedRule(editor)
        XCTAssertEqual(rule?.name, "Kill product tracking")
        XCTAssertEqual(rule?.displayName, "Kill product tracking")
    }

    func testDerivedNamePreviewFollowsWhatIsArmed() {
        let editor = newRuleEditor(path: longPath, host: host)
        let empty = editor.derivedNamePreview
        XCTAssertTrue(empty.hasPrefix("Empty rule"), "Nothing armed yet, got \(empty)")

        selectExact(editor)
        armBlock(editor)
        let armed = editor.derivedNamePreview
        XCTAssertNotEqual(armed, empty, "The placeholder must update as the rule is configured")
        XCTAssertTrue(armed.contains("Blocked"), "got \(armed)")
        XCTAssertTrue(armed.contains(longPath), "The name should say where it applies, got \(armed)")
    }

    // MARK: - Nothing else regressed

    /// "Only checked rows apply" survives the new save path — it still goes
    /// through `partition`. (The pure coverage lives in
    /// InterceptRuleActivationTests; this is the wiring.)
    func testUncheckedHeaderIsStillInert() {
        let editor = Editor()
        editor.httpModel = richModel(path: longPath, host: host)
        editor.initialMatchMode = .normalized
        editor.loadViewIfNeeded()

        let all = savedRule(editor)
        XCTAssertEqual(all?.headerOverrides.count, 2, "Both captured headers start switched on")
        XCTAssertEqual(all?.queryParamOverrides.count, 1)

        // Section 4 = HEADERS. Switch the first row off the way a tap does.
        let cell = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: 0, section: 4))
        guard let card = cell as? KeyValueCardCell else {
            return XCTFail("HEADERS rows are KeyValueCardCells")
        }
        card.onActiveToggled?()

        let trimmed = savedRule(editor)
        XCTAssertEqual(trimmed?.headerOverrides.count, 1,
                       "An unchecked header must not be carried into the rule")
    }

    func testAnEmptyRuleIsStillRefused() {
        let editor = newRuleEditor(path: longPath, host: host)
        switch editor.validatedRule() {
        case .noEffect: break
        default: XCTFail("A rule that does nothing must not be saveable")
        }
    }
}
