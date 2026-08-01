//
//  JSONEditorUnrepresentableBodyTests.swift
//  SwiftyDebugTests
//
//  A body that PARSES but cannot be written back.
//
//  `JSONSerialization` accepts a negative literal that overflows a `Double` —
//  `{"balance":-2e308}` is valid JSON per RFC 8259 and a backend really can emit
//  it — and hands back `-infinity`. JSON has no way to spell that, so
//  `JSONTextWriter` throws and `JSONDocument.prettyText()` answers `""`.
//
//  Everything downstream took that `""` at face value:
//
//    * switching to RAW rendered an empty text view over a body that was still
//      in the tree, and switching back was then refused ("" is not valid JSON),
//      so the editor was stuck showing nothing;
//    * FORMAT and PASTE blanked the text view the same way;
//    * COPY VALUE put an empty string on the clipboard;
//    * SAVE called `onSave`, and every caller of `onSave` writes
//      `document.prettyText()` straight into something the host app reads — a
//      mock body (`MockResponseEditorViewController`), a held request and a held
//      response (`BreakpointInboxViewController`). The app was served an EMPTY
//      body, with nothing on screen saying why.
//
//  These drive the real controls: the segmented control, the toolbar buttons and
//  the Save item, so a regression has to land where the taps go.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONEditorUnrepresentableBodyTests: XCTestCase {

    /// Valid JSON whose number overflows a Double. Only the NEGATIVE direction
    /// parses — Foundation rejects `2e308` outright — so this is the literal
    /// that actually reaches the editor.
    private static let overflowingBody = #"{"id":7,"balance":-2e308,"currency":"SAR"}"#

    private var window: UIWindow!
    private var editor: JSONEditorViewController!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        editor = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func open(_ text: String) {
        editor = JSONEditorViewController(text: text, title: "Body")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    private func spinUntil(_ condition: () -> Bool, timeout: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func mirrored<T>(_ label: String) -> T? {
        Mirror(reflecting: editor!).children.first { $0.label == label }?.value as? T
    }

    private var modeControl: UISegmentedControl? { mirrored("modeControl") }
    private var rawTextView: UITextView? { mirrored("rawTextView") }
    private var statusLabel: UILabel? { mirrored("statusLabel") }

    /// The Raw segment, driven through the same handler the control calls.
    /// `sendActions(for:)` does not reach a private `@objc` target in this
    /// environment, so the selector is invoked directly — same code path.
    ///
    /// `expectsAlert` only decides how long to wait: spinning for an alert that
    /// is never coming is what made this suite take half a minute.
    private func switchToRaw(expectsAlert: Bool = true) {
        guard let control = modeControl else { return XCTFail("no mode control") }
        control.selectedSegmentIndex = 1
        editor.perform(NSSelectorFromString("modeChanged"))
        if expectsAlert { spinUntil { self.editor.presentedViewController != nil } }
    }

    private func tapFormat(expectsAlert: Bool = true) {
        editor.perform(NSSelectorFromString("formatTapped"))
        if expectsAlert { spinUntil { self.editor.presentedViewController != nil } }
    }

    private func presentedAlert() -> UIAlertController? {
        editor.presentedViewController as? UIAlertController
    }

    /// The Save item, driven through its own target/action.
    private func tapSave(expectsAlert: Bool = true) {
        guard let item = editor.navigationItem.rightBarButtonItem,
              let action = item.action, let target = item.target else {
            return XCTFail("no Save button")
        }
        _ = target.perform(action, with: item)
        if expectsAlert { spinUntil { self.editor.presentedViewController != nil } }
    }

    // MARK: - 0. The premise

    func testTheBodyParsesAndThenRefusesToSerialise() throws {
        let document = try XCTUnwrap(JSONDocument(text: Self.overflowingBody),
                                     "the premise is wrong — this body does not parse")
        XCTAssertTrue(JSONDocument.validate(Self.overflowingBody).isValid)
        XCTAssertEqual(document.prettyText(), "",
                       "the premise is wrong — this body serialises fine")
        XCTAssertEqual(document.serializationProblem(),
                       "root.balance is infinity or NaN, which JSON cannot represent.")
        // The values are all still there; only the TEXT cannot be produced.
        XCTAssertEqual(document.value(at: [.key("id")]) as? NSNumber, 7)
        XCTAssertEqual(document.value(at: [.key("currency")]) as? String, "SAR")
    }

    // MARK: - 1. Save must not hand an empty body to the host app

    func testSavingRefusesInsteadOfDeliveringAnEmptyBody() {
        open(Self.overflowingBody)
        var saved: JSONDocument?
        editor.onSave = { saved = $0 }

        tapSave()

        XCTAssertNil(saved, "SAVE handed the host app a document that serialises to \"\"")
        let alert = presentedAlert()
        XCTAssertNotNil(alert, "SAVE failed silently")
        XCTAssertEqual(alert?.title, "Can't save")
        XCTAssertTrue(alert?.message?.contains("balance") == true,
                      "the alert does not name the offending value: \(alert?.message ?? "nil")")
    }

    /// The same editor must still save a body that is fine — the guard is not
    /// allowed to become "Save never works".
    func testSavingAnOrdinaryBodyStillWorks() throws {
        open(#"{"zeta":1250.00,"alpha":"a"}"#)
        var saved: JSONDocument?
        editor.onSave = { saved = $0 }

        tapSave(expectsAlert: false)

        let document = try XCTUnwrap(saved, "an ordinary body did not reach onSave")
        XCTAssertEqual(document.prettyText(),
                       "{\n  \"zeta\" : 1250.00,\n  \"alpha\" : \"a\"\n}")
        XCTAssertNil(presentedAlert(), "an ordinary save put up an alert")
    }

    // MARK: - 2. Raw mode must not show an empty document

    func testSwitchingToRawRefusesRatherThanShowingAnEmptyEditor() {
        open(Self.overflowingBody)
        switchToRaw()

        XCTAssertEqual(modeControl?.selectedSegmentIndex, 0,
                       "the editor switched to Raw with nothing to show")
        XCTAssertTrue(rawTextView?.isHidden ?? false,
                      "the empty raw view was put on screen anyway")
        let alert = presentedAlert()
        XCTAssertEqual(alert?.title, "Can't show this as text")
        XCTAssertTrue(alert?.message?.contains("balance") == true,
                      "the alert does not name the offending value")
    }

    func testSwitchingToRawStillWorksForAnOrdinaryBody() {
        open(#"{"zeta":1250.00,"alpha":"a"}"#)
        switchToRaw(expectsAlert: false)

        XCTAssertEqual(modeControl?.selectedSegmentIndex, 1)
        XCTAssertEqual(rawTextView?.text, "{\n  \"zeta\" : 1250.00,\n  \"alpha\" : \"a\"\n}")
        XCTAssertEqual(statusLabel?.text, "Valid JSON")
        XCTAssertNil(presentedAlert())
    }

    // MARK: - 3. FORMAT must not blank the text the user typed

    /// Typing an overflowing literal into Raw and tapping FORMAT used to replace
    /// the whole text view with "". The text is the only copy of what was typed.
    func testFormattingUnwritableRawTextLeavesItAlone() throws {
        open(#"{"keep":"me"}"#)
        switchToRaw(expectsAlert: false)
        XCTAssertEqual(modeControl?.selectedSegmentIndex, 1)

        let typed = Self.overflowingBody
        rawTextView?.text = typed
        tapFormat()

        XCTAssertEqual(rawTextView?.text, typed, "FORMAT wiped the text that was typed")
        let alert = presentedAlert()
        XCTAssertEqual(alert?.title, "Can't format")
        XCTAssertTrue(alert?.message?.contains("balance") == true,
                      "the alert does not name the offending value: \(alert?.message ?? "nil")")
    }

    func testFormattingOrdinaryRawTextStillFormatsIt() throws {
        open(#"{"keep":"me"}"#)
        switchToRaw(expectsAlert: false)
        rawTextView?.text = #"{"zeta":1250.00,"alpha":"a"}"#
        tapFormat(expectsAlert: false)

        XCTAssertEqual(rawTextView?.text, "{\n  \"zeta\" : 1250.00,\n  \"alpha\" : \"a\"\n}")
        XCTAssertNil(presentedAlert(), "an ordinary format put up an alert")
    }

    // MARK: - 4. Nothing else regressed

    /// The guard must key on "cannot be written", not on "looks unusual". A
    /// body of `null`, `""`, `{}`, `[]` or a bare fragment all serialise, and
    /// all must still save and still open in Raw.
    func testShapesThatDoSerialiseAreNeverRefused() {
        for body in ["null", "\"OK\"", "42", "true", "{}", "[]", "\"\"", "[[]]", "{\"a\":{}}"] {
            open(body)
            var saved: JSONDocument?
            editor.onSave = { saved = $0 }
            tapSave(expectsAlert: false)
            XCTAssertNotNil(saved, "SAVE refused a perfectly writable body: \(body)")
            XCTAssertNil(presentedAlert(), "\(body) put up an alert")

            open(body)
            switchToRaw(expectsAlert: false)
            XCTAssertEqual(modeControl?.selectedSegmentIndex, 1, "\(body) could not open in Raw")
            XCTAssertFalse(rawTextView?.text.isEmpty ?? true, "\(body) rendered as empty text")
        }
    }
}
