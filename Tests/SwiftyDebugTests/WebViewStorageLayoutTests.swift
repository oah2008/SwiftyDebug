//
//  WebViewStorageLayoutTests.swift
//  SwiftyDebugTests
//
//  The storage screen's header was laid out with frame math against
//  `view.bounds.width` read in `viewDidLoad` — before the view has its real
//  width — and carried an autoresizing mask on a `tableHeaderView`, which UIKit
//  sizes specially. The result was a row wider than the screen, clipped at BOTH
//  edges: "Force overwrite" lost its first letters and the switch ran off the
//  right.
//
//  The whole suite stayed green while that screen was visibly broken, because
//  nothing asserted on frames. These do.
//

import XCTest
import UIKit
import WebKit
@testable import SwiftyDebug

final class WebViewStorageLayoutTests: XCTestCase {

    private let phone = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// Kept alive for the test's duration — the controller holds the web view weakly.
    private var webView: WKWebView!

    override func setUp() {
        super.setUp()
        webView = WKWebView(frame: .zero)
    }

    override func tearDown() {
        webView = nil
        super.tearDown()
    }

    private func laidOut(_ frame: CGRect) -> WebViewStorageViewController {
        let vc = WebViewStorageViewController(webView: webView)
        vc.view.frame = frame
        let window = UIWindow(frame: frame)
        window.rootViewController = vc
        window.isHidden = false
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return vc
    }

    private func header(of vc: WebViewStorageViewController) throws -> UIView {
        try XCTUnwrap(vc.tableView.tableHeaderView, "The screen must have a header")
    }

    // MARK: - The reported bug

    func testHeaderMatchesTheTableWidth() throws {
        let vc = laidOut(phone)
        let head = try header(of: vc)
        XCTAssertEqual(head.frame.width, vc.tableView.bounds.width, accuracy: 0.5,
                       "A header wider than the table is what clipped the row at both edges")
    }

    func testEveryHeaderControlStaysInsideTheScreen() throws {
        let vc = laidOut(phone)
        let head = try header(of: vc)

        func check(_ v: UIView, _ name: String) {
            let f = v.convert(v.bounds, to: head)
            XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(name) is clipped off the LEFT edge")
            XCTAssertLessThanOrEqual(f.maxX, head.bounds.width + 0.5,
                                     "\(name) runs off the RIGHT edge")
        }
        // Walk the real hierarchy rather than naming private properties.
        for sub in head.subviews {
            check(sub, "header subview")
            for leaf in sub.subviews where !(leaf is UIStackView) {
                check(leaf, String(describing: type(of: leaf)))
            }
        }
    }

    func testHeaderIsTallEnoughForItsContent() throws {
        let vc = laidOut(phone)
        let head = try header(of: vc)
        XCTAssertGreaterThan(head.frame.height, 60,
                             "The segment plus the force-overwrite row need real height")
        // And it must be measured, not a hardcoded guess that content can outgrow.
        let fitted = head.systemLayoutSizeFitting(
            CGSize(width: head.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        XCTAssertEqual(head.frame.height, fitted, accuracy: 1.0,
                       "The header height must come from its own constraints")
    }

    // MARK: - It has to survive a width change

    func testHeaderReflowsWhenTheWidthChanges() throws {
        let vc = laidOut(phone)
        let narrow = CGRect(x: 0, y: 0, width: 320, height: 568)
        vc.view.frame = narrow
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        let head = try header(of: vc)
        XCTAssertEqual(head.frame.width, vc.tableView.bounds.width, accuracy: 0.5,
                       "Rotating or resizing must re-measure the header")
        for sub in head.subviews {
            let f = sub.convert(sub.bounds, to: head)
            XCTAssertLessThanOrEqual(f.maxX, head.bounds.width + 0.5,
                                     "A control runs off the edge on a small phone")
        }
    }

    func testLayoutHoldsOnTheSmallestSupportedWidth() throws {
        let vc = laidOut(CGRect(x: 0, y: 0, width: 320, height: 568))
        let head = try header(of: vc)
        XCTAssertGreaterThan(head.frame.width, 0)
        XCTAssertGreaterThan(head.frame.height, 60)
    }
}
