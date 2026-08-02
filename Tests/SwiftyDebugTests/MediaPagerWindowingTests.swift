//
//  MediaPagerWindowingTests.swift
//  SwiftyDebugTests
//
//  The full-screen media viewer used to build one page per URL the moment it
//  appeared, and load every one of them with `maxPixel: 0` — ImageLoader's
//  "decode at full resolution". A 12 MP asset is roughly 48 MB decoded, so a
//  gallery of large images asked the host app for hundreds of megabytes at once.
//  Inside somebody else's app that is not a slow screen, it is a jetsam, and the
//  crash report says the app, not the debugger.
//
//  What is pinned down here:
//
//    * only the visible page and its immediate neighbours exist, whatever the
//      size of the gallery,
//    * the window follows the user and releases what is behind them, and
//    * pages are never decoded at full resolution again (`maxPixel` is never 0).
//

import XCTest
@testable import SwiftyDebug

final class MediaPagerWindowingTests: XCTestCase {

    private let pageWidth: CGFloat = 390
    private let pageHeight: CGFloat = 844

    /// Offline "images": a data URI whose payload is not valid base64, so
    /// ImageLoader decodes nothing and never touches the network.
    private func urls(_ count: Int) -> [String] {
        (0..<count).map { "data:image/png;base64,not-a-real-image-\($0)" }
    }

    private func makePager(count: Int, start: Int) -> MediaPagerViewController {
        let pager = MediaPagerViewController(imageURLs: urls(count), startIndex: start)
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        return pager
    }

    /// The paging scroll view is the only scroll view the controller adds
    /// directly to its own view (the others are its children).
    private func pagingScrollView(of pager: MediaPagerViewController) -> UIScrollView? {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    /// Pages living in the hierarchy. Counted by type, because a `UIScrollView`
    /// also keeps its scroll indicators in `subviews`.
    private func livePageViews(in scroll: UIScrollView) -> [UIScrollView] {
        scroll.subviews.compactMap { $0 as? UIScrollView }
    }

    // MARK: - The window itself

    func testTheWindowIsTheCurrentPageAndItsTwoNeighbours() {
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 10, count: 200), [9, 10, 11])
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 1, count: 3), [0, 1, 2])
    }

    func testTheWindowIsClampedAtBothEnds() {
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 0, count: 200), [0, 1])
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 199, count: 200), [198, 199])
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 999, count: 200), [198, 199],
                       "an out-of-range index must clamp, not reach past the end")
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: -5, count: 200), [0, 1])
    }

    func testDegenerateGalleriesProduceNoImpossiblePages() {
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 0, count: 0), [])
        XCTAssertEqual(MediaPagerViewController.windowedIndices(around: 0, count: 1), [0])
    }

    // MARK: - Decode size

    func testAPageIsNeverDecodedAtFullResolution() {
        // 0 is ImageLoader's "full size" sentinel — the value this replaced.
        let phone = MediaPagerViewController.pageMaxPixel(forScreenSize: CGSize(width: 393, height: 852),
                                                          scale: 3)
        XCTAssertEqual(phone, 2556)
        XCTAssertGreaterThan(phone, 0)

        let pad = MediaPagerViewController.pageMaxPixel(forScreenSize: CGSize(width: 1024, height: 1366),
                                                        scale: 2)
        XCTAssertEqual(pad, 2732)

        // Degenerate geometry (a controller laid out before it has bounds) must
        // still ask for a downsample, never for the full-resolution bitmap.
        XCTAssertGreaterThan(MediaPagerViewController.pageMaxPixel(forScreenSize: .zero, scale: 0), 0)
        XCTAssertEqual(MediaPagerViewController.pageMaxPixel(forScreenSize: .zero, scale: 3), 640)
    }

    // MARK: - What actually gets built

    func testALargeGalleryBuildsOnlyTheWindow() {
        let pager = makePager(count: 200, start: 0)
        XCTAssertEqual(pager.loadedPageIndices, [0, 1],
                       "every page was built up front — this is the out-of-memory bug")
        XCTAssertEqual(pagingScrollView(of: pager).map { livePageViews(in: $0).count }, 2,
                       "a page that is not in the window must not be in the hierarchy either")
    }

    func testOpeningInTheMiddleBuildsTheMiddleAndNotEverythingBeforeIt() {
        let pager = makePager(count: 200, start: 100)
        XCTAssertEqual(pager.loadedPageIndices, [99, 100, 101])
    }

    func testTheWindowFollowsTheUserAndReleasesWhatIsBehindThem() {
        let pager = makePager(count: 200, start: 0)
        guard let scroll = pagingScrollView(of: pager) else {
            return XCTFail("no paging scroll view")
        }

        // Exactly what a swipe does: move the offset, which drives the delegate.
        scroll.contentOffset = CGPoint(x: pageWidth * 100, y: 0)
        XCTAssertEqual(pager.loadedPageIndices, [99, 100, 101])
        XCTAssertEqual(livePageViews(in: scroll).count, 3,
                       "pages left behind must be released, not accumulated")

        scroll.contentOffset = CGPoint(x: pageWidth * 199, y: 0)
        XCTAssertEqual(pager.loadedPageIndices, [198, 199])
        XCTAssertEqual(livePageViews(in: scroll).count, 2)

        scroll.contentOffset = .zero
        XCTAssertEqual(pager.loadedPageIndices, [0, 1])
        XCTAssertEqual(livePageViews(in: scroll).count, 2)
    }

    /// The pager still has to be a pager: full width per page, all of them
    /// reachable, even though only three exist at a time.
    func testEveryPageIsStillReachableEvenThoughOnlyThreeExist() {
        let pager = makePager(count: 50, start: 0)
        guard let scroll = pagingScrollView(of: pager) else {
            return XCTFail("no paging scroll view")
        }
        XCTAssertEqual(scroll.contentSize.width, pageWidth * 50)
        XCTAssertTrue(scroll.isPagingEnabled)

        for index in stride(from: 0, to: 50, by: 7) {
            scroll.contentOffset = CGPoint(x: pageWidth * CGFloat(index), y: 0)
            XCTAssertTrue(pager.loadedPageIndices.contains(index),
                          "page \(index) was scrolled to but never built")
        }
    }
}
