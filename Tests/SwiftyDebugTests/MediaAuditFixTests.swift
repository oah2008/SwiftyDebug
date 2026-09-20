//
//  MediaAuditFixTests.swift
//  SwiftyDebugTests
//
//  Four defects in the Media area, each of which showed up as "the debugger is
//  lying about what it captured" or as memory the host app pays for:
//
//    * the Media tab deduplicated by URL on a first-come basis, so a captured
//      media request was silently discarded whenever any *newer* JSON body
//      mentioned the same image URL — the tile then opened a detail page that
//      claimed the asset was only parsed out of JSON, with no method, status,
//      headers or "View source request",
//    * the full-screen pager anchored its content offset exactly once, so after
//      a rotation or an iPad split-view resize the offset still addressed pages
//      in units of the old width and the user was left staring at a black
//      screen with the counter naming a page that was nowhere on it,
//    * ImageLoader's 64 MB cache budget was charged the *download* size, while
//      every cached entry owns a fully decoded bitmap — an order-of-magnitude
//      undercount that re-opened the jetsam hazard the pager windowing work
//      closed (and the data: URI path was charged nothing at all), and
//    * animated GIFs were frozen on their first frame everywhere in the Media
//      tab even though the same GIF plays in the request detail.
//

import XCTest
import ImageIO
@testable import SwiftyDebug

final class MediaAuditFixTests: XCTestCase {

    private var store: NetworkRequestStore { NetworkRequestStore.shared }

    override func setUp() {
        super.setUp()
        emptyStore()
    }

    override func tearDown() {
        emptyStore()
        super.tearDown()
    }

    /// `reset()` deliberately keeps pinned entries, so unpin first.
    private func emptyStore() {
        for model in store.snapshot() {
            model.isPinned = false
        }
        store.reset()
    }

    // MARK: - Fixtures

    /// A captured request for the asset itself (a .png path makes it media).
    @discardableResult
    private func addMediaTransaction(_ urlString: String) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: urlString)
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "image/png"
        model.isImage = true
        XCTAssertTrue(store.addHttpRequset(model))
        return model
    }

    /// A JSON API response whose body mentions the given image URLs, indexed the
    /// way capture time indexes it.
    @discardableResult
    private func addJSONTransaction(path: String, mentioning imageURLs: [String]) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com\(path)")
        model.method = "GET"
        model.statusCode = "200"
        model.mineType = "application/json"
        let payload = imageURLs.enumerated().map { #""avatar\#($0.offset)": "\#($0.element)""# }
        let body = Data("{\(payload.joined(separator: ","))}".utf8)
        model.searchIndex = RequestSearchIndex.build(from: model, responseBody: body)
        XCTAssertEqual(model.imageURLs, imageURLs, "fixture did not index the image URLs it claims to mention")
        XCTAssertTrue(store.addHttpRequset(model))
        return model
    }

    // MARK: - Aggregation (the transaction-backed entry wins)

    func testACapturedRequestIsNotDroppedBecauseANewerJSONBodyMentionsItsURL() {
        let asset = "https://cdn.example.com/a.png"
        addJSONTransaction(path: "/feed", mentioning: [asset])
        let capture = addMediaTransaction(asset)
        // The pull-to-refresh: the same feed, captured again, after the download.
        addJSONTransaction(path: "/feed", mentioning: [asset])

        let items = MediaTabViewController.collectAllItems()
        let matches = items.filter { $0.urlString == asset }
        XCTAssertEqual(matches.count, 1, "the URL must still appear exactly once")
        XCTAssertTrue(matches.first?.transaction === capture,
                      "the captured request was dropped in favour of a JSON-only placeholder")
    }

    /// Order is the other half of the contract: upgrading in place must not move
    /// the item to the front, or the grid would reshuffle as requests arrive.
    func testUpgradingAnEntryKeepsItsNewestFirstPosition() {
        let older = "https://cdn.example.com/older.png"
        let newer = "https://cdn.example.com/newer.png"
        addJSONTransaction(path: "/feed", mentioning: [older])
        let capture = addMediaTransaction(older)
        addMediaTransaction(newer)

        let items = MediaTabViewController.collectAllItems()
        XCTAssertEqual(items.map { $0.urlString }, [newer, older])
        XCTAssertTrue(items.last?.transaction === capture)
    }

    func testAJSONOnlyURLStaysJSONOnlyAndACaptureStaysACapture() {
        let parsedOnly = "https://cdn.example.com/parsed.png"
        let downloaded = "https://cdn.example.com/downloaded.png"
        addJSONTransaction(path: "/feed", mentioning: [parsedOnly])
        addMediaTransaction(downloaded)

        let items = MediaTabViewController.collectAllItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items.first(where: { $0.urlString == parsedOnly })?.transaction)
        XCTAssertNotNil(items.first(where: { $0.urlString == downloaded })?.transaction)
    }

    func testTheSameAssetCapturedTwiceIsStillOneItem() {
        let asset = "https://cdn.example.com/a.png"
        addMediaTransaction(asset)
        let newest = addMediaTransaction(asset)

        let items = MediaTabViewController.collectAllItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.transaction === newest,
                      "newest-first means the most recent capture backs the tile")
    }

    // MARK: - The pager survives a bounds change

    private func makePager(count: Int, start: Int, width: CGFloat, height: CGFloat) -> MediaPagerViewController {
        let pager = MediaPagerViewController(imageURLs: (0..<count).map { "data:image/png;base64,not-real-\($0)" },
                                             startIndex: start)
        pager.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        return pager
    }

    private func pagingScrollView(of pager: MediaPagerViewController) -> UIScrollView? {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    func testTheFirstLayoutStillAnchorsOnThePageTheCallerAskedFor() {
        let pager = makePager(count: 20, start: 6, width: 390, height: 844)
        XCTAssertEqual(pagingScrollView(of: pager)?.contentOffset.x, 390 * 6)
        XCTAssertEqual(pager.loadedPageIndices, [5, 6, 7])
    }

    func testARotationKeepsTheUserOnTheSamePageInsteadOfOnABlackScreen() {
        let pager = makePager(count: 20, start: 6, width: 390, height: 844)

        pager.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()

        guard let scroll = pagingScrollView(of: pager) else { return XCTFail("no paging scroll view") }
        XCTAssertEqual(scroll.contentSize.width, 844 * 20)
        XCTAssertEqual(scroll.contentOffset.x, 844 * 6,
                       "the offset was left in points of the old width, pointing at a discarded page")
        XCTAssertEqual(pager.loadedPageIndices, [5, 6, 7])

        let page = scroll.subviews.compactMap { $0 as? UIScrollView }
            .first { $0.frame.origin.x == 844 * 6 }
        XCTAssertNotNil(page, "no page view exists at the offset the user is looking at")
    }

    func testARepeatedLayoutPassAtTheSameWidthDoesNotYankTheUserBack() {
        let pager = makePager(count: 20, start: 0, width: 390, height: 844)
        guard let scroll = pagingScrollView(of: pager) else { return XCTFail("no paging scroll view") }

        // Exactly what a swipe does: move the offset, which drives the delegate.
        scroll.contentOffset = CGPoint(x: 390 * 11, y: 0)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()

        XCTAssertEqual(scroll.contentOffset.x, 390 * 11)
        XCTAssertEqual(pager.loadedPageIndices, [10, 11, 12])
    }

    // MARK: - What the cache budget counts

    func testTheCacheCostIsTheDecodedBitmapNotTheDownload() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        guard let cg = image.cgImage else { return XCTFail("expected a CGImage-backed image") }

        XCTAssertEqual(ImageLoader.memoryCost(of: image), cg.bytesPerRow * cg.height)

        guard let jpeg = image.jpegData(compressionQuality: 0.6) else { return XCTFail("no JPEG data") }
        XCTAssertGreaterThan(ImageLoader.memoryCost(of: image), jpeg.count,
                             "costing the download is what let the 64 MB budget hold hundreds of megabytes")
    }

    /// An animated image has no single `cgImage`, and it is exactly the entry
    /// that holds every frame decoded — it must never be charged zero.
    func testAnAnimatedImageIsStillCharged() {
        guard let gif = UIImage.imageWithGIFData(animatedGIFData(frames: 3, side: 64)) else {
            return XCTFail("could not build an animated GIF")
        }
        XCTAssertNotNil(gif.images)
        XCTAssertGreaterThan(ImageLoader.memoryCost(of: gif), 0)
    }

    // MARK: - Animated GIFs

    /// A real multi-frame GIF, built with ImageIO so no network or asset is needed.
    private func animatedGIFData(frames: Int, side: Int) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames, nil) else {
            XCTFail("could not create a GIF destination")
            return Data()
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        for index in 0..<frames {
            let frame = renderer.image { context in
                (index % 2 == 0 ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
            guard let cg = frame.cgImage else { continue }
            CGImageDestinationAddImage(destination, cg,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func gifDataURI(frames: Int = 3) -> String {
        return "data:image/gif;base64," + animatedGIFData(frames: frames, side: 32).base64EncodedString()
    }

    private func load(_ urlString: String, maxPixel: CGFloat, animated: Bool) -> UIImage? {
        var result: UIImage?
        let done = expectation(description: "load animated=\(animated)")
        ImageLoader.shared.loadImage(urlString: urlString, maxPixel: maxPixel, animated: animated) { image in
            result = image
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
        return result
    }

    func testOptingInDecodesEveryFrameWhileTheDefaultStaysOnOne() {
        let uri = gifDataURI(frames: 3)

        let animated = load(uri, maxPixel: 512, animated: true)
        XCTAssertEqual(animated?.images?.count, 3, "the GIF that plays in the request detail is frozen here")

        // Same URL, same size: the static entry must not be served the animated
        // one out of the cache, or a grid cell would hold every frame decoded.
        let still = load(uri, maxPixel: 512, animated: false)
        XCTAssertNil(still?.images, "a grid thumbnail must stay a single downsampled frame")
    }

    func testAFullScreenPageAsksForTheAnimatedDecode() {
        let uri = gifDataURI(frames: 3)
        // Warm the cache with exactly the key the pager asks for, so the page's
        // load completes synchronously and the test needs no timing.
        let maxPixel = MediaPagerViewController.pageMaxPixel(forScreenSize: UIScreen.main.bounds.size,
                                                             scale: UIScreen.main.scale)
        XCTAssertEqual(load(uri, maxPixel: maxPixel, animated: true)?.images?.count, 3)

        let pager = MediaPagerViewController(imageURLs: [uri], startIndex: 0)
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()

        let imageViews = pagingScrollView(of: pager)?.subviews
            .compactMap { $0 as? UIScrollView }
            .flatMap { $0.subviews.compactMap { $0 as? UIImageView } } ?? []
        XCTAssertEqual(imageViews.count, 1)
        XCTAssertEqual(imageViews.first?.image?.images?.count, 3,
                       "the pager asked for a static decode, so the page shows a motionless first frame")
    }
}
