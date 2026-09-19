//
//  TagResolutionTests.swift
//  SwiftyDebugTests
//
//  The tag a request shows and the filter that keeps it are now one decision
//  (`TagResolver`). These pin the behaviours that were broken before it existed:
//
//   • Two tags sharing a host but differing by path collapsed into one filter row.
//   • A tag stopped matching the moment the request carried a query string,
//     because the comparison ran against `absoluteString`.
//   • The request cell picked the FIRST match out of a Swift Dictionary — no
//     order — so the same URL showed a different pill on different launches,
//     while the filter sheet used longest-match and disagreed by construction.
//   • A `*` in a keyword was compared literally and could never match.
//   • Untagged traffic had no tag at all beyond a truncated host.
//

import XCTest
@testable import SwiftyDebug

final class TagResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SwiftyDebug.removeAllTags()
        TagResolver.invalidate()
    }

    override func tearDown() {
        SwiftyDebug.removeAllTags()
        TagResolver.invalidate()
        super.tearDown()
    }

    private func tag(_ urlString: String) -> NetworkTag? {
        TagResolver.tag(forURLString: urlString)
    }

    // MARK: - The reported bug: two tags, one host, different paths

    func testTwoTagsSharingAHostButDifferingByPathAreBothResolved() {
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/events", label: "algolia events")
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/indexes", label: "algolia proxy")

        XCTAssertEqual(tag("https://algolia.mahally.com/1/events")?.label, "algolia events")
        XCTAssertEqual(tag("https://algolia.mahally.com/1/indexes/products/query")?.label, "algolia proxy")
    }

    /// The filter sheet lists tags, and it must list BOTH of the above. This is
    /// the exact symptom that was reported: only one of the two ever appeared.
    func testBothTagsAppearInTheFilterListing() {
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/events", label: "algolia events")
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/indexes", label: "algolia proxy")

        let listing = TagResolver.tags(forURLStrings: [
            "https://algolia.mahally.com/1/events?x-algolia-api-key=abc",
            "https://algolia.mahally.com/1/events?x-algolia-api-key=abc",
            "https://algolia.mahally.com/1/indexes/products/query",
        ])

        let labels = listing.map { $0.tag.label }
        XCTAssertTrue(labels.contains("algolia events"), "listing was \(labels)")
        XCTAssertTrue(labels.contains("algolia proxy"), "listing was \(labels)")

        let events = listing.first { $0.tag.label == "algolia events" }
        XCTAssertEqual(events?.count, 2, "counts come from the traffic, not the tag table")
    }

    // MARK: - Query strings

    /// The single highest-impact defect: `modelURL.hasPrefix(key + "/") || modelURL == key`
    /// ran against the full absolute string, so a tagged endpoint carrying query
    /// parameters matched nothing and its filter showed an empty list.
    func testATaggedEndpointStillMatchesWhenTheRequestCarriesAQueryString() {
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/events", label: "algolia events")

        XCTAssertEqual(tag("https://algolia.mahally.com/1/events?x-algolia-api-key=abc&x-algolia-agent=iOS")?.label,
                       "algolia events")
        XCTAssertEqual(tag("https://algolia.mahally.com/1/events#frag")?.label, "algolia events")
        XCTAssertEqual(tag("https://algolia.mahally.com/1/events/")?.label, "algolia events")
    }

    func testSelectingOneTagDoesNotAdmitTheOtherTagsTraffic() {
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/events", label: "algolia events")
        SwiftyDebug.addTag(keyword: "https://algolia.mahally.com/1/indexes", label: "algolia proxy")

        let eventsKey = tag("https://algolia.mahally.com/1/events")!.key
        XCTAssertTrue(TagResolver.matches(tagKey: eventsKey,
                                          urlString: "https://algolia.mahally.com/1/events?a=1"))
        XCTAssertFalse(TagResolver.matches(tagKey: eventsKey,
                                           urlString: "https://algolia.mahally.com/1/indexes/x/query"))
    }

    // MARK: - Determinism

    /// A Swift Dictionary has no iteration order, so "return the first keyword
    /// that matches" returned a different answer between launches — and a
    /// different pill COLOUR with it, since the colour is hashed from the winner.
    func testOverlappingKeywordsResolveToTheMostSpecificOneEveryTime() {
        SwiftyDebug.addTag(keyword: "api.salla.dev", label: "Salla")
        SwiftyDebug.addTag(keyword: "api.salla.dev/recommendations/v1/products", label: "AI-recommend")

        let url = "https://api.salla.dev/recommendations/v1/products/123"
        for _ in 0..<200 {
            TagResolver.invalidate()
            XCTAssertEqual(tag(url)?.label, "AI-recommend",
                           "a path-scoped keyword must always beat a host keyword")
        }
    }

    func testAPathScopedKeywordBeatsALongerHostKeyword() {
        SwiftyDebug.addTag(keyword: "averyveryverylonghostname.example.com", label: "host tag")
        SwiftyDebug.addTag(keyword: "averyveryverylonghostname.example.com/a", label: "path tag")
        XCTAssertEqual(tag("https://averyveryverylonghostname.example.com/a/b")?.label, "path tag")
    }

    func testTheSameURLAlwaysProducesTheSameColourKey() {
        SwiftyDebug.addTag(keyword: "api.salla.dev", label: "Salla")
        let first = TagResolver.pill(for: URL(string: "https://api.salla.dev/x")!)
        TagResolver.invalidate()
        let second = TagResolver.pill(for: URL(string: "https://api.salla.dev/x")!)
        XCTAssertEqual(first?.colorKey, second?.colorKey)
        XCTAssertEqual(first?.label, second?.label)
    }

    // MARK: - Wildcards

    func testSingleStarMatchesExactlyOnePathSegment() {
        SwiftyDebug.addTag(keyword: "https://api.salla.dev/1/indexes/*/recommendations",
                           label: "salla-recommend")

        XCTAssertEqual(tag("https://api.salla.dev/1/indexes/products/recommendations")?.label,
                       "salla-recommend")
        XCTAssertNotEqual(tag("https://api.salla.dev/1/indexes/a/b/recommendations")?.label,
                          "salla-recommend", "`*` is one segment; `**` is any depth")
    }

    func testDoubleStarMatchesAnyDepth() {
        SwiftyDebug.addTag(keyword: "api.salla.dev/1/indexes/**/recommendations", label: "deep")
        XCTAssertEqual(tag("https://api.salla.dev/1/indexes/a/b/c/recommendations")?.label, "deep")
    }

    func testWildcardTailStillRequiresAPathBoundary() {
        SwiftyDebug.addTag(keyword: "api.salla.dev/1/indexes/*/recommendations", label: "rec")
        XCTAssertEqual(tag("https://api.salla.dev/1/indexes/x/recommendations/related")?.label, "rec")
        XCTAssertNotEqual(tag("https://api.salla.dev/1/indexes/x/recommendations-v2")?.label, "rec")
    }

    // MARK: - Normalisation

    func testSchemeCaseTrailingSlashPortAndWWWDoNotDefeatAKeyword() {
        SwiftyDebug.addTag(keyword: "HTTPS://API.Salla.dev/v2/stores/", label: "stores")

        for url in ["https://api.salla.dev/v2/stores",
                    "http://api.salla.dev/v2/stores/",
                    "https://www.api.salla.dev/v2/stores/123",
                    "https://api.salla.dev./v2/stores"] {
            XCTAssertEqual(tag(url)?.label, "stores", "failed for \(url)")
        }
    }

    /// Boundary-aware, so a keyword cannot claim a longer sibling path.
    func testAPathKeywordDoesNotClaimALongerSiblingSegment() {
        SwiftyDebug.addTag(keyword: "api.example.com/1/index", label: "index")
        XCTAssertNotEqual(tag("https://api.example.com/1/indexes")?.label, "index")
        XCTAssertEqual(tag("https://api.example.com/1/index/a")?.label, "index")
    }

    /// A host keyword matches subdomains but never a host that merely ends with
    /// the same letters.
    func testAHostKeywordMatchesSubdomainsButNotASuffixLookalike() {
        SwiftyDebug.addTag(keyword: "algolia.net", label: "Algolia")
        XCTAssertEqual(tag("https://abc-dsn.algolia.net/1/x")?.label, "Algolia")
        XCTAssertEqual(tag("https://algolia.net/1/x")?.label, "Algolia")
        XCTAssertNotEqual(tag("https://notalgolia.net/1/x")?.label, "Algolia")
    }

    /// The documented behaviour of `addTag` since day one — a bare word is a
    /// substring match — is preserved, so existing integrations keep working.
    func testABareKeywordStillMatchesAsASubstring() {
        SwiftyDebug.addTag(keyword: "algolia", label: "Algolia")
        XCTAssertEqual(tag("https://xyz-3.algolianet.com/1/indexes")?.label, "Algolia")
    }

    // MARK: - Catalog and derived fallbacks

    func testAKnownAPIHostIsNamedWithoutAnyConfiguration() {
        XCTAssertEqual(tag("https://api.stripe.com/v1/charges")?.label, "Stripe")
        XCTAssertEqual(tag("https://graph.facebook.com/v18.0/me")?.label, "Facebook")
        XCTAssertEqual(tag("https://firebaseremoteconfig.googleapis.com/v1/x")?.label, "Firebase")
        XCTAssertEqual(tag("https://55c0a1-dsn.algolia.net/1/indexes")?.label, "Algolia")
    }

    func testTheCatalogPrefersTheMostSpecificDomainEntry() {
        // `firebaselogging-pa.googleapis.com` has its own entry and must not lose
        // to the broader `googleapis.com`.
        XCTAssertEqual(tag("https://firebaselogging-pa.googleapis.com/v1/x")?.label, "Firebase")
        XCTAssertEqual(tag("https://translate.googleapis.com/x")?.label, "Google Translate")
    }

    func testADeveloperTagAlwaysBeatsTheCatalog() {
        SwiftyDebug.addTag(keyword: "api.stripe.com", label: "Payments")
        XCTAssertEqual(tag("https://api.stripe.com/v1/charges")?.label, "Payments")
        XCTAssertEqual(tag("https://api.stripe.com/v1/charges")?.origin, .userTag)
    }

    func testAnUnknownUntaggedHostStillGetsAGeneratedTag() {
        let resolved = tag("https://algolia.mahally.com/whatever")
        XCTAssertEqual(resolved?.origin, .derivedHost)
        XCTAssertEqual(resolved?.label, "mahally")
    }

    func testTwoSubdomainsOfOneUntaggedDomainShareASingleGeneratedTag() {
        let a = tag("https://algolia.mahally.com/x")
        let b = tag("https://cdn.mahally.com/y")
        XCTAssertEqual(a?.key, b?.key, "one derived tag per registrable domain, not per host")
        XCTAssertEqual(a?.label, b?.label)
    }

    func testMultiPartPublicSuffixesResolveTheBrandNotTheSuffix() {
        XCTAssertEqual(TagResolver.derivedLabel(forHost: "api.salla.com.sa"), "salla")
        XCTAssertEqual(TagResolver.derivedLabel(forHost: "shop.example.co.uk"), "example")
        XCTAssertEqual(TagResolver.registrableDomain(forHost: "api.salla.com.sa"), "salla.com.sa")
    }

    func testIPLiteralsAndLocalhostAreLeftAlone() {
        XCTAssertEqual(TagResolver.derivedLabel(forHost: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(TagResolver.derivedLabel(forHost: "localhost"), "localhost")
        XCTAssertNotNil(tag("http://127.0.0.1:8080/x"))
    }

    /// Every request must resolve to something — an untagged row with no pill was
    /// the old behaviour and is what made third-party traffic unreadable.
    func testEveryRequestWithAHostResolvesToATag() {
        for url in ["https://a.b.example/x", "http://xyz.co/1", "https://127.0.0.1/y",
                    "https://api.stripe.com/v1", "https://weird-host.internal/path"] {
            XCTAssertNotNil(tag(url), "no tag for \(url)")
        }
    }

    // MARK: - Listing semantics

    func testTheListingIsOrderedDeveloperTagsThenCatalogThenDerived() {
        SwiftyDebug.addTag(keyword: "mine.example.com", label: "Mine")
        let listing = TagResolver.tags(forURLStrings: [
            "https://mine.example.com/a",
            "https://api.stripe.com/v1/charges",
            "https://unknown-vendor.test/x",
        ])
        XCTAssertEqual(listing.map { $0.tag.origin }, [.userTag, .knownAPI, .derivedHost])
    }

    func testTheListingHasOneRowPerTagAndNoDuplicates() {
        let listing = TagResolver.tags(forURLStrings: Array(repeating: "https://api.stripe.com/v1/x", count: 50)
                                       + ["https://api.stripe.com/v1/y"])
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing.first?.count, 51)
    }

    func testAListedTagsLabelIsExactlyThePillItsRequestsShow() {
        SwiftyDebug.addTag(keyword: "algolia.mahally.com/1/events", label: "algolia events")
        let urls = ["https://algolia.mahally.com/1/events?a=1",
                    "https://cdn.mahally.com/img",
                    "https://api.stripe.com/v1/charges"]
        for (tag, _) in TagResolver.tags(forURLStrings: urls) {
            let matching = urls.filter { TagResolver.matches(tagKey: tag.key, urlString: $0) }
            XCTAssertFalse(matching.isEmpty, "listed tag \(tag.key) matches nothing")
            for url in matching {
                XCTAssertEqual(TagResolver.pill(for: URL(string: url)!)?.label, tag.label,
                               "sheet row and cell pill disagree for \(url)")
            }
        }
    }

    // MARK: - Cache invalidation

    /// A tag added after traffic has already been rendered must re-tag it, or the
    /// list keeps showing pills computed before the tag existed.
    func testAddingATagAfterResolutionRetagsAlreadySeenTraffic() {
        let url = "https://api.stripe.com/v1/charges"
        XCTAssertEqual(tag(url)?.label, "Stripe")
        SwiftyDebug.addTag(keyword: "api.stripe.com", label: "Payments")
        XCTAssertEqual(tag(url)?.label, "Payments", "the resolver cache must key on the tag generation")
    }

    func testRemovingATagRevertsToTheCatalog() {
        SwiftyDebug.addTag(keyword: "api.stripe.com", label: "Payments")
        XCTAssertEqual(tag("https://api.stripe.com/v1")?.label, "Payments")
        SwiftyDebug.removeTag(keyword: "api.stripe.com")
        XCTAssertEqual(tag("https://api.stripe.com/v1")?.label, "Stripe")
    }

    // MARK: - Robustness

    func testAURLFoundationCannotParseStillResolves() {
        // Real traffic contains unencoded characters; returning no tag for them
        // would silently drop the row's pill.
        let resolved = tag("https://api.example.com/search/a b{c}")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.label, "example")
    }

    func testAnEmptyOrHostlessURLResolvesToNothingRatherThanCrashing() {
        XCTAssertNil(tag(""))
        XCTAssertNil(TagResolver.tag(for: nil as URL?))
    }

    func testAnUncompilableWildcardTagsNothingRatherThanEverything() {
        SwiftyDebug.addTag(keyword: "api.example.com/[", label: "broken")
        XCTAssertNotEqual(tag("https://api.example.com/anything")?.label, "broken")
    }

    func testResolutionIsThreadSafe() {
        SwiftyDebug.addTag(keyword: "api.salla.dev", label: "Salla")
        let done = expectation(description: "concurrent resolution")
        done.expectedFulfillmentCount = 8
        for index in 0..<8 {
            DispatchQueue.global().async {
                for inner in 0..<200 {
                    _ = TagResolver.tag(forURLString: "https://api.salla.dev/\(index)/\(inner)")
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
    }

    // MARK: - One label, many keywords

    /// `addTag` is a many-keywords-to-one-label API and real configurations use it
    /// that way. Keying a tag by its KEYWORD split one label into several rows
    /// with identical names — the same unreadable sheet this engine exists to fix.
    func testSeveralKeywordsSharingOneLabelProduceOneRow() {
        SwiftyDebug.addTag(keyword: "https://cdn-settings.segment.com", label: "segment")
        SwiftyDebug.addTag(keyword: "https://api.segment.io", label: "segment")

        let listing = TagResolver.tags(forURLStrings: [
            "https://api.segment.io/v1/batch",
            "https://cdn-settings.segment.com/v1/projects/x",
        ])
        XCTAssertEqual(listing.filter { $0.tag.label == "segment" }.count, 1,
                       "one label is one tag: \(listing.map { $0.tag.label })")
        XCTAssertEqual(listing.first { $0.tag.label == "segment" }?.count, 2)
    }

    /// …and two tags whose LABELS differ stay separate even on one host. That is
    /// the reported case, and it must not be collapsed by the fix above.
    func testTwoLabelsOnOneHostStaySeparate() {
        SwiftyDebug.addTag(keyword: "algolia.mahally.com/1/events", label: "algolia events")
        SwiftyDebug.addTag(keyword: "algolia.mahally.com/1/indexes", label: "algolia proxy")

        let listing = TagResolver.tags(forURLStrings: [
            "https://algolia.mahally.com/1/events?k=1",
            "https://algolia.mahally.com/1/indexes/p/query",
        ])
        XCTAssertEqual(listing.count, 2)
        XCTAssertEqual(Set(listing.map { $0.tag.label }), ["algolia events", "algolia proxy"])
    }

    func testAMergedRowsSubtitleIsStableRegardlessOfCaptureOrder() {
        SwiftyDebug.addTag(keyword: "https://b.segment.io", label: "segment")
        SwiftyDebug.addTag(keyword: "https://a.segment.io", label: "segment")

        let forwards = TagResolver.tags(forURLStrings: ["https://a.segment.io/x", "https://b.segment.io/y"])
        TagResolver.invalidate()
        let backwards = TagResolver.tags(forURLStrings: ["https://b.segment.io/y", "https://a.segment.io/x"])
        XCTAssertEqual(forwards.first?.tag.matchedKeyword, backwards.first?.tag.matchedKeyword)
    }

    // MARK: - Keywords that do not name a host

    /// The documented contract is a substring match. A keyword with no host to
    /// anchor to must keep working, or an integration that shipped before this
    /// engine silently stops tagging anything.
    func testAPathFragmentKeywordStillMatchesAsASubstring() {
        SwiftyDebug.addTag(keyword: "/v1/checkout", label: "Checkout")
        XCTAssertEqual(tag("https://api.shop.com/v1/checkout/confirm")?.label, "Checkout")
    }

    func testADottedNonHostKeywordStillMatchesAsASubstring() {
        SwiftyDebug.addTag(keyword: "config.json", label: "Config")
        XCTAssertEqual(tag("https://cdn.example.com/assets/config.json")?.label, "Config")
    }

    /// …without loosening the boundary rules for keywords that DO name a host.
    func testTheSubstringFallbackDoesNotLoosenHostOrPathBoundaries() {
        SwiftyDebug.addTag(keyword: "algolia.net", label: "Algolia")
        SwiftyDebug.addTag(keyword: "api.example.com/1/index", label: "index")
        XCTAssertNotEqual(tag("https://notalgolia.net/1/x")?.label, "Algolia")
        XCTAssertNotEqual(tag("https://api.example.com/1/indexes")?.label, "index")
    }

    func testHostnameHeuristic() {
        for value in ["algolia.net", "api.salla.dev", "example.co.uk", "x.io", "a.b.sa"] {
            XCTAssertTrue(TagResolver.looksLikeHostname(value), value)
        }
        for value in ["config.json", "v1.2", "", "foo", ".com", "bar.", "file.tar.gz2x"] {
            XCTAssertFalse(TagResolver.looksLikeHostname(value), value)
        }
    }

    // MARK: - Hosts that are not names

    func testIPv6LiteralHostsKeepTheirIdentity() {
        let a = tag("http://[::1]:8080/api/users")
        let b = tag("http://[fe80::1]/health")
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a?.key, b?.key, "two IPv6 hosts must not collapse into one tag")
        XCTAssertFalse(a?.label.hasPrefix("[") == true && a?.label == "[",
                       "the port strip must not cut an IPv6 literal down to \"[\"")
        XCTAssertEqual(TagResolver.normalizeHost("[::1]:8080"), "[::1]")
    }

    // MARK: - Allow-list changes invalidate the cache

    /// `SwiftyDebug.urls` feeds tag resolution, so changing it must re-tag traffic
    /// that has already been resolved — otherwise the pills are stuck forever.
    func testChangingTheMonitoredURLListRetagsAlreadySeenTraffic() {
        let url = "https://api.acme-unknown.test/v2/items"
        XCTAssertEqual(tag(url)?.origin, .derivedHost)

        SwiftyDebug.urls = ["https://api.acme-unknown.test/v2"]
        defer { SwiftyDebug.urls = [] }

        XCTAssertEqual(tag(url)?.origin, .allowListURL,
                       "a change to SwiftyDebug.urls must invalidate the resolver cache")
    }

    // MARK: - The web marker

    /// Webview traffic keeps its tag — identity, colour and filtering unchanged —
    /// and only its displayed pill says so, so the cell and the sheet still agree
    /// about which tag the row belongs to.
    func testAWebViewRequestKeepsItsTagAndGainsAMarker() {
        SwiftyDebug.addTag(keyword: "api.shop.test", label: "Shop")
        let url = URL(string: "https://api.shop.test/v1/items")!

        XCTAssertEqual(TagResolver.pill(for: url)?.label, "Shop")
        let web = TagResolver.pill(for: url, isWebView: true)
        XCTAssertTrue(web?.label.hasPrefix("Shop") == true)
        XCTAssertTrue(web?.label.contains("web") == true)
        XCTAssertEqual(web?.colorKey, TagResolver.pill(for: url)?.colorKey,
                       "the web marker must not change the tag's identity or colour")
    }

    // MARK: - Endpoint keys

    /// A path alone collided across hosts, so picking an endpoint under one tag
    /// also admitted an identical route served by a different host.
    func testEndpointKeysAreHostScoped() {
        let a = NetworkViewController.endpointKey(for: URL(string: "https://algolia.mahally.com/1/indexes/x/query"))
        let b = NetworkViewController.endpointKey(for: URL(string: "https://insights.algolia.io/1/indexes/x/query"))
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    func testEndpointKeyIgnoresTheQueryStringAndTrailingSlash() {
        let a = NetworkViewController.endpointKey(for: URL(string: "https://api.x.dev/v2/stores?page=1"))
        let b = NetworkViewController.endpointKey(for: URL(string: "https://api.x.dev/v2/stores"))
        XCTAssertEqual(a, b)
    }
}
