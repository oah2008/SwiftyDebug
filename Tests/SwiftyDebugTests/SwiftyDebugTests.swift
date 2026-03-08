//
//  SwiftyDebugTests.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import XCTest
@testable import SwiftyDebug

final class SwiftyDebugTests: XCTestCase {

    func testSettingsSharedInstance() {
        let settings = SwiftyDebugSettings.shared
        XCTAssertNotNil(settings)
    }

    func testDefaultMonitorAllUrlsIsFalse() {
        XCTAssertFalse(SwiftyDebug.monitorAllUrls)
    }

    func testDefaultEnableConsoleLogIsTrue() {
        XCTAssertTrue(SwiftyDebug.enableConsoleLog)
    }

    func testUrlsDefaultEmpty() {
        XCTAssertTrue(SwiftyDebug.urls.isEmpty)
    }
}
