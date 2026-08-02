//
//  ResponseRewriteRegexBudgetTests.swift
//  SwiftyDebugTests
//
//  The find/replace action runs a regular expression that a human typed and that
//  nothing checked for cost — only for syntax. It runs
//
//    * on the networking thread, for every response a rule matches, and
//    * on the main thread, on every keystroke, while the pattern is being typed.
//
//  `^https?://([\w.-]+)+$` is a pattern someone would plausibly write for "the
//  host part of a URL", and against `"https://" + "a"*n + "!"` it backtracks
//  catastrophically: 21 chars 0.006 s, 25 chars 0.148 s, 29 chars 6.3 s, ~x2.6
//  per additional character. Unbounded, a 30-character value is ~16 s and a
//  40-character one is a hang — a frozen app for the developer and a stalled
//  request for the host app.
//
//  So the claims pinned down here are:
//
//    * a runaway pattern is STOPPED, not waited on,
//    * one budget covers the whole run, so N matched values cost one timeout and
//      not N of them,
//    * being stopped is REPORTED, in the applied report and in the editor's
//      preview rows — it can never read as "matched nothing" or "nothing
//      changed", and
//    * ordinary patterns still produce exactly what `stringByReplacingMatches`
//      produced before the bound existed.
//

import XCTest
@testable import SwiftyDebug

final class ResponseRewriteRegexBudgetTests: XCTestCase {

    // MARK: - Helpers

    /// The measured bomb. Written the way a person writes "host of a URL".
    private let bombPattern = #"^https?://([\w.-]+)+$"#

    /// A value that cannot match, so the engine backtracks over every way of
    /// splitting the run of `a`s before giving up. 30 is chosen so that a
    /// regression is unmistakable (~16 s against a 0.25 s budget) while still
    /// terminating instead of wedging the suite.
    private func bombValue(_ length: Int) -> String {
        "https://" + String(repeating: "a", count: length) + "!"
    }

    private func body(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private func regexRewrite(_ pattern: String, find: String, replace: String = "X") -> ResponseRewrite {
        ResponseRewrite(pattern: pattern,
                        action: .findReplace(find: find, replace: replace, isRegex: true))
    }

    /// Runs `work` off the test's thread so a returned regression fails in
    /// bounded time instead of wedging the whole suite.
    private func runBounded<T>(timeout: TimeInterval = 5,
                               _ work: @escaping () -> T,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> (value: T, elapsed: TimeInterval)? {
        // A standalone expectation + waiter, deliberately: the point is to fail
        // in bounded time even when the work under test never finishes.
        let done = XCTestExpectation(description: "bounded work")
        var result: T?
        var elapsed: TimeInterval = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let started = CFAbsoluteTimeGetCurrent()
            let value = work()
            elapsed = CFAbsoluteTimeGetCurrent() - started
            result = value
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: timeout)
        guard outcome == .completed, let value = result else {
            XCTFail("the regular expression was never stopped — it was still running after \(timeout)s",
                    file: file, line: line)
            return nil
        }
        return (value, elapsed)
    }

    // MARK: - The bound exists

    func testACatastrophicPatternIsStoppedInsteadOfRunningToCompletion() {
        let data = body(["url": bombValue(30)])
        let rewrite = regexRewrite("url", find: bombPattern)

        guard let run = runBounded({ ResponseRewriteEngine.apply([rewrite], to: data) }) else { return }

        XCTAssertLessThan(run.elapsed, 3,
                          "one value took \(run.elapsed)s — the regex is unbounded again")
        XCTAssertEqual(run.value.data, data,
                       "a stopped rewrite must hand back the original bytes, not a half-substituted value")
        XCTAssertFalse(run.value.report.didChange)

        let entry = run.value.report.entries.first
        XCTAssertEqual(entry?.matched, 1, "the path did match — only the substitution was abandoned")
        XCTAssertEqual(entry?.changed, 0)
        XCTAssertEqual(entry?.error, ResponseRewriteEngine.regexTimeoutMessage,
                       "being stopped has to be reported; silence reads as \"my rewrite did nothing\"")
    }

    /// The budget is per run, not per value: 50 slow values must cost one
    /// timeout. Otherwise the bound just multiplies by the match count.
    func testOneBudgetCoversEveryValueInTheRun() {
        let data = body(["urls": Array(repeating: bombValue(30), count: 50)])
        let rewrite = regexRewrite("urls[*]", find: bombPattern)

        guard let run = runBounded({ ResponseRewriteEngine.apply([rewrite], to: data) }) else { return }

        XCTAssertLessThan(run.elapsed, 3,
                          "\(run.elapsed)s for 50 values — the budget is being spent per value")
        let entry = run.value.report.entries.first
        XCTAssertEqual(entry?.matched, 50)
        XCTAssertEqual(entry?.changed, 0)
        XCTAssertEqual(entry?.error, "\(ResponseRewriteEngine.regexTimeoutMessage) (50 values)",
                       "every abandoned value has to be counted in the report")
    }

    /// The editor is where a runaway pattern is first typed, so its preview has
    /// to come back — and has to say what happened.
    func testThePreviewSaysTheRegexWasStoppedRatherThanShowingNoChange() {
        let data = body(["url": bombValue(30)])
        let rewrite = regexRewrite("url", find: bombPattern)

        guard let run = runBounded({ ResponseRewriteEngine.preview(rewrite, on: data, limit: 20) })
        else { return }

        XCTAssertLessThan(run.elapsed, 3, "the editor preview would have frozen the UI for \(run.elapsed)s")
        XCTAssertEqual(run.value.count, 1)
        XCTAssertEqual(run.value.first?.before, bombValue(30))
        XCTAssertEqual(run.value.first?.after,
                       "(unchanged — \(ResponseRewriteEngine.regexTimeoutMessage))",
                       "the preview row must name the reason; the editor quotes it verbatim")
    }

    /// An exhausted budget refuses immediately instead of starting a match it
    /// cannot afford to finish.
    func testAnExhaustedBudgetRefusesWithoutRunningTheRegex() {
        let spent = ResponseRewriteEngine.RegexBudget(seconds: 0)
        XCTAssertTrue(spent.isExhausted)

        let regex = try! NSRegularExpression(pattern: bombPattern)
        let started = CFAbsoluteTimeGetCurrent()
        let outcome = ResponseRewriteEngine.outcome(
            of: .findReplace(find: bombPattern, replace: "X", isRegex: true),
            on: bombValue(30), regex: regex, budget: spent)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.05)

        guard case .failed(let message) = outcome else {
            return XCTFail("an exhausted budget must refuse, got \(outcome)")
        }
        XCTAssertEqual(message, ResponseRewriteEngine.regexTimeoutMessage)
    }

    /// Even a well-behaved pattern is linear in its input, and one JSON string
    /// inside a 2 MB body can be 2 MB long.
    func testAnOverlongValueIsRefusedWithAReasonInsteadOfBeingMatched() {
        let long = String(repeating: "a", count: ResponseRewriteEngine.RegexBudget.maxInputLength + 1)
        let data = body(["v": long])
        let rewrite = regexRewrite("v", find: "a+", replace: "b")

        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: data)
        XCTAssertEqual(out, data)
        XCTAssertEqual(report.entries.first?.changed, 0)
        XCTAssertEqual(report.entries.first?.error?.contains("longer than"), true,
                       "skipping a value silently is the failure mode; it has to say so")
    }

    /// …and the cap is a cap, not a wall: a value under it is still rewritten.
    func testAValueUnderTheLengthCapIsStillRewritten() {
        let long = String(repeating: "a", count: ResponseRewriteEngine.RegexBudget.maxInputLength - 1)
        let data = body(["v": long])
        let rewrite = regexRewrite("v", find: "a+", replace: "b")

        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: data)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.entries.first?.changed, 1)
        let root = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        XCTAssertEqual(root?["v"] as? String, "b")
    }

    // MARK: - The bound did not change what a normal pattern does

    /// The bounded path re-implements `stringByReplacingMatches` on top of
    /// `enumerateMatches`, so it is checked against the thing it replaced.
    func testBoundedSubstitutionMatchesStringByReplacingMatchesExactly() {
        let cases: [(text: String, find: String, replace: String)] = [
            ("a-b-c",                       "-",                    "+"),
            ("user@example.com",            #"^(\w+)@([\w.]+)$"#,   "$2 at $1"),
            ("nothing here",                #"\d+"#,                "N"),
            ("2026-07-30",                  #"(\d+)-(\d+)-(\d+)"#,  "$3/$2/$1"),
            ("abc",                         "x*",                   "-"),
            ("héllo wörld",                 #"\s+"#,                "_"),
            ("🍎 and 🍎",                    "🍎",                   "apple"),
            ("keep",                        #"^$"#,                 "empty"),
            ("aaa",                         "a",                    ""),
            ("https://a.example.com/x?y=1", #"https?://([^/]+)"#,   "https://$1.test"),
        ]

        for item in cases {
            let regex = try! NSRegularExpression(pattern: item.find)
            let expected = regex.stringByReplacingMatches(
                in: item.text,
                range: NSRange(item.text.startIndex..., in: item.text),
                withTemplate: item.replace)

            let outcome = ResponseRewriteEngine.outcome(
                of: .findReplace(find: item.find, replace: item.replace, isRegex: true),
                on: item.text, regex: regex)

            switch outcome {
            case .newValue(let value):
                XCTAssertEqual(value as? String, expected, "pattern \(item.find) on \(item.text)")
            case .unchanged:
                XCTAssertEqual(expected, item.text, "pattern \(item.find) on \(item.text)")
            default:
                XCTFail("pattern \(item.find) on \(item.text) produced \(outcome)")
            }
        }
    }

    /// End to end through `apply`, so the wiring is covered and not just the
    /// single-value helper.
    func testAnOrdinaryRegexRewriteStillAppliesThroughTheEngine() {
        let data = body(["data": ["token": "Bearer abc123"]])
        let rewrite = regexRewrite("data.token", find: #"Bearer\s+(\w+)"#, replace: "Bearer REDACTED")

        let (out, report) = ResponseRewriteEngine.apply([rewrite], to: data)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.entries.first?.changed, 1)
        XCTAssertNil(report.entries.first?.error)

        let root = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        XCTAssertEqual((root?["data"] as? [String: Any])?["token"] as? String, "Bearer REDACTED")
    }
}
