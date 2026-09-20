//
//  BodyStreamPumpTests.swift
//  SwiftyDebugTests
//
//  The pump exists so that bytes taken from a not-yet-finished body stream can
//  be handed back. It runs on its own thread, so the property that matters most
//  is that it always ends — including for a request that is never sent at all.
//

import XCTest
@testable import SwiftyDebug

final class BodyStreamPumpTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// `startLoading` drains the body BEFORE intercept rules are resolved, and a
    /// rule can block the request, answer it from a mock, or park it at a
    /// breakpoint — none of which ever send it. The pump then fills its pipe,
    /// finds nobody draining it, and waits. Cancelling has to end it.
    func testCancellingEndsAPumpNobodyIsReadingFrom() throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &input, outputStream: &output)
        let appStream = try XCTUnwrap(input)
        let appProducer = try XCTUnwrap(output)
        appProducer.open()

        // Far more than the pump's own pipe holds, so it is guaranteed to block
        // writing into a pipe that nothing is reading.
        let bulk = [UInt8](repeating: 0x41, count: 512 * 1024)
        let producing = Thread {
            var offset = 0
            while offset < bulk.count, appProducer.streamStatus != .error,
                  appProducer.streamStatus != .closed {
                if !appProducer.hasSpaceAvailable { Thread.sleep(forTimeInterval: 0.002); continue }
                let written = bulk.withUnsafeBufferPointer {
                    appProducer.write($0.baseAddress! + offset, maxLength: bulk.count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
        }
        producing.start()

        let before = CustomHTTPProtocol.livePumpCountForTesting
        let resumed = try XCTUnwrap(
            CustomHTTPProtocol.resumedBodyStream(prefix: Data("prefix".utf8), rest: appStream),
            "the bound pair could not be created")

        XCTAssertTrue(waitUntil { CustomHTTPProtocol.livePumpCountForTesting == before + 1 },
                      "precondition: the pump started")
        // Nothing reads `resumed.stream` — this is the mocked/blocked request.
        XCTAssertTrue(waitUntil({ CustomHTTPProtocol.livePumpCountForTesting == before + 1 },
                                timeout: 0.4),
                      "precondition: it is still running, i.e. genuinely parked")

        resumed.token.cancel()

        XCTAssertTrue(waitUntil { CustomHTTPProtocol.livePumpCountForTesting == before },
                      """
                      A pump for a request that was never sent is still running. It would hold \
                      its thread, its pipe and the app's body stream until the backstop \
                      deadline — ten minutes — for every blocked or mocked streamed request.
                      """)
        appProducer.close()
    }

    /// The ordinary end: the producer finishes, the consumer drains, the pump
    /// reaches EOF and exits on its own with no cancellation at all.
    func testAPumpEndsByItselfOnceTheBodyIsFullyForwarded() throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &input, outputStream: &output)
        let appStream = try XCTUnwrap(input)
        let appProducer = try XCTUnwrap(output)
        appProducer.open()

        let tail = Array("-tail".utf8)
        _ = appProducer.write(tail, maxLength: tail.count)
        appProducer.close()

        let before = CustomHTTPProtocol.livePumpCountForTesting
        let resumed = try XCTUnwrap(
            CustomHTTPProtocol.resumedBodyStream(prefix: Data("head".utf8), rest: appStream))

        // Drain it the way CFNetwork would.
        resumed.stream.open()
        var forwarded = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !resumed.stream.hasBytesAvailable {
                if resumed.stream.streamStatus == .atEnd { break }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let n = resumed.stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            forwarded.append(buffer, count: n)
        }
        resumed.stream.close()

        XCTAssertEqual(forwarded, Data("head-tail".utf8),
                       "The prefix must come back first, then the rest, in order.")
        XCTAssertTrue(waitUntil { CustomHTTPProtocol.livePumpCountForTesting == before },
                      "A pump that reached EOF must exit without needing to be cancelled.")
    }
}
