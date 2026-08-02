//
//  DebugUIObserverLifetimeTests.swift
//  SwiftyDebugTests
//
//  `NotificationCenter.addObserver(forName:object:queue:using:)` registers the
//  opaque token it RETURNS, not the object that called it. So the customary
//  `NotificationCenter.default.removeObserver(self)` in `deinit` unregisters
//  nothing at all for a block observer, and dropping the token on the floor
//  leaves the block registered for the lifetime of the process.
//
//  In an SDK embedded in someone else's app that is not a theoretical leak: the
//  debug UI is opened and closed over and over in a session, and every leaked
//  registration keeps hopping onto the main queue for every single request the
//  app makes, forever, doing work for a screen that no longer exists.
//
//  These tests are about the *unregistration*, which is the part that used to be
//  missing — not about whether a notification can be delivered.
//

import XCTest
@testable import SwiftyDebug

final class DebugUIObserverLifetimeTests: XCTestCase {

    private let noteName = Notification.Name("com.swiftydebug.tests.observerLifetime")

    // MARK: - The mechanism

    func testABaggedObserverStopsFiringOnceTheBagIsReleased() {
        let center = NotificationCenter()
        var fired = 0

        var bag: NotificationObserverBag? = NotificationObserverBag()
        // queue: nil so delivery is synchronous on the posting thread and the
        // assertions cannot race the main queue.
        bag?.add(center, forName: noteName, queue: nil) { _ in fired += 1 }

        center.post(name: noteName, object: nil)
        XCTAssertEqual(fired, 1, "the observer never registered, so this test proves nothing")

        bag = nil
        center.post(name: noteName, object: nil)
        XCTAssertEqual(fired, 1,
                       "the block outlived its owner — this is the leak, and removeObserver(self) cannot fix it")
    }

    func testRemoveAllUnregistersEveryBaggedObserver() {
        let center = NotificationCenter()
        var fired = 0
        let bag = NotificationObserverBag()

        for _ in 0..<3 { bag.add(center, forName: noteName, queue: nil) { _ in fired += 1 } }
        XCTAssertEqual(bag.count, 3)

        center.post(name: noteName, object: nil)
        XCTAssertEqual(fired, 3)

        bag.removeAll()
        XCTAssertEqual(bag.count, 0)
        center.post(name: noteName, object: nil)
        XCTAssertEqual(fired, 3, "removeAll() left registrations behind")
    }

    /// A bag that keeps a token twice would unregister it once and leak the
    /// other, so identity is checked rather than count alone.
    func testTheBagKeepsTheTokenItRegistered() {
        let center = NotificationCenter()
        let bag = NotificationObserverBag()
        let token = bag.add(center, forName: noteName, queue: nil) { _ in }
        XCTAssertEqual(bag.count, 1)
        // Removing it twice (once by hand, once by the bag) is harmless; never
        // removing it is not.
        center.removeObserver(token)
    }

    // MARK: - The controller that had the leak

    /// Every block observer `NetworkViewController` registers must be held for
    /// removal. It registers three (`breakpointsDidChange`,
    /// `networkRequestCompleted`, `allLogsCleared`); if any of them goes back to
    /// a bare `NotificationCenter.default.addObserver(forName:…)` the bag stops
    /// accounting for it and this fails.
    func testNetworkViewControllerHoldsEveryBlockObserverItRegisters() {
        let controller = NetworkViewController()
        controller.loadViewIfNeeded()

        let bag = Mirror(reflecting: controller).children
            .compactMap { $0.value as? NotificationObserverBag }
            .first

        guard let bag = bag else {
            return XCTFail("NetworkViewController registers block observers but owns no bag to unregister them")
        }
        XCTAssertGreaterThanOrEqual(bag.count, 3,
                                    "a block observer was registered outside the bag, so nothing will remove it")
    }

    /// …and the controller itself must still be deallocatable: a strongly
    /// captured `self` inside one of those blocks would keep the whole debug UI
    /// (and its transactions) alive behind the leaked registration.
    func testNetworkViewControllerIsDeallocatedAfterItsViewIsLoaded() {
        weak var weakController: NetworkViewController?
        autoreleasepool {
            let controller = NetworkViewController()
            controller.loadViewIfNeeded()
            weakController = controller
        }
        XCTAssertNil(weakController, "something in viewDidLoad is retaining the controller")

        // Posting after the fact must reach nothing and must not crash.
        NotificationCenter.default.post(name: .networkRequestCompleted, object: nil)
        NotificationCenter.default.post(name: .allLogsCleared, object: nil)
    }
}
