//
//  RuleEditorNoAutoScopeSheetTests.swift
//  SwiftyDebugTests
//
//  Reported from the device: creating a rule popped a sheet asking "this host
//  or any host?" before the user had done anything. The answer it offered as
//  the default (THIS HOST) was already the default the editor applies, so the
//  sheet asked a question whose answer was never going to change — it just
//  stood between the user and the screen they asked for.
//
//  What these pin:
//    * appearing NEVER presents anything on its own;
//    * a new endpoint rule still defaults to the request's host;
//    * the endpoint row still SAYS which scope is in force;
//    * the existing control still opens the picker on tap, and both answers
//      still reach the store and the wire.
//
//  The last two matter as much as the first: deleting the presentation and
//  leaving the scope unreachable would "fix" the complaint by removing the
//  feature.
//

import XCTest
import UIKit
@testable import SwiftyDebug

/// The shipped editor with ONE thing changed: it records what it is asked to
/// present instead of presenting it. Nothing else is overridden, so every
/// assertion below is about the real screen's behaviour.
private final class PresentationRecordingEditor: InterceptRuleEditorViewController {
    private(set) var presentedControllers: [UIViewController] = []

    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool,
                          completion: (() -> Void)?) {
        presentedControllers.append(viewControllerToPresent)
        completion?()
    }
}

final class RuleEditorNoAutoScopeSheetTests: XCTestCase {

    private let path = "/product/10289032912/20920220"
    private let host = "api.example.com"

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    private func model(path: String, host: String) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(host)\(path)")
        model.method = "GET"
        model.statusCode = "200"
        return model
    }

    /// A loaded editor for a BRAND-NEW endpoint rule — the exact case that
    /// popped the sheet.
    private func newRuleEditor(mode: EndpointMatchMode = .normalized) -> PresentationRecordingEditor {
        let editor = PresentationRecordingEditor()
        editor.httpModel = model(path: path, host: host)
        editor.initialMatchMode = mode
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        editor.view.layoutIfNeeded()
        return editor
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for sub in view.subviews { found.append(contentsOf: labels(in: sub)) }
        return found
    }

    private func endpointRowText(_ editor: InterceptRuleEditorViewController, row: Int) -> [String] {
        let cell = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: row, section: 1))
        return labels(in: cell).compactMap { $0.text }
    }

    private func savedRule(_ editor: InterceptRuleEditorViewController,
                           file: StaticString = #filePath, line: UInt = #line) -> InterceptRule? {
        switch editor.validatedRule() {
        case .ok(let rule): return rule
        default: XCTFail("The editor refused to build a rule", file: file, line: line); return nil
        }
    }

    // MARK: - 1. Appearing presents nothing

    func testCreatingARuleDoesNotAutoOpenTheHostScopeSheet() {
        let editor = newRuleEditor()
        editor.viewDidAppear(false)

        XCTAssertTrue(editor.presentedControllers.isEmpty,
                      "Creating a rule auto-opened a sheet: "
                        + editor.presentedControllers.map { String(describing: type(of: $0)) }.joined(separator: ", "))
    }

    /// Appearing repeatedly (pushing the mock editor and coming back, for
    /// instance) must not start presenting it either.
    func testReappearingNeverStartsPresentingTheSheet() {
        let editor = newRuleEditor()
        editor.viewDidAppear(false)
        editor.viewDidAppear(false)
        editor.viewDidAppear(false)
        XCTAssertTrue(editor.presentedControllers.isEmpty,
                      "The scope sheet came back on a later appearance")
    }

    func testEditingAnExistingRuleAlsoPresentsNothing() {
        var rule = InterceptRule.endpointRule(path: path, mode: .exact, host: host)
        rule.isBlocked = true
        let editor = PresentationRecordingEditor()
        editor.httpModel = model(path: path, host: host)
        editor.ruleToEdit = rule
        editor.loadViewIfNeeded()
        editor.viewDidAppear(false)
        XCTAssertTrue(editor.presentedControllers.isEmpty)
    }

    // MARK: - 2. The default the sheet used to offer is still the default

    func testANewEndpointRuleStillDefaultsToThisHost() {
        let editor = newRuleEditor()
        editor.viewDidAppear(false)
        editor.setBlocked(true)

        let rule = savedRule(editor)
        XCTAssertEqual(rule?.matchHost, host,
                       "Removing the sheet must not remove the pin it defaulted to")
        XCTAssertFalse(rule?.appliesToAnyHost ?? true)
    }

    /// …and the screen still says so, so the default is never silent.
    func testTheActiveScopeIsShownOnTheEndpointRow() {
        let editor = newRuleEditor()
        editor.viewDidAppear(false)
        XCTAssertEqual(editor.tableView(editor.tableView, numberOfRowsInSection: 1), 3,
                       "ENDPOINT is mode + path + host scope")
        XCTAssertTrue(endpointRowText(editor, row: 2).contains(host),
                      "The host-scope row must show the host in force, got \(endpointRowText(editor, row: 2))")

        editor.setHostScope(pinned: false)
        XCTAssertTrue(endpointRowText(editor, row: 2).contains("Any host"),
                      "…and must say so when the pin is cleared, got \(endpointRowText(editor, row: 2))")
    }

    // MARK: - 3. The control that changes it still works

    func testTappingTheHostScopeRowStillOpensThePicker() {
        let editor = newRuleEditor()
        editor.viewDidAppear(false)
        XCTAssertTrue(editor.presentedControllers.isEmpty, "Precondition: nothing opened on its own")

        editor.tableView(editor.tableView, didSelectRowAt: IndexPath(row: 2, section: 1))

        XCTAssertEqual(editor.presentedControllers.count, 1,
                       "The host-scope row must still be the way to change the scope")
        let picker = (editor.presentedControllers.first as? UINavigationController)?.viewControllers.first
        XCTAssertTrue(picker is OptionPickerSheetViewController,
                      "Tapping the row should open the scope picker, got \(String(describing: picker))")
    }

    func testBothAnswersStillReachTheStoreAndTheWire() throws {
        // Any host, chosen from the row, saved the way Save saves it.
        let creating = newRuleEditor(mode: .exact)
        creating.viewDidAppear(false)
        creating.setBlocked(true)
        creating.setHostScope(pinned: false)
        let anyHost = try XCTUnwrap(savedRule(creating))
        XCTAssertEqual(anyHost.matchHost, "")
        InterceptRuleStore.shared.addOrUpdate(anyHost)
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://other.com\(path)")!),
                        "An any-host rule chosen from the row did not reach the wire")

        // Re-open THAT rule and pin it back — one rule, re-keyed, not two.
        let reopening = PresentationRecordingEditor()
        reopening.httpModel = model(path: path, host: host)
        reopening.ruleToEdit = try XCTUnwrap(InterceptRuleStore.shared.allRules().first)
        reopening.loadViewIfNeeded()
        reopening.viewDidAppear(false)
        XCTAssertTrue(reopening.presentedControllers.isEmpty)

        reopening.setHostScope(pinned: true)
        let pinned = try XCTUnwrap(savedRule(reopening))
        XCTAssertEqual(pinned.matchHost, host)
        XCTAssertEqual(pinned.id, anyHost.id, "It must stay one rule, not become two")
        InterceptRuleStore.shared.addOrUpdate(pinned)
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1,
                       "Re-scoping left a stale twin behind")
        XCTAssertNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://other.com\(path)")!),
                     "The pin chosen from the row is not enforced on the wire")
        XCTAssertNotNil(InterceptRuleStore.shared.resolvedRule(forURL: URL(string: "https://\(host)\(path)")!))
    }
}
