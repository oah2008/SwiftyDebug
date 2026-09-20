//
//  RequestBodyCaptureProbeTests.swift
//  SwiftyDebugTests
//
//  Pins the single fact the whole request-body capture path rests on: what a
//  URLProtocol actually receives when the app set `httpBody`.
//

import XCTest
@testable import SwiftyDebug

/// Records what the URL loading system hands a protocol, then fails the load so
/// nothing leaves the device.
final class BodyShapeProbeProtocol: URLProtocol {
    struct Observation {
        var httpBodyWasNil = false
        var httpBodyStreamWasPresent = false
        var httpBodyByteCount = -1
    }
    static var observation: Observation?
    static let done = DispatchSemaphore(value: 0)

    /// Set by the streamed-upload probe so it can compare identity.
    static var appSuppliedStream: InputStream?
    static var sawSameStreamObject = false
    static var streamStatusAtCanInit: Stream.Status = .notOpen
    static var hadBytesAvailableAtCanInit = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.host == "body-shape.invalid" else { return false }
        observation = Observation(
            httpBodyWasNil: request.httpBody == nil,
            httpBodyStreamWasPresent: request.httpBodyStream != nil,
            httpBodyByteCount: request.httpBody?.count ?? -1)
        if let supplied = appSuppliedStream {
            sawSameStreamObject = (request.httpBodyStream === supplied)
            if let s = request.httpBodyStream {
                streamStatusAtCanInit = s.streamStatus
                hadBytesAvailableAtCanInit = s.hasBytesAvailable
            }
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        Self.done.signal()
    }

    override func stopLoading() {}
}

final class RequestBodyCaptureProbeTests: XCTestCase {

    /// **This is the fact.** `URLProtocol` does not see `httpBody` — the loading
    /// system converts it to an `httpBodyStream` before the protocol is asked
    /// anything. So reading that stream is not an optimisation for streamed
    /// uploads: it is the ONLY way any request body is ever captured.
    func testTheLoadingSystemHandsAProtocolAStreamNotHTTPBody() {
        URLProtocol.registerClass(BodyShapeProbeProtocol.self)
        defer { URLProtocol.unregisterClass(BodyShapeProbeProtocol.self) }
        BodyShapeProbeProtocol.observation = nil

        var request = URLRequest(url: URL(string: "https://body-shape.invalid/echo")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hello":"world"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodyShapeProbeProtocol.self]
        let session = URLSession(configuration: configuration)
        let finished = expectation(description: "load finished")
        session.dataTask(with: request) { _, _, _ in finished.fulfill() }.resume()
        wait(for: [finished], timeout: 10)
        session.invalidateAndCancel()

        let observation = BodyShapeProbeProtocol.observation
        XCTAssertNotNil(observation, "the probe never saw the request")
        print("PROBE-A httpBodyWasNil=\(observation?.httpBodyWasNil as Any) "
              + "streamPresent=\(observation?.httpBodyStreamWasPresent as Any) "
              + "bodyBytes=\(observation?.httpBodyByteCount as Any)")
    }

    /// The dangerous shape: the app hands over a bound-pair read stream whose
    /// producer has not finished. Does the protocol receive THAT object, and
    /// does it look starved at the moment `startLoading` would run?
    func testAnAppSuppliedBoundPairReachesTheProtocol() {
        URLProtocol.registerClass(BodyShapeProbeProtocol.self)
        defer { URLProtocol.unregisterClass(BodyShapeProbeProtocol.self) }
        BodyShapeProbeProtocol.observation = nil
        BodyShapeProbeProtocol.sawSameStreamObject = false

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &input, outputStream: &output)
        guard let readEnd = input, let writeEnd = output else { return XCTFail("no bound pair") }
        BodyShapeProbeProtocol.appSuppliedStream = readEnd
        defer { BodyShapeProbeProtocol.appSuppliedStream = nil }

        writeEnd.open()
        let head = Array("--boundary\r\nfirst-part".utf8)
        _ = writeEnd.write(head, maxLength: head.count)
        // The rest arrives later, exactly like a producer still working.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let tail = Array("second-part\r\n--boundary--".utf8)
            _ = writeEnd.write(tail, maxLength: tail.count)
            writeEnd.close()
        }

        var request = URLRequest(url: URL(string: "https://body-shape.invalid/upload")!)
        request.httpMethod = "POST"
        request.httpBodyStream = readEnd

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodyShapeProbeProtocol.self]
        let session = URLSession(configuration: configuration)
        let finished = expectation(description: "load finished")
        session.dataTask(with: request) { _, _, _ in finished.fulfill() }.resume()
        wait(for: [finished], timeout: 10)
        session.invalidateAndCancel()

        print("PROBE-B sameStreamObject=\(BodyShapeProbeProtocol.sawSameStreamObject) "
              + "status=\(BodyShapeProbeProtocol.streamStatusAtCanInit.rawValue) "
              + "hasBytesAvailable=\(BodyShapeProbeProtocol.hadBytesAvailableAtCanInit) "
              + "httpBodyWasNil=\(BodyShapeProbeProtocol.observation?.httpBodyWasNil as Any)")
    }
}
