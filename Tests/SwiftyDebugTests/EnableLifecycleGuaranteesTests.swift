//
//  EnableLifecycleGuaranteesTests.swift
//  SwiftyDebugTests
//
//  Two guarantees `SwiftyDebug.enable()` has to keep, both of which it used to
//  break:
//
//  1. Calling `enable()` a second time must not destroy what the first one
//     captured. `enable()` ran `NetworkTransaction.clearDiskCache()` every time,
//     so a re-entrant setup or a second scene wiped every captured body off disk
//     while the matching rows stayed in the list — every request in the UI
//     rendered empty, with no explanation.
//
//  2. `enable()` must clear the `fullStop()` kill switch. It never called
//     `SwiftyDebugRuntime.markActive()`, and the only other caller is
//     `resumeFromFullStop()` (reachable from the shake gesture, not from the
//     public API). After a full stop, `SwiftyDebug.enable()` returned a fully
//     navigable UI that captured nothing.
//

import XCTest
@testable import SwiftyDebug

final class EnableLifecycleGuaranteesTests: XCTestCase {

    private var savedMonitorAllUrls = false
    private var savedNetworkEnabled = false
    private var savedRuntimeActive = true

    override func setUp() {
        super.setUp()
        savedMonitorAllUrls = SwiftyDebug.monitorAllUrls
        savedNetworkEnabled = NetworkMonitor.shared.isNetworkEnable
        savedRuntimeActive = SwiftyDebugRuntime.isActive
    }

    override func tearDown() {
        SwiftyDebug.monitorAllUrls = savedMonitorAllUrls
        NetworkMonitor.shared.isNetworkEnable = savedNetworkEnabled
        if savedRuntimeActive {
            SwiftyDebugRuntime.markActive()
        } else {
            SwiftyDebugRuntime.markStopped()
        }
        super.tearDown()
    }

    // MARK: - The previous-session sweep runs once per process

    func testPreviousSessionSweepRunsAtMostOncePerProcess() {
        var runs = 0

        // Consume the one-shot gate if it is still armed. Whether it fires here
        // depends on test ordering, so the assertion below is relative — what
        // matters is that no LATER call ever sweeps again.
        SwiftyDebug.sweepPreviousSessionBodiesIfNeeded { runs += 1 }
        XCTAssertTrue(SwiftyDebug.didSweepPreviousSessionBodies,
                      "The sweep must record that it has run, or the guard cannot hold.")

        let runsAfterFirstCall = runs

        for _ in 0..<5 {
            SwiftyDebug.sweepPreviousSessionBodiesIfNeeded { runs += 1 }
        }

        XCTAssertEqual(runs, runsAfterFirstCall,
                       "Every enable() after the first re-swept the previous-session cache, "
                       + "deleting bodies captured since the first enable().")
        XCTAssertLessThanOrEqual(runs, 1,
                                 "The sweep is a startup concern and must run at most once per process.")
    }

    func testASecondEnableDoesNotDeleteBodiesCapturedByTheFirst() throws {
        // Disarm the gate with a no-op so the real disk sweep never runs inside
        // the test process (it would delete other suites' captured bodies).
        SwiftyDebug.sweepPreviousSessionBodiesIfNeeded { }

        let directory = NetworkTransaction.diskCacheDirectory()
        let path = (directory as NSString)
            .appendingPathComponent("EnableLifecycleGuaranteesTests-\(UUID().uuidString).body")
        let body = Data("captured after the first enable()".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: body),
                      "Precondition: the disk cache directory is writable.")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A second enable() — the real path, default sweep and all.
        SwiftyDebug.sweepPreviousSessionBodiesIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "A second enable() deleted a body captured during the session. "
                      + "The row would stay in the list showing an empty response.")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), body)
    }

    // MARK: - enable() reverses the kill switch

    func testEnableClearsTheFullStopKillSwitch() {
        NetworkMonitor.shared.isNetworkEnable = true
        SwiftyDebug.monitorAllUrls = true
        let request = URLRequest(url: URL(string: "https://api.example.com/v1/me")!)

        SwiftyDebugRuntime.markStopped()
        XCTAssertFalse(CustomHTTPProtocol.canInit(with: request),
                       "Precondition: a fully stopped SDK intercepts nothing.")

        // The first statement of `enable()`.
        SwiftyDebug.activateRuntimeForEnable()

        XCTAssertTrue(SwiftyDebugRuntime.isActive)
        XCTAssertTrue(CustomHTTPProtocol.canInit(with: request),
                      "SwiftyDebug.enable() after a full stop must resume capture. Without "
                      + "this, the only way back was the shake gesture — the public API "
                      + "could not undo its own kill switch.")
    }

    func testEnableAlsoUngatesLogCaptureAfterAFullStop() {
        // `NSLogHook.enableIfNeeded()` returns immediately while the gate is
        // closed, so the ordering inside enable() matters as much as the call:
        // the gate has to be open before any of the enable steps run.
        SwiftyDebugRuntime.markStopped()
        XCTAssertFalse(SwiftyDebugRuntime.isActive)

        SwiftyDebug.activateRuntimeForEnable()

        XCTAssertTrue(SwiftyDebugRuntime.isActive,
                      "Log capture, web-view capture and network capture are all gated on "
                      + "this flag; enable() must open it before it does anything else.")
    }
}
