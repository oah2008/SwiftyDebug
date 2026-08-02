//
//  JSONEditorAddItemMenuTests.swift
//  SwiftyDebugTests
//
//  Inferring the element type is only half the feature: the menu has to SAY
//  what it is about to add, before the tap, and it has to leave a way to add
//  something else. The old menu offered one option with the fixed subtitle
//  "Shaped like the existing items" — which said nothing about what the shape
//  was, and was the only way in, so an array of strings that needed one object
//  meant a trip to Raw mode.
//
//  These drive the REAL menu: the row is selected through the table delegate,
//  and the options are read off the picker that is actually presented, so a fix
//  has to land where the taps go.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONEditorAddItemMenuTests: XCTestCase {

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

    private struct NotFound: Error { let what: String }

    /// Every document here is `{"a": …}`, so the array is always tree row 1 —
    /// row 0 is the root object. The sheet's message is asserted against the
    /// path either way, so a wrong row can't pass as a right one.
    private func open(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
        document = try XCTUnwrap(JSONDocument(text: json), file: file, line: line)
        editor = JSONEditorViewController(document: document, title: "Body")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    private func table() throws -> UITableView {
        try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UITableView }.first)
    }

    private func selectRow(_ index: Int) throws {
        let table = try table()
        editor.tableView(table, didSelectRowAt: IndexPath(row: index, section: 0))
        spinUntil { self.editor.presentedViewController != nil }
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Presentation and dismissal are animated even at 0 duration — wait for the
    /// state rather than for a fixed sleep.
    private func spinUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func presentedPicker() throws -> OptionPickerSheetViewController {
        let nav = try XCTUnwrap(editor.presentedViewController as? UINavigationController,
                                "no sheet was presented")
        return try XCTUnwrap(nav.viewControllers.first as? OptionPickerSheetViewController)
    }

    /// The picker keeps its options private — read them the way the cells do.
    private func options(of picker: OptionPickerSheetViewController) throws
        -> [OptionPickerSheetViewController.Option] {
        try XCTUnwrap(Mirror(reflecting: picker).children
            .first { $0.label == "options" }?.value as? [OptionPickerSheetViewController.Option])
    }

    private func mirrored<T>(_ label: String, of subject: Any) throws -> T {
        guard let value = Mirror(reflecting: subject).children
            .first(where: { $0.label == label })?.value as? T else {
            throw NotFound(what: label)
        }
        return value
    }

    /// Opens the action menu for the array at tree row 1 and returns its options.
    private func arrayMenu(_ json: String, expectedPath: String = "root.a",
                           file: StaticString = #filePath, line: UInt = #line) throws
        -> [OptionPickerSheetViewController.Option] {
        try open(json, file: file, line: line)
        try selectRow(1)
        let picker = try presentedPicker()
        let message: String? = try? mirrored("sheetMessage", of: picker)
        XCTAssertEqual(message, expectedPath, "opened the menu for the wrong row", file: file, line: line)
        return try options(of: picker)
    }

    private func option(titled title: String,
                        in options: [OptionPickerSheetViewController.Option],
                        file: StaticString = #filePath, line: UInt = #line) throws
        -> OptionPickerSheetViewController.Option {
        guard let match = options.first(where: { $0.title == title }) else {
            XCTFail("no option titled \"\(title)\" in \(options.map(\.title))", file: file, line: line)
            throw NotFound(what: title)
        }
        return match
    }

    /// A modal presented into a scene-less test window never finishes its
    /// transition, so `dismiss` cannot finish either and the editor would refuse
    /// to present anything else. Re-rooting the window is what frees it — the
    /// closest this environment gets to "the sheet closed".
    private func releaseSheet() {
        window.rootViewController = nil
        spin(0.05)
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.layoutIfNeeded()
    }

    /// Runs an option's handler the way the picker does: the sheet goes away
    /// first, so a handler that opens another sheet can.
    private func tap(_ option: OptionPickerSheetViewController.Option,
                     opensAnotherSheet: Bool = false) {
        let previous = editor.presentedViewController
        releaseSheet()
        option.handler()
        if opensAnotherSheet {
            spinUntil { self.editor.presentedViewController !== previous }
        }
    }

    // MARK: - 1. The subtitle names the type you are about to get

    func testAddItemNamesTheObjectShapeItIsAboutToAdd() throws {
        let menu = try arrayMenu(#"{"a":[{"id":1,"name":"x","admin":true}]}"#)
        let add = try option(titled: "Add item", in: menu)
        XCTAssertEqual(add.subtitle, "object with 3 keys",
                       "the menu has to say WHAT it will add, not just that it fits")
    }

    func testAddItemNamesEveryPrimitiveElementType() throws {
        XCTAssertEqual(try option(titled: "Add item", in: try arrayMenu(#"{"a":["x"]}"#)).subtitle,
                       "string")
        XCTAssertEqual(try option(titled: "Add item", in: try arrayMenu(#"{"a":[1,2]}"#)).subtitle,
                       "number")
        XCTAssertEqual(try option(titled: "Add item", in: try arrayMenu(#"{"a":[1.5]}"#)).subtitle,
                       "number (decimal)")
        XCTAssertEqual(try option(titled: "Add item", in: try arrayMenu(#"{"a":[true]}"#)).subtitle,
                       "bool")
        XCTAssertEqual(try option(titled: "Add item", in: try arrayMenu(#"{"a":[[1]]}"#)).subtitle,
                       "array of number · adds an empty array")
    }

    /// A fallback is not an inference. It says so, and it does not get the
    /// accent colour that every real match on this sheet wears.
    func testAddItemOnAnEmptyArraySaysItIsGuessingAndIsNotDressedAsAMatch() throws {
        let menu = try arrayMenu(#"{"a":[]}"#)
        let add = try option(titled: "Add item", in: menu)
        XCTAssertEqual(add.subtitle, "empty array · nothing to copy, adding an empty string")
        XCTAssertNil(add.tint)

        let matched = try option(titled: "Add item", in: try arrayMenu(#"{"a":["x"]}"#))
        XCTAssertEqual(matched.tint, DebugTheme.accentColor)
    }

    /// An object still gets "Add key" — the array wording must not leak onto it.
    func testAnObjectStillOffersAddKeyAndNoAddItem() throws {
        try open(#"{"a":{"b":1}}"#)
        try selectRow(1)
        let menu = try options(of: try presentedPicker())
        XCTAssertTrue(menu.contains { $0.title == "Add key" })
        XCTAssertFalse(menu.contains { $0.title == "Add item" })
    }

    // MARK: - 2. Tapping it adds that item, through the document

    func testTappingAddItemAppendsAnItemOfTheSameShape() throws {
        let menu = try arrayMenu(#"{"a":[{"id":1,"name":"x","tags":["t"]}]}"#)
        try option(titled: "Add item", in: menu).handler()

        let array = try XCTUnwrap(document.value(at: [.key("a")]) as? [Any])
        XCTAssertEqual(array.count, 2)
        let added = try XCTUnwrap(array.last as? [String: Any])
        XCTAssertEqual(Set(added.keys), ["id", "name", "tags"])
        XCTAssertEqual(added["id"] as? NSNumber, 0)
        XCTAssertEqual(added["name"] as? String, "")
        XCTAssertEqual((added["tags"] as? [Any])?.count, 0)
    }

    /// The append goes through the path API, so the payload the host app gets
    /// back still has the server's key order and the server's number spelling.
    func testTappingAddItemDoesNotReorderKeysOrRespellNumbers() throws {
        let orders = #"{"a":[{"id":1001,"status":"shipped","total":19.99},{"status":"pending","id":1002,"total":1.50}]}"#
        let menu = try arrayMenu(orders)
        try option(titled: "Add item", in: menu).handler()
        XCTAssertEqual(document.minifiedText(),
                       orders.replacingOccurrences(of: "]", with: #",{"id":0,"status":"","total":0}]"#),
                       "1.50 must not come back as 1.5, and nothing may be alphabetised")
        XCTAssertTrue(document.canUndo, "and it has to be one undo away")
    }

    /// The new element is no use if it lands inside a collapsed array.
    func testTappingAddItemExpandsACollapsedArraySoTheNewItemIsVisible() throws {
        try open(#"{"a":["x"]}"#)
        let table = try table()
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3)   // root, a, [0]

        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 1, section: 0)) as? JSONNodeCell)
        cell.onDisclosureTapped?()
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2, "the array should be collapsed now")

        try selectRow(1)
        try option(titled: "Add item", in: try options(of: try presentedPicker())).handler()
        XCTAssertEqual(table.numberOfRows(inSection: 0), 4, "root, a, [0], [1]")
    }

    // MARK: - 3. The escape hatch

    func testTheMenuAlsoOffersAnItemOfADifferentType() throws {
        let menu = try arrayMenu(#"{"a":["x","y"]}"#)
        let escape = try option(titled: "Add item of another type\u{2026}", in: menu)
        tap(escape, opensAnotherSheet: true)

        let picker = try presentedPicker()
        let types = try options(of: picker)
        XCTAssertEqual(types.map(\.title), JSONValueKind.allCases.map(\.badge))
        let selected: Int? = try? mirrored("selectedIndex", of: picker)
        XCTAssertEqual(selected, JSONValueKind.allCases.firstIndex(of: .string),
                       "the inferred type should be checked, so the escape hatch is a change not a puzzle")

        try option(titled: JSONValueKind.object.badge, in: types).handler()
        let array = try XCTUnwrap(document.value(at: [.key("a")]) as? [Any])
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual((array.last as? [String: Any])?.isEmpty, true,
                       "a type the user picked on purpose starts empty")
    }

    /// Picking the type that was already inferred must still give the inferred
    /// SHAPE, not a bare empty object.
    func testPickingTheInferredTypeFromTheEscapeHatchKeepsTheInferredShape() throws {
        let menu = try arrayMenu(#"{"a":[{"id":1,"name":"x"}]}"#)
        let escape = try option(titled: "Add item of another type\u{2026}", in: menu)
        tap(escape, opensAnotherSheet: true)

        try option(titled: JSONValueKind.object.badge, in: try options(of: try presentedPicker())).handler()
        let added = try XCTUnwrap((document.value(at: [.key("a")]) as? [Any])?.last as? [String: Any])
        XCTAssertEqual(Set(added.keys), ["id", "name"])
    }

    /// After a fallback there is nothing to check: the sheet must not claim an
    /// empty array "matches" a string.
    func testTheEscapeHatchChecksNothingWhenTheArrayCouldNotBeRead() throws {
        let menu = try arrayMenu(#"{"a":[]}"#)
        let escape = try option(titled: "Add item of another type\u{2026}", in: menu)
        tap(escape, opensAnotherSheet: true)

        let picker = try presentedPicker()
        let selected: Int?? = try? mirrored("selectedIndex", of: picker)
        XCTAssertEqual(selected ?? nil, nil)
        XCTAssertTrue(try options(of: picker).allSatisfy { $0.subtitle == nil })
    }
}
