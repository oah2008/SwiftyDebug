//
//  JSONNonFiniteNumberTests.swift
//  SwiftyDebugTests
//
//  `Double("inf")`, `Double("Infinity")` and `Double("nan")` all succeed, and
//  both number coercion sites used to be `Double(text) ?? 0`. Typing `inf` into
//  the JSON value editor and saving therefore put an infinity into the tree,
//  and the next serialisation raised NSInvalidArgumentException
//  ("Invalid number value (infinite) in JSON write") — an **ObjC** exception,
//  which `try?` does not catch. It terminated the HOST APP, not SwiftyDebug.
//
//  If any of this regresses, the failures below will not be assertions: the
//  test process will die the same way the host app did.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class JSONNonFiniteNumberTests: XCTestCase {

    private let poison = ["inf", "-inf", "Inf", "infinity", "INFINITY", "nan", "NaN", "-nan", "1e400"]

    // MARK: - Coercion

    func testCoderRefusesEveryNonFiniteSpelling() {
        for text in poison {
            XCTAssertNil(JSONInlineValueCoder.number(from: text),
                         "\"\(text)\" is not a JSON number and must be refused, not coerced")
        }
    }

    func testCoderStillAcceptsRealNumbers() throws {
        XCTAssertEqual(JSONInlineValueCoder.number(from: "42"), NSNumber(value: 42))
        XCTAssertEqual(JSONInlineValueCoder.number(from: " -3.5 "), NSNumber(value: -3.5))
        XCTAssertEqual(JSONInlineValueCoder.number(from: "0"), NSNumber(value: 0))
        // Integers stay integral, so they don't render as "1.0".
        let seven = try XCTUnwrap(JSONInlineValueCoder.number(from: "7"))
        XCTAssertEqual(JSONDocument(root: seven).minifiedText(), "7")
    }

    func testValueFromTextNeverYieldsANonFiniteNumber() throws {
        for text in poison {
            let value = try XCTUnwrap(JSONInlineValueCoder.value(from: text, kind: .number) as? NSNumber)
            XCTAssertTrue(value.doubleValue.isFinite, "\(text) produced \(value)")
        }
    }

    /// `JSONDocument.convert` is the other `Double(text) ?? 0` site: it runs
    /// when the type switcher turns a string node into a number.
    func testChangingKindToNumberCannotSmuggleInAnInfinity() throws {
        for text in poison {
            let converted = try XCTUnwrap(JSONDocument.convert(text, to: .number) as? NSNumber)
            XCTAssertTrue(converted.doubleValue.isFinite, "\(text) produced \(converted)")
        }
        let doc = try XCTUnwrap(JSONDocument(text: #"{"a":"inf"}"#))
        XCTAssertTrue(doc.changeKind(at: [.key("a")], to: .number))
        XCTAssertNotNil(doc.data(), "The document must still be deliverable")
    }

    // MARK: - Serialisation refuses instead of raising

    func testSerialisingAnInfinityFailsInsteadOfKillingTheProcess() {
        // Only a buggy caller can get one in here — that is the point.
        let doc = JSONDocument(root: ["x": NSNumber(value: Double.infinity)])
        XCTAssertNil(doc.data())
        XCTAssertEqual(doc.minifiedText(), "")
        XCTAssertEqual(doc.prettyText(), "")
        let problem = doc.serializationProblem()
        XCTAssertNotNil(problem, "A body that cannot be written must say so, not no-op silently")
        XCTAssertTrue(problem?.contains("root.x") ?? false, problem ?? "nil")
    }

    func testSerialisingANaNFailsInsteadOfKillingTheProcess() {
        let doc = JSONDocument(root: ["deep": ["list": [NSNumber(value: Double.nan)]]])
        XCTAssertNil(doc.data())
        XCTAssertTrue(doc.serializationProblem()?.contains("root.deep.list[0]") ?? false,
                      doc.serializationProblem() ?? "nil")
    }

    /// Foundation raises the same uncatchable exception for a non-JSON type.
    func testANonJSONValueIsReportedRatherThanRaised() {
        let doc = JSONDocument(root: ["when": Date(timeIntervalSince1970: 0)])
        XCTAssertNil(doc.data())
        XCTAssertNotNil(doc.serializationProblem())
    }

    func testAFiniteDocumentHasNoProblemToReport() throws {
        let doc = try XCTUnwrap(JSONDocument(text: #"{"a":1,"b":[2.5,null,true,"x"]}"#))
        XCTAssertNil(doc.serializationProblem())
        XCTAssertNotNil(doc.data())
    }

    // MARK: - The editor refuses, out loud

    func testSaveOutcomeRefusesNonFiniteInput() {
        for text in poison {
            let outcome = JSONValueEditorViewController.saveOutcome(kind: .number, text: text, boolIsOn: false)
            XCTAssertNil(outcome.writtenValue, "\"\(text)\" must not be saved as a number")
            XCTAssertNotNil(outcome.refusalReason, "\"\(text)\" must be refused with a reason")
        }
    }

    func testSaveOutcomeRefusesEmptyTextRatherThanWritingZero() {
        let outcome = JSONValueEditorViewController.saveOutcome(kind: .number, text: "   ", boolIsOn: false)
        XCTAssertNil(outcome.writtenValue)
        XCTAssertNotNil(outcome.refusalReason)
    }

    func testSaveOutcomeStillWritesEveryValidValue() throws {
        let number = JSONValueEditorViewController.saveOutcome(kind: .number, text: " 12.5 ", boolIsOn: false)
        XCTAssertEqual(number.writtenValue as? NSNumber, NSNumber(value: 12.5))

        let string = JSONValueEditorViewController.saveOutcome(kind: .string, text: "inf", boolIsOn: false)
        XCTAssertEqual(string.writtenValue as? String, "inf",
                       "\"inf\" is a perfectly good string — only the number field refuses it")

        XCTAssertEqual(JSONValueEditorViewController
            .saveOutcome(kind: .bool, text: "", boolIsOn: true).writtenValue as? Bool, true)
        XCTAssertTrue(JSONValueEditorViewController
            .saveOutcome(kind: .null, text: "", boolIsOn: false).writtenValue is NSNull)
    }

    /// End to end through the real Done button: nothing may be handed back.
    func testTappingDoneOnInfinitySavesNothing() throws {
        let (vc, window) = editor(startingFrom: NSNumber(value: 3))
        defer { window.isHidden = true }

        var saved: Any?
        vc.onSave = { saved = $0 }
        try XCTUnwrap(textView(in: vc.view)).text = "inf"
        tapDone(vc)

        XCTAssertNil(saved, "Done must refuse an infinity instead of handing it to the document")
    }

    func testTappingDoneOnARealNumberStillSaves() throws {
        let (vc, window) = editor(startingFrom: NSNumber(value: 3))
        defer { window.isHidden = true }

        var saved: Any?
        vc.onSave = { saved = $0 }
        try XCTUnwrap(textView(in: vc.view)).text = "9.75"
        tapDone(vc)

        XCTAssertEqual(saved as? NSNumber, NSNumber(value: 9.75))
    }

    // MARK: - Helpers

    private func editor(startingFrom value: Any) -> (JSONValueEditorViewController, UIWindow) {
        let vc = JSONValueEditorViewController(value: value, pathDisplay: "root.price")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = UINavigationController(rootViewController: vc)
        window.isHidden = false
        vc.view.layoutIfNeeded()
        return (vc, window)
    }

    private func tapDone(_ vc: JSONValueEditorViewController) {
        guard let item = vc.navigationItem.rightBarButtonItem,
              let action = item.action, let target = item.target else {
            return XCTFail("The editor lost its Done button")
        }
        _ = target.perform(action, with: item)
    }

    private func textView(in view: UIView) -> UITextView? {
        if let found = view as? UITextView { return found }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }
}
