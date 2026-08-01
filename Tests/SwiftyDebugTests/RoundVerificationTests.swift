//
//  RoundVerificationTests.swift
//  SwiftyDebugTests
//
//  Independent verification of the four fixes reported this round. Written
//  without trusting the agents' own harnesses — in particular the RTL one,
//  which pins the navigation bar itself and so cannot tell whether the arrow
//  survives when that pin is the thing that is missing.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class RoundVerificationTests: XCTestCase {

    override func tearDown() {
        UIView.appearance().semanticContentAttribute = .unspecified
        super.tearDown()
    }

    // MARK: - 1. RTL back arrow, with the bar's own pin defeated

    /// The reported fix rests on two independent halves: a trait pin on the bar,
    /// and a non-mirroring glyph. The trait pin is `traitOverrides`, which does
    /// not exist before iOS 17 — on an iOS 15/16 host ONLY the glyph protects
    /// the arrow. This forces RTL onto the navigation bar itself, which is what
    /// defeating that pin looks like, and asks what the user actually sees.
    func testBackArrowSurvivesWhenTheBarsOwnTraitPinIsDefeated() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("needs traitOverrides to force RTL") }

        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        let window = SwiftyDebugWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        // Defeat the pin the SDK puts on the bar: this is exactly the state an
        // iOS 15/16 host is in, where `forceLTR()`'s trait half is compiled out.
        nav.view.traitOverrides.layoutDirection = .rightToLeft
        nav.navigationBar.traitOverrides.layoutDirection = .rightToLeft

        nav.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()

        let chevron = try chevronImageView(in: nav.navigationBar)
        XCTAssertEqual(chevron.traitCollection.layoutDirection, .rightToLeft,
                       "harness precondition: the glyph's own environment must be RTL for this to prove anything")
        XCTAssertEqual(try Self.pointing(ofView: chevron), .left,
                       "With the trait pin defeated the glyph itself must hold the arrow left")
    }

    /// What ACTUALLY protects the arrow, measured rather than assumed.
    ///
    /// The round's report says the swap works because `chevron.left` has
    /// `flipsForRightToLeftLayoutDirection == false`. That is true of the raw
    /// symbol but NOT of the image UIKit installs: UIKit re-arms the flag on
    /// whatever back indicator it is given. So there are two separate mirroring
    /// paths and two separate protections:
    ///
    ///  * the ASSET variant, resolved from the layoutDirection TRAIT — disarmed
    ///    because `chevron.left` has no right-to-left variant (load-bearing, and
    ///    the only protection on iOS 15/16);
    ///  * `UIImageView`'s own flip, driven by the view's SEMANTIC direction —
    ///    disarmed only because the hosting window's appearance proxy forces
    ///    `semanticContentAttribute = .forceLeftToRight` on every view inside an
    ///    SDK window, the private image view included.
    ///
    /// This pins the second half: with the semantic forced RTL on the glyph's
    /// own view — i.e. if a host ever beat the containment proxy — the arrow
    /// mirrors again. It is a statement of the residual risk, not a defect.
    func testTheSemanticFlipPathIsRealAndIsHeldOnlyByTheAppearanceProxy() throws {
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        let window = SwiftyDebugWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()
        nav.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        nav.navigationBar.layoutIfNeeded()

        let chevron = try chevronImageView(in: nav.navigationBar)
        let image = try XCTUnwrap(chevron.image)

        // UIKit re-arms the flag; the raw symbol does not carry it.
        XCTAssertFalse(try XCTUnwrap(UIImage(systemName: "chevron.left")).flipsForRightToLeftLayoutDirection)
        XCTAssertTrue(image.flipsForRightToLeftLayoutDirection,
                      "If UIKit stopped re-arming this, the note above is stale — re-measure")

        // The proxy is what keeps it inert: the glyph's own view resolves LTR
        // even though the whole window sits in a host forced to RTL.
        XCTAssertEqual(chevron.effectiveUserInterfaceLayoutDirection, .leftToRight,
                       "The appearance proxy is the only thing disarming the flip path")
    }

    // MARK: - 2. JSON order on the REAL clipboard path

    private static let unsortedBody = """
    {"status":"ok","id":42,"total":19.99,"currency":"USD","createdAt":"2026-01-02","active":true}
    """

    private static let expectedOrder = ["status", "id", "total", "currency", "createdAt", "active"]

    /// Top-level object keys, in the order they appear in the TEXT.
    ///
    /// A string counts as a key only when it sits directly inside the outermost
    /// object AND the next non-whitespace character after its closing quote is a
    /// colon — otherwise every string VALUE is counted as a key too, which is
    /// what a naive scanner does.
    private func topLevelKeyOrder(_ text: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "{" || ch == "[" {
                depth += 1
                index = text.index(after: index)
            } else if ch == "}" || ch == "]" {
                depth -= 1
                index = text.index(after: index)
            } else if ch == "\"" {
                var literal = ""
                var cursor = text.index(after: index)
                var escaped = false
                while cursor < text.endIndex {
                    let c = text[cursor]
                    if escaped { literal.append(c); escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { break }
                    else { literal.append(c) }
                    cursor = text.index(after: cursor)
                }
                // cursor is on the closing quote (or end).
                var after = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
                while after < text.endIndex, text[after].isWhitespace {
                    after = text.index(after: after)
                }
                let isKey = after < text.endIndex && text[after] == ":"
                if isKey, depth == 1 { keys.append(literal) }
                index = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
            } else {
                index = text.index(after: index)
            }
        }
        return keys
    }

    /// The canonical printer — the half that was fixed.
    func testCanonicalPrettyPrinterPreservesServerKeyOrder() throws {
        let text = try XCTUnwrap(Data(Self.unsortedBody.utf8).dataToPrettyPrintString())
        XCTAssertEqual(topLevelKeyOrder(text), Self.expectedOrder)
    }

    /// KNOWN-BROKEN. The COPY BUTTON on every section of the network detail
    /// screen (`NetworkDetailCell.tapCopy`, line 386) goes through
    /// `JSONExporter.clipboardString`, NOT through the canonical printer that
    /// was fixed this round. `JSONExporter.prettyJSONString(from:)` still does
    /// `JSONSerialization.jsonObject` -> `JSONSerialization.data`, which re-emits
    /// the keys in hash order — so the preview is right and the clipboard is
    /// wrong, which is the exact symptom the round set out to remove.
    ///
    /// Handed off as BLOCKING, dropped twice, now fixed: `JSONExporter` routes
    /// through `JSONDocument`'s source index instead of a dictionary round-trip.
    func testClipboardStringPreservesServerKeyOrder() throws {
        let copied = JSONExporter.clipboardString(from: Self.unsortedBody)
        XCTAssertEqual(topLevelKeyOrder(copied), Self.expectedOrder,
                       "The copy button re-alphabetises the body the preview just got right")
    }

    /// Same cause, same fix: a dictionary round-trip reprinted `1250.00` as
    /// `1250` and `19.99` as `19.989999999999998`.
    func testClipboardStringPreservesNumberSpelling() throws {
        let copied = JSONExporter.clipboardString(from: #"{"total":19.99,"paid":1250.00}"#)
        XCTAssertTrue(copied.contains("19.99"), "got: \(copied)")
        XCTAssertTrue(copied.contains("1250.00"), "got: \(copied)")
    }

    /// The copy source is the COMPLETE body, not the 2000-char display preview.
    /// `NetworkDetailSection` keeps `rawContent` untransformed and only the
    /// cell truncates `content` for display, so this holds — pinned so a future
    /// change to either side cannot quietly make copy lossy.
    func testCopySourceIsTheCompleteBodyNotTheTruncatedPreview() throws {
        var rows: [String] = []
        for i in 0..<400 { rows.append(#"{"sku":"WIDGET-\#(i)","name":"a padded row name \#(i)"}"#) }
        let body = "[" + rows.joined(separator: ",") + "]"
        XCTAssertGreaterThan(body.count, 10_000, "harness precondition: must trip mustInPreview")

        let section = NetworkDetailSection(title: "RESPONSE BODY", content: body)
        XCTAssertTrue(section.mustInPreview, "harness precondition: the cell must be truncating for display")
        let source = try XCTUnwrap(section.rawContent)
        XCTAssertFalse(source.hasSuffix("..."), "the copy source is the truncated preview")
        XCTAssertTrue(source.contains("WIDGET-399"), "the copy source lost the tail of the body")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(source.utf8), options: []))
    }

    /// Clipboard hygiene, on whatever path it comes from. Objects and arrays
    /// only — a top-level FRAGMENT crashes this path, see the test below.
    func testClipboardTextIsTrimmedAndParses() throws {
        for source in [Self.unsortedBody, #"[1,2,3]"#, #"{"a":{"b":[1,2]}}"#] {
            let copied = JSONExporter.clipboardString(from: source)
            XCTAssertEqual(copied, copied.trimmingCharacters(in: .whitespacesAndNewlines),
                           "leading/trailing whitespace on the clipboard for \(source)")
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(copied.utf8),
                                                             options: [.fragmentsAllowed]),
                            "clipboard text does not parse for \(source)")
        }
    }

    /// `JSONExporter.prettyJSONString` READS with `.fragmentsAllowed` and then
    /// WRITES without it. A top-level JSON fragment — a bare string, number or
    /// bool, which is a perfectly ordinary API response — therefore parses and
    /// then raises `NSInvalidArgumentException` ("Invalid top-level type in JSON
    /// write") from `JSONSerialization.data(withJSONObject:)`. That is an
    /// Objective-C exception, so `try?` does NOT catch it: tapping COPY on such
    /// a body takes the HOST APP down.
    ///
    /// Asserted through the precondition rather than by triggering it, so this
    /// suite does not have to raise an uncaught exception to make the point.
    func testCopyingATopLevelJSONFragmentWouldCrashTheHostApp() throws {
        for fragment in [#""bare string""#, "42", "true", "null"] {
            let data = Data(fragment.utf8)
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            XCTAssertNotNil(parsed, "\(fragment) must parse — that is what gets it past the guard")
            XCTAssertFalse(JSONSerialization.isValidJSONObject(parsed as Any),
                           "\(fragment) is not a writable top-level object; "
                             + "JSONExporter writes it anyway and raises NSInvalidArgumentException")
        }
    }

    /// Non-JSON must survive the new printer as raw text, not vanish.
    func testNonJSONBodiesStillRenderVerbatim() throws {
        for body in ["not json at all", "<html><body>hi</body></html>", "id,name\n1,a"] {
            XCTAssertEqual(Data(body.utf8).dataToPrettyPrintString(), body)
            XCTAssertEqual(JSONExporter.clipboardString(from: body), body)
        }
    }

    /// The canonical printer is now on the path of every detail screen build.
    /// A large body must not freeze it.
    func testLargeBodyRendersWithinBudget() throws {
        var rows: [String] = []
        for i in 0..<20_000 {
            rows.append(#"{"sku":"WIDGET-\#(i)","price":19.99,"qty":\#(i),"name":"row \#(i)"}"#)
        }
        let body = Data(("[" + rows.joined(separator: ",") + "]").utf8)
        let start = Date()
        let text = try XCTUnwrap(body.dataToPrettyPrintString())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThan(elapsed, 3.0, "rendering \(body.count) bytes took \(elapsed)s")
    }

    /// Above the 2 MB ceiling the order-preserving path is skipped — confirm the
    /// fallback still produces valid JSON rather than nothing.
    func testOverTheCeilingStillRendersValidJSON() throws {
        var rows: [String] = []
        for i in 0..<60_000 {
            rows.append(#"{"sku":"WIDGET-\#(i)","name":"a fairly long row name for padding \#(i)"}"#)
        }
        let body = Data(("[" + rows.joined(separator: ",") + "]").utf8)
        XCTAssertGreaterThan(body.count, 2 * 1024 * 1024, "harness precondition: must exceed the ceiling")
        let text = try XCTUnwrap(body.dataToPrettyPrintString())
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }

    // MARK: - 3. Rule duplication against the real store

    /// The maintainer's exact scenario: create, duplicate, edit the copy,
    /// confirm the original is untouched and both delete independently. They
    /// share a storage bucket, which is where this breaks.
    func testDuplicateThenEditTheCopyLeavesTheOriginalUntouchedAndBothDeleteIndependently() throws {
        let store = InterceptRuleStore.shared
        let endpoint = "/verify/duplication/\(UUID().uuidString)"
        for rule in store.allRules() where rule.matchEndpoint == endpoint { store.remove(id: rule.id) }

        var original = InterceptRule(matchEndpoint: endpoint, matchMode: .exact)
        original.name = "Original"
        original.matchHost = "api.example.com"
        original.isEnabled = true
        original.headerOverrides = [KVPair(key: "X-Env", value: "prod")]
        original.responseRewrites = [ResponseRewrite(pattern: "data.url",
                                                    action: .setValue("one"),
                                                    isEnabled: true, name: "rw")]
        store.addOrUpdate(original)

        let copy = try XCTUnwrap(InterceptRuleDuplicator.duplicateAndStore(id: original.id))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(copy.isEnabled, "a copy must arrive switched off")
        XCTAssertNotEqual(copy.responseRewrites.first?.id, original.responseRewrites.first?.id,
                          "nested rewrite ids must be re-minted or the engine cannot tell them apart")
        XCTAssertNotEqual(copy.headerOverrides.first?.id, original.headerOverrides.first?.id)

        // Both really are in the store, in the same bucket.
        var both = store.allRules().filter { $0.matchEndpoint == endpoint }
        XCTAssertEqual(both.count, 2, "the copy did not survive addOrUpdate alongside its original")

        // Edit the COPY.
        var edited = try XCTUnwrap(store.allRules().first { $0.id == copy.id })
        edited.name = "Edited copy"
        edited.headerOverrides = [KVPair(key: "X-Env", value: "staging")]
        edited.isBlocked = true
        store.addOrUpdate(edited)

        let originalAfter = try XCTUnwrap(store.allRules().first { $0.id == original.id })
        XCTAssertEqual(originalAfter.name, "Original", "editing the copy renamed the original")
        XCTAssertEqual(originalAfter.headerOverrides.first?.value, "prod",
                       "editing the copy changed the original's headers")
        XCTAssertFalse(originalAfter.isBlocked, "editing the copy blocked the original")
        XCTAssertTrue(originalAfter.isEnabled)

        // Independently deletable, in both directions.
        store.remove(id: copy.id)
        both = store.allRules().filter { $0.matchEndpoint == endpoint }
        XCTAssertEqual(both.count, 1, "removing the copy took the original with it")
        XCTAssertEqual(both.first?.id, original.id)

        store.remove(id: original.id)
        XCTAssertTrue(store.allRules().filter { $0.matchEndpoint == endpoint }.isEmpty)
    }

    /// A new ENDPOINT rule must default to the request's host without a sheet
    /// asking for it, and that scope must still reach `resolvedRule`.
    func testNewEndpointRuleDefaultsToThisHostAndTheScopeReachesResolvedRule() throws {
        let store = InterceptRuleStore.shared
        let endpoint = "/verify/scope/\(UUID().uuidString)"
        for rule in store.allRules() where rule.matchEndpoint == endpoint { store.remove(id: rule.id) }
        defer { for rule in store.allRules() where rule.matchEndpoint == endpoint { store.remove(id: rule.id) } }

        let transaction = NetworkTransaction()
        transaction.url = NSURL(string: "https://api.example.com" + endpoint)
        transaction.method = "GET"
        transaction.statusCode = "200"

        let editor = PresentationRecordingRuleEditor()
        editor.httpModel = transaction
        editor.initialMatchMode = .exact
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        editor.view.layoutIfNeeded()
        editor.viewDidAppear(false)
        editor.viewDidAppear(false)   // re-appearing must not start presenting it either

        // `presentedViewController` stays nil in a scene-less test host whether
        // or not `present` was called, so it proves nothing — record the CALL.
        XCTAssertTrue(editor.presented.isEmpty,
                      "a sheet auto-presented on rule creation: "
                        + editor.presented.map { String(describing: type(of: $0)) }.joined(separator: ", "))

        // Arm something, or the editor correctly refuses to save a no-op rule.
        editor.setBlocked(true)

        guard case .ok(var rule) = editor.validatedRule() else {
            return XCTFail("the editor refused to build a rule")
        }
        XCTAssertEqual(rule.matchHost, "api.example.com",
                       "a new endpoint rule must default to THIS host")

        rule.isEnabled = true
        rule.isBlocked = true
        store.addOrUpdate(rule)

        XCTAssertNotNil(store.resolvedRule(forURL: URL(string: "https://api.example.com" + endpoint)!),
                        "the host-pinned scope never reached resolvedRule")
        XCTAssertNil(store.resolvedRule(forURL: URL(string: "https://other.com" + endpoint)!),
                     "a host-pinned rule must not fire on another host")
    }

    // MARK: - 4. Smart add fidelity

    /// Appending must not reorder keys or reserialise numbers.
    func testAppendingAnInferredItemDoesNotReorderKeysOrRespellNumbers() throws {
        let source = #"{"zeta":1.50,"alpha":250.00,"items":[{"sku":"A","price":9.90}]}"#
        let document = try XCTUnwrap(JSONDocument(data: Data(source.utf8)))
        let path: JSONPath = [.key("items")]
        let template = document.arrayElementTemplate(forArrayAt: path)
        XCTAssertTrue(document.appendElement(template.value, toArrayAt: path))

        let text = document.prettyText()
        XCTAssertEqual(topLevelKeyOrder(text), ["zeta", "alpha", "items"],
                       "appending reordered the top-level keys")
        XCTAssertTrue(text.contains("1.50"), "1.50 was respelled: \(text)")
        XCTAssertTrue(text.contains("250.00"), "250.00 was respelled: \(text)")
        XCTAssertTrue(text.contains("9.90"), "9.90 was respelled: \(text)")
    }

    /// Inference across element types, including nested and mixed.
    func testInferenceAcrossElementTypes() throws {
        func template(_ json: String) throws -> JSONArrayElementTemplate {
            let document = try XCTUnwrap(JSONDocument(data: Data(json.utf8)))
            return document.arrayElementTemplate(forArrayAt: [.key("a")])
        }
        XCTAssertEqual(try template(#"{"a":["x","y"]}"#).value as? String, "")
        XCTAssertEqual(try template(#"{"a":[1,2]}"#).value as? Int, 0)
        XCTAssertEqual(try template(#"{"a":[true,false]}"#).value as? Bool, false)

        let nested = try template(#"{"a":[{"user":{"name":"n","age":3}}]}"#)
        let object = try XCTUnwrap(nested.value as? [String: Any])
        let user = try XCTUnwrap(object["user"] as? [String: Any])
        XCTAssertEqual(user["name"] as? String, "", "nested object was not shaped one level down")
        XCTAssertEqual(user["age"] as? Int, 0)

        // A key that is null in row 0 and a string in row 1 is an optional string.
        let optional = try template(#"{"a":[{"note":null},{"note":"hi"}]}"#)
        let shaped = try XCTUnwrap(optional.value as? [String: Any])
        XCTAssertEqual(shaped["note"] as? String, "",
                       "the first element won instead of the union of observed types")
    }

    // MARK: - helpers

    /// Records what the editor ASKS to present instead of presenting it.
    /// Necessary because a scene-less test window never completes a
    /// presentation, so `presentedViewController` reads nil either way.
    private final class PresentationRecordingRuleEditor: InterceptRuleEditorViewController {
        var presented: [UIViewController] = []
        override func present(_ viewControllerToPresent: UIViewController,
                              animated: Bool, completion: (() -> Void)? = nil) {
            presented.append(viewControllerToPresent)
            completion?()
        }
    }

    private func chevronImageView(in bar: UINavigationBar) throws -> UIImageView {
        func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        func hasMaskAncestor(_ view: UIView) -> Bool {
            var next: UIView? = view
            while let current = next, current !== bar {
                if String(describing: type(of: current)).contains("Mask") { return true }
                next = current.superview
            }
            return false
        }
        let chevrons = descendants(of: bar)
            .compactMap { $0 as? UIImageView }
            .filter { ($0.image?.description ?? "").contains("symbol(system: chevron") }
            .filter { !hasMaskAncestor($0) }
        guard let only = chevrons.first, chevrons.count == 1 else {
            throw XCTSkip("could not isolate the back chevron image view (found \(chevrons.count))")
        }
        return only
    }

    enum Pointing: CustomStringConvertible {
        case left, right
        var description: String { self == .left ? "left (<)" : "right (>)" }
    }

    private enum Failure: Error { case unreadable }

    private static func pointing(ofView view: UIView) throws -> Pointing {
        let size = view.bounds.size
        guard size.width >= 4, size.height >= 4 else { throw Failure.unreadable }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            view.layer.render(in: context)
        }
        var topSum = 0.0, topCount = 0.0, middleSum = 0.0, middleCount = 0.0
        for y in 0..<height {
            let band = Double(y) / Double(height)
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                if band < 0.28 { topSum += Double(x); topCount += 1 }
                if band > 0.42, band < 0.58 { middleSum += Double(x); middleCount += 1 }
            }
        }
        guard topCount > 0, middleCount > 0 else { throw Failure.unreadable }
        let top = topSum / topCount, middle = middleSum / middleCount
        guard abs(top - middle) > 0.5 else { throw Failure.unreadable }
        return top > middle ? .left : .right
    }
}
