//
//  InterceptRuleListNameVerificationTests.swift
//  SwiftyDebugTests
//
//  Independent check of item B across every screen that lists rules:
//  a mock-only, breakpoint-only, rewrite-only and redirect-only rule must each
//  be identifiable, and "Empty rule" must appear on none of them.
//
//  Also checks the thing the reported bug actually was — a long string in a
//  row that cannot grow to hold it. The name and scope are now longer than the
//  raw endpoint they replaced, so the same clipping would land in the lists.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class InterceptRuleListNameVerificationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptRuleStore.shared.removeAll()
        seedOneOfEachKind()
    }

    override func tearDown() {
        InterceptRuleStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One rule of each single-purpose kind — the four the report calls out as
    /// indistinguishable.
    private func seedOneOfEachKind() {
        var mockOnly = InterceptRule.endpointRule(path: "/product/{id}", host: "api.example.com")
        mockOnly.mock = MockResponse(isEnabled: true, statusCode: 404, body: "{}")

        var breakpointOnly = InterceptRule.endpointRule(path: "/cart", host: "api.example.com")
        breakpointOnly.breakpointMode = .beforeSend

        var rewriteOnly = InterceptRule.endpointRule(path: "/feed", host: "api.example.com")
        rewriteOnly.responseRewrites = [ResponseRewrite(pattern: "data.url", action: .setValue("x"))]

        var redirectOnly = InterceptRule.endpointRule(path: "/checkout", host: "api.example.com")
        redirectOnly.redirectMode = .host
        redirectOnly.redirectTarget = "beta.example.com"

        for rule in [mockOnly, breakpointOnly, rewriteOnly, redirectOnly] {
            InterceptRuleStore.shared.addOrUpdate(rule)
        }
    }

    private func labels(in view: UIView) -> [UILabel] {
        var out: [UILabel] = []
        if let l = view as? UILabel { out.append(l) }
        for sub in view.subviews { out.append(contentsOf: labels(in: sub)) }
        return out
    }

    private func firstTable(in view: UIView) -> UITableView? {
        if let tv = view as? UITableView { return tv }
        for sub in view.subviews { if let tv = firstTable(in: sub) { return tv } }
        return nil
    }

    /// Every string rendered by every cell of a table-driven screen.
    private func renderedText(of vc: UIViewController) -> [String] {
        vc.loadViewIfNeeded()
        // These screens snapshot the store in viewWillAppear; without it the
        // table renders an empty list and every assertion below is vacuous.
        vc.viewWillAppear(false)
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.view.layoutIfNeeded()
        guard let tv = firstTable(in: vc.view), let ds = tv.dataSource else { return [] }
        tv.reloadData()
        tv.layoutIfNeeded()
        var out: [String] = []
        for section in 0..<tv.numberOfSections {
            for row in 0..<tv.numberOfRows(inSection: section) {
                let cell = ds.tableView(tv, cellForRowAt: IndexPath(row: row, section: section))
                for l in labels(in: cell) {
                    if let t = l.text { out.append(t) }
                    if let a = l.attributedText?.string { out.append(a) }
                }
            }
        }
        return out
    }

    /// The four rules must be identifiable, and none may read "Empty rule".
    private func assertNamesPresent(_ texts: [String], screen: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let joined = texts.joined(separator: " | ")
        XCTAssertFalse(joined.contains("Empty rule"),
                       "\(screen) rendered 'Empty rule'. Rendered: \(joined)", file: file, line: line)
        for needle in ["Mock 404", "Breakpoint before send", "Rewrite data.url", "Redirect"] {
            XCTAssertTrue(joined.contains(needle),
                          "\(screen) never rendered \"\(needle)\". Rendered: \(joined)",
                          file: file, line: line)
        }
    }

    // MARK: - The three screens

    /// The rule list is opened FROM a request and lists what matches it, so it
    /// is checked one rule at a time with a URL that rule matches.
    func testTheRuleListNamesEveryKindOfRule() {
        let cases = [("https://api.example.com/product/55", "Mock 404"),
                     ("https://api.example.com/cart", "Breakpoint before send"),
                     ("https://api.example.com/feed", "Rewrite data.url"),
                     ("https://api.example.com/checkout", "Redirect")]

        for (urlString, needle) in cases {
            let vc = InterceptRuleListViewController()
            let model = NetworkTransaction()
            model.url = NSURL(string: urlString)
            vc.httpModel = model

            let texts = renderedText(of: vc).joined(separator: " | ")
            XCTAssertFalse(texts.contains("Empty rule"),
                           "Rule list rendered 'Empty rule' for \(urlString). Rendered: \(texts)")
            XCTAssertTrue(texts.contains(needle),
                          "Rule list never rendered \"\(needle)\" for \(urlString). Rendered: \(texts)")
        }
    }

    func testTheAppTabNamesEveryKindOfRule() {
        assertNamesPresent(renderedText(of: AppInfoViewController()), screen: "App tab")
    }

    func testTheExportPickerNamesEveryKindOfRule() {
        assertNamesPresent(renderedText(of: RuleTransferViewController()), screen: "Export picker")
    }

    /// Whatever the screens render must agree with the model's own answer, so
    /// there is one definition of a rule's name and not four.
    func testEveryScreenAgreesWithTheModelsDisplayName() {
        let expected = Set(InterceptRuleStore.shared.allRules().map { $0.displayName })
        XCTAssertEqual(expected.count, 4, "The four rules do not have four distinct names")

        for rule in InterceptRuleStore.shared.allRules() {
            XCTAssertNotEqual(rule.displayName, "Empty rule", "\(rule.matchEndpoint) has no name")
        }
    }

    // MARK: - The rows must hold what they render

    /// The reported bug in a new place: a long name in a list row.
    ///
    /// Measured with `rectForRow` on a table in a real window — NOT with
    /// `systemLayoutSizeFitting` on a detached cell, which reports the stock
    /// 44pt for a stock cell whatever its content and would fail this for the
    /// wrong reason.
    func testRowsGrowToHoldALongNameOnEveryScreen() {
        InterceptRuleStore.shared.removeAll()
        let longPath = "/product/10289032912/20920220/reviews/8837273/replies/992837"
        var rule = InterceptRule.endpointRule(path: longPath, mode: .exact,
                                              host: "api.staging.example.com")
        rule.redirectMode = .hostAndPath
        rule.redirectTarget = "beta.example.com/checkout/xyz"
        rule.name = "A deliberately long rule name that will not fit on one line of a phone screen"
        InterceptRuleStore.shared.addOrUpdate(rule)

        let listVC = InterceptRuleListViewController()
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.staging.example.com" + longPath)

        listVC.httpModel = model
        for (screen, vc) in [("Rule list", listVC as UIViewController),
                             ("App tab", AppInfoViewController()),
                             ("Export picker", RuleTransferViewController())] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UINavigationController(rootViewController: vc)
            window.makeKeyAndVisible()
            vc.loadViewIfNeeded()
            vc.viewWillAppear(false)
            guard let tv = firstTable(in: vc.view), let ds = tv.dataSource else {
                return XCTFail("\(screen) has no table")
            }
            tv.reloadData()
            tv.layoutIfNeeded()

            var measured = false
            for section in 0..<tv.numberOfSections {
                for row in 0..<tv.numberOfRows(inSection: section) {
                    let ip = IndexPath(row: row, section: section)
                    let cell = ds.tableView(tv, cellForRowAt: ip)
                    let carriesName = labels(in: cell).contains {
                        ($0.text ?? $0.attributedText?.string ?? "").contains("A deliberately long rule name")
                    }
                    guard carriesName else { continue }
                    measured = true
                    XCTAssertGreaterThan(
                        tv.rectForRow(at: ip).height, 44,
                        "\(screen): the row carrying a long name did not grow past a stock row height, "
                            + "so the name is clipped — the reported bug, moved")
                }
            }
            XCTAssertTrue(measured, "\(screen) never rendered the long-named rule")
        }
    }

    /// A rule the user renamed must be listed under that name, not the derived
    /// one, on every screen.
    func testAUserTypedNameIsWhatTheListsShow() {
        InterceptRuleStore.shared.removeAll()
        var rule = InterceptRule.endpointRule(path: "/cart", host: "api.example.com")
        rule.mock = MockResponse(isEnabled: true, statusCode: 500, body: "{}")
        rule.name = "Checkout blows up"
        InterceptRuleStore.shared.addOrUpdate(rule)

        let listVC = InterceptRuleListViewController()
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/cart")
        listVC.httpModel = model

        for (screen, vc) in [("Rule list", listVC as UIViewController),
                             ("App tab", AppInfoViewController()),
                             ("Export picker", RuleTransferViewController())] {
            let texts = renderedText(of: vc).joined(separator: " | ")
            XCTAssertTrue(texts.contains("Checkout blows up"),
                          "\(screen) did not show the user's own name. Rendered: \(texts)")
        }
    }
}
