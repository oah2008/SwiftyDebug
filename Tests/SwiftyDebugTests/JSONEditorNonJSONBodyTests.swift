//
//  JSONEditorNonJSONBodyTests.swift
//  SwiftyDebugTests
//
//  `JSONEditorViewController(text:)` fell back to `JSONDocument.empty()` for
//  anything that didn't parse, so opening a paused HTML or plain-text response
//  in the editor replaced it with `{}` before a single key was touched. Tapping
//  Save then handed the host app `{}` in place of the real payload — the
//  breakpoint screen pins the card visible for EVERY non-binary body, so this
//  was one tap away on any text response that isn't JSON.
//
//  The rule: never substitute an empty object for someone's data. A body JSON
//  cannot represent opens in Raw with the original text intact, and Save is
//  refused (with the parse error) rather than delivering `{}`.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONEditorNonJSONBodyTests: XCTestCase {

    private var window: UIWindow!
    private var editor: JSONEditorViewController!

    private let html = "<html>\n  <body>Payment failed</body>\n</html>"

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        editor = nil
        super.tearDown()
    }

    // MARK: - Harness

    @discardableResult
    private func open(_ text: String?) -> JSONEditorViewController {
        let controller = JSONEditorViewController(text: text, title: "Response Body")
        editor = controller
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        return controller
    }

    /// The mode segmented control, found in the hierarchy rather than by name.
    private func modeControl() -> UISegmentedControl? {
        editor.view.subviews.compactMap { $0 as? UISegmentedControl }.first
    }

    /// The raw editor — the only text view the screen owns directly (inline row
    /// editors live inside the table's cells).
    private func rawTextView() -> UITextView? {
        editor.view.subviews.compactMap { $0 as? UITextView }.first
    }

    private func tapSave() {
        guard let item = editor.navigationItem.rightBarButtonItem,
              let target = item.target as? NSObject, let action = item.action else {
            XCTFail("Save button is not wired")
            return
        }
        target.perform(action)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    // MARK: - The defect

    func testOpeningANonJSONBodyKeepsTheOriginalTextInsteadOfEmptyObject() throws {
        open(html)

        let raw = try XCTUnwrap(rawTextView())
        XCTAssertEqual(raw.text, html,
                       "a body JSON can't hold must be shown verbatim, not replaced by {}")
        XCTAssertFalse(raw.isHidden, "it has to be the visible editor, or the text is unreachable")
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 1,
                       "the editor must open in Raw for a body the tree cannot represent")
    }

    func testSavingANonJSONBodyNeverDeliversAnEmptyObject() throws {
        open(html)
        var delivered: String?
        editor.onSave = { delivered = $0.prettyText() }

        tapSave()

        XCTAssertNotEqual(delivered, "{}",
                          "Save must never hand the app {} in place of the real body")
        XCTAssertNil(delivered, "Save is refused while the text isn't JSON")
        XCTAssertTrue(editor.presentedViewController is UIAlertController,
                      "refusing silently is no better — say why")
        XCTAssertEqual(rawTextView()?.text, html, "the refused save must leave the text alone")
    }

    func testFixingTheTextIntoValidJSONThenSaves() throws {
        open(html)
        var delivered: String?
        editor.onSave = { delivered = $0.prettyText() }

        let raw = try XCTUnwrap(rawTextView())
        raw.text = #"{"error":"Payment failed"}"#
        editor.textViewDidChange(raw)

        tapSave()

        XCTAssertNil(editor.presentedViewController)
        let saved = try XCTUnwrap(delivered)
        XCTAssertTrue(saved.contains("Payment failed"), saved)
    }

    /// Plain text, not just markup — a form body or a stack trace hits the same
    /// path.
    func testPlainTextBodyIsAlsoKept() throws {
        open("user=42&token=abc")
        XCTAssertEqual(rawTextView()?.text, "user=42&token=abc")
    }

    // MARK: - Adjacent behaviour

    func testEmptyTextStillStartsAnEmptyObjectInTree() throws {
        open("")
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 0, "\"type my own\" still starts in Tree")

        var delivered: String?
        editor.onSave = { delivered = $0.prettyText() }
        tapSave()
        XCTAssertEqual(delivered, "{}", "an empty start is genuinely an empty object")
    }

    func testNilTextStillStartsAnEmptyObjectInTree() throws {
        open(nil)
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 0)
        var delivered: String?
        editor.onSave = { delivered = $0.prettyText() }
        tapSave()
        XCTAssertEqual(delivered, "{}")
    }

    func testWhitespaceOnlyTextStillStartsAnEmptyObjectInTree() throws {
        open("   \n\t ")
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 0)
    }

    func testValidJSONStillOpensInTreeAndKeepsSourceFormatting() throws {
        open(#"{"zeta":1,"amount":19.99}"#)
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 0, "JSON still opens in Tree")

        var delivered: String?
        editor.onSave = { delivered = $0.prettyText() }
        tapSave()

        let saved = try XCTUnwrap(delivered)
        XCTAssertTrue(saved.contains("19.99") && !saved.contains("19.9899"),
                      "number spelling must survive: \(saved)")
        let zeta = try XCTUnwrap(saved.range(of: "\"zeta\""))
        let amount = try XCTUnwrap(saved.range(of: "\"amount\""))
        XCTAssertTrue(zeta.lowerBound < amount.lowerBound, "key order must survive: \(saved)")
    }

    /// A bare fragment is valid JSON and must keep behaving like one.
    func testJSONFragmentStillOpensInTree() throws {
        open("42")
        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 0)
    }

    func testSwitchingToTreeFromAnUnparsableBodyIsRefusedWithTheReason() throws {
        open(html)
        let control = try XCTUnwrap(modeControl())
        control.selectedSegmentIndex = 0
        // `sendActions(for:)` routes through UIApplication, which does not
        // deliver in this test host — invoke the registered action directly.
        for target in control.allTargets {
            for name in control.actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
                (target as? NSObject)?.perform(Selector(name))
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(control.selectedSegmentIndex, 1, "the switch must bounce back")
        XCTAssertTrue(editor.presentedViewController is UIAlertController)
        XCTAssertEqual(rawTextView()?.text, html)
    }
}
