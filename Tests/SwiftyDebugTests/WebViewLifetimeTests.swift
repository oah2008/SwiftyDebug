//
//  WebViewLifetimeTests.swift
//  SwiftyDebugTests
//
//  The maintainer reported that SwiftyDebug can keep a host app's WKWebView
//  alive so its `deinit` never runs. That is the worst class of defect this SDK
//  can have: it is the debugger breaking the app it is observing.
//
//  These assert deallocation directly — a weak reference must be nil once the
//  owner is gone. They run in the SIMULATOR; they are not a substitute for an
//  Instruments run on device, but every retain edge they cover is a real one.
//

import XCTest
import WebKit
@testable import SwiftyDebug

final class WebViewLifetimeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SwiftyDebugRuntime.markActive()
    }

    /// Spins the run loop until `isGone()` or the deadline.
    ///
    /// `WKWebView` does not deallocate the instant its last Swift reference
    /// goes: it is autoreleased and its teardown hops through the run loop and
    /// the WebKit IPC machinery. Asserting immediately after an autorelease pool
    /// therefore reports a leak that is not one. This is the only concession the
    /// tests make to timing — the assertion itself is still "it is gone".
    private func waitUntil(_ isGone: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // Spin FIRST: the condition usually depends on a deallocation that has
        // not happened yet at the moment of the call, and for the sweep the
        // condition itself has a side effect, so evaluating it before letting the
        // run loop turn just wastes the first iteration.
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if isGone() { return true }
        } while Date() < deadline
        return isGone()
    }

    // MARK: - The picker must not pin the host's web views

    /// `WebViewStoragePickerViewController` listed the host app's web views in a
    /// STRONG array that nothing ever cleared, so merely opening the Web View
    /// Storage screen pinned every web view in the app — and through the content
    /// controller's registered handlers, usually the host screen's own view
    /// controller too.
    func testThePickerDoesNotRetainTheWebViewsItLists() {
        weak var weakWebView: WKWebView?

        autoreleasepool {
            let webView = WKWebView(frame: .zero)
            weakWebView = webView
            WKWebViewSwizzling.trackedWebViews.add(webView)

            let picker = WebViewStoragePickerViewController()
            picker.loadViewIfNeeded()
            picker.beginAppearanceTransition(true, animated: false)
            picker.endAppearanceTransition()

            XCTAssertEqual(picker.tableView.numberOfRows(inSection: 0), 1,
                           "precondition: the picker listed the web view")
            // The picker is still alive here. If it holds the web view strongly,
            // the weak reference below cannot clear.
            _ = picker.tableView.numberOfRows(inSection: 0)
        }

        XCTAssertTrue(waitUntil { weakWebView == nil },
                      """
                      A web view released by its owner is still alive. The picker \
                      must hold the host app's web views weakly — listing something \
                      must never extend its life.
                      """)
    }

    /// And once the screen is off, it holds nothing at all — which is what makes
    /// a debug UI left presented after `disable()` harmless.
    func testThePickerDropsEverythingWhenItDisappears() {
        let picker = WebViewStoragePickerViewController()
        picker.loadViewIfNeeded()

        weak var weakWebView: WKWebView?
        autoreleasepool {
            let webView = WKWebView(frame: .zero)
            weakWebView = webView
            WKWebViewSwizzling.trackedWebViews.add(webView)

            picker.beginAppearanceTransition(true, animated: false)
            picker.endAppearanceTransition()
            picker.beginAppearanceTransition(false, animated: false)
            picker.endAppearanceTransition()
        }

        XCTAssertTrue(waitUntil { weakWebView == nil })
        XCTAssertEqual(picker.tableView.numberOfRows(inSection: 0), 1,
                       "the empty-state row remains, and indexing it must not crash")
        XCTAssertNoThrow(picker.tableView.dataSource?.tableView(picker.tableView,
                                                                cellForRowAt: IndexPath(row: 0, section: 0)))
    }

    // MARK: - Orphaned instrumentation is collected

    /// Registering a script message handler puts the content controller in
    /// WebKit's own message registry, and that reference outlives the web view
    /// and the configuration. A host app that builds one configuration per screen
    /// therefore accumulated an immortal controller — still carrying the SDK's
    /// injected scripts — for every screen visited.
    func testHandlersAreRemovedOnceNoLiveWebViewUsesTheController() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        autoreleasepool {
            let webView = WKWebView(frame: .zero, configuration: configuration)
            WKWebViewSwizzling.trackedWebViews.add(webView)
            WKWebViewSwizzling.instrumentIfNeeded(controller)
            XCTAssertFalse(controller.swiftyDebugHandlerNames.isEmpty,
                           "precondition: the SDK registered its channels")
            WKWebViewSwizzling.sweepOrphanedInstrumentation()
            XCTAssertFalse(controller.swiftyDebugHandlerNames.isEmpty,
                           "a controller whose web view is ALIVE must keep its handlers")
        }

        XCTAssertTrue(waitUntil {
            WKWebViewSwizzling.sweepOrphanedInstrumentation()
            return controller.swiftyDebugHandlerNames.isEmpty
        }, """
           The SDK's handlers are still registered on a content controller no live \
           web view uses. WebKit keeps the controller — and the SDK's injected \
           scripts — alive for as long as they are.
           """)
    }

    /// A configuration reused for a second web view must be captured again. The
    /// instrumentation flag used to gate handlers and scripts together, so once
    /// handlers were swept they could never come back.
    func testAReusedConfigurationIsInstrumentedAgainAfterASweep() {
        let controller = WKUserContentController()

        autoreleasepool {
            let first = WKWebView(frame: .zero,
                                  configuration: { let c = WKWebViewConfiguration()
                                                   c.userContentController = controller; return c }())
            WKWebViewSwizzling.trackedWebViews.add(first)
            WKWebViewSwizzling.instrumentIfNeeded(controller)
        }
        XCTAssertTrue(waitUntil {
            WKWebViewSwizzling.sweepOrphanedInstrumentation()
            return controller.swiftyDebugHandlerNames.isEmpty
        }, "precondition: swept")

        WKWebViewSwizzling.instrumentIfNeeded(controller)
        XCTAssertFalse(controller.swiftyDebugHandlerNames.isEmpty,
                       "a web view created later from the same configuration must be captured")
    }

    /// The sweep must never touch a name the SDK did not register.
    ///
    /// `swiftyDebugRemoveOwnHandlers()` removes exactly the names recorded in
    /// `swiftyDebugHandlerNames`, so the guarantee is that the app's name never
    /// enters that list — including when the app chose one of the SDK's own.
    func testTheSweepOnlyEverRemovesNamesTheSDKRecorded() {
        final class AppHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
        }
        let controller = WKUserContentController()
        controller.add(AppHandler(), name: "appBridge")
        WKWebViewSwizzling.instrumentIfNeeded(controller)

        let recorded = controller.swiftyDebugHandlerNames
        XCTAssertFalse(recorded.contains("appBridge"),
                       "the app's bridge must never be recorded as the SDK's")
        XCTAssertTrue(recorded.allSatisfy { WebViewMessageChannel.all.contains($0) },
                      "only the SDK's own channels are recorded: \(recorded)")

        WKWebViewSwizzling.sweepOrphanedInstrumentation()
        XCTAssertTrue(controller.swiftyDebugHandlerNames.isEmpty)
    }

    // MARK: - The SDK's own viewer

    /// The viewer is a CHILD view controller, and a child's own
    /// `isMovingFromParent` is false while its PARENT is the thing being popped —
    /// so a pop never tore its web view down and the JS heap holding the whole
    /// body survived until the host happened to deallocate.
    func testTheJSONViewerReleasesItsWebViewWhenItsHostIsPopped() {
        let window = SwiftyDebugWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let nav = SwiftyDebugNavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()

        weak var weakHost: DemoJSONViewerHostController?

        autoreleasepool {
            let host = DemoJSONViewerHostController()
            host.jsonString = "{\"a\":1}"
            weakHost = host
            nav.pushViewController(host, animated: false)
            window.layoutIfNeeded()

            nav.popViewController(animated: false)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(waitUntil { weakHost == nil },
                      "the JSON viewer screen must deallocate when popped")
    }
}
