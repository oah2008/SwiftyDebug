//
//  StorageAuditFixTests.swift
//  SwiftyDebugTests
//
//  Four storage-screen defects, each pinned to what the screen actually shows:
//
//    * the file viewer classified by extension alone, so a binary plist — the
//      app's own preferences — rendered as a hex dump under a "TEXT" label,
//      while an extension-less cache entry holding JSON never got read at all;
//    * COPY on a capped read said "Copied" and gave no hint that 200 KB of a
//      5 MB log is all that was taken;
//    * the UserDefaults explainer was a section footer on a `.plain` table, so
//      it floated permanently over the bottom of the list;
//    * the UserDefaults toast had no upper width bound, so a reverse-DNS key
//      pushed both ends of the message off-screen.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class StorageAuditFixTests: XCTestCase {

    private var window: UIWindow!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAuditFixTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    // MARK: - Harness

    /// Puts the real screen in a real window: the file viewer reads on a
    /// background queue and the footer is sized from `viewDidLayoutSubviews`,
    /// so neither answers anything useful off-screen.
    private func present(_ vc: UIViewController, height: CGFloat = 800) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.rootViewController = SwiftyDebugNavigationController(rootViewController: vc)
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        window.layoutIfNeeded()
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(in vc: UIViewController) -> [UILabel] {
        descendants(of: vc.view).compactMap { $0 as? UILabel }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func openViewer(_ url: URL) -> FileContentViewerViewController {
        let vc = FileContentViewerViewController(fileURL: url)
        present(vc)
        waitUntil { !self.body(in: vc).isEmpty }
        return vc
    }

    /// Whatever the viewer put in its text view — decoded text or a hex dump.
    private func body(in vc: UIViewController) -> String {
        for case let textView as UITextView in descendants(of: vc.view) {
            return textView.text ?? ""
        }
        return ""
    }

    /// The header card's INFO row: "<KIND>  ·  <size>  ·  <modified>".
    private func infoRow(in vc: UIViewController) -> String {
        guard let caption = labels(in: vc).first(where: { $0.text == "INFO" }),
              let stack = caption.superview as? UIStackView,
              let value = stack.arrangedSubviews.compactMap({ $0 as? UILabel }).last else { return "" }
        return value.text ?? ""
    }

    private func tapCopy(_ vc: UIViewController) {
        let copySelector = Selector(("copyTapped:"))
        guard let item = vc.navigationItem.rightBarButtonItems?
                .first(where: { $0.action == copySelector }) else {
            return XCTFail("no COPY bar button item")
        }
        _ = vc.perform(copySelector, with: item)
    }

    // MARK: - Finding 35: the decoder, not the extension, decides the rendering

    func testBinaryPlistRendersAsPropertyListTextAndSaysSo() throws {
        // How every `<bundle id>.plist` in Library/Preferences is written.
        let url = dir.appendingPathComponent("com.acme.app.plist")
        let plist: [String: Any] = [
            "hasCompletedOnboarding": true,
            "launchCount": 7,
            "lastRun": Date(timeIntervalSince1970: 1_700_000_000),
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url)

        let vc = openViewer(url)
        let body = self.body(in: vc)
        XCTAssertTrue(body.contains("hasCompletedOnboarding"),
                      "a binary plist must be decoded, not hex-dumped: \(body.prefix(120))")
        XCTAssertFalse(body.contains("bplist00"), "the raw header means this is still a hex dump")
        XCTAssertTrue(infoRow(in: vc).hasPrefix("PLIST"),
                      "the header must name what was decoded, not the extension: \(infoRow(in: vc))")
    }

    func testExtensionlessCacheEntryHoldingJSONIsReadAsJSON() throws {
        // URLCache and hand-rolled disk caches name entries without extensions,
        // and the body is routinely JSON well past the 2 KB hex window.
        let url = dir.appendingPathComponent("fsCachedData-4F2C9B")
        let items = (0..<200).map { ["id": $0, "name": "item-\($0)"] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["items": items], options: [])
        XCTAssertGreaterThan(data.count, 2 * 1024, "the point of this test is a body past the hex window")
        try data.write(to: url)

        let vc = openViewer(url)
        XCTAssertTrue(body(in: vc).contains("item-199"),
                      "an extension-less JSON cache entry must be read whole, not hex-dumped")
        XCTAssertTrue(infoRow(in: vc).hasPrefix("JSON"), infoRow(in: vc))
    }

    func testGenuinelyOpaqueBytesStillFallBackToHexAndNeverClaimToBeText() throws {
        let url = dir.appendingPathComponent("blob")
        var bytes: [UInt8] = []
        for i in 0..<256 { bytes.append(UInt8((i * 7 + 0xF1) % 256)) }
        try Data(bytes).write(to: url)

        let vc = openViewer(url)
        XCTAssertTrue(body(in: vc).contains("— first "), "opaque bytes are still a hex dump")
        XCTAssertTrue(infoRow(in: vc).hasPrefix("HEX"),
                      "a hex dump must never be labelled TEXT: \(infoRow(in: vc))")
    }

    // MARK: - Finding 36: a capped read says so

    func testCopyOnATruncatedReadNamesHowMuchWasTaken() throws {
        let url = dir.appendingPathComponent("app.log")
        var text = ""
        let line = "2026-09-19 10:04:11.123  INFO  request finished in 42 ms\n"
        while text.utf8.count < 300 * 1024 { text += line }
        try text.write(to: url, atomically: true, encoding: .utf8)

        let vc = openViewer(url)
        tapCopy(vc)
        XCTAssertTrue(labels(in: vc).contains { $0.text == "Copied 200 KB" },
                      "COPY on a capped read must not claim the whole file was taken")
    }

    func testCopyOnAWholeFileStillJustSaysCopied() throws {
        let url = dir.appendingPathComponent("small.log")
        try "one line\n".write(to: url, atomically: true, encoding: .utf8)

        let vc = openViewer(url)
        // The toast is built reading "Copied", so blank it first or this test
        // passes without the tap ever running.
        let toast = labels(in: vc).first(where: { $0.layer.cornerRadius == 10 })
        toast?.text = ""
        tapCopy(vc)
        XCTAssertEqual(toast?.text, "Copied", "an untruncated copy must not grow a size suffix")
    }

    // MARK: - Finding 80: the explainer scrolls with the list

    func testUserDefaultsExplainerIsAScrollingTableFooterNotAFloatingSectionFooter() {
        let vc = UserDefaultsBrowserViewController()
        present(vc)

        // `titleForFooterInSection` is a DATA SOURCE method, not a delegate one.
        XCTAssertNil((vc as UITableViewDataSource).tableView?(vc.tableView, titleForFooterInSection: 0),
                     "a section footer on a .plain table floats over the last row")

        guard let footer = vc.tableView.tableFooterView else {
            return XCTFail("the explainer has no table footer view to live in")
        }
        XCTAssertGreaterThan(footer.bounds.height, 20, "the footer was never sized")
        let text = descendants(of: footer).compactMap { ($0 as? UILabel)?.text }.joined()
        XCTAssertTrue(text.contains("System and global defaults are never listed"),
                      "the explainer text must survive the move: \(text)")
    }

    // MARK: - Finding 81: the toast fits the screen

    func testUserDefaultsToastTruncatesInsteadOfRunningOffBothEdges() {
        let vc = UserDefaultsBrowserViewController()
        present(vc)

        guard let toast = labels(in: vc).first(where: { $0.layer.cornerRadius == 12 }) else {
            return XCTFail("no toast label")
        }
        toast.text = "  Saved “com.acme.onboarding.hasCompletedWalkthrough” as Bool  "
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        XCTAssertLessThanOrEqual(toast.bounds.width, vc.view.bounds.width - 32 + 0.5,
                                 "a reverse-DNS key must not push the message off-screen")
        XCTAssertGreaterThanOrEqual(toast.bounds.width, 160, "the minimum bubble width still holds")
    }
}
