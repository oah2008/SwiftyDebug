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

        // Nothing reads `resumed.stream` — this is the mocked/blocked request.
        // Wait long enough for the pump to have filled its pipe and parked in
        // the write, rather than cancelling it before it ever got going.
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(CustomHTTPProtocol.livePumpCountForTesting, before + 1,
                       "precondition: it is still running, i.e. genuinely parked on a full pipe")

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

    /// The leak this design nearly shipped with.
    ///
    /// A producer that stops writing and never closes — an upload the user
    /// cancelled, an asset export that gave up — leaves the pump waiting for
    /// bytes that will never come. While the pump waited inside a BLOCKING
    /// read, nothing could end it: not the token, not a close from another
    /// thread (measured: still parked three seconds later), not any deadline.
    /// One stranded thread, pipe and stream per abandoned upload, for the life
    /// of the process.
    ///
    /// The test has to get the pump GENUINELY parked in the read before it
    /// cancels, or it proves nothing: drain everything the pump forwards, so
    /// the only thing left for it to do is wait on a producer that is finished
    /// speaking. (An earlier version of this test cancelled so quickly that the
    /// pump exited at its first `stillWanted()` check, and passed against the
    /// blocking read it was written to catch.)
    func testCancellingEndsAPumpWhoseProducerWentSilent() throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &input, outputStream: &output)
        let appStream = try XCTUnwrap(input)
        let appProducer = try XCTUnwrap(output)
        appProducer.open()

        // A little data, then silence. Crucially: never closed.
        let trickle = Array("still-writing".utf8)
        _ = appProducer.write(trickle, maxLength: trickle.count)

        let before = CustomHTTPProtocol.livePumpCountForTesting
        let prefix = Data("head".utf8)
        let resumed = try XCTUnwrap(
            CustomHTTPProtocol.resumedBodyStream(prefix: prefix, rest: appStream))

        // Drain the pump dry, the way CFNetwork would. Once we have every byte
        // it can possibly have, it is by definition waiting on `appStream`.
        resumed.stream.open()
        var forwarded = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let drainDeadline = Date().addingTimeInterval(5)
        while forwarded.count < prefix.count + trickle.count, Date() < drainDeadline {
            if !resumed.stream.hasBytesAvailable { Thread.sleep(forTimeInterval: 0.005); continue }
            let n = resumed.stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            forwarded.append(buffer, count: n)
        }
        XCTAssertEqual(forwarded, prefix + Data(trickle),
                       "precondition: the pump forwarded everything it had")

        // Give it a moment to settle into the wait it can no longer leave.
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(CustomHTTPProtocol.livePumpCountForTesting, before + 1,
                       "precondition: it is still running, i.e. genuinely parked on the producer")

        resumed.token.cancel()

        XCTAssertTrue(waitUntil { CustomHTTPProtocol.livePumpCountForTesting == before },
                      """
                      The pump is still running after cancellation, waiting on a producer that \
                      has gone silent. Every abandoned upload strands a thread, a 64KB pipe and \
                      the app's own stream — permanently.
                      """)
        resumed.stream.close()
        appProducer.close()
    }

    // MARK: - The drain's ceiling

    /// A body bigger than the cap is not buffered: the drain stops, and the
    /// rest is forwarded. Without this a 200MB upload was made fully resident
    /// in the host app just so a debugger could read its first half-megabyte.
    func testABodyLargerThanTheCapStopsTheDrainInsteadOfBuffering() throws {
        let oversize = Data(repeating: 0x5A, count: CustomHTTPProtocol.maxDrainedRequestBodyBytes + 256 * 1024)
        let stream = InputStream(data: oversize)

        let drained = CustomHTTPProtocol.drainBody(from: stream)

        XCTAssertEqual(drained.outcome, .more,
                       "Past the ceiling the body has to be FORWARDED, not swallowed.")
        XCTAssertLessThanOrEqual(drained.data.count,
                                 CustomHTTPProtocol.maxDrainedRequestBodyBytes + 64 * 1024,
                                 "The drain must stop at the cap, give or take one read.")
        stream.close()
    }

    /// And a body that fits is still drained whole — the ceiling must not
    /// quietly turn ordinary requests into forwarded ones.
    func testABodyWithinTheCapIsDrainedWhole() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let stream = InputStream(data: payload)

        let drained = CustomHTTPProtocol.drainBody(from: stream)

        XCTAssertEqual(drained.outcome, .ended)
        XCTAssertEqual(drained.data, payload)
        stream.close()
    }

    /// A stream that never opened reads like one at EOF. It must not be reported
    /// as a clean end, or its zero bytes become "the body".
    func testAnUnreadableStreamIsNotReportedAsACleanEnd() {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 512, inputStream: &input, outputStream: &output)
        guard let appStream = input, let producer = output else { return XCTFail("no pair") }
        producer.open()
        let some = Array("partial".utf8)
        _ = producer.write(some, maxLength: some.count)
        // Producer still open and still working: this is "more", never "ended".
        let drained = CustomHTTPProtocol.drainBody(from: appStream)
        XCTAssertEqual(drained.outcome, .more,
                       "A producer that has not finished must never be read as EOF.")
        producer.close()
        appStream.close()
    }
}
