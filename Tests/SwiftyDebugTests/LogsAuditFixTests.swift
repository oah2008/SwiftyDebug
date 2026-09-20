//
//  LogsAuditFixTests.swift
//  SwiftyDebugTests
//
//  Two halves of console search used to disagree with each other, and one of
//  them could kill the host app.
//
//  The DB half built its pattern by raw interpolation — `"%\(query)%"` — and
//  bound it to a bare LIKE. In SQL LIKE `_` matches any single character and
//  `%` matches any run, so searching `access_token` also counted
//  `access-token`, and searching `%` reported every row in the table as a
//  match while nothing at all was highlighted on screen.
//
//  The UI half computed its highlight ranges inside `mutable.string
//  .lowercased()` and applied them to the original, un-lowercased attributed
//  string. `lowercased()` is not length-preserving in Unicode: "İ" (U+0130) is
//  one UTF-16 unit and lowercases to two. Every match after such a character
//  was shifted, and a match near the end of a line produced a range past the
//  original's length — `NSMutableAttributedString.addAttribute` then raises
//  NSRangeException, an ObjC exception `try?` cannot catch, from
//  `cellForRowAt` while the user is scrolling.
//
//  These tests pin both halves: the escaping helper the SQL patterns go
//  through, and the fact that every range the highlighter produces indexes the
//  string it annotates.
//

import XCTest
import UIKit
@testable import SwiftyDebug

final class LogsAuditFixTests: XCTestCase {

    // MARK: - LIKE pattern escaping (FINDING 28 / 42)

    func testUnderscoreIsEscapedSoItCannotMatchAnyCharacter() {
        XCTAssertEqual(ConsoleLogDB.escapedLike("access_token"), "%access\\_token%")
    }

    func testPercentIsEscapedSoItCannotMatchAnyRun() {
        XCTAssertEqual(ConsoleLogDB.escapedLike("100%"), "%100\\%%")
    }

    func testBareWildcardQueryBecomesALiteralWildcardSearch() {
        // `%` alone used to report the full row count as matches.
        XCTAssertEqual(ConsoleLogDB.escapedLike("%"), "%\\%%")
    }

    func testBackslashIsDoubledBeforeTheOtherEscapesAreInserted() {
        // Escaping `%`/`_` first would leave `\%` looking like an escaped
        // percent instead of a literal backslash followed by a wildcard.
        XCTAssertEqual(ConsoleLogDB.escapedLike("a\\b"), "%a\\\\b%")
        XCTAssertEqual(ConsoleLogDB.escapedLike("a\\_b"), "%a\\\\\\_b%")
    }

    func testOrdinaryTextIsOnlyWrapped() {
        XCTAssertEqual(ConsoleLogDB.escapedLike("timeout"), "%timeout%")
        XCTAssertEqual(ConsoleLogDB.escapedLike(""), "%%")
    }

    // MARK: - Search highlight ranges (FINDING 29 / 46)

    /// Every range the highlighter marked, in the order it marked them.
    private func highlightedRanges(_ attributed: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: ConsoleCell.consoleFont])
    }

    func testRangesStayInsideTheAnnotatedStringWhenLowercasingLengthensIt() {
        // "İ" is one UTF-16 unit but lowercases to two, so ranges computed in
        // a lowercased copy ran past the original's length and crashed.
        let source = attributed("İ error")
        XCTAssertEqual((source.string as NSString).length, 7)
        XCTAssertEqual((source.string.lowercased() as NSString).length, 8)

        let result = ConsoleCell.applySearchHighlight(to: source, query: "error", isCurrentMatch: false)

        XCTAssertEqual(result.length, source.length)
        XCTAssertEqual(highlightedRanges(result), [NSRange(location: 2, length: 5)])
    }

    func testHighlightLandsOnTheLiteralTermAfterALengtheningCharacter() {
        let text = "İstanbul warehouse sync failed: retry_after=30"
        let result = ConsoleCell.applySearchHighlight(to: attributed(text), query: "retry", isCurrentMatch: true)

        let expected = (text as NSString).range(of: "retry")
        XCTAssertEqual(highlightedRanges(result), [expected])
        XCTAssertEqual((text as NSString).substring(with: expected), "retry")
    }

    func testMatchingRemainsCaseInsensitive() {
        let text = "Request FAILED with Error"
        let result = ConsoleCell.applySearchHighlight(to: attributed(text), query: "error", isCurrentMatch: false)

        XCTAssertEqual(highlightedRanges(result), [(text as NSString).range(of: "Error")])
    }

    func testEveryOccurrenceIsMarked() {
        let text = "retry retry retry"
        let result = ConsoleCell.applySearchHighlight(to: attributed(text), query: "retry", isCurrentMatch: false)

        XCTAssertEqual(highlightedRanges(result), [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 5),
            NSRange(location: 12, length: 5),
        ])
    }

    func testEmptyQueryMarksNothing() {
        let result = ConsoleCell.applySearchHighlight(to: attributed("İ error"), query: "", isCurrentMatch: false)

        XCTAssertTrue(highlightedRanges(result).isEmpty)
    }

    func testNoMatchMarksNothing() {
        let result = ConsoleCell.applySearchHighlight(to: attributed("all good"), query: "error", isCurrentMatch: false)

        XCTAssertTrue(highlightedRanges(result).isEmpty)
    }
}
