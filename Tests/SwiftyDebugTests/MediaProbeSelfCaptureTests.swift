//
//  MediaProbeSelfCaptureTests.swift
//  SwiftyDebugTests
//
//  The media detail screen probes the asset itself to discover byte size, pixel
//  dimensions and the sniffed MIME type. That probe is SwiftyDebug's own
//  traffic, and it must never be captured as if the host app had made it.
//
//  `MediaAssetProbe` builds its session with `config.protocolClasses = []` and a
//  comment saying the probe "deliberately excludes CustomHTTPProtocol". That is
//  not true on its own: the SDK swizzles the `protocolClasses` GETTER, so every
//  read of a configuration re-inserts CustomHTTPProtocol regardless of what was
//  assigned. `ImageLoader` knows this and marks its requests with the
//  recursive-request flag, which is the only thing that makes `canInit` bail.
//
//  The probe did not. Consequences:
//    * opening a media detail screen appended a phantom request to the network
//      list, attributed to the host app, that the host app never made;
//    * that capture posts `.networkRequestCompleted`, which reloads the Media
//      tab — the same shape as the media request loop that was fixed before.
//
//  These tests run the REAL probe against a closed local port (fast, refused)
//  and read the REAL capture store.
//

import XCTest
@testable import SwiftyDebug

final class MediaProbeSelfCaptureTests: XCTestCase {

    // A port nothing listens on: the connection is refused immediately, so the
    // request completes fast — and a failed request is captured exactly like a
    // successful one (`stopLoading` records status "0").
    private static let deadPort = 9

    private var savedMonitorAllUrls = false
    private var savedMonitorMedia = false
    private var savedPersistedAllRequests = false
    private var savedPersistedMedia = false
    private var savedUrls: [String] = []
    private var savedNetworkEnabled = false
    private var savedRuntimeActive = true

    override func setUp() {
        super.setUp()

        savedPersistedAllRequests = Settings.shared.monitorAllRequests
        savedPersistedMedia = Settings.shared.monitorMediaEnabled
        savedMonitorAllUrls = SwiftyDebug.monitorAllUrls
        savedMonitorMedia = SwiftyDebug.monitorMedia
        savedUrls = SwiftyDebug.urls
        savedNetworkEnabled = NetworkMonitor.shared.isNetworkEnable
        savedRuntimeActive = SwiftyDebugRuntime.isActive

        // The exact configuration a user browsing the Media tab is in: capture
        // is live, and media is not filtered out of `canInit`.
        CustomHTTPProtocol.swizzleSessionConfiguration()
        SwiftyDebugRuntime.markActive()
        NetworkMonitor.shared.isNetworkEnable = true
        SwiftyDebug.urls = []
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.monitorMedia = true
    }

    override func tearDown() {
        SwiftyDebug.monitorAllUrls = savedMonitorAllUrls
        SwiftyDebug.monitorMedia = savedMonitorMedia
        SwiftyDebug.urls = savedUrls
        Settings.shared.monitorAllRequests = savedPersistedAllRequests
        Settings.shared.monitorMediaEnabled = savedPersistedMedia
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        if savedRuntimeActive {
            SwiftyDebugRuntime.markActive()
        } else {
            SwiftyDebugRuntime.markStopped()
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// A URL nothing else in the suite can have touched, so the probe's own
    /// static memo cache cannot answer for it.
    private func uniqueAssetURL() -> String {
        return "http://127.0.0.1:\(Self.deadPort)/swiftydebug-probe-\(UUID().uuidString).png"
    }

    /// Everything the capture store holds for `urlString`, read the same way the
    /// network screen reads it.
    private func capturedTransactions(for urlString: String) -> [NetworkTransaction] {
        return NetworkRequestStore.shared.snapshot().filter {
            $0.url?.absoluteString == urlString
        }
    }

    /// Waits until `urlString` shows up in the store, or `timeout` elapses.
    /// Returns whether it showed up. Polls because `stopLoading` lands the
    /// transaction on the protocol's own thread, slightly after the caller's
    /// completion handler runs.
    @discardableResult
    private func waitForCapture(of urlString: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !capturedTransactions(for: urlString).isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !capturedTransactions(for: urlString).isEmpty
    }

    private func dropFromStore(_ urlString: String) {
        for model in capturedTransactions(for: urlString) {
            NetworkRequestStore.shared.remove(model)
        }
    }

    // MARK: - The mechanism, proven before anything else is asserted

    /// If this fails, the two capture assertions below prove nothing — so it is
    /// asserted explicitly rather than assumed.
    func testProtocolClassesGetterReInsertsSwiftyDebugIntoAnEmptiedConfiguration() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []

        let classes = config.protocolClasses ?? []
        XCTAssertTrue(classes.contains { $0 == CustomHTTPProtocol.self },
                      "`config.protocolClasses = []` does NOT keep SwiftyDebug out of a "
                      + "session — the swizzled getter re-inserts it. Any internal fetch "
                      + "that relies on the empty assignment alone is captured.")
    }

    /// Positive control: a request shaped exactly like the probe's used to be —
    /// same session settings, no recursive flag — IS captured. This is the
    /// defect being reproduced, and it is what makes the next test meaningful.
    func testAProbeShapedRequestWithoutTheRecursiveFlagIsCaptured() {
        let urlString = uniqueAssetURL()
        addTeardownBlock { self.dropFromStore(urlString) }

        // Byte-for-byte the session `MediaAssetProbe` builds.
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.protocolClasses = []
        let session = URLSession(configuration: config)

        var request = URLRequest(url: URL(string: urlString)!)
        request.timeoutInterval = 20

        let done = expectation(description: "unflagged probe-shaped request finished")
        session.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 30)

        XCTAssertTrue(waitForCapture(of: urlString, timeout: 5),
                      "Control failed: a probe-shaped request with no recursive-request "
                      + "flag was NOT captured, so this test cannot detect the defect. "
                      + "Check that capture is live in this environment.")
    }

    /// The real probe, called exactly as `MediaDetailViewController.loadProbe`
    /// calls it, must not land in the capture store.
    func testMediaAssetProbeIsNotCapturedAsAHostAppRequest() {
        let urlString = uniqueAssetURL()
        addTeardownBlock { self.dropFromStore(urlString) }

        let done = expectation(description: "probe finished")
        MediaAssetProbe.probe(urlString: urlString, transaction: nil) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        // Give a capture the same window the control test gets. If nothing shows
        // up in it, nothing is going to.
        let captured = waitForCapture(of: urlString, timeout: 5)
        XCTAssertFalse(captured,
                       "The media detail screen's own asset probe was captured as a host "
                       + "app request. `config.protocolClasses = []` is not enough — the "
                       + "probe request must carry "
                       + "`CustomHTTPProtocol.recursiveRequestFlagProperty`, the way "
                       + "ImageLoader's does, or every media detail screen appends a "
                       + "phantom request and re-triggers the media reload loop.")
    }

    // MARK: - Adjacent behaviour that must not move

    /// The media detail screen still builds, and its OVERVIEW rows still come
    /// out of the probe. A probe that stopped answering would leave the screen
    /// with no DIMENSIONS / SIZE / MIME TYPE.
    func testMediaDetailScreenStillLoadsAndShowsProbedMetadata() {
        let item = MediaItem(urlString: Self.onePixelGIF)
        let vc = MediaDetailViewController(item: item)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = SwiftyDebugNavigationController(rootViewController: vc)
        win.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()

        // The probe answers on the main queue; give it a turn.
        let settled = expectation(description: "detail screen settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        vc.view.layoutIfNeeded()

        let labels = allLabels(in: vc.view).compactMap { $0.text }
        XCTAssertTrue(labels.contains("DIMENSIONS"),
                      "The media detail screen lost its probed DIMENSIONS row.")
        XCTAssertTrue(labels.contains { $0.contains("1 × 1 px") },
                      "The media detail screen shows no pixel size for a probed asset.")
        win.isHidden = true
    }

    /// Tapping the preview still opens the full-screen pager, positioned on this
    /// item and holding a live page window around it — "opens and pages".
    func testTappingThePreviewStillOpensTheFullScreenPager() {
        let items = (0..<4).map { _ in MediaItem(urlString: Self.onePixelGIF) }
        let vc = MediaDetailViewController(items: items, startIndex: 2)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = vc
        win.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()

        vc.perform(NSSelectorFromString("openFullscreen"))

        let presented = expectation(description: "pager presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { presented.fulfill() }
        wait(for: [presented], timeout: 5)

        guard let pager = vc.presentedViewController as? MediaPagerViewController else {
            win.isHidden = true
            return XCTFail("Tapping the media preview no longer opens the full-screen pager.")
        }
        pager.view.layoutIfNeeded()
        XCTAssertEqual(pager.loadedPageIndices,
                       MediaPagerViewController.windowedIndices(around: 2, count: 4),
                       "The pager opened on the wrong item, or stopped building the "
                       + "neighbouring pages a swipe lands on.")
        win.isHidden = true
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for sub in view.subviews { found += allLabels(in: sub) }
        return found
    }

    /// 1x1 transparent GIF — probed and decoded entirely in-process.
    private static let onePixelGIF =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    /// The probe still answers — a fix that silences the capture by refusing to
    /// fetch would break the DIMENSIONS / SIZE / MIME TYPE rows.
    func testProbeStillReportsMetadataForAnInlineDataURI() {
        let gif = Self.onePixelGIF

        let done = expectation(description: "data: probe finished")
        var result: MediaAssetProbe.Result?
        MediaAssetProbe.probe(urlString: gif, transaction: nil) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(result?.pixelSize, CGSize(width: 1, height: 1),
                       "The probe stopped reporting pixel dimensions.")
        XCTAssertEqual(result?.mimeType, "image/gif",
                       "The probe stopped sniffing the MIME type.")
        XCTAssertNotNil(result?.byteCount,
                        "The probe stopped reporting the byte count.")
    }
}
