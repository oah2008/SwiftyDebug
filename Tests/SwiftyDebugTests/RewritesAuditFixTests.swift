//
//  RewritesAuditFixTests.swift
//  SwiftyDebugTests
//
//  A response rewrite is armed once and then runs unattended, so every number
//  this feature prints is the only evidence the developer has. These pin the
//  four ways it lied:
//
//   * a walk that stopped at the traversal limit reported its partial count as
//     an exact one, so a half-applied rewrite read as a complete one;
//   * the preview decided "nothing changes" by comparing two strings the
//     renderer had already clipped to 200 characters, so a real edit past that
//     clip was announced as a no-op the user had to confirm past;
//   * seeding "Set a fixed value" from the same renderer armed a rewrite that
//     wrote the clipped, newline-flattened text into every response;
//   * the VALUE field promised the type is preserved when the engine only
//     preserves it for text that fits the type.
//
//  One case here pins the preview overload that takes an already-parsed
//  root: the editor previews on every typing pause, and re-parsing the body for
//  each one cost a full JSON parse on the main thread. Both entry points have to
//  produce the same rows, or the screen's "same code as the wire" claim goes.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class RewritesAuditFixTests: XCTestCase {

    // MARK: - Bodies

    /// A product catalog: `products` items, one in every `every` of them
    /// carrying a "url". Ordinary JSON of a few hundred KB — well inside the
    /// engine's 2 MB limit and well past the pattern walker's node budget.
    private func catalog(products: Int, every: Int) -> Any {
        var items: [Any] = []
        for i in 0..<products {
            var item: [String: Any] = ["id": i, "name": "product \(i)"]
            if i % every == 0 { item["url"] = "https://cdn.example.com/\(i).png" }
            items.append(item)
        }
        return ["items": items] as [String: Any]
    }

    private func data(_ root: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: root)
    }

    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func rewrite(_ pattern: String, _ action: RewriteAction) -> ResponseRewrite {
        ResponseRewrite(pattern: pattern, action: action)
    }

    // MARK: - A walk that stopped early says so

    func testBroadPatternThatRunsOutOfBudgetReportsThatItWasTruncated() {
        let root = catalog(products: 12_000, every: 25)
        let pattern = JSONPathPattern("**.url")!

        let matched = pattern.matchesReporting(in: root)
        XCTAssertTrue(matched.wasTruncated,
                      "the walk stopped at maxVisitedNodes; reporting it as complete is the defect")
        XCTAssertLessThan(matched.paths.count, 12_000 / 25,
                          "this body holds 480 urls — a truncated walk necessarily found fewer")
        XCTAssertFalse(matched.paths.isEmpty)

        // The plain overload is unchanged for the call sites that only want paths.
        XCTAssertEqual(pattern.matches(in: root).map { $0.display },
                       matched.paths.map { $0.display })
    }

    func testCompleteWalkIsNotReportedAsTruncated() {
        let matched = JSONPathPattern("**.url")!.matchesReporting(in: catalog(products: 20, every: 2))
        XCTAssertEqual(matched.paths.count, 10)
        XCTAssertFalse(matched.wasTruncated)
    }

    func testHittingTheResultCapAlsoCountsAsTruncated() {
        let root = json("""
        {"items":[{"url":"a"},{"url":"b"},{"url":"c"}]}
        """)
        let pattern = JSONPathPattern("items[*].url")!
        XCTAssertTrue(pattern.matchesReporting(in: root, limit: 2).wasTruncated)
        // Filling the cap exactly is reported as truncated too: the walk stopped
        // on the cap, and nothing at that point knows there was no fourth value.
        XCTAssertTrue(pattern.matchesReporting(in: root, limit: 3).wasTruncated)
        XCTAssertFalse(pattern.matchesReporting(in: root, limit: 4).wasTruncated)
    }

    func testRewriteReportSaysTheBodyWasOnlyPartlyVisitedInsteadOfPrintingAnExactCount() {
        let body = data(catalog(products: 12_000, every: 25))
        XCTAssertLessThanOrEqual(body.count, ResponseRewriteEngine.maxBodyBytes,
                                 "the point of this case is that the walk gives up long before the size limit does")

        let result = ResponseRewriteEngine.apply(
            [rewrite("**.url", .replaceHost("cdn.staging.example.com"))], to: body)
        let entry = result.report.entries.first

        XCTAssertNotNil(entry?.error,
                        "\"matched N, changed N\" with no error is indistinguishable from a full sweep")
        XCTAssertTrue(entry?.error?.contains("traversal limit") == true, entry?.error ?? "no error")
        XCTAssertEqual(entry?.matched, entry?.changed)
        XCTAssertLessThan(entry?.matched ?? 0, 480, "480 values carry a url; the walk never reached most of them")
    }

    func testRewriteReportOfACompleteWalkCarriesNoError() {
        let result = ResponseRewriteEngine.apply(
            [rewrite("**.url", .replaceHost("cdn.staging.example.com"))],
            to: data(catalog(products: 20, every: 2)))
        XCTAssertNil(result.report.entries.first?.error)
        XCTAssertEqual(result.report.entries.first?.matched, 10)
    }

    // MARK: - The preview counts what the engine did, not what it rendered

    /// 600 characters of copy with the hit at roughly offset 300 — past the
    /// 200-character clip `displayText` applies to both sides of the row.
    private var longDescriptionBody: Data {
        let text = String(repeating: "x", count: 300) + "google.com" + String(repeating: "y", count: 300)
        return data(["description": text] as [String: Any])
    }

    func testFindAndReplacePastTheDisplayLimitIsCountedAsAChange() {
        let rows = ResponseRewriteEngine.preview(
            rewrite("**.description", .findReplace(find: "google.com", replace: "salla.com", isRegex: false)),
            on: longDescriptionBody, limit: 10)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].before, rows[0].after,
                       "both sides are clipped at 200 characters — which is exactly why they cannot be compared")
        XCTAssertTrue(rows[0].changed, "the engine rewrites this value on every response")
    }

    func testTheSameRewriteReallyDoesChangeTheBodyOnTheWire() {
        let result = ResponseRewriteEngine.apply(
            [rewrite("**.description", .findReplace(find: "google.com", replace: "salla.com", isRegex: false))],
            to: longDescriptionBody)
        XCTAssertTrue(result.report.didChange)
        XCTAssertEqual(result.report.changedCount, 1)
    }

    func testAChangeThatOnlyAffectsNewlinesIsCountedAsAChange() {
        let rows = ResponseRewriteEngine.preview(
            rewrite("text", .findReplace(find: "\n", replace: " ", isRegex: false)),
            on: data(["text": "first\nsecond"] as [String: Any]), limit: 10)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].before, rows[0].after, "the renderer flattens newlines to spaces on both sides")
        XCTAssertTrue(rows[0].changed)
    }

    func testAValueThatIsGenuinelyLeftAloneIsNotCountedAsAChange() {
        let body = data(["text": "hello"] as [String: Any])

        let missing = ResponseRewriteEngine.preview(
            rewrite("text", .findReplace(find: "nowhere", replace: "x", isRegex: false)),
            on: body, limit: 10)
        XCTAssertEqual(missing.count, 1)
        XCTAssertFalse(missing[0].changed)

        let notAURL = ResponseRewriteEngine.preview(
            rewrite("text", .replaceHost("salla.com")), on: body, limit: 10)
        XCTAssertEqual(notAURL.count, 1)
        XCTAssertFalse(notAURL[0].changed, "a value the engine refuses is not a change")

        let removal = ResponseRewriteEngine.preview(rewrite("text", .removeKey), on: body, limit: 10)
        XCTAssertTrue(removal[0].changed)
    }

    // MARK: - Previewing an already-parsed body is the same preview

    func testPreviewFromAParsedRootMatchesPreviewFromBytes() {
        let body = data(catalog(products: 20, every: 2))
        let rule = rewrite("**.url", .replaceHost("cdn.staging.example.com"))

        let fromBytes = ResponseRewriteEngine.preview(rule, on: body, limit: 12)
        let fromRoot = ResponseRewriteEngine.preview(rule, root: json(String(data: body, encoding: .utf8)!),
                                                     sourceText: String(data: body, encoding: .utf8), limit: 12)

        XCTAssertFalse(fromBytes.isEmpty)
        XCTAssertEqual(fromBytes.map { $0.path }, fromRoot.map { $0.path })
        XCTAssertEqual(fromBytes.map { $0.before }, fromRoot.map { $0.before })
        XCTAssertEqual(fromBytes.map { $0.after }, fromRoot.map { $0.after })
        XCTAssertEqual(fromBytes.map { $0.changed }, fromRoot.map { $0.changed })
    }

    // MARK: - Seeding the VALUE field

    /// The editor as it is opened from a tapped value, laid out so its cells can
    /// be asked what they show.
    private func editor(sampleBody: Data?, seedPath: JSONPath?,
                        rewrite: ResponseRewrite? = nil) -> ResponseRewriteEditorViewController {
        let vc = ResponseRewriteEditorViewController(rewrite: rewrite, sampleBody: sampleBody,
                                                     sampleLabel: nil, seedPath: seedPath,
                                                     destination: .caller)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        vc.view.layoutIfNeeded()
        return vc
    }

    private func allCells(_ vc: ResponseRewriteEditorViewController) -> [UITableViewCell] {
        var cells: [UITableViewCell] = []
        for section in 0..<vc.numberOfSections(in: vc.tableView) {
            for row in 0..<vc.tableView(vc.tableView, numberOfRowsInSection: section) {
                cells.append(vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: row, section: section)))
            }
        }
        return cells
    }

    private func textFieldTexts(_ vc: ResponseRewriteEditorViewController) -> [String] {
        allCells(vc).flatMap { fields(in: $0) }.compactMap { $0.text }.filter { !$0.isEmpty }
    }

    private func labelTexts(_ vc: ResponseRewriteEditorViewController) -> [String] {
        allCells(vc).flatMap { labels(in: $0) }.compactMap { $0.text }
    }

    private func fields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        if let field = view as? UITextField { found.append(field) }
        for sub in view.subviews { found.append(contentsOf: fields(in: sub)) }
        return found
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for sub in view.subviews { found.append(contentsOf: labels(in: sub)) }
        return found
    }

    func testSeedingAFixedValuePrefillsTheWholeValueNotItsPreviewText() {
        let description = String(repeating: "a", count: 300) + "\nsecond paragraph "
            + String(repeating: "b", count: 300)
        let body = data(["description": description] as [String: Any])
        let vc = editor(sampleBody: body, seedPath: [.key("description")])

        let seeded = textFieldTexts(vc).first { $0.hasPrefix("aaa") }
        XCTAssertNotNil(seeded, "the VALUE field is pre-filled from the tapped value")

        // The defect: the field used to be seeded from `displayText(limit: 400)`,
        // so a 600-character value arrived cut at 400 with an ellipsis on the end
        // — and that shortened string is what the rewrite then WROTE. The whole
        // value has to survive.
        XCTAssertFalse(seeded?.contains("\u{2026}") == true, "a seeded value must not carry a display ellipsis")
        XCTAssertEqual(seeded?.count, description.count, "the whole value is seeded, not a 400-character preview")

        // `seedText` is the value that gets written. A UITextField cannot RENDER
        // a line break, so the field shows it collapsed — but the seeded value
        // keeps it, and the footer says what editing the field would cost.
        XCTAssertEqual(ResponseRewriteEditorViewController.seedText(for: description), description)
        XCTAssertTrue(ResponseRewriteEditorViewController.seedText(for: description).contains("\n"))
    }

    func testSeedingAContainerPrefillsJSONTheEngineCanParseBack() {
        var big: [String: Any] = [:]
        for i in 0..<40 { big["key\(i)"] = "value \(i) padded out so the object is well over 400 characters" }
        let body = data(["meta": big] as [String: Any])
        let vc = editor(sampleBody: body, seedPath: [.key("meta")])

        let seeded = textFieldTexts(vc).first { $0.hasPrefix("{") }
        XCTAssertNotNil(seeded, "a container seeds as JSON text")
        // "value is a container — the replacement must be JSON" is what a clipped
        // seed produced, for every container over the display limit.
        XCTAssertNotNil(JSONDocument(text: seeded ?? "")?.root)
    }

    // MARK: - The VALUE field says what the engine actually does

    func testValueFieldFooterDoesNotPromiseATypeItMayNotKeep() {
        let vc = editor(sampleBody: nil, seedPath: nil,
                        rewrite: ResponseRewrite(pattern: "stock.qty", action: .setValue("12")))
        let texts = labelTexts(vc)

        XCTAssertFalse(texts.contains { $0.contains("a number stays a number") },
                       "the engine writes unparseable text as text, which changes the field's type")
        XCTAssertTrue(texts.contains { $0.contains("changes the field's type") },
                      "the footer has to say the flip can happen: \(texts)")
    }

    /// The behaviour the footer describes, pinned next to it so the words and
    /// the engine cannot drift apart.
    func testUnparseableTextOnANumberIsWrittenAsText() {
        let result = ResponseRewriteEngine.apply([rewrite("qty", .setValue("12 units"))],
                                                 to: data(["qty": 5] as [String: Any]))
        let root = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        XCTAssertEqual(root?["qty"] as? String, "12 units")
    }
}
