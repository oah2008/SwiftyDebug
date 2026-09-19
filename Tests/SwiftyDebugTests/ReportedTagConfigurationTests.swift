//
//  ReportedTagConfigurationTests.swift
//  SwiftyDebugTests
//
//  The exact configuration from the bug report, end to end.
//
//  The reporter registers two tags that share a host and differ only by path
//  ("algolia.mahally.com/1/events" and ".../1/indexes"), puts the same URLs in
//  `SwiftyDebug.urls`, and adds a wildcard keyword. The filter sheet showed ONE
//  row for the two algolia tags, and selecting a tag whose requests carry query
//  parameters matched nothing.
//

import XCTest
@testable import SwiftyDebug

final class ReportedTagConfigurationTests: XCTestCase {

    private let applicationID = "abc123"

    /// Reproduces the reporter's `Plist`/`Envs` wiring verbatim.
    private func installReportedConfiguration() {
        SwiftyDebug.removeAllTags()

        let hosts: [(String, String)] = [
            ("algolia", "https://\(applicationID).algolia.net"),
            ("algolia", "https://\(applicationID)-1.algolianet.com"),
            ("algolia", "https://\(applicationID)-dsn.algolia.net"),
            ("segment", "https://cdn-settings.segment.com"),
            ("segment", "https://api.segment.io"),
            ("jitsu", "https://jitsu.salla.dev"),
            ("jitsu", "https://st.salla.dev"),
            ("pay.salla", "https://pay.salla.sa"),
            ("adjust", "https://consent.adjust.com"),
            ("adjust", "https://analytics.adjust.com"),
            ("algolia proxy", "https://algolia.mahally.com/1/indexes"),
            ("one signal", "https://api.onesignal.com"),
            ("algolia events", "https://insights.algolia.io"),
            ("algolia events", "https://algolia.mahally.com/1/events"),
            ("Remote Config", "https://firebaseremoteconfig.googleapis.com"),
            ("Braze", "sdk.iad-07.braze.com"),
            ("AI", "https://api.salla.dev/recommendations/v1/feeds"),
        ]
        for (label, url) in hosts {
            SwiftyDebug.addTag(keyword: url, label: label)
        }

        SwiftyDebug.urls = hosts.map { $0.1 }

        SwiftyDebug.addTag(keyword: "https://api.salla.dev/1/indexes/*/recommendations", label: "salla-recommend")
        SwiftyDebug.addTag(keyword: "https://api.salla.dev/recommendations/v1/products/", label: "AI-recommend")

        TagResolver.invalidate()
    }

    /// Traffic shaped the way the reporter's app actually sends it — Algolia puts
    /// its credentials in the query string, which is what broke matching.
    private let traffic = [
        "https://algolia.mahally.com/1/events?x-algolia-api-key=KEY&x-algolia-application-id=APP",
        "https://algolia.mahally.com/1/events?x-algolia-api-key=KEY&x-algolia-application-id=APP",
        "https://algolia.mahally.com/1/indexes/products/query?x-algolia-agent=iOS",
        "https://algolia.mahally.com/1/indexes/categories/query",
        "https://api.salla.dev/1/indexes/products/recommendations",
        "https://api.salla.dev/recommendations/v1/products/9911",
        "https://api.salla.dev/recommendations/v1/feeds?page=1",
        "https://abc123-dsn.algolia.net/1/indexes/*/queries",
        "https://api.segment.io/v1/batch",
        "https://analytics.adjust.com/session",
        "https://sdk.iad-07.braze.com/api/v3/data",
        "https://firebaseremoteconfig.googleapis.com/v1/projects/x/namespaces/firebase:fetch",
        "https://api.onesignal.com/players",
        "https://unknown-vendor.example.com/v1/thing",
        "https://api.stripe.com/v1/payment_intents",
    ]

    override func setUp() {
        super.setUp()
        installReportedConfiguration()
    }

    override func tearDown() {
        SwiftyDebug.removeAllTags()
        SwiftyDebug.urls = []
        TagResolver.invalidate()
        super.tearDown()
    }

    // MARK: - The reported symptom

    /// "on filter sheet only one tag is shown". Both must be there, with counts.
    func testBothAlgoliaMahallyTagsAppearInTheFilterListing() {
        let listing = TagResolver.tags(forURLStrings: traffic)
        let labels = listing.map { $0.tag.label }

        XCTAssertTrue(labels.contains("algolia events"), "listing was \(labels)")
        XCTAssertTrue(labels.contains("algolia proxy"), "listing was \(labels)")

        XCTAssertEqual(listing.first { $0.tag.label == "algolia events" }?.count, 2)
        XCTAssertEqual(listing.first { $0.tag.label == "algolia proxy" }?.count, 2)
    }

    /// "filter sheet MUST show all tags that have request logs" — every tag with
    /// traffic, and nothing with none.
    func testEveryTagWithTrafficIsListedAndNoTagWithoutTrafficIs() {
        let listing = TagResolver.tags(forURLStrings: traffic)
        let labels = Set(listing.map { $0.tag.label })

        for expected in ["algolia events", "algolia proxy", "salla-recommend", "AI-recommend",
                         "AI", "algolia", "segment", "adjust", "Braze", "Remote Config", "one signal"] {
            XCTAssertTrue(labels.contains(expected), "\(expected) has traffic but is missing from \(labels)")
        }
        // Configured, but nothing in this session hit it.
        XCTAssertFalse(labels.contains("pay.salla"))
        XCTAssertFalse(labels.contains("jitsu"))

        // Every row corresponds to at least one captured request.
        for entry in listing {
            XCTAssertGreaterThan(entry.count, 0, "\(entry.tag.label) is listed with no traffic")
        }
    }

    /// Every captured request is accounted for by exactly one listed tag.
    func testEveryRequestIsCoveredByExactlyOneListedTag() {
        let listing = TagResolver.tags(forURLStrings: traffic)
        XCTAssertEqual(listing.reduce(0) { $0 + $1.count }, traffic.count,
                       "The counts across all rows must add up to the traffic")

        for url in traffic {
            let owners = listing.filter { TagResolver.matches(tagKey: $0.tag.key, urlString: url) }
            XCTAssertEqual(owners.count, 1, "\(url) is owned by \(owners.map { $0.tag.label })")
        }
    }

    /// "filter by the full tag url not just host" — selecting one algolia tag
    /// must not drag in the other's traffic, even though they share a host.
    func testSelectingATagShowsExactlyThatTagsRequests() {
        let events = TagResolver.tag(forURLString: traffic[0])!
        let proxy = TagResolver.tag(forURLString: traffic[2])!
        XCTAssertNotEqual(events.key, proxy.key)

        let shown = traffic.filter { TagResolver.matches(tagKey: events.key, urlString: $0) }
        XCTAssertEqual(shown, [traffic[0], traffic[1]])

        let shownProxy = traffic.filter { TagResolver.matches(tagKey: proxy.key, urlString: $0) }
        XCTAssertEqual(shownProxy, [traffic[2], traffic[3]])
    }

    // MARK: - The specific keywords in the report

    func testTheWildcardRecommendationKeywordTagsItsTraffic() {
        XCTAssertEqual(TagResolver.tag(forURLString: "https://api.salla.dev/1/indexes/products/recommendations")?.label,
                       "salla-recommend")
    }

    /// Two salla.dev path tags plus a third for feeds — the most specific wins,
    /// and the trailing slash in the configured keyword must not matter.
    func testOverlappingSallaKeywordsResolveToTheMostSpecific() {
        XCTAssertEqual(TagResolver.tag(forURLString: "https://api.salla.dev/recommendations/v1/products/9911")?.label,
                       "AI-recommend")
        XCTAssertEqual(TagResolver.tag(forURLString: "https://api.salla.dev/recommendations/v1/feeds?page=1")?.label,
                       "AI")
    }

    /// The bare "algolia"-style keywords still behave as the documented
    /// case-insensitive substring match.
    func testTheAlgoliaApplicationHostsKeepTheirTag() {
        XCTAssertEqual(TagResolver.tag(forURLString: "https://abc123-dsn.algolia.net/1/indexes/*/queries")?.label,
                       "algolia")
    }

    /// A tag registered without a scheme ("sdk.iad-07.braze.com") must work like
    /// the ones registered with one.
    func testASchemelessKeywordWorks() {
        XCTAssertEqual(TagResolver.tag(forURLString: "https://sdk.iad-07.braze.com/api/v3/data")?.label, "Braze")
    }

    // MARK: - Untagged traffic

    func testUntaggedThirdPartyTrafficIsNamedFromTheCatalog() {
        XCTAssertEqual(TagResolver.tag(forURLString: "https://api.stripe.com/v1/payment_intents")?.label, "Stripe")
    }

    func testAnUnknownUntaggedHostGetsAGeneratedTag() {
        let tag = TagResolver.tag(forURLString: "https://unknown-vendor.example.com/v1/thing")
        XCTAssertEqual(tag?.origin, .derivedHost)
        XCTAssertEqual(tag?.label, "example")
    }

    // MARK: - Determinism

    /// The pill and the sheet used to be computed by different algorithms, one of
    /// which iterated a Swift Dictionary and took the first hit.
    func testResolutionIsIdenticalAcrossManyRunsAndMatchesThePill() {
        var first: [String] = []
        for run in 0..<50 {
            TagResolver.invalidate()
            let labels = traffic.map { TagResolver.tag(forURLString: $0)?.label ?? "<none>" }
            if run == 0 { first = labels } else { XCTAssertEqual(labels, first, "run \(run) differs") }

            for url in traffic {
                XCTAssertEqual(TagResolver.pill(for: URL(string: url)!)?.label,
                               TagResolver.tag(forURLString: url)?.label)
            }
        }
    }
}
