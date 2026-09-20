//
//  DetailPageAuditFixTests.swift
//  SwiftyDebugTests
//
//  The request detail screen's audit fixes, pinned down where they can be
//  observed without a running host app:
//
//   * a section's truncation threshold has to follow its content, not the
//     argument `init` happened to be handed (REQUEST PARAMETERS, JWT and the
//     other `content: nil` sections are filled in AFTER construction);
//   * an image response is a body — its card has to offer the Preview control,
//     and tapping it has to reach the viewer that can draw an image;
//   * an image card is sized by the image, not by a square baked into
//     `setupViews()` that every text row also had to solve;
//   * the header card prints the row number of the request actually being
//     shown;
//   * a key/value card's custom stack spacing is registered after the fields
//     are arranged, which is the only point at which UIStackView keeps it.
//

import XCTest
@testable import SwiftyDebug

final class DetailPageAuditFixTests: XCTestCase {

    private var window: UIWindow!
    private var navigation: UINavigationController!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        navigation = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A solid-colour image of an exact point size, so the aspect ratio the cell
    /// derives from it is known up front.
    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeImageTransaction() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://cdn.example.com/assets/banner.png")
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "image/png"
        model.isImage = true
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = String(format: "%f", Date().timeIntervalSince1970 + 0.1)
        model.responseHeaderFields = ["Content-Type": "image/png"] as NSDictionary
        let png = makeImage(width: 40, height: 10).pngData()
        model.responseData = png
        model.responseDataSize = UInt(png?.count ?? 0)
        return model
    }

    private func makeTextTransaction(path: String) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com" + path)
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "application/json"
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        model.endTime = String(format: "%f", Date().timeIntervalSince1970 + 0.1)
        model.responseHeaderFields = ["Content-Type": "application/json"] as NSDictionary
        let body = #"{"ok":true}"#.data(using: .utf8)
        model.responseData = body
        model.responseDataSize = UInt(body?.count ?? 0)
        return model
    }

    /// The detail screen on a real navigation stack, laid out.
    private func presentDetail(_ model: NetworkTransaction,
                               in list: [NetworkTransaction]) -> NetworkDetailViewController {
        let vc = NetworkDetailViewController()
        vc.httpModel = model
        vc.httpModels = list

        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = nav
        win.isHidden = false
        win.layoutIfNeeded()

        nav.pushViewController(vc, animated: false)
        win.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        window = win
        navigation = nav
        return vc
    }

    // MARK: - FINDING 21 — mustInPreview follows the content

    func testContentAssignedAfterInitTripsMustInPreview() {
        var section = NetworkDetailSection(title: "REQUEST PARAMETERS", content: nil,
                                           url: nil, httpModel: nil)
        XCTAssertFalse(section.mustInPreview,
                       "Setup failed: an empty section must not want truncation.")

        section.content = String(repeating: "a", count: 20_000)

        XCTAssertTrue(section.mustInPreview,
                      "A 20 KB body assigned after init is rendered whole in one cell — four "
                      + "regex sweeps in cellForRowAt and no \"Show Full\" way out of it.")
    }

    func testContentPassedToInitStillTripsMustInPreview() {
        let section = NetworkDetailSection(title: "RESPONSE",
                                           content: String(repeating: "b", count: 20_000),
                                           url: nil, httpModel: nil)
        XCTAssertTrue(section.mustInPreview,
                      "Property observers do not run during init, so init must keep computing "
                      + "the flag itself.")
    }

    func testSmallContentAssignedAfterInitDoesNotTripMustInPreview() {
        var section = NetworkDetailSection(title: "JWT TOKEN", content: nil, url: nil, httpModel: nil)
        section.content = "{\"sub\":\"42\"}"
        XCTAssertFalse(section.mustInPreview,
                       "A short body must still be shown in full, not truncated at 2000 chars.")
    }

    func testReplacingLargeContentWithSmallContentClearsMustInPreview() {
        var section = NetworkDetailSection(title: "RESPONSE",
                                           content: String(repeating: "c", count: 20_000),
                                           url: nil, httpModel: nil)
        section.content = "{}"
        XCTAssertFalse(section.mustInPreview,
                       "The flag has to track the CURRENT value, otherwise a two-character body "
                       + "is still shown truncated with a Show Full button that adds nothing.")
    }

    // MARK: - FINDING 20 — an image response has a Preview control

    func testImageResponseCardOffersThePreviewButton() {
        let cell = NetworkDetailCell(style: .default, reuseIdentifier: "NetworkDetailCell")
        var section = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil,
                                           image: makeImage(width: 40, height: 10), httpModel: nil)
        section.showPreview = true
        cell.detailModel = section

        XCTAssertFalse(cell.previewButton.isHidden,
                       "The RESPONSE card for an image offers no control at all: no Preview, no "
                       + "copy, and the row is not selectable — the body cannot be opened.")
    }

    func testSectionWithNeitherTextNorImageStillHidesThePreviewButton() {
        let cell = NetworkDetailCell(style: .default, reuseIdentifier: "NetworkDetailCell")
        var section = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil, httpModel: nil)
        section.showPreview = true
        cell.detailModel = section

        XCTAssertTrue(cell.previewButton.isHidden,
                      "A section with no body at all must not offer to preview one.")
    }

    func testTappingPreviewOnAnImageResponseOpensTheImageViewer() {
        let model = makeImageTransaction()
        let vc = presentDetail(model, in: [model])

        guard let responseRow = vc.detailModels.firstIndex(where: { $0.image != nil }) else {
            return XCTFail("Setup failed: the image response built no section carrying the image.")
        }
        let indexPath = IndexPath(row: responseRow + 1, section: 0)
        guard let cell = vc.tableView(vc.tableView, cellForRowAt: indexPath) as? NetworkDetailCell else {
            return XCTFail("Setup failed: the image RESPONSE row is not a NetworkDetailCell.")
        }

        cell.tapEditViewCallback?(cell.detailModel)

        guard let pushed = navigation.viewControllers.last as? JsonViewController else {
            return XCTFail("Preview on an image response pushed "
                           + "\(String(describing: navigation.viewControllers.last)) — the viewer "
                           + "that can draw an image was never reached.")
        }
        XCTAssertNotNil(pushed.detailModel?.image,
                        "The viewer was pushed with a content-only copy of the section, so its "
                        + "image branch never runs and the page is empty.")
    }

    func testSharedTextNamesAnImageResponseInsteadOfDroppingIt() {
        let model = makeImageTransaction()
        let vc = presentDetail(model, in: [model])

        XCTAssertTrue(vc.messageBody.contains("<image response"),
                      "\"Share full details (text)\" exports an image request with no RESPONSE "
                      + "section and no note that a body existed.")
    }

    // MARK: - FINDING 69 — the image card is sized by the image

    private func aspectConstraints(of cell: NetworkDetailCell) -> [NSLayoutConstraint] {
        cell.imgView.constraints.filter {
            $0.firstAttribute == .height && $0.secondAttribute == .width
        }
    }

    func testImageCardUsesTheImagesOwnAspectRatio() {
        let cell = NetworkDetailCell(style: .default, reuseIdentifier: "NetworkDetailCell")
        var section = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil,
                                           image: makeImage(width: 1200, height: 300), httpModel: nil)
        section.showPreview = true
        cell.detailModel = section

        let active = aspectConstraints(of: cell).filter { $0.isActive }
        XCTAssertEqual(active.count, 1, "Exactly one height:width constraint may be active.")
        XCTAssertEqual(active.first?.multiplier ?? 0, 0.25, accuracy: 0.001,
                       "A 1200x300 banner is force-fitted into a screen-wide square, so the card "
                       + "is ~370pt tall and almost entirely empty.")
    }

    func testAspectConstraintIsDroppedWhenTheCellIsReusedForText() {
        let cell = NetworkDetailCell(style: .default, reuseIdentifier: "NetworkDetailCell")
        var image = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil,
                                         image: makeImage(width: 40, height: 10), httpModel: nil)
        image.showPreview = true
        cell.detailModel = image
        XCTAssertFalse(aspectConstraints(of: cell).filter { $0.isActive }.isEmpty,
                       "Setup failed: the image row never got an aspect constraint.")

        cell.detailModel = NetworkDetailSection(title: "REQUEST HEADER", content: "{\"a\":1}",
                                                url: nil, httpModel: nil)

        XCTAssertTrue(aspectConstraints(of: cell).filter { $0.isActive }.isEmpty,
                      "A plain-text row keeps solving a tall hidden image view, saved from being "
                      + "visible only by the card's clipsToBounds.")
    }

    func testReconfiguringWithASecondImageDoesNotStackAspectConstraints() {
        let cell = NetworkDetailCell(style: .default, reuseIdentifier: "NetworkDetailCell")
        var first = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil,
                                         image: makeImage(width: 40, height: 10), httpModel: nil)
        first.showPreview = true
        cell.detailModel = first

        var second = NetworkDetailSection(title: "RESPONSE", content: nil, url: nil,
                                          image: makeImage(width: 10, height: 40), httpModel: nil)
        second.showPreview = true
        cell.detailModel = second

        let active = aspectConstraints(of: cell).filter { $0.isActive }
        XCTAssertEqual(active.count, 1,
                       "Two ratios active at once is an unsatisfiable layout on a reused cell.")
        XCTAssertEqual(active.first?.multiplier ?? 0, 4.0, accuracy: 0.001,
                       "The reused cell kept the previous image's ratio.")
    }

    // MARK: - FINDING 71 — the header card's row number

    func testHeaderCardShowsTheRowNumberOfTheRequestBeingViewed() {
        let list = (0..<5).map { makeTextTransaction(path: "/v1/item/\($0)") }
        let vc = presentDetail(list[3], in: list)

        XCTAssertEqual(vc.headerCell?.index, 3,
                       "Every request detail claims to be request 1, so the header card can never "
                       + "be correlated back to the row that was tapped.")
    }

    func testHeaderCardFallsBackToTheFirstRowWhenTheModelIsNotInTheList() {
        let model = makeTextTransaction(path: "/v1/solo")
        let vc = presentDetail(model, in: [])
        XCTAssertEqual(vc.headerCell?.index, 0)
    }

    // MARK: - FINDING 82 — the tapped thumbnail opens that image

    func testTappingAMediaThumbnailOpensThatImageRatherThanTheGrid() {
        let model = makeTextTransaction(path: "/v1/feed")
        let vc = presentDetail(model, in: [model])

        // The MEDIA section is normally built from the response's parsed image
        // URLs; injecting it keeps the test on the tile-tap plumbing, which is
        // what the defect is in.
        var media = NetworkDetailSection(title: "MEDIA", content: nil, url: nil, httpModel: model)
        media.mediaImageURLs = (0..<12).map { "https://cdn.example.invalid/img\($0).png" }
        vc.detailModels.append(media)
        vc.tableView.reloadData()

        let indexPath = IndexPath(row: vc.detailModels.count, section: 0)
        guard let cell = vc.tableView(vc.tableView, cellForRowAt: indexPath) as? NetworkMediaGridCell else {
            return XCTFail("Setup failed: the MEDIA row is not a NetworkMediaGridCell.")
        }

        cell.onSelectImage?(5)

        XCTAssertTrue(navigation.viewControllers.last is MediaDetailViewController,
                      "Tapping the 6th thumbnail pushed "
                      + "\(String(describing: navigation.viewControllers.last)) — the start index "
                      + "is threaded end to end and then discarded, so every tile and \"Show all\" "
                      + "open the same grid scrolled to the top.")
    }

    func testShowAllStillOpensTheGallery() {
        let model = makeTextTransaction(path: "/v1/feed")
        let vc = presentDetail(model, in: [model])

        var media = NetworkDetailSection(title: "MEDIA", content: nil, url: nil, httpModel: model)
        media.mediaImageURLs = (0..<3).map { "https://cdn.example.invalid/img\($0).png" }
        vc.detailModels.append(media)
        vc.tableView.reloadData()

        let indexPath = IndexPath(row: vc.detailModels.count, section: 0)
        guard let cell = vc.tableView(vc.tableView, cellForRowAt: indexPath) as? NetworkMediaGridCell else {
            return XCTFail("Setup failed: the MEDIA row is not a NetworkMediaGridCell.")
        }

        cell.onShowAll?()

        XCTAssertTrue(navigation.viewControllers.last is MediaGalleryViewController,
                      "\"Show all\" must still open the grid of every image.")
    }

    // MARK: - FINDING 70 — the header card refreshes after pin / intercept

    /// Blanking the header cell's model and watching it come back is the only
    /// observable proof that the card was re-configured: `NetworkCell` draws its
    /// pin and intercept indicators from `configure()`, which runs from the
    /// `httpModel` setter and nowhere else.
    func testPinningRefreshesTheHeaderCard() {
        let model = makeTextTransaction(path: "/v1/orders/9")
        let vc = presentDetail(model, in: [model])
        vc.headerCell?.httpModel = nil

        _ = vc.perform(NSSelectorFromString("togglePin"))

        XCTAssertTrue(vc.headerCell?.httpModel === model,
                      "The nav-bar button flips but the pin indicator in the header card below it "
                      + "stays as it was until the screen is left and re-entered.")
        // Leave the store as it was found.
        _ = vc.perform(NSSelectorFromString("togglePin"))
    }

    func testARuleChangeRefreshesTheHeaderCard() {
        let model = makeTextTransaction(path: "/v1/orders/10")
        let vc = presentDetail(model, in: [model])
        vc.headerCell?.httpModel = nil

        NotificationCenter.default.post(name: .interceptRulesDidChange, object: nil)
        let delivered = expectation(description: "rule change delivered on the main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)

        XCTAssertTrue(vc.headerCell?.httpModel === model,
                      "A rule created through the header card's own \"Intercept Request\" button "
                      + "leaves the bolt badge on that very card switched off — the editor is a "
                      + "page-sheet, so this screen never gets an appearance callback.")
    }

    // MARK: - FINDING 73 — the key/value card's custom spacing

    /// The vertical stack inside the card — found by the field it arranges,
    /// because the cell keeps it private.
    private func verticalStack(in cell: KeyValueCardCell) -> UIStackView? {
        var queue: [UIView] = [cell.contentView]
        while let view = queue.first {
            queue.removeFirst()
            if let stack = view as? UIStackView, stack.axis == .vertical,
               stack.arrangedSubviews.contains(cell.keyField) {
                return stack
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    func testBothCustomGapsSurviveInTheKeyValueCard() {
        let cell = KeyValueCardCell(style: .default, reuseIdentifier: "KeyValueCardCell")
        guard let stack = verticalStack(in: cell) else {
            return XCTFail("Setup failed: the card's vertical stack was not found.")
        }

        XCTAssertEqual(stack.customSpacing(after: cell.keyField), 10,
                       "setCustomSpacing was issued before keyField was an arranged subview, so "
                       + "UIStackView dropped it: the separator sits closer to the key than to "
                       + "the value it divides.")

        // Arranged in setup() as key row / key field / separator / caption / value.
        guard stack.arrangedSubviews.count >= 3 else {
            return XCTFail("Setup failed: the card's stack no longer arranges five views.")
        }
        let separator = stack.arrangedSubviews[2]
        XCTAssertEqual(stack.customSpacing(after: separator), 10,
                       "The gap below the separator regressed.")
    }
}
