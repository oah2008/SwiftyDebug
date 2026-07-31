//
//  ReplayCapturedBodyFidelityTests.swift
//  SwiftyDebugTests
//
//  Replay pretty-prints a captured body so it can be edited on a phone, and
//  used to re-encode the request from that display text. Pretty-printing goes
//  through `JSONSerialization`, which reorders every object key, adds
//  whitespace and respells numbers — `19.99` comes back as
//  `19.989999999999998`. The bytes on the wire were therefore NOT the bytes
//  being replayed, which breaks any endpoint that signs or hashes the raw
//  payload, and made "replay this request" produce a different request.
//
//  The cURL import path on the same screen already got this right: it keeps the
//  original bytes until `bodyWasEdited` flips. These tests hold the captured
//  path to the same contract, and pin the two ways an edit can happen (typing
//  in the field, saving from the tree editor) so "keep the original" can never
//  turn into "ignore my edit".
//
//  Everything here drives the real screen through its real Send button and
//  reads the bytes off the wire through a URLProtocol, so a fix that only
//  changes a private helper cannot make these pass.
//

import XCTest
import UIKit
@testable import SwiftyDebug

/// Captures the request URLSession actually put on the wire.
private final class ReplayWireTapProtocol: URLProtocol {

    nonisolated(unsafe) static var host = "replay-fidelity.test"
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastMethod: String?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        lastBody = nil
        lastMethod = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastMethod = request.httpMethod
        // URLSession may hand a protocol the body as a stream instead of `httpBody`.
        Self.lastBody = request.httpBody ?? Self.drain(request.httpBodyStream)

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            guard read > 0 else { break }
            out.append(buffer, count: read)
        }
        return out
    }
}

final class ReplayCapturedBodyFidelityTests: XCTestCase {

    /// Key order is deliberately NOT alphabetical and `19.99` is a number
    /// Foundation's writer cannot reproduce — both survive only if the original
    /// bytes are sent.
    private let capturedJSON = #"{"zeta":1,"amount":19.99,"alpha":"x"}"#

    private var window: UIWindow!
    private var navigation: UINavigationController!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ReplayWireTapProtocol.self)
        ReplayWireTapProtocol.reset()
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        navigation = nil
        URLProtocol.unregisterClass(ReplayWireTapProtocol.self)
        super.tearDown()
    }

    // MARK: - Harness

    private func makeCapture(body: Data?, method: String = "POST") -> NetworkTransaction {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://\(ReplayWireTapProtocol.host)/v1/orders?page=2")
        model.method = method
        model.requestHeaderFields = ["Content-Type": "application/json"] as NSDictionary
        model.requestData = body
        return model
    }

    @discardableResult
    private func present(_ controller: RequestReplayViewController) -> RequestReplayViewController {
        navigation = UINavigationController(rootViewController: controller)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = navigation
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        return controller
    }

    /// Taps the real Send button, then waits for the response to come back.
    private func tapSendAndWait(_ controller: RequestReplayViewController,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let item = controller.navigationItem.rightBarButtonItem,
              let target = item.target as? NSObject, let action = item.action else {
            XCTFail("Send button is not wired", file: file, line: line)
            return
        }
        target.perform(action)
        let sent = expectation(description: "request finished")
        // The completion hops back to main and pushes the detail screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sent.fulfill() }
        wait(for: [sent], timeout: 10)
    }

    private func wireText(file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let data = ReplayWireTapProtocol.lastBody else {
            XCTFail("nothing reached the wire", file: file, line: line)
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The BODY section sits below the fold on a phone, so its cell does not
    /// exist until the table scrolls to it.
    private func scrollToBody(_ controller: RequestReplayViewController) {
        let body = IndexPath(row: 0, section: 3)
        guard controller.tableView.numberOfSections > body.section,
              controller.tableView.numberOfRows(inSection: body.section) > 0 else { return }
        controller.tableView.scrollToRow(at: body, at: .top, animated: false)
        controller.tableView.layoutIfNeeded()
    }

    private func bodyField(in controller: RequestReplayViewController,
                           file: StaticString = #filePath, line: UInt = #line) -> UITextView? {
        scrollToBody(controller)
        // 901 is the body text view's tag on the replay screen.
        guard let field = controller.view.viewWithTag(901) as? UITextView else {
            XCTFail("body field is not on screen", file: file, line: line)
            return nil
        }
        return field
    }

    private func jsonCard(in root: UIView) -> JSONEditorCardView? {
        if let card = root as? JSONEditorCardView, !card.isHidden { return card }
        for sub in root.subviews {
            if let found = jsonCard(in: sub) { return found }
        }
        return nil
    }

    /// Fires a control's registered actions directly — `sendActions(for:)`
    /// routes through UIApplication, which does not deliver in this test host.
    private func fire(_ control: UIControl, _ event: UIControl.Event) {
        for target in control.allTargets {
            for name in control.actions(forTarget: target, forControlEvent: event) ?? [] {
                (target as? NSObject)?.perform(Selector(name))
            }
        }
    }

    // MARK: - The defect

    func testCapturedJSONBodyIsReplayedAsTheOriginalBytes() throws {
        let original = Data(capturedJSON.utf8)
        let controller = present(RequestReplayViewController(model: makeCapture(body: original)))

        tapSendAndWait(controller)

        XCTAssertEqual(ReplayWireTapProtocol.lastBody, original,
                       """
                       Replay must put the CAPTURED bytes on the wire. Re-encoding the \
                       pretty-printed display text reorders keys, adds whitespace and \
                       respells 19.99 as 19.989999999999998, so the replayed request is \
                       not the request being replayed.
                       """)
        XCTAssertEqual(wireText(), capturedJSON)
    }

    /// The three separate ways the display text differs from the source, spelled
    /// out so a partial fix (say, minifying instead of keeping the bytes) still
    /// fails.
    func testReplayedBodyKeepsKeyOrderWhitespaceAndNumberSpelling() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8))))
        tapSendAndWait(controller)

        let sent = try XCTUnwrap(wireText())
        XCTAssertTrue(sent.contains("19.99") && !sent.contains("19.989999999999998"),
                      "number spelling changed: \(sent)")
        XCTAssertFalse(sent.contains("\n"), "whitespace was added: \(sent)")
        let zeta = try XCTUnwrap(sent.range(of: "\"zeta\""))
        let alpha = try XCTUnwrap(sent.range(of: "\"alpha\""))
        XCTAssertTrue(zeta.lowerBound < alpha.lowerBound, "keys were reordered: \(sent)")
    }

    /// A captured body that isn't UTF-8 has no text form at all, so there is
    /// nothing to re-encode from — it used to be dropped entirely.
    func testBinaryCapturedBodyIsReplayedUnchanged() throws {
        let binary = Data([0x00, 0xFF, 0x10, 0xC0, 0x80, 0x42])
        let controller = present(RequestReplayViewController(model: makeCapture(body: binary)))

        tapSendAndWait(controller)

        XCTAssertEqual(ReplayWireTapProtocol.lastBody, binary,
                       "a body with no text form must still be replayed byte-for-byte")
    }

    /// The field is empty for a binary body because there is nothing to show —
    /// which reads exactly like "there is nothing to send". Say which it is.
    func testABinaryCapturedBodySaysItIsSentUnchanged() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data([0x00, 0xFF, 0x10]))))
        scrollToBody(controller)

        let texts = Self.labelTexts(in: controller.view)
        XCTAssertTrue(texts.contains { $0.contains("Binary body") && $0.contains("3 bytes") },
                      "an empty body field must not read as \"nothing to send\": \(texts)")
    }

    func testATextCapturedBodyGetsNoBinaryNotice() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8))))
        scrollToBody(controller)

        XCTAssertFalse(Self.labelTexts(in: controller.view).contains { $0.contains("Binary body") })
    }

    private static func labelTexts(in root: UIView) -> [String] {
        var out: [String] = []
        if let label = root as? UILabel, let text = label.text { out.append(text) }
        for sub in root.subviews { out.append(contentsOf: labelTexts(in: sub)) }
        return out
    }

    // MARK: - An edit must still win

    func testTypingInTheBodyFieldSendsWhatWasTyped() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8))))
        let field = try XCTUnwrap(bodyField(in: controller))

        field.text = #"{"typed":"by hand"}"#
        controller.textViewDidChange(field)

        tapSendAndWait(controller)

        XCTAssertEqual(wireText(), #"{"typed":"by hand"}"#,
                       "keeping the original bytes must not survive an actual edit")
    }

    /// The other way to edit: the JSON card pushes the tree editor and "Use Body"
    /// writes back. That write is an edit too — treating it as "untouched" would
    /// send the original bytes and silently discard the tree edit.
    func testEditingThroughTheTreeEditorSendsTheEditedDocument() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8))))

        scrollToBody(controller)
        let card = try XCTUnwrap(jsonCard(in: controller.view), "the JSON card should be offered for a JSON body")
        fire(card, .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let editor = try XCTUnwrap(navigation.viewControllers.last as? JSONEditorViewController,
                                   "tapping the card should push the tree editor")
        editor.loadViewIfNeeded()
        // Change one value through the document, exactly as a row edit would.
        let document = try XCTUnwrap(Mirror(reflecting: editor).children
            .first { $0.label == "document" }?.value as? JSONDocument)
        document.setValue("edited", at: [.key("alpha")])

        guard let save = editor.navigationItem.rightBarButtonItem,
              let target = save.target as? NSObject, let action = save.action else {
            return XCTFail("the editor has no Save button")
        }
        target.perform(action)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        tapSendAndWait(controller)

        let sent = try XCTUnwrap(wireText())
        XCTAssertTrue(sent.contains("\"edited\""),
                      "the tree edit must reach the wire, not be replaced by the captured bytes: \(sent)")
    }

    // MARK: - Adjacent behaviour

    func testCurlImportStillSendsItsOriginalBytesUnlessEdited() throws {
        let body = Data(#"{"b":2,"a":1}"#.utf8)
        let parsed = ParsedCurlRequest(
            method: "POST",
            url: URL(string: "https://\(ReplayWireTapProtocol.host)/import")!,
            headers: [CurlHeader(name: "Content-Type", value: "application/json")],
            body: body,
            ignoredFlags: [],
            followsRedirects: true,
            allowsInsecureTLS: false,
            wantsCompressedResponse: false)
        let controller = present(RequestReplayViewController(curl: parsed))

        tapSendAndWait(controller)

        XCTAssertEqual(ReplayWireTapProtocol.lastBody, body)
    }

    func testGetRequestStillSendsNoBody() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8),
                                                                               method: "GET")))
        tapSendAndWait(controller)

        XCTAssertEqual(ReplayWireTapProtocol.lastMethod, "GET")
        XCTAssertTrue(ReplayWireTapProtocol.lastBody?.isEmpty ?? true,
                      "GET never carries a body")
    }

    func testReplayStillLandsOnTheDetailScreen() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: Data(capturedJSON.utf8))))
        tapSendAndWait(controller)

        XCTAssertEqual(ReplayWireTapProtocol.requestCount, 1)
        let detail = try XCTUnwrap(navigation.viewControllers.last as? NetworkDetailViewController,
                                   "the replay result must open the normal detail screen")
        XCTAssertTrue(detail.isReplayResult)
        XCTAssertEqual(detail.httpModel?.statusCode, "200")
        XCTAssertEqual(detail.httpModel?.requestData, Data(capturedJSON.utf8),
                       "the detail screen must show the request that was actually sent")
    }

    func testQueryParametersAreStillRebuiltOntoTheURL() throws {
        let controller = present(RequestReplayViewController(model: makeCapture(body: nil)))
        tapSendAndWait(controller)

        let detail = try XCTUnwrap(navigation.viewControllers.last as? NetworkDetailViewController)
        XCTAssertEqual(detail.httpModel?.url?.absoluteString,
                       "https://\(ReplayWireTapProtocol.host)/v1/orders?page=2")
    }
}
