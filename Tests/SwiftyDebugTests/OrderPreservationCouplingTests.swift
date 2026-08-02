//
//  OrderPreservationCouplingTests.swift
//  SwiftyDebugTests
//
//  Order preservation depends on two ceilings agreeing. Nothing in the code
//  enforces that, and if they drift the copy button silently goes back to
//  alphabetising — the exact defect the maintainer reported, with a green suite.
//

import XCTest
@testable import SwiftyDebug

final class OrderPreservationCouplingTests: XCTestCase {

    func testTheByteCeilingNeverExceedsTheIndexedSourceCeiling() {
        // `Data` decides a body is worth printing in source order; `JSONDocument`
        // decides whether it kept a source index at all. If the first is larger,
        // a body in between takes the order-preserving path with no index and the
        // writer falls back to keys.sorted() — silently.
        XCTAssertLessThanOrEqual(Data.maxOrderPreservingBytes,
                                 JSONDocument.maxIndexedSourceBytes,
                                 "The printer would ask for source order on a body with no source index")
    }

    func testAModestNestedBodyStillKeepsServerOrder() throws {
        // The node ceiling was calibrated on FLAT shapes and did not bound nested
        // ones; lowering it must not swing so far that ordinary payloads lose order.
        let rows = (0..<200).map { #"{"zebra":\#($0),"alpha":"a","middle":{"inner":[1,2,3]}}"# }
        let body = Data("[\(rows.joined(separator: ","))]".utf8)

        let printed = try XCTUnwrap(body.dataToPrettyPrintString())
        let z = try XCTUnwrap(printed.range(of: "\"zebra\""))
        let a = try XCTUnwrap(printed.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound,
                          "A 200-row nested body must still keep the server's key order")
    }

    func testALongProseValueDoesNotCostOrderPreservation() throws {
        // The separator counter used to count commas and colons INSIDE string
        // literals, so one long prose value could exceed the node limit on its own
        // and alphabetise a body with three real keys.
        let prose = String(repeating: "a, b: c, ", count: 20_000)
        let body = Data(#"{"zebra":1,"note":"\#(prose)","alpha":2}"#.utf8)

        let printed = try XCTUnwrap(body.dataToPrettyPrintString())
        let z = try XCTUnwrap(printed.range(of: "\"zebra\""))
        let a = try XCTUnwrap(printed.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound,
                          "Separators inside a string are not nodes")
    }

    func testABracketInsideAStringDoesNotCountAsNesting() throws {
        let brackets = String(repeating: "[{", count: 200)
        let body = Data(#"{"zebra":1,"note":"\#(brackets)","alpha":2}"#.utf8)

        let printed = try XCTUnwrap(body.dataToPrettyPrintString())
        let z = try XCTUnwrap(printed.range(of: "\"zebra\""))
        let a = try XCTUnwrap(printed.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound,
                          "Brackets inside a string are not depth")
    }

    func testAnEscapedQuoteDoesNotEndTheStringEarly() throws {
        let body = Data(#"{"zebra":1,"note":"he said \"hi\", then left","alpha":2}"#.utf8)
        let printed = try XCTUnwrap(body.dataToPrettyPrintString())
        let z = try XCTUnwrap(printed.range(of: "\"zebra\""))
        let a = try XCTUnwrap(printed.range(of: "\"alpha\""))
        XCTAssertLessThan(z.lowerBound, a.lowerBound)
    }
}
