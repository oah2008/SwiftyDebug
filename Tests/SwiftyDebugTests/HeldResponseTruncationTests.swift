//
//  HeldResponseTruncationTests.swift
//  SwiftyDebugTests
//
//  Pins the bound on a HELD response body in `CustomHTTPProtocol`.
//
//  While a response is held (for an `.afterResponse` breakpoint, or for armed
//  response rewrites) nothing is streamed to the client, so the capture buffer
//  is the ONLY copy of the body the app will ever get. The 10 MB capture cap
//  used to truncate that buffer anyway, and `deliverHeldResponse` then rebuilt
//  the headers with a Content-Length matching the SHORT body — a well-formed
//  response the app cannot distinguish from a complete one.
//
//  The rule now is: a hold is bounded, and reaching the bound gives the hold up
//  (flush + stream the rest) instead of shortening the body.
//

import XCTest
@testable import SwiftyDebug

final class HeldResponseTruncationTests: XCTestCase {

    private var holdCap: Int { CustomHTTPProtocol.maxCapturedResponseBytes }
    private var rewriteCap: Int { ResponseRewriteEngine.maxBodyBytes }

    private func reason(buffered: Int, incoming: Int, rewriteOnly: Bool)
        -> CustomHTTPProtocol.HoldAbandonReason? {
        CustomHTTPProtocol.holdAbandonReason(bufferedBytes: buffered,
                                             incomingBytes: incoming,
                                             isHoldingForRewriteOnly: rewriteOnly)
    }

    // MARK: - The bound exists at all

    func testTheHoldCapIsNotSmallerThanTheRewriteCap() {
        XCTAssertGreaterThanOrEqual(holdCap, rewriteCap,
                                    "A hold that includes a breakpoint must be able to buffer at "
                                    + "least as much as a rewrite-only hold.")
    }

    // MARK: - A breakpoint hold under the cap keeps holding

    func testABreakpointHoldIsNotAbandonedWhileTheBodyFits() {
        XCTAssertNil(reason(buffered: 0, incoming: 1, rewriteOnly: false))
        XCTAssertNil(reason(buffered: holdCap - 1_000, incoming: 1_000, rewriteOnly: false),
                     "Exactly at the cap still fits — truncation only starts past it.")
    }

    func testABreakpointHoldSurvivesGrowthPastTheRewriteCap() {
        // Rewrites cannot run on a body this large, but the developer asked for
        // the pause, so the hold stays.
        XCTAssertNil(reason(buffered: rewriteCap, incoming: 1, rewriteOnly: false))
        XCTAssertNil(reason(buffered: rewriteCap * 2, incoming: 1, rewriteOnly: false))
    }

    // MARK: - A breakpoint hold past the cap is abandoned, never truncated

    func testABreakpointHoldIsAbandonedTheByteBeforeTruncationWouldStart() {
        XCTAssertEqual(reason(buffered: holdCap, incoming: 1, rewriteOnly: false),
                       .holdBufferExceeded,
                       "The hold must be given up BEFORE the capture cap can shorten the buffer "
                       + "that is about to be delivered as the whole response.")
    }

    func testASingleOversizedChunkAbandonsTheHoldImmediately() {
        XCTAssertEqual(reason(buffered: 0, incoming: holdCap + 1, rewriteOnly: false),
                       .holdBufferExceeded)
    }

    /// The bug, stated as a bound: the decision is made on the PROJECTED length,
    /// so the buffer is never allowed to reach a state where it would be cut.
    func testHoldIsAbandonedBeforeTheBufferCanEverExceedTheCap() {
        var buffered = 0
        let chunk = 64 * 1024
        var abandoned = false
        while buffered < holdCap + chunk * 4 {
            if reason(buffered: buffered, incoming: chunk, rewriteOnly: false) != nil {
                abandoned = true
                break
            }
            buffered += chunk
            XCTAssertLessThanOrEqual(buffered, holdCap,
                                     "A held buffer must never grow past the cap — that is the "
                                     + "point at which truncation would silently shorten the "
                                     + "delivered body.")
        }
        XCTAssertTrue(abandoned, "The hold must be abandoned rather than growing without bound.")
    }

    // MARK: - Rewrite-only holds keep their own, tighter bound

    func testARewriteOnlyHoldIsAbandonedAtTheRewriteCap() {
        XCTAssertEqual(reason(buffered: rewriteCap, incoming: 1, rewriteOnly: true),
                       .rewriteLimitExceeded)
        XCTAssertNil(reason(buffered: rewriteCap - 1, incoming: 1, rewriteOnly: true))
    }

    func testTheRewriteCapIsReportedInPreferenceToTheHoldCap() {
        // Both bounds are blown; the rewrite-only hold must say why it really
        // gave up, so the developer is not told about a breakpoint they never set.
        XCTAssertEqual(reason(buffered: holdCap, incoming: 1, rewriteOnly: true),
                       .rewriteLimitExceeded)
    }

    // MARK: - Whatever happens, the developer is told

    func testEveryAbandonReasonProducesANonEmptyExplanation() {
        for reason: CustomHTTPProtocol.HoldAbandonReason in [.rewriteLimitExceeded, .holdBufferExceeded] {
            XCTAssertFalse(CustomHTTPProtocol.holdAbandonedMessage(reason).isEmpty,
                           "A hold that silently stops holding is the exact failure this bound "
                           + "must not introduce.")
        }
    }

    func testTheRewriteMessageNamesTheRewriteLimit() {
        let message = CustomHTTPProtocol.holdAbandonedMessage(.rewriteLimitExceeded)
        XCTAssertTrue(message.contains("\(rewriteCap / 1024 / 1024) MB"), message)
        XCTAssertTrue(message.lowercased().contains("rewrite"), message)
    }

    func testTheBreakpointMessageSaysTheBodyWasNotTruncated() {
        let message = CustomHTTPProtocol.holdAbandonedMessage(.holdBufferExceeded)
        XCTAssertTrue(message.contains("\(holdCap / 1024 / 1024) MB"), message)
        XCTAssertTrue(message.lowercased().contains("breakpoint"),
                      "It has to explain the missing pause: \(message)")
        XCTAssertTrue(message.lowercased().contains("truncated"),
                      "It has to say the app still got the whole body: \(message)")
    }
}

// MARK: - Host-app cancellation

/// `stopLoading()` cancels the task, which comes back as NSURLErrorCancelled on
/// `didCompleteWithError`. Reporting that to the client would mean delivering
/// `didFailWithError` after `stopLoading` — which the URL loading system forbids
/// and which `stopLoading`'s own comment always claimed was trapped.
final class ClientCancellationTrapTests: XCTestCase {

    func testCancellationIsRecognised() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertTrue(CustomHTTPProtocol.isClientInitiatedCancellation(error, didCancel: true))
    }

    func testRealFailuresAreStillReported() {
        let codes = [NSURLErrorTimedOut,
                     NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotFindHost,
                     NSURLErrorNetworkConnectionLost,
                     NSURLErrorSecureConnectionFailed]
        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: nil)
            XCTAssertFalse(CustomHTTPProtocol.isClientInitiatedCancellation(error, didCancel: true),
                           "Code \(code) is a genuine failure and must reach the app.")
        }
    }

    func testTheSameCodeInAnotherDomainIsNotSwallowed() {
        // NSURLErrorCancelled is -999; -999 in POSIXErrorDomain means nothing of
        // the sort, and swallowing it would hang the request.
        let error = NSError(domain: NSPOSIXErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertFalse(CustomHTTPProtocol.isClientInitiatedCancellation(error, didCancel: true))
    }

    func testCFNetworkDomainCancellationIsNotSwallowed() {
        let error = NSError(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertFalse(CustomHTTPProtocol.isClientInitiatedCancellation(error, didCancel: true))
    }

    func testCancellationIsOnlySwallowedWhenWeCancelled() {
        // An unconditional trap delivers no terminal callback at all, so a -999
        // the SDK did not cause would leave a host-app request hanging forever.
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        XCTAssertTrue(CustomHTTPProtocol.isClientInitiatedCancellation(cancelled, didCancel: true),
                      "Our own stopLoading cancellation is the case the trap exists for")
        XCTAssertFalse(CustomHTTPProtocol.isClientInitiatedCancellation(cancelled, didCancel: false),
                       "A cancellation we did not cause must still reach the client — "
                       + "a hang is worse than a spurious error")
    }

    // MARK: - The notice channel

    func testAbandonedHoldIsReportedWhereTheDeveloperIsWaiting() {
        // A breakpoint that never paused used to explain itself inside the
        // RESPONSE REWRITES section of the request's detail screen — the last
        // place anyone would look for it.
        BreakpointCenter.shared.clearNotices()
        defer { BreakpointCenter.shared.clearNotices() }

        BreakpointCenter.shared.note("The response grew past the 10 MB limit.",
                                     for: URL(string: "https://api.example.com/big"))

        let notices = BreakpointCenter.shared.notices
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.url, "https://api.example.com/big")
        XCTAssertTrue(notices.first?.message.contains("10 MB") == true)
    }

    func testNoticesAreNewestFirstAndBounded() {
        BreakpointCenter.shared.clearNotices()
        defer { BreakpointCenter.shared.clearNotices() }

        for i in 0..<25 {
            BreakpointCenter.shared.note("note \(i)", for: URL(string: "https://a.com/\(i)"))
        }
        let notices = BreakpointCenter.shared.notices
        XCTAssertEqual(notices.first?.message, "note 24", "Newest first")
        XCTAssertLessThanOrEqual(notices.count, 20, "This is a diagnostic aid, not an unbounded log")
    }
}
