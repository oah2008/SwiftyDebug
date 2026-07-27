//
//  JSONValueEditorLayoutTests.swift
//  SwiftyDebugTests
//
//  The full-page value editor once had `boolRow` pinned to all four edges of the
//  card *and* a fixed 56pt height, which forced the card to 56pt. Once the
//  fill-to-bottom constraint became required, the two were unsatisfiable and Auto
//  Layout broke the top of the chain instead — the breadcrumb ended up floating in
//  the middle of an empty screen with the field squashed at the bottom.
//
//  A conflict like that produces a plausible-looking screen and no test failure,
//  so these assert the resolved geometry directly.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONValueEditorLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 390, height: 780)

    private func laidOut(value: Any) -> UIView {
        let vc = JSONValueEditorViewController(value: value, pathDisplay: "root.abilities[0].ability.url")
        vc.view.frame = screen
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return vc.view
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView { return tv }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    /// The breadcrumb is the only label that is a direct child of the root view.
    private func breadcrumb(in view: UIView) -> UILabel? {
        return view.subviews.compactMap { $0 as? UILabel }.first
    }

    // MARK: - String / number: the field owns the page

    func testBreadcrumbSitsAtTheTop() {
        let view = laidOut(value: "https://pokeapi.co/api/v2/ability/65/")
        let label = try? XCTUnwrap(breadcrumb(in: view))
        // Was ~350pt down the screen when the constraints conflicted.
        XCTAssertLessThan(label?.frame.minY ?? .greatestFiniteMagnitude, 40,
                          "The breadcrumb must be pinned to the top, not floating")
    }

    func testTextFieldFillsMostOfThePage() {
        let view = laidOut(value: "https://pokeapi.co/api/v2/ability/65/")
        let field = try? XCTUnwrap(firstTextView(in: view))
        let height = field?.frame.height ?? 0
        XCTAssertGreaterThan(height, 400,
                             "A full page should give the value most of its height, got \(height)")
        XCTAssertLessThan(field?.frame.minY ?? .greatestFiniteMagnitude, 140,
                          "The field should start just under the type switcher")
    }

    func testNumberAlsoGetsTheFullPage() {
        let view = laidOut(value: NSNumber(value: 42))
        let field = try? XCTUnwrap(firstTextView(in: view))
        XCTAssertGreaterThan(field?.frame.height ?? 0, 400)
    }

    func testLayoutHoldsOnASmallScreen() {
        let vc = JSONValueEditorViewController(value: "abc", pathDisplay: "root.a")
        vc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        vc.view.layoutIfNeeded()
        XCTAssertLessThan(breadcrumb(in: vc.view)?.frame.minY ?? .greatestFiniteMagnitude, 40)
        XCTAssertGreaterThan(firstTextView(in: vc.view)?.frame.height ?? 0, 200)
    }

    // MARK: - Bool / null: one short row, not a full page

    func testBoolUsesAShortRowRatherThanTheWholePage() {
        let view = laidOut(value: true)
        let field = firstTextView(in: view)
        XCTAssertTrue(field?.isHidden ?? false, "A bool edits with a switch, not a text field")
        XCTAssertLessThan(breadcrumb(in: view)?.frame.minY ?? .greatestFiniteMagnitude, 40,
                          "Swapping to the short layout must not disturb the top of the chain")
    }

    func testNullKeepsTheTopOfTheChainIntact() {
        let view = laidOut(value: NSNull())
        XCTAssertLessThan(breadcrumb(in: view)?.frame.minY ?? .greatestFiniteMagnitude, 40)
    }
}
