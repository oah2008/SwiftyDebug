//
//  JsonEditorAuditFixTests.swift
//  SwiftyDebugTests
//
//  The JSON editor's whole reason for existing is that the payload it hands
//  back is the payload the user saw — same key order, same number spelling.
//  Five separate paths broke that promise while still producing valid JSON, so
//  every assertion here is on the WHOLE rendered body, never on "the value is
//  present": the defects all survived that weaker check.
//
//  Covered:
//    * renaming a key re-ordered and re-spelled its entire subtree
//    * replacing the whole document kept the OLD body's key order and literals
//    * "Copy value" put an alphabetised, re-spelled sub-tree on the clipboard
//    * the tree listed rows alphabetically while the save wrote source order
//    * starting an inline edit broke the field's required height constraint
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JsonEditorAuditFixTests: XCTestCase {

    // MARK: - Renaming a key keeps its subtree intact

    func testRenamingAKeyKeepsItsChildrensOrderAndNumberSpelling() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"data":{"zulu":1,"alpha":1250.00,"mike":3},"tail":"x"}"#))
        XCTAssertTrue(doc.renameKey(at: [.key("data")], to: "payload"))
        XCTAssertEqual(doc.minifiedText(),
                       #"{"payload":{"zulu":1,"alpha":1250.00,"mike":3},"tail":"x"}"#)
    }

    func testRenamingAKeyKeepsExoticNumberLiteralsBelowIt() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"a":{"p":19.99,"q":1.0e3}}"#))
        XCTAssertTrue(doc.renameKey(at: [.key("a")], to: "c"))
        XCTAssertEqual(doc.minifiedText(), #"{"c":{"p":19.99,"q":1.0e3}}"#)
    }

    func testRenamingAKeyInsideAnArrayElementKeepsItsSubtreeInSourceOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"rows":[{"o":{"z":1,"a":2}}]}"#))
        XCTAssertTrue(doc.renameKey(at: [.key("rows"), .index(0), .key("o")], to: "p"))
        XCTAssertEqual(doc.minifiedText(), #"{"rows":[{"p":{"z":1,"a":2}}]}"#)
    }

    /// The records under a renamed key are keyed by the SOURCE path, which for a
    /// reordered array is not the path the element has now. Renaming an ancestor
    /// has to move them without flattening that translation.
    func testRenamingAnAncestorOfAReorderedArrayKeepsEachElementsOwnKeyOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"w":{"rows":[{"z":1,"a":2},{"q":3,"b":4}]}}"#))
        XCTAssertTrue(doc.remove(at: [.key("w"), .key("rows"), .index(0)]))
        XCTAssertTrue(doc.renameKey(at: [.key("w")], to: "v"))
        XCTAssertEqual(doc.minifiedText(), #"{"v":{"rows":[{"q":3,"b":4}]}}"#)
    }

    /// Nested arrays: the outer reorder and the rename have to compose, or the
    /// inner rows come back alphabetised.
    func testRenamingInsideAReorderedOuterArrayKeepsTheInnerRowsInOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"groups":[{"name":"north","rows":[{"sku":"a","qty":2},{"qty":5,"sku":"b"}]},{"name":"south","rows":[{"qty":9,"sku":"c"}]}]}"#))
        XCTAssertTrue(doc.moveElement(inArrayAt: [.key("groups")], from: 0, to: 1))
        XCTAssertTrue(doc.renameKey(at: [.key("groups"), .index(1), .key("rows")], to: "lines"))
        XCTAssertEqual(doc.minifiedText(),
                       #"{"groups":[{"name":"south","rows":[{"qty":9,"sku":"c"}]},{"name":"north","lines":[{"sku":"a","qty":2},{"qty":5,"sku":"b"}]}]}"#)
    }

    /// A duplicate has records of its own; renaming inside the copy must move
    /// only the copy's, never the element it was copied from.
    func testRenamingInsideADuplicateLeavesTheOriginalAlone() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"r":[{"o":{"z":1,"a":2}}]}"#))
        XCTAssertTrue(doc.duplicateElement(at: [.key("r"), .index(0)]))
        XCTAssertTrue(doc.renameKey(at: [.key("r"), .index(1), .key("o")], to: "p"))
        XCTAssertEqual(doc.minifiedText(), #"{"r":[{"o":{"z":1,"a":2}},{"p":{"z":1,"a":2}}]}"#)
    }

    func testUndoingARenameRestoresTheOriginalSpellingAndOrder() throws {
        let original = #"{"data":{"zulu":1,"alpha":1250.00},"tail":"x"}"#
        let doc = try XCTUnwrap(JSONDocument(text: original))
        XCTAssertTrue(doc.renameKey(at: [.key("data")], to: "payload"))
        doc.undo()
        XCTAssertEqual(doc.minifiedText(), original)
    }

    // MARK: - Replacing the whole document

    func testReplacingTheDocumentAdoptsTheNewNumberSpelling() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"n":1.50,"m":1e3}"#))
        let typed = try XCTUnwrap(JSONDocument(text: #"{"n":1.5,"m":1000}"#))
        doc.replaceAll(with: typed)
        XCTAssertEqual(doc.minifiedText(), #"{"n":1.5,"m":1000}"#)
    }

    func testReplacingTheDocumentAdoptsTheNewKeyOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":2,"mike":3}"#))
        let typed = try XCTUnwrap(JSONDocument(text: #"{"alpha":2,"mike":3,"zulu":1}"#))
        doc.replaceAll(with: typed)
        XCTAssertEqual(doc.minifiedText(), #"{"alpha":2,"mike":3,"zulu":1}"#)
    }

    /// Paste: a clipboard payload must not be re-ordered into the key order of
    /// the document it replaced.
    func testPastingAPayloadKeepsTheClipboardsOwnKeyOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":2,"mike":3}"#))
        let pasted = try XCTUnwrap(JSONDocument(text: #"{"name":"bob","alpha":9,"zulu":8,"beta":7}"#))
        doc.replaceAll(with: pasted)
        XCTAssertEqual(doc.minifiedText(), #"{"name":"bob","alpha":9,"zulu":8,"beta":7}"#)
    }

    func testUndoingAReplacementRestoresTheOriginalOrderAndSpelling() throws {
        let original = #"{"zulu":1,"alpha":1250.00}"#
        let doc = try XCTUnwrap(JSONDocument(text: original))
        doc.replaceAll(with: try XCTUnwrap(JSONDocument(text: #"{"alpha":1250,"zulu":1}"#)))
        XCTAssertTrue(doc.canUndo)
        doc.undo()
        XCTAssertEqual(doc.minifiedText(), original)
    }

    /// A replacement parsed from a tree rather than text has no index of its
    /// own; adopting it must not resurrect the old body's order.
    func testReplacingWithAnIndexlessDocumentDoesNotReimposeTheOldOrder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":2}"#))
        doc.replaceAll(with: JSONDocument(root: ["zulu": 1, "alpha": 2] as [String: Any]))
        XCTAssertEqual(doc.minifiedText(), #"{"alpha":2,"zulu":1}"#)
    }

    // MARK: - Copying a sub-tree

    func testCopyingASubTreeKeepsTheOrderAndSpellingOnScreen() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"data":{"zulu":1,"alpha":1250.00,"mike":"x"},"id":9}"#))
        XCTAssertEqual(doc.prettyText(at: [.key("data")]),
                       "{\n  \"zulu\" : 1,\n  \"alpha\" : 1250.00,\n  \"mike\" : \"x\"\n}")
    }

    func testCopyingAnArrayElementFollowsItThroughAReorder() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"rows":[{"z":1,"a":2},{"q":3,"b":4}]}"#))
        XCTAssertTrue(doc.remove(at: [.key("rows"), .index(0)]))
        XCTAssertEqual(doc.prettyText(at: [.key("rows"), .index(0)]),
                       "{\n  \"q\" : 3,\n  \"b\" : 4\n}")
    }

    func testCopyingTheWholeRootMatchesTheDocumentsOwnText() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":1250.00}"#))
        XCTAssertEqual(doc.prettyText(at: []), doc.prettyText())
    }

    func testCopyingAPathThatDoesNotResolveIsEmptyRatherThanWrong() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"a":1}"#))
        XCTAssertEqual(doc.prettyText(at: [.key("nope")]), "")
    }

    // MARK: - The tree lists rows in the order the save will write

    func testOrderedKeysMatchesTheOrderTheDocumentWrites() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":2,"mike":3}"#))
        let dict = try XCTUnwrap(doc.value(at: []) as? [String: Any])
        XCTAssertEqual(doc.orderedKeys(at: [], of: dict), ["zulu", "alpha", "mike"])
    }

    func testAKeyAddedAtTheEndIsListedAtTheEnd() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"zulu":1,"alpha":2,"mike":3}"#))
        XCTAssertTrue(doc.addKey("beta", value: 4, toObjectAt: []))
        let dict = try XCTUnwrap(doc.value(at: []) as? [String: Any])
        XCTAssertEqual(doc.orderedKeys(at: [], of: dict), ["zulu", "alpha", "mike", "beta"])
        XCTAssertEqual(doc.minifiedText(), #"{"zulu":1,"alpha":2,"mike":3,"beta":4}"#)
    }

    /// With no source index the writer falls back to a case-SENSITIVE sort; the
    /// tree has to use the same one or the two disagree on `["B", "a"]`.
    func testOrderedKeysFallsBackToTheSameSortTheWriterUses() {
        let doc = JSONDocument(root: ["a": 1, "B": 2, "c": 3] as [String: Any])
        let dict = doc.value(at: []) as? [String: Any] ?? [:]
        XCTAssertEqual(doc.orderedKeys(at: [], of: dict), ["B", "a", "c"])
        XCTAssertEqual(doc.minifiedText(), #"{"B":2,"a":1,"c":3}"#)
    }

    func testOrderedKeysFollowsAnArrayElementThroughADelete() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"rows":[{"z":1,"a":2},{"q":3,"b":4}]}"#))
        XCTAssertTrue(doc.remove(at: [.key("rows"), .index(0)]))
        let element = try XCTUnwrap(doc.value(at: [.key("rows"), .index(0)]) as? [String: Any])
        XCTAssertEqual(doc.orderedKeys(at: [.key("rows"), .index(0)], of: element), ["q", "b"])
    }

    // MARK: - Picker mode offers nothing that mutates

    func testPickerModeStripsTheToolbarButKeepsTheBar() throws {
        let editor = pickerEditor(#"{"data":{"items":[{"url":"a"},{"url":"b"}]}}"#)
        let toolbar = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UIToolbar }.first,
                                    "the toolbar is the table's bottom anchor and must still exist")
        XCTAssertEqual(toolbar.items?.isEmpty ?? true, true,
                       "Add/Paste/Format/Undo/Redo all mutate a body the picker only samples")
    }

    func testEditingModeStillHasItsToolbarItems() throws {
        let editor = editingEditor(#"{"data":{"items":[{"url":"a"},{"url":"b"}]}}"#)
        let toolbar = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UIToolbar }.first)
        XCTAssertGreaterThan(toolbar.items?.count ?? 0, 0)
    }

    func testPickerModeOffersNoSwipeActions() throws {
        let editor = pickerEditor(#"{"data":{"items":[{"url":"a"},{"url":"b"}]}}"#)
        let table = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UITableView }.first)
        let rows = editor.tableView(table, numberOfRowsInSection: 0)
        XCTAssertGreaterThan(rows, 1, "need a non-root row to swipe")
        for row in 0..<rows {
            let indexPath = IndexPath(row: row, section: 0)
            XCTAssertNil(editor.tableView(table, trailingSwipeActionsConfigurationForRowAt: indexPath),
                         "Delete/Duplicate renumber the array the picked path indexes into")
            XCTAssertNil(editor.tableView(table, leadingSwipeActionsConfigurationForRowAt: indexPath),
                         "\"More\" is the funnel into Delete / Change type / Add key")
        }
    }

    func testEditingModeStillOffersSwipeActionsOnANonRootRow() throws {
        let editor = editingEditor(#"{"data":{"items":[{"url":"a"},{"url":"b"}]}}"#)
        let table = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UITableView }.first)
        let indexPath = IndexPath(row: 1, section: 0)
        XCTAssertNotNil(editor.tableView(table, trailingSwipeActionsConfigurationForRowAt: indexPath))
        XCTAssertNotNil(editor.tableView(table, leadingSwipeActionsConfigurationForRowAt: indexPath))
    }

    func testPickerModeHasNoSaveButton() {
        let editor = pickerEditor(#"{"a":1}"#)
        XCTAssertNil(editor.navigationItem.rightBarButtonItem)
    }

    // MARK: - The inline field's height constraint

    /// A required 92pt height and the table's cached row height cannot both
    /// hold while a row is switched into editing — one of them gets broken.
    func testTheInlineFieldHeightConstraintYieldsToTheTablesCachedHeight() throws {
        let cell = JSONNodeCell(style: .default, reuseIdentifier: "node")
        let editor = try XCTUnwrap(Self.firstTextView(in: cell), "the inline field")
        let height = try XCTUnwrap(editor.constraints.first {
            $0.firstAttribute == .height && $0.secondItem == nil
        }, "the inline field's own height constraint")
        XCTAssertEqual(height.constant, JSONInlineEditMetrics.minHeight)
        XCTAssertEqual(height.priority, .init(999),
                       "required would make the switch into editing unsatisfiable")
    }

    func testTheInlineFieldStillMeasuresAtItsFullHeight() throws {
        let cell = JSONNodeCell(style: .default, reuseIdentifier: "node")
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        cell.configure(label: "name", preview: "bob", kind: .string, depth: 1,
                       isContainer: false, isExpanded: false, childCount: 0,
                       editing: JSONNodeCell.EditingState(text: "bob", height: nil, kind: .string))
        let fitted = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThanOrEqual(fitted.height, JSONInlineEditMetrics.minHeight,
                                    "dropping to 999 must not shrink the field")
    }

    // MARK: - Harness

    /// Both harnesses put the editor in a real window: `viewDidLoad` is what
    /// wires Save and the toolbar, and the picker gate lives there.
    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        super.tearDown()
    }

    private func pickerEditor(_ json: String) -> JSONEditorViewController {
        let editor = JSONEditorViewController(document: JSONDocument(text: json)!, title: "Pick")
        editor.onPickPath = { _ in }
        return host(editor)
    }

    private func editingEditor(_ json: String) -> JSONEditorViewController {
        host(JSONEditorViewController(document: JSONDocument(text: json)!, title: "Edit"))
    }

    private func host(_ editor: JSONEditorViewController) -> JSONEditorViewController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private static func firstTextView(in view: UIView) -> UITextView? {
        for subview in view.subviews {
            if let found = subview as? UITextView { return found }
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}
