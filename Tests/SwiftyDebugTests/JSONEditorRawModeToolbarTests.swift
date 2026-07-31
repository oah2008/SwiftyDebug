//
//  JSONEditorRawModeToolbarTests.swift
//  SwiftyDebugTests
//
//  In Raw mode the text view is the truth on screen and `document` is one step
//  behind — nothing folds the text back until you switch mode or tap Save. Every
//  toolbar action, however, worked on `document`, and each of them ends with the
//  document re-rendering itself into the text view. So Undo, Redo, Add and Paste
//  each threw away everything typed since the last sync, with no warning and no
//  way to get it back.
//
//  These drive the REAL toolbar items (target/action off `UIToolbar.items`), so
//  a fix has to land where the buttons actually point.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONEditorRawModeToolbarTests: XCTestCase {

    private var window: UIWindow!
    private var editor: JSONEditorViewController!
    private var document: JSONDocument!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        editor = nil
        document = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func open(_ json: String) {
        document = JSONDocument(text: json)!
        editor = JSONEditorViewController(document: document, title: "Body")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    private func modeControl() -> UISegmentedControl? {
        editor.view.subviews.compactMap { $0 as? UISegmentedControl }.first
    }

    private func rawTextView() -> UITextView? {
        editor.view.subviews.compactMap { $0 as? UITextView }.first
    }

    private func toolbar() -> UIToolbar? {
        editor.view.subviews.compactMap { $0 as? UIToolbar }.first
    }

    private func selectMode(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let control = modeControl() else {
            XCTFail("no mode control", file: file, line: line); return
        }
        control.selectedSegmentIndex = index
        // `sendActions(for:)` routes through UIApplication, which does not
        // deliver in this test host — invoke the registered action directly.
        for target in control.allTargets {
            for name in control.actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
                (target as? NSObject)?.perform(Selector(name))
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func switchToRaw(file: StaticString = #filePath, line: UInt = #line) {
        selectMode(1, file: file, line: line)
        XCTAssertEqual(rawTextView()?.isHidden, false, "raw editor should be showing", file: file, line: line)
    }

    /// Types into the raw editor exactly the way UIKit does: set the text, fire
    /// the delegate callback.
    private func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let raw = rawTextView() else { XCTFail("no raw editor", file: file, line: line); return }
        raw.text = text
        editor.textViewDidChange(raw)
    }

    /// Taps the toolbar button whose action is `selectorName`.
    private func tapToolbar(_ selectorName: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let items = toolbar()?.items,
              let item = items.first(where: { $0.action.map(NSStringFromSelector) == selectorName }) else {
            XCTFail("no toolbar item wired to \(selectorName)", file: file, line: line)
            return
        }
        guard let target = item.target as? NSObject, let action = item.action else {
            XCTFail("\(selectorName) has no target", file: file, line: line)
            return
        }
        target.perform(action)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func alert() -> UIAlertController? {
        editor.presentedViewController as? UIAlertController
    }

    // MARK: - Undo

    func testUndoInRawModeKeepsWhatYouTyped() throws {
        open(#"{"a":1}"#)
        document.setValue(NSNumber(value: 2), at: [.key("a")])   // something to undo
        switchToRaw()

        type(#"{"a":2,"typed":"kept"}"#)
        tapToolbar("undoTapped")

        // Undo may legitimately step back past the typing — but the typing must
        // still exist to come forward to.
        tapToolbar("redoTapped")
        XCTAssertEqual(document.value(at: [.key("typed")]) as? String, "kept",
                       """
                       Undo worked on the document and then re-rendered it over the text \
                       view, so everything typed in Raw mode was destroyed with no way back.
                       """)
    }

    func testUndoInRawModeIsRefusedWhenTheTextDoesNotParse() throws {
        open(#"{"a":1}"#)
        document.setValue(NSNumber(value: 2), at: [.key("a")])
        switchToRaw()

        type(#"{"a":2,"half":"# )                                 // deliberately broken
        tapToolbar("undoTapped")

        XCTAssertEqual(rawTextView()?.text, #"{"a":2,"half":"#,
                       "text that can't be committed must be left alone, not overwritten")
        XCTAssertEqual(document.value(at: [.key("a")]) as? NSNumber, NSNumber(value: 2),
                       "the refused action must not mutate the document either")
        XCTAssertEqual(alert()?.title, "Invalid JSON", "refusing silently is no better than discarding")
    }

    // MARK: - Add

    func testAddInRawModeActsOnWhatIsOnScreen() throws {
        open(#"{"a":1}"#)
        switchToRaw()

        type(#"{"a":1,"b":2}"#)
        tapToolbar("addRootChildTapped")

        XCTAssertEqual(document.value(at: [.key("b")]) as? NSNumber, NSNumber(value: 2),
                       """
                       Add opens a prompt on the document root. With the typed text still \
                       unsynced, the new key lands in a document that never had "b" — the \
                       moment the prompt is answered, "b" is gone.
                       """)
    }

    func testAddInRawModeIsRefusedWhenTheTextDoesNotParse() throws {
        open(#"{"a":1}"#)
        switchToRaw()

        type(#"{"a":1,"#)
        tapToolbar("addRootChildTapped")

        XCTAssertEqual(rawTextView()?.text, #"{"a":1,"#)
        XCTAssertEqual(alert()?.title, "Invalid JSON")
        XCTAssertTrue(alert()?.textFields?.isEmpty ?? true,
                      "the \"new key\" prompt must not open on a document you can't see")
    }

    // Paste is the fourth affected action and takes the same
    // `commitRawText()` path, but driving it needs `UIPasteboard.general`,
    // whose first read in this test host blocks for 15–360 seconds
    // ("Operation not authorized"). It is deliberately left uncovered rather
    // than making the suite unrunnable.

    // MARK: - Adjacent behaviour

    func testFormatInRawModeStillPrettyPrintsTheTypedText() throws {
        open(#"{"a":1}"#)
        switchToRaw()

        type(#"{"b":2,"a":1}"#)
        tapToolbar("formatTapped")

        let text = try XCTUnwrap(rawTextView()?.text)
        XCTAssertTrue(text.contains("\n"), "Format must reformat the typed text: \(text)")
        XCTAssertTrue(text.contains("\"b\""), "…without losing it: \(text)")
    }

    func testFormatInRawModeStillReportsInvalidText() throws {
        open(#"{"a":1}"#)
        switchToRaw()
        type(#"{"a":"#)
        tapToolbar("formatTapped")

        XCTAssertNotNil(alert())
        XCTAssertEqual(rawTextView()?.text, #"{"a":"#)
    }

    func testSwitchingBackToTreeStillCommitsTheTypedText() throws {
        open(#"{"a":1}"#)
        switchToRaw()
        type(#"{"a":1,"typed":"kept"}"#)

        selectMode(0)

        XCTAssertEqual(document.value(at: [.key("typed")]) as? String, "kept")
    }

    func testSwitchingBackToTreeIsStillRefusedOnInvalidText() throws {
        open(#"{"a":1}"#)
        switchToRaw()
        type(#"{"a":"#)

        selectMode(0)

        XCTAssertEqual(modeControl()?.selectedSegmentIndex, 1, "the switch must bounce back")
        XCTAssertNotNil(alert())
        XCTAssertEqual(rawTextView()?.text, #"{"a":"#)
    }

    func testSaveFromRawStillCommitsTheTypedText() throws {
        open(#"{"a":1}"#)
        switchToRaw()
        type(#"{"a":1,"typed":"kept"}"#)

        var delivered: JSONDocument?
        editor.onSave = { delivered = $0 }
        guard let save = editor.navigationItem.rightBarButtonItem,
              let target = save.target as? NSObject, let action = save.action else {
            return XCTFail("no Save button")
        }
        target.perform(action)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(delivered?.value(at: [.key("typed")]) as? String, "kept")
    }

    // MARK: - Tree mode is untouched

    func testUndoAndRedoStillWorkInTreeMode() throws {
        open(#"{"a":1}"#)
        document.setValue(NSNumber(value: 2), at: [.key("a")])

        tapToolbar("undoTapped")
        XCTAssertEqual(document.value(at: [.key("a")]) as? NSNumber, NSNumber(value: 1))

        tapToolbar("redoTapped")
        XCTAssertEqual(document.value(at: [.key("a")]) as? NSNumber, NSNumber(value: 2))
    }

    func testAddInTreeModeStillOpensTheKeyPrompt() throws {
        open(#"{"a":1}"#)
        tapToolbar("addRootChildTapped")
        XCTAssertEqual(alert()?.textFields?.count, 1, "the \"new key\" prompt still opens")
    }

    func testFormatInTreeModeStillExpandsEverything() throws {
        open(#"{"a":{"b":1}}"#)
        tapToolbar("formatTapped")
        XCTAssertNil(alert(), "Format in Tree mode never complains")
    }
}
