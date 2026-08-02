//
//  JSONInlineEditNonFiniteTests.swift
//  SwiftyDebugTests
//
//  `Double("inf")`, `Double("nan")` and `Double("1e400")` all succeed, so
//  `Double(text) ?? 0` turns any of them into a number the JSON writer cannot
//  serialise — and the coder that refuses them returns nil, which a naive caller
//  turns into 0.
//
//  Inline edits commit on loss of first responder, not on an explicit Save. A
//  refused number must therefore be DISCARDED, not coerced: otherwise tapping
//  away from a field containing `inf` silently overwrites a real value with 0,
//  in a body the developer is about to replay against a live backend.
//
//  `JSONNonFiniteNumberTests` covers the coder and the full-page editor.
//  Nothing covered the inline path — the guard in `commitInlineEdit()` could be
//  deleted with the whole suite green, because the only test of an inline commit
//  re-implements the commit rather than calling it. These drive the real editor.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONInlineEditNonFiniteTests: XCTestCase {

    private var window: UIWindow!
    private var document: JSONDocument!
    private var editor: JSONEditorViewController!

    private let agePath: JSONPath = [.key("age")]

    override func setUp() {
        super.setUp()
        document = JSONDocument(root: ["age": NSNumber(value: 36)])
        editor = JSONEditorViewController(document: document, title: "Edit JSON")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = editor
        window.isHidden = false
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        editor = nil
        document = nil
        super.tearDown()
    }

    // MARK: - The guard

    /// Every spelling `Double(_:)` accepts and JSON does not. Typing one into
    /// the row and tapping elsewhere must leave the value alone.
    func testTappingAwayFromANonFiniteNumberDiscardsItInsteadOfWritingZero() throws {
        for poison in ["inf", "-inf", "Inf", "infinity", "INFINITY", "nan", "NaN", "1e400"] {
            document.setValue(NSNumber(value: 36), at: agePath)
            let cell = try beginEditingTheNumberRow()

            // Loss of first responder with `poison` in the field — the inline
            // editor's only commit trigger.
            cell.onEditingEnded?(poison)

            let value = try XCTUnwrap(document.value(at: agePath) as? NSNumber,
                                      "\(poison) removed the value entirely")
            XCTAssertEqual(value.doubleValue, 36,
                           "\"\(poison)\" was coerced to \(value) over a real value. Inline edits "
                           + "commit on loss of focus, so this destroys data with no Save tap and "
                           + "no way to notice.")
            XCTAssertEqual(document.kind(at: agePath), .number)
            XCTAssertTrue(value.doubleValue.isFinite)
        }
    }

    /// A refused edit is not an edit: it must not land on the undo stack, or
    /// "undo" walks back a change that never happened.
    func testARefusedInlineEditIsNotUndoable() throws {
        let cell = try beginEditingTheNumberRow()
        cell.onEditingEnded?("nan")

        XCTAssertFalse(document.canUndo,
                       "A discarded edit must not push an undo entry.")
    }

    // MARK: - …and real numbers still commit

    /// The control that stops the tests above from passing for the wrong reason:
    /// if this harness never reached the commit at all, every assertion above
    /// would hold trivially.
    func testARealNumberTypedInTheSameFieldIsCommitted() throws {
        let cell = try beginEditingTheNumberRow()
        cell.onEditingEnded?("41")

        XCTAssertEqual((document.value(at: agePath) as? NSNumber)?.intValue, 41,
                       "The inline field must still write ordinary numbers — this test proves the "
                       + "commit path is genuinely being exercised.")
        XCTAssertEqual(document.kind(at: agePath), .number,
                       "Typing into a number node must not turn it into a string.")
    }

    func testADecimalTypedInTheSameFieldIsCommitted() throws {
        let cell = try beginEditingTheNumberRow()
        cell.onEditingEnded?(" -3.5 ")

        XCTAssertEqual((document.value(at: agePath) as? NSNumber)?.doubleValue, -3.5)
    }

    // MARK: - Harness

    /// Taps the `age` row exactly as the user does and returns the live cell,
    /// now in inline-editing mode with the controller's real closures attached.
    private func beginEditingTheNumberRow() throws -> JSONNodeCell {
        let table = try treeTable()
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2,
                       "Expected the synthetic root row and one `age` row.")
        let indexPath = IndexPath(row: 1, section: 0)

        editor.tableView(table, didSelectRowAt: indexPath)
        window.layoutIfNeeded()

        let cell = try XCTUnwrap(table.cellForRow(at: indexPath) as? JSONNodeCell,
                                 "The tapped row has no live cell, so no inline edit started.")
        XCTAssertTrue(cell.isEditingValue,
                      "Tapping a short number row must open the inline field — if it opened the "
                      + "full page instead, this test is exercising the wrong commit path.")
        return cell
    }

    private func treeTable() throws -> UITableView {
        let tables = Self.tableViews(in: editor.view).filter { $0.dataSource === editor }
        return try XCTUnwrap(tables.first, "The JSON editor no longer has a tree table.")
    }

    private static func tableViews(in view: UIView) -> [UITableView] {
        var out: [UITableView] = []
        if let table = view as? UITableView { out.append(table) }
        for subview in view.subviews { out += tableViews(in: subview) }
        return out
    }
}
