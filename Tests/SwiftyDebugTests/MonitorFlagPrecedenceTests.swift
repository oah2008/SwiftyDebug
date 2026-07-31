//
//  MonitorFlagPrecedenceTests.swift
//  SwiftyDebugTests
//
//  Pins the documented configure-then-enable contract:
//
//      SwiftyDebug.monitorAllUrls = true
//      SwiftyDebug.enable()
//
//  `enable()` used to overwrite `monitorAllUrls` and `monitorMedia` from the
//  persisted App-tab toggles AFTER the host app had assigned them. On a fresh
//  install both persisted values are `false`, so nothing looked wrong — but from
//  the second launch onward the host app's assignment was silently discarded and
//  the README quick start and the demo app captured nothing they asked for.
//
//  These tests exercise `applyMonitorFlags(from:)`, which is the reconciliation
//  `enable()` performs, and then the user-visible consequence through
//  `CustomHTTPProtocol.canInit(with:)` — the code that actually decides whether a
//  request is captured.
//

import XCTest
@testable import SwiftyDebug

final class MonitorFlagPrecedenceTests: XCTestCase {

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
    }

    override func tearDown() {
        // Settings first: its `didSet` writes through to the SwiftyDebug flags,
        // so restoring it afterwards would clobber them again.
        Settings.shared.monitorAllRequests = savedPersistedAllRequests
        Settings.shared.monitorMediaEnabled = savedPersistedMedia
        SwiftyDebug.monitorAllUrls = savedMonitorAllUrls
        SwiftyDebug.monitorMedia = savedMonitorMedia
        SwiftyDebug.urls = savedUrls
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        if savedRuntimeActive {
            SwiftyDebugRuntime.markActive()
        } else {
            SwiftyDebugRuntime.markStopped()
        }
        super.tearDown()
    }

    // MARK: - Host assignment wins

    func testHostMonitorAllUrlsSurvivesAPersistedOffToggle() {
        Settings.shared.monitorAllRequests = false   // previous launch left it OFF
        SwiftyDebug.monitorAllUrls = true            // host app, before enable()

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(SwiftyDebug.monitorAllUrls,
                      "enable() discarded the host app's `monitorAllUrls = true` and "
                      + "restored last launch's OFF toggle — the documented quick start "
                      + "would capture nothing from the second launch onward.")
    }

    func testHostMonitorMediaSurvivesAPersistedOffToggle() {
        Settings.shared.monitorMediaEnabled = false
        SwiftyDebug.monitorMedia = true

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(SwiftyDebug.monitorMedia,
                      "enable() discarded the host app's `monitorMedia = true`.")
    }

    func testHostAssignmentIsWrittenBackSoTheAppTabTogglesAgree() {
        Settings.shared.monitorAllRequests = false
        Settings.shared.monitorMediaEnabled = false
        SwiftyDebug.monitorAllUrls = true
        SwiftyDebug.monitorMedia = true

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(Settings.shared.monitorAllRequests,
                      "The App tab would show an OFF switch sitting over a live capture.")
        XCTAssertTrue(Settings.shared.monitorMediaEnabled,
                      "The App tab would show an OFF switch sitting over a live capture.")
    }

    // MARK: - Persisted toggle still decides when the host says nothing

    func testPersistedMonitorAllRequestsToggleSurvivesWhenTheHostLeavesTheDefault() {
        // `didSet` writes through, so re-assert the "host never touched it" state
        // afterwards — that is exactly the situation at enable() time.
        Settings.shared.monitorAllRequests = true
        SwiftyDebug.monitorAllUrls = false

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(SwiftyDebug.monitorAllUrls,
                      "A toggle switched on from the App tab must still be on after a "
                      + "relaunch of a host app that never assigns the flag.")
    }

    func testPersistedMonitorMediaToggleSurvivesWhenTheHostLeavesTheDefault() {
        Settings.shared.monitorMediaEnabled = true
        SwiftyDebug.monitorMedia = false

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(SwiftyDebug.monitorMedia,
                      "A toggle switched on from the App tab must still be on after a relaunch.")
    }

    func testEverythingOffStaysOff() {
        Settings.shared.monitorAllRequests = false
        Settings.shared.monitorMediaEnabled = false
        SwiftyDebug.monitorAllUrls = false
        SwiftyDebug.monitorMedia = false

        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertFalse(SwiftyDebug.monitorAllUrls)
        XCTAssertFalse(SwiftyDebug.monitorMedia)
        XCTAssertFalse(Settings.shared.monitorAllRequests)
        XCTAssertFalse(Settings.shared.monitorMediaEnabled)
    }

    // MARK: - The consequence that is actually visible to a user

    func testHostMonitorMediaBeforeEnableActuallyCapturesMedia() {
        SwiftyDebugRuntime.markActive()
        NetworkMonitor.shared.isNetworkEnable = true
        SwiftyDebug.urls = []

        let sprite = URLRequest(url: URL(string: "https://cdn.example.com/pokemon/25.png")!)

        Settings.shared.monitorMediaEnabled = false
        SwiftyDebug.monitorMedia = false
        XCTAssertFalse(CustomHTTPProtocol.canInit(with: sprite),
                       "Precondition: a .png is skipped while monitorMedia is off.")

        // Previous launch left the App-tab toggle OFF; the host app asks for media.
        Settings.shared.monitorMediaEnabled = false
        SwiftyDebug.monitorMedia = true
        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(CustomHTTPProtocol.canInit(with: sprite),
                      "`monitorMedia = true` before enable() must actually capture media; "
                      + "the demo app's Pokemon sprites depend on it.")
    }

    func testHostMonitorAllUrlsBeforeEnableActuallyWidensCaptureBeyondTheUrlFilter() {
        SwiftyDebugRuntime.markActive()
        NetworkMonitor.shared.isNetworkEnable = true
        SwiftyDebug.urls = ["api.allowed.com"]

        let thirdParty = URLRequest(url: URL(string: "https://third-party.example.com/track")!)

        Settings.shared.monitorAllRequests = false
        SwiftyDebug.monitorAllUrls = false
        XCTAssertFalse(CustomHTTPProtocol.canInit(with: thirdParty),
                       "Precondition: a non-matching host is filtered out by `urls`.")

        Settings.shared.monitorAllRequests = false   // previous launch left it OFF
        SwiftyDebug.monitorAllUrls = true            // host app, before enable()
        SwiftyDebug.applyMonitorFlags(from: .shared)

        XCTAssertTrue(CustomHTTPProtocol.canInit(with: thirdParty),
                      "`monitorAllUrls = true` before enable() must actually capture everything.")
    }
}
