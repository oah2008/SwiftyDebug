//
//  AdversarialRuleScopeEntryPointTests.swift
//  SwiftyDebugTests
//
//  Every scope, from every entry point, all the way to the wire.
//
//  Three screens open the rule editor, and they configure it differently:
//
//    * the request detail screen  → `httpModel` + `initialMatchMode`
//    * the rule list              → `httpModel` + `initialMatchMode`
//    * the App tab                → `initialMatchMode` only, NO request
//
//  The last one is the interesting one: with no request there is no host to pin
//  to and no path to match, so an endpoint rule cannot be created there at all —
//  and the editor has to refuse it rather than save something inert. The other
//  two must default an endpoint rule to the request's OWN host, must not present
//  anything on their own, and must still let the host row change that answer.
//
//  Every case ends at `InterceptRuleStore.resolvedRule(forURL:)` with two URLs:
//  the one the rule is for, and one on a different host. A scope that does not
//  reach the wire, or that reaches too far, fails here.
//

import XCTest
import UIKit
@testable import SwiftyDebug

/// The shipped editor that records what it is asked to present instead of
/// presenting it. Nothing else is overridden.
private final class ScopeRecordingEditor: InterceptRuleEditorViewController {
    private(set) var presented: [UIViewController] = []
    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool, completion: (() -> Void)?) {
        presented.append(viewControllerToPresent)
        completion?()
    }
}

final class AdversarialRuleScopeEntryPointTests: XCTestCase {

    private let path = "/product/10289032912/20920220"
    private let pattern = "/product/{id}/{id}"
    private let host = "api.example.com"
    private let otherHost = "staging.example.com"

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    /// The three ways the SDK builds this screen, named after where they come
    /// from. Only `httpModel` differs — which is exactly the axis the scope
    /// defaulting depends on.
    private enum EntryPoint: String, CaseIterable {
        case requestDetail, ruleList, appTab
        var carriesARequest: Bool { self != .appTab }
    }

    private func transaction() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(host)\(path)")
        model.method = "GET"
        model.statusCode = "200"
        return model
    }

    private func editor(_ entry: EntryPoint, mode: EndpointMatchMode) -> ScopeRecordingEditor {
        let editor = ScopeRecordingEditor()
        if entry.carriesARequest { editor.httpModel = transaction() }
        editor.initialMatchMode = mode
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        editor.view.layoutIfNeeded()
        return editor
    }

    /// Arms the rule with something, so validation has an effect to save.
    private func arm(_ editor: ScopeRecordingEditor) {
        editor.setBlocked(true)
    }

    private func save(_ editor: ScopeRecordingEditor,
                      file: StaticString = #filePath, line: UInt = #line) -> InterceptRule? {
        switch editor.validatedRule() {
        case .ok(let rule):
            InterceptRuleStore.shared.addOrUpdate(rule)
            return rule
        case .noHosts:    XCTFail("refused: no hosts", file: file, line: line); return nil
        case .noEndpoint: XCTFail("refused: no endpoint", file: file, line: line); return nil
        case .noEffect:   XCTFail("refused: no effect", file: file, line: line); return nil
        }
    }

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    private func fires(on absoluteURL: String) throws -> Bool {
        InterceptRuleStore.shared.resolvedRule(forURL: try url(absoluteURL)) != nil
    }

    // MARK: - 1. Nothing is presented on its own, from any entry point

    /// The reported complaint, checked across every entry point AND every scope
    /// — not just the one that had the sheet. Loading, appearing and appearing
    /// again must all present nothing.
    func testNoEntryPointAndNoScopeAutoPresentsAnything() {
        for entry in EntryPoint.allCases {
            for mode in EndpointMatchMode.allModes {
                let e = editor(entry, mode: mode)
                e.viewWillAppear(false)
                e.viewDidAppear(false)
                e.viewWillAppear(false)
                e.viewDidAppear(false)
                XCTAssertTrue(e.presented.isEmpty,
                              "\(entry.rawValue)/\(mode.rawValue) presented \(e.presented) unasked")
                XCTAssertNil(e.presentedViewController,
                             "\(entry.rawValue)/\(mode.rawValue) presented something unasked")
            }
        }
    }

    // MARK: - 2. Endpoint scopes from a request: pinned by default, both answers reach the wire

    /// PATTERN and EXACT, from both request-carrying entry points. Default is
    /// the request's own host; the rule fires there and nowhere else.
    func testEndpointRulesDefaultToThisHostAndFireOnlyThere() throws {
        for entry in EntryPoint.allCases where entry.carriesARequest {
            for mode in [EndpointMatchMode.normalized, .exact] {
                InterceptRuleStore.shared.removeAll()
                let e = editor(entry, mode: mode)
                arm(e)

                let rule = try XCTUnwrap(save(e), "\(entry.rawValue)/\(mode.rawValue)")
                XCTAssertEqual(rule.matchMode, mode)
                XCTAssertEqual(InterceptRule.canonicalHost(rule.matchHost), host,
                               "\(entry.rawValue)/\(mode.rawValue) did not pin to the request's host")
                XCTAssertFalse(rule.appliesToAnyHost)
                XCTAssertEqual(rule.matchEndpoint, mode == .exact ? path : pattern,
                               "\(entry.rawValue)/\(mode.rawValue) saved the wrong endpoint")

                XCTAssertTrue(try fires(on: "https://\(host)\(path)"),
                              "\(entry.rawValue)/\(mode.rawValue) does not fire on its own host")
                XCTAssertFalse(try fires(on: "https://\(otherHost)\(path)"),
                               "\(entry.rawValue)/\(mode.rawValue) fired on another host")
            }
        }
    }

    /// The control that replaced the sheet. Tapping the host row opens the
    /// picker (nothing else does), and BOTH of its answers land on the wire.
    func testTheHostRowStillOffersAndAppliesBothAnswers() throws {
        for entry in EntryPoint.allCases where entry.carriesARequest {
            InterceptRuleStore.shared.removeAll()
            let e = editor(entry, mode: .normalized)

            // Section 1 is ENDPOINT; the host-scope row is the third of its rows.
            let rows = e.tableView(e.tableView, numberOfRowsInSection: 1)
            XCTAssertEqual(rows, 3, "\(entry.rawValue): the host-scope row is missing")
            e.tableView(e.tableView, didSelectRowAt: IndexPath(row: 2, section: 1))
            XCTAssertEqual(e.presented.count, 1,
                           "\(entry.rawValue): tapping the host row opened nothing")

            // Answer "any host".
            e.setHostScope(pinned: false)
            arm(e)
            let anyHost = try XCTUnwrap(save(e))
            XCTAssertTrue(anyHost.appliesToAnyHost)
            XCTAssertTrue(try fires(on: "https://\(host)\(path)"))
            XCTAssertTrue(try fires(on: "https://\(otherHost)\(path)"),
                          "\(entry.rawValue): \"any host\" did not reach the wire")

            // Re-open the saved rule the way the list does, and change the
            // answer to "this host". The rule must MOVE buckets, not fork — a
            // stale twin still matching every host is what re-keying exists to
            // stop.
            let reopened = ScopeRecordingEditor()
            reopened.httpModel = transaction()
            reopened.existingRuleId = anyHost.id
            reopened.loadViewIfNeeded()
            XCTAssertNil(reopened.presentedViewController,
                         "\(entry.rawValue): re-opening a rule presented something unasked")
            reopened.setHostScope(pinned: true)
            let pinned = try XCTUnwrap(save(reopened))

            XCTAssertEqual(pinned.id, anyHost.id, "changing the scope forked the rule")
            XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 1,
                           "\(entry.rawValue): a stale copy was left behind")
            XCTAssertTrue(try fires(on: "https://\(host)\(path)"))
            XCTAssertFalse(try fires(on: "https://\(otherHost)\(path)"),
                           "\(entry.rawValue): the any-host copy is still matching")
        }
    }

    // MARK: - 3. Host and global scopes, from every entry point

    func testHostScopedRulesFireOnTheirHostsOnly() throws {
        for entry in EntryPoint.allCases {
            InterceptRuleStore.shared.removeAll()
            let e = editor(entry, mode: .host)
            // The App tab has no request, so nothing is pre-selected. Pick a
            // host the way the screen does: tap the URLs row, then apply from
            // the picker it opens.
            e.tableView(e.tableView, didSelectRowAt: IndexPath(row: 0, section: 1))
            let picker = try XCTUnwrap(e.presented.last as? HostPickerSheetViewController,
                                       "\(entry.rawValue): the URLs row opened no host picker")
            try XCTUnwrap(picker.onApply)([host])
            arm(e)

            let rule = try XCTUnwrap(save(e), entry.rawValue)
            XCTAssertEqual(rule.matchMode, .host)
            XCTAssertEqual(rule.matchHosts, [host])
            XCTAssertTrue(try fires(on: "https://\(host)/anything/at/all"),
                          "\(entry.rawValue): a host rule did not fire on its host")
            XCTAssertFalse(try fires(on: "https://\(otherHost)/anything/at/all"),
                           "\(entry.rawValue): a host rule fired on another host")
        }
    }

    func testGlobalRulesFireEverywhereFromEveryEntryPoint() throws {
        for entry in EntryPoint.allCases {
            InterceptRuleStore.shared.removeAll()
            let e = editor(entry, mode: .global)
            arm(e)

            let rule = try XCTUnwrap(save(e), entry.rawValue)
            XCTAssertEqual(rule.matchMode, .global)
            XCTAssertEqual(rule.storageKey, "global")
            for target in ["https://\(host)\(path)", "https://\(otherHost)/", "https://third.party.dev/x?y=1"] {
                XCTAssertTrue(try fires(on: target),
                              "\(entry.rawValue): a global rule missed \(target)")
            }
        }
    }

    // MARK: - 4. The App tab cannot create an endpoint rule, and says so

    /// With no request there is no path, so an "endpoint" rule would be filed
    /// under an empty endpoint and match nothing. Saving must be REFUSED, not
    /// quietly accepted — an inert rule that looks armed is the worst outcome.
    func testAnEndpointRuleWithNoRequestBehindItIsRefused() {
        for mode in [EndpointMatchMode.normalized, .exact] {
            let e = editor(.appTab, mode: mode)
            arm(e)
            switch e.validatedRule() {
            case .noEndpoint:
                break   // the only right answer
            case .ok(let rule):
                XCTFail("the App tab saved an endpoint rule with endpoint \"\(rule.matchEndpoint)\"")
            case .noHosts, .noEffect:
                break   // also a refusal; the point is that it is not saved
            }
            XCTAssertTrue(InterceptRuleStore.shared.allRules().isEmpty)
        }
    }

    // MARK: - 5. Two scopes for the same path coexist

    /// An EXACT rule and a PATTERN rule for the same request are different
    /// rules in different buckets. Both must survive, and both must fire.
    func testExactAndPatternForTheSameRequestAreTwoRulesNotOne() throws {
        let exactEditor = editor(.requestDetail, mode: .exact)
        arm(exactEditor)
        let exact = try XCTUnwrap(save(exactEditor))

        let patternEditor = editor(.requestDetail, mode: .normalized)
        arm(patternEditor)
        let patternRule = try XCTUnwrap(save(patternEditor))

        XCTAssertNotEqual(exact.id, patternRule.id)
        XCTAssertNotEqual(exact.storageKey, patternRule.storageKey,
                          "exact and pattern rules landed in the same bucket")
        XCTAssertEqual(InterceptRuleStore.shared.allRules().count, 2)

        let resolved = try XCTUnwrap(
            InterceptRuleStore.shared.resolvedRule(forURL: try url("https://\(host)\(path)")))
        XCTAssertTrue(resolved.isBlocked)
        XCTAssertEqual(InterceptRuleStore.shared.matchingRules(forURL: try url("https://\(host)\(path)")).count, 2)

        // A sibling path only the pattern covers still matches the pattern rule.
        XCTAssertTrue(try fires(on: "https://\(host)/product/1/2"))
    }
}

private extension EndpointMatchMode {
    /// Every scope the editor can be opened with.
    static var allModes: [EndpointMatchMode] { [.normalized, .exact, .host, .global] }
}
