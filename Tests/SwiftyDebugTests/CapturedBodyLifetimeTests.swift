//
//  CapturedBodyLifetimeTests.swift
//  SwiftyDebugTests
//
//  A captured response body lives in a file under Caches. The RESPONSE section in
//  the detail screen is dropped when its content is empty — correct for a genuinely
//  empty body, catastrophic when the body existed and its file was deleted behind
//  the model's back.
//
//  That is what happened: `NetworkRequestStore`'s LAZY singleton init wiped the whole
//  body directory, and the first captured request of a session is what triggered that
//  init — 55 lines after it had written its own body file. It presented as "the
//  response section did not render... does not happen all the time".
//

import XCTest
@testable import SwiftyDebug

final class CapturedBodyLifetimeTests: XCTestCase {

    private func makeTransaction(body: String) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = NSURL(string: "https://api.example.com/v1/orders")
        model.responseData = Data(body.utf8)
        return model
    }

    // MARK: - The reported bug

    func testCapturedBodySurvivesTouchingTheStore() {
        // The exact sequence from CustomHTTPProtocol.stopLoading: write the body,
        // then hand the model to the store. Touching the store must not destroy
        // what was just written.
        let model = makeTransaction(body: #"{"data":{"url":"https://google.com/a"}}"#)
        XCTAssertNotNil(model.responseData, "precondition: the body was written")

        _ = NetworkRequestStore.shared

        XCTAssertNotNil(model.responseData,
                        "Initializing the store deleted a body captured before it — this is the "
                        + "missing RESPONSE section bug")
        XCTAssertEqual(String(data: model.responseData ?? Data(), encoding: .utf8),
                       #"{"data":{"url":"https://google.com/a"}}"#)
    }

    func testSizeAndReadabilityNeverDisagree() {
        // `responseDataSize > 0` while `responseData == nil` is the signature of a
        // body that was claimed but cannot be produced. The UI has no way to tell
        // that apart from "there was no response".
        let model = makeTransaction(body: "hello world")
        XCTAssertGreaterThan(model.responseDataSize, 0)
        XCTAssertNotNil(model.responseData)

        _ = NetworkRequestStore.shared

        if model.responseDataSize > 0 {
            XCTAssertNotNil(model.responseData,
                            "A model reporting \(model.responseDataSize) bytes must be able to "
                            + "produce them")
        }
    }

    func testEmptyBodyStoresNothingAndClaimsNothing() {
        // Hiding the section for a genuinely empty body is intended behaviour, so
        // the model must be honest about it rather than claiming phantom bytes.
        let model = NetworkTransaction()
        model.responseData = Data()
        XCTAssertNil(model.responseData)
        XCTAssertEqual(model.responseDataSize, 0)
    }

    // MARK: - Independent lifetimes

    func testOneTransactionsBodyOutlivesAnothersDeallocation() {
        // `NetworkTransaction.deinit` deletes its own files. Each model must own a
        // distinct file, or one dying takes another's body with it.
        let survivor = makeTransaction(body: "survivor payload")
        autoreleasepool {
            let doomed = makeTransaction(body: "doomed payload")
            XCTAssertNotNil(doomed.responseData)
        }
        XCTAssertEqual(String(data: survivor.responseData ?? Data(), encoding: .utf8),
                       "survivor payload",
                       "Deallocating one transaction deleted another's body file")
    }

    func testReplacingABodyDoesNotStrandTheOldFile() {
        let model = makeTransaction(body: "first")
        model.responseData = Data("second".utf8)
        XCTAssertEqual(String(data: model.responseData ?? Data(), encoding: .utf8), "second")
        XCTAssertEqual(model.responseDataSize, UInt("second".utf8.count))
    }

    func testRequestAndResponseBodiesAreIndependent() {
        let model = NetworkTransaction()
        model.requestData = Data("the request".utf8)
        model.responseData = Data("the response".utf8)
        XCTAssertEqual(String(data: model.requestData ?? Data(), encoding: .utf8), "the request")
        XCTAssertEqual(String(data: model.responseData ?? Data(), encoding: .utf8), "the response")
    }
}
