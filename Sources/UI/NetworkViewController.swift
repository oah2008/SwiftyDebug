//
//  NetworkViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

private enum NetworkTab: Int { case app = 0, web = 1, pinned = 2 }

/// Per-tab filter + layout state (includes auto-follow + scroll offset).
private final class TabFilterState {
    /// Identities from `TagResolver` (`NetworkTag.key`). One set, not the old
    /// path-filters/host-filters pair: a request resolves to exactly one tag, so
    /// "is this row selected" is a set membership test and can no longer disagree
    /// with the pill the row displays. (See TAGS-FILTER.)
    var selectedTagKeys = Set<String>()
    /// Host-scoped endpoint keys ("api.salla.dev/v2/stores/{id}"). Host-scoped
    /// because a path alone collided across hosts: picking an endpoint under one
    /// tag also admitted an identical path served by a different host.
    var selectedEndpoints = Set<String>()
    var searchText: String = ""
    var isGroupedMode: Bool = false
    var isAutoFollowing: Bool = true
    var savedContentOffset: CGPoint = .zero

    // MARK: Body search (BODY-SEARCH)
    //
    // Opt-in, per tab, and per *side*: request bodies and response bodies are
    // two independent scopes, mirroring `ResponseBodySearch.Options`'
    // `searchRequestBodies` / `searchResponseBodies` flags. Nothing is read from
    // disk until the Advanced Search sheet turns a side on — that arms the tab,
    // and scans are then debounced behind typing.
    //
    // A scope being ON means "read this side and merge its hits into the list".

    /// Body search is armed for this tab (auto-scan after the debounce).
    var isBodySearchEnabled: Bool = false
    /// Hits from this side are merged into the result list. Mirrors the
    /// Advanced sheet's two body switches.
    var enabledScopes: Set<BodySearchSide> = []
    /// Sides with a scan in flight — the progress banner is reporting on them.
    var scanningSides: Set<BodySearchSide> = []
    /// The (trimmed) query the counts and matches below belong to. Anything else
    /// in the search field makes them stale.
    var scannedQuery: String = ""
    /// side -> (transactionId -> hit) for the last completed scan of that side.
    var matchesBySide: [BodySearchSide: [String: BodySearchMatch]] = [:]
    /// side -> hit count. nil (absent) means "never scanned for this query",
    /// which is what makes a side count as stale and worth (re)scanning.
    var countsBySide: [BodySearchSide: Int] = [:]
    /// side -> the transaction ids the last completed scan of that side covered.
    ///
    /// A scan is a snapshot of the tab taken when it started, so a request
    /// captured afterwards has no entry in `matchesBySide` and its body hit can
    /// never be merged into the list. This is what lets `scheduleAutoScan` see
    /// that the tab now holds transactions the side has no verdict for.
    var scannedIdsBySide: [BodySearchSide: Set<String>] = [:]
    /// One-line summary of the last scan, reported by the progress banner when
    /// the scan lands.
    var bodySearchSummary: String = ""
    /// Everything from the Advanced Search sheet. Per tab, and sticky across
    /// queries — these are settings, not part of a single search.
    var advanced = AdvancedSearchOptions()

    func isScopeOn(_ side: BodySearchSide) -> Bool { enabledScopes.contains(side) }

    func setScope(_ side: BodySearchSide, on: Bool) {
        if on { enabledScopes.insert(side) } else { enabledScopes.remove(side) }
    }

    func match(for id: String, side: BodySearchSide) -> BodySearchMatch? {
        return matchesBySide[side]?[id]
    }

    /// Drops everything a scan produced (matches, counts, progress) while keeping
    /// the user's chip choices, which are sticky across queries.
    func resetScanResults() {
        scanningSides.removeAll()
        scannedQuery = ""
        matchesBySide.removeAll()
        countsBySide.removeAll()
        scannedIdsBySide.removeAll()
        bodySearchSummary = ""
    }

    /// Full reset, including the scopes — used when body search is disarmed or
    /// the capture store is cleared.
    ///
    /// Clears the Advanced sheet's scope switches too: leaving them on would
    /// make the sheet claim bodies are searched when nothing is. The matching
    /// options (case, media, byte cap) survive — those are preferences, not
    /// part of one search.
    func resetBodySearch() {
        resetScanResults()
        enabledScopes.removeAll()
        advanced.searchResponseBodies = false
        advanced.searchRequestBodies = false
    }
}

class NetworkViewController: UIViewController {

    var reachEnd: Bool = true

    var models: [NetworkTransaction]?
    var cacheModels: [NetworkTransaction]?

    var naviItemTitleLabel: UILabel?

    private var tableView: UITableView!
    private var searchBar: UISearchBar!
    private var deleteItem: UIBarButtonItem!
    /// Tools menu (Compare / Import cURL). Built once and re-used by every
    /// `navigationItem.rightBarButtonItems` assignment.
    private var toolsItem: UIBarButtonItem!

    // Segment tabs
    private var segmentControl: UISegmentedControl!
    private static var savedTab: NetworkTab = .app
    private static var tabStates: [NetworkTab: TabFilterState] = [
        .app: TabFilterState(), .web: TabFilterState(), .pinned: TabFilterState()
    ]
    private var currentTab: NetworkTab = NetworkViewController.savedTab
    private var currentTabState: TabFilterState { Self.tabStates[currentTab]! }

    // Labelled controls under the search field. Same three actions as before —
    // each now says what it does instead of relying on an icon alone.
    private var advancedSearchButton: UIButton!
    private var filterButton: UIButton!
    private var layoutToggleButton: UIButton!
    /// Arms body search (BODY-SEARCH). Default OFF.

    /// Every block-based notification registration this controller makes.
    ///
    /// `NotificationCenter.removeObserver(self)` in `deinit` does **not**
    /// unregister these: the observer of a block registration is the opaque token
    /// the call returns, not `self`. Discarding the token leaks the registration —
    /// one more per debug-UI open, each doing main-thread work on every single
    /// request for the rest of the process's life. The bag holds the tokens and
    /// hands them back on dealloc. (See OBSERVER-LEAK.)
    private let observers = NotificationObserverBag()

    // Body search UI + scan bookkeeping (BODY-SEARCH)
    private var scanBanner: BodySearchProgressBanner?
    private var activeScanToken: BodySearchCancellationToken?
    /// The tab state the in-flight scan belongs to, so cancelling always clears
    /// the right "scanning" flags even after a tab switch.
    private weak var activeScanState: TabFilterState?
    /// Sides still running under `activeScanToken`.
    private var pendingScanSides = 0
    /// side -> transactions completed, for the banner's determinate progress.
    private var scanProgress: [BodySearchSide: Int] = [:]
    private var scanTotal = 0
    /// Typing never scans. This fires once the user pauses.
    private var scanDebounceTimer: Timer?

    /// The query the pending debounce timer was armed for.
    ///
    /// `scheduleAutoScan()` is called from capture as well as from typing, and
    /// re-arming on every captured request pushed the deadline out forever on a
    /// host app with steady background traffic — the scan simply never ran, with
    /// no banner and no explanation.
    private var pendingScanQuery: String?
    private static let scanDebounceInterval: TimeInterval = 0.45
    /// Bumped every time the banner is shown, re-shown or hidden, so a pending
    /// auto-dismiss can tell whether it still owns what is on screen.
    private var bannerGeneration = 0
    /// How long the finished-scan summary stays up before the banner closes.
    private static let bannerResultDuration: TimeInterval = 3.0

    /// Body hit per displayed row (nil = matched on metadata only), index-aligned
    /// with `models`. Built by `applyFilter()`, never read from disk.
    private var rowMatches: [BodySearchMatch?] = []

    // Floating glass header (iOS 26+)
    private var floatingHeader: UIView?
    private var searchRow: UIView!

    // Grouped mode
    private var groupedModels: [NetworkGroup] = []

    // Auto-follow (per-tab, accessed via currentTabState)
    private var followButton: UIButton!
    private static let followButtonSize: CGFloat = 40

    private var isShowingDetail = false

    // Convenience
    private var isAutoFollowing: Bool {
        get { currentTabState.isAutoFollowing }
        set { currentTabState.isAutoFollowing = newValue }
    }

    //MARK: - Helpers

    /// Renders an SF Symbol icon + text into a single template image for UISegmentedControl.
    private static func makeSegmentImage(systemName: String, title: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 13, weight: .medium)
        let symbolConfig = UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 12, weight: .medium))
        let icon = UIImage(systemName: systemName, withConfiguration: symbolConfig)?
            .withTintColor(.black, renderingMode: .alwaysOriginal) ?? UIImage()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let spacing: CGFloat = 4
        let totalWidth = icon.size.width + spacing + textSize.width
        let height = max(icon.size.height, textSize.height)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: height))
        let img = renderer.image { _ in
            icon.draw(at: CGPoint(x: 0, y: (height - icon.size.height) / 2))
            (title as NSString).draw(
                at: CGPoint(x: icon.size.width + spacing, y: (height - textSize.height) / 2),
                withAttributes: attrs
            )
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    /// Whether a transaction is **media** (image/video/audio/font).
    ///
    /// Media responses are routed to the **Media tab** and hidden from the
    /// App/Web network lists so real API traffic isn't drowned out by sprite
    /// sheets, avatars and web fonts. They stay visible on **Pinned** when the
    /// user explicitly pinned them. (See MEDIA-TAB.)
    /// File extensions that identify a media asset straight from the URL.
    /// Checking the path is essential: many CDNs return no/!generic Content-Type,
    /// so MIME alone lets media leak into the App tab.
    private static let mediaPathExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "tif", "heic", "heif", "avif",
        "mp4", "mov", "avi", "m4v", "mkv", "webm", "m3u8", "ts",
        "mp3", "m4a", "wav", "aac", "ogg", "flac",
        "woff", "woff2", "ttf", "otf", "eot",
    ]

    static func isMediaTransaction(_ model: NetworkTransaction) -> Bool {
        if model.isImage { return true }

        // 1. MIME type, when the server gave us a useful one.
        if let mime = model.mineType?.lowercased(), !mime.isEmpty {
            for prefix in ["image/", "video/", "audio/", "font/"] where mime.hasPrefix(prefix) {
                return true
            }
        }

        // 2. URL path extension — works even with no/incorrect Content-Type.
        if let url = model.url as URL? {
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, mediaPathExtensions.contains(ext) { return true }
            // Extensionless CDN URLs sometimes carry the type in the last path
            // component or a query (e.g. ".../image.jpg?w=200" already handled,
            // or ".../format=webp").
            let lower = url.absoluteString.lowercased()
            for ext in mediaPathExtensions where lower.contains(".\(ext)?") || lower.hasSuffix(".\(ext)") {
                return true
            }
        }
        return false
    }

    /// The App/Web tabs show non-media traffic only; Pinned shows everything the
    /// user pinned. Shared by the list, the filter sheet and the endpoint sheet
    /// so a media host can never leak into one of them.
    ///
    /// The two settings flags read here are the DISPLAY half of those switches.
    /// Capture itself is gated at the source — `CustomHTTPProtocol.canInit` for
    /// native traffic, the injected JS for web views — so switching one off now
    /// genuinely stops the SDK touching that traffic rather than just hiding it.
    private func tabModels(from cache: [NetworkTransaction]) -> [NetworkTransaction] {
        switch currentTab {
        case .app:
            return Settings.shared.networkRequestsEnabled
                ? cache.filter { !$0.isWebViewRequest && !Self.isMediaTransaction($0) }
                : []
        case .web:
            return Settings.shared.webNetworkRequestsEnabled
                ? cache.filter { $0.isWebViewRequest && !Self.isMediaTransaction($0) }
                : []
        case .pinned:
            return cache.filter { $0.isPinned }
        }
    }

    /// The rows a body scan may read, and the rows its hits may be rendered on.
    ///
    /// Same tab ownership as `tabModels(from:)` but without the media filter,
    /// for the one case the Advanced sheet promises: "Include media" on, with a
    /// query being matched. Both the scan's candidate list and `applyFilter`'s
    /// row set have to widen together — a media body that is scanned but whose
    /// row is filtered out produces a hit nothing can show.
    ///
    /// Gated on `isSearching` so the toggle widens what the SEARCH reaches and
    /// not what the idle list shows, and `tabModels` itself is untouched: it is
    /// the display filter for the list, the filter sheet and the endpoint sheet.
    private func searchCandidates(from cache: [NetworkTransaction]) -> [NetworkTransaction] {
        guard currentTabState.advanced.includeMedia, isSearching else {
            return tabModels(from: cache)
        }
        switch currentTab {
        case .app:
            return Settings.shared.networkRequestsEnabled
                ? cache.filter { !$0.isWebViewRequest }
                : []
        case .web:
            return Settings.shared.webNetworkRequestsEnabled
                ? cache.filter { $0.isWebViewRequest }
                : []
        case .pinned:
            return cache.filter { $0.isPinned }
        }
    }

    //MARK: - Filter entry building

    /// Every tag that has at least one request in the current tab, with its count.
    ///
    /// Enumerated FROM THE TRAFFIC via `TagResolver`, not assembled from four
    /// overlapping passes over `SwiftyDebug.urls`, the tag table and the host
    /// list. Those passes deduped by a normalised filter key, and that dedup is
    /// what swallowed one of two tags that shared a host — the reported bug.
    /// There is nothing left to swallow: one request resolves to one tag, and
    /// every tag with a request gets a row. (See TAGS-FILTER.)
    private func buildFilterEntries() -> [(tag: NetworkTag, count: Int)] {
        let models = tabModels(from: cacheModels ?? [])
        var entries = TagResolver.tags(forURLStrings: models.compactMap { $0.url?.absoluteString })

        // A tag the user has selected but whose traffic has since been cleared
        // must still render, or the sheet would silently drop a filter that is
        // actively hiding rows.
        let known = Set(entries.map { $0.tag.key })
        for key in currentTabState.selectedTagKeys where !known.contains(key) {
            entries.append((tag: NetworkTag(key: key,
                                            label: Self.orphanedTagLabel(forKey: key),
                                            origin: .derivedHost,
                                            matchedKeyword: ""),
                            count: 0))
        }
        return entries
    }

    /// Display name for a selected tag with no traffic left to name it.
    static func orphanedTagLabel(forKey key: String) -> String {
        for prefix in ["tag:", "url:", "api:", "host:"] where key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }

    /// True when any request in the tab is a webview request carrying `tagKey`.
    /// Drives the "· web" annotation the sheet shows under a row.
    private func tagHasWebTraffic(_ tagKey: String, in models: [NetworkTransaction]) -> Bool {
        models.contains { $0.isWebViewRequest && TagResolver.matches(tagKey: tagKey, url: $0.url) }
    }

    /// The endpoints reachable under the selected tags, one row per distinct
    /// host+endpoint.
    ///
    /// Keyed by HOST and path, not by path alone. The old key was the normalised
    /// path on its own, so a proxy and its origin exposing the same route shared
    /// one row: selecting it under one tag admitted the other host's traffic, and
    /// the second host's row never appeared at all because the dedup had already
    /// claimed the path. (See TAGS-FILTER.)
    private func uniqueEndpointsForFilters(tagKeys: Set<String>) -> [FilterableEndpoint] {
        guard !tagKeys.isEmpty, let allCache = cacheModels else { return [] }
        let models = tabModels(from: allCache)

        var seen = Set<String>()
        var result = [FilterableEndpoint]()
        var webKeys = Set<String>()

        for model in models {
            guard let url = model.url as URL?,
                  let tag = TagResolver.tag(for: url),
                  tagKeys.contains(tag.key) else { continue }

            let normalizedPath = Self.normalizeEndpoint(url.path)
            guard !normalizedPath.isEmpty, normalizedPath != "/" else { continue }

            let host = TagResolver.normalizeHost(url.host ?? "")
            let filterKey = Self.endpointKey(host: host, normalizedPath: normalizedPath)
            if model.isWebViewRequest { webKeys.insert(filterKey) }
            guard seen.insert(filterKey).inserted else { continue }

            result.append(FilterableEndpoint(displayPath: normalizedPath,
                                             filterPath: filterKey,
                                             tag: tag.label))
        }

        // The "· web" annotation is applied after the sweep so it does not depend
        // on whether the webview request happened to be the first one seen.
        return result
            .map { endpoint in
                guard webKeys.contains(endpoint.filterPath) else { return endpoint }
                return FilterableEndpoint(displayPath: endpoint.displayPath,
                                          filterPath: endpoint.filterPath,
                                          tag: endpoint.tag.isEmpty ? "web" : endpoint.tag + " \u{00B7} web")
            }
            .sorted { ($0.tag, $0.displayPath) < ($1.tag, $1.displayPath) }
    }

    /// The identity of one endpoint row. Host-scoped — see
    /// `uniqueEndpointsForFilters`.
    static func endpointKey(host: String, normalizedPath: String) -> String {
        host + normalizedPath
    }

    /// The endpoint key for a captured request, so the list and the predicate
    /// derive it the same way.
    static func endpointKey(for url: URL?) -> String? {
        guard let url else { return nil }
        let normalizedPath = normalizeEndpoint(url.path)
        guard !normalizedPath.isEmpty, normalizedPath != "/" else { return nil }
        return endpointKey(host: TagResolver.normalizeHost(url.host ?? ""),
                           normalizedPath: normalizedPath)
    }

    static func normalizeEndpoint(_ path: String) -> String {
        return EndpointNormalizer.normalize(path)
    }

    //MARK: - Filter logic

    private func applyFilter() {
        guard let cacheModels = cacheModels else {
            models = nil
            groupedModels = []
            rowMatches = []
            return
        }

        let state = currentTabState

        // 1. Tab segment filter (respecting settings toggles). Media requests are
        //    routed to the Media tab and hidden here — except on Pinned, where a
        //    pinned item is always shown, and except while "Include media" is
        //    scanning them, which is the only way a media body's hit can reach a
        //    row (see `searchCandidates`).
        var filtered = searchCandidates(from: cacheModels)

        // 2. Tag filter.
        //
        // "Belongs to the selected tag" is `TagResolver`'s own answer, so the
        // rows kept are exactly the rows showing that pill. The predicate this
        // replaces compared a tag keyword against `absoluteString` — which
        // carries the query string — so selecting a tag for an endpoint like
        // `/1/events` matched nothing at all as soon as the request had
        // `?x-algolia-api-key=…` on it. (See TAGS-FILTER.)
        let tagKeys = state.selectedTagKeys
        let endpoints = state.selectedEndpoints

        if !tagKeys.isEmpty {
            filtered = filtered.filter { model in
                guard let key = TagResolver.tag(for: model.url)?.key else { return false }
                return tagKeys.contains(key)
            }
        }

        // 3. Endpoint filter — host-scoped, derived by the same helper the sheet
        //    lists with.
        if !endpoints.isEmpty {
            filtered = filtered.filter { model in
                guard let key = Self.endpointKey(for: model.url as URL?) else { return false }
                return endpoints.contains(key)
            }
        }

        // 4. Search text — index-backed rich search over URL parts, method,
        //    status, header names, query params and response-derived metadata
        //    (see SEARCH), falling back to a plain URL contains for any model
        //    that predates the index.
        //
        //    Body hits are merged into that SAME list (BODY-SEARCH): a row is
        //    kept when the metadata matched *or* an enabled scope has a hit for
        //    it, and rows keep capture order either way. `rowMatches` carries the
        //    hit that the row should render its extra snippet line from — no
        //    second list, no second section, and no disk read (the scan already
        //    did that once, off the main thread).
        rowMatches = []
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.searchText.isEmpty {
            let raw = state.searchText
            let plain = raw.lowercased()
            let scopes = state.enabledScopes
            let hasFreshScan = !scopes.isEmpty && !query.isEmpty && state.scannedQuery == query

            var kept: [NetworkTransaction] = []
            var keptMatches: [BodySearchMatch?] = []
            for model in filtered {
                var bodyMatch: BodySearchMatch?
                if hasFreshScan {
                    let id = ResponseBodySearch.identifier(for: model)
                    // Response first: when both sides hit, that is the one the
                    // developer is usually reading.
                    if scopes.contains(.response) { bodyMatch = state.match(for: id, side: .response) }
                    if bodyMatch == nil, scopes.contains(.request) {
                        bodyMatch = state.match(for: id, side: .request)
                    }
                }

                let metadataHit: Bool
                if let index = model.searchIndex {
                    metadataHit = index.matches(raw)
                } else {
                    metadataHit = (model.url?.absoluteString ?? "").lowercased().contains(plain)
                }

                guard metadataHit || bodyMatch != nil else { continue }
                kept.append(model)
                keptMatches.append(bodyMatch)
            }
            filtered = kept
            rowMatches = keptMatches
        }

        models = filtered

        // 5. Build groups if in grouped mode
        if state.isGroupedMode {
            groupedModels = buildGroupedModels(from: filtered)
        } else {
            groupedModels = []
        }
    }

    /// Same action, same state (the icon still switches to the `.fill` variant
    /// once a filter is applied) — now with the word "Filter" next to it, and an
    /// active pill so an applied filter is visible without decoding a glyph.
    private func updateFilterButtonIcon() {
        let state = currentTabState
        let hasFilter = !state.selectedTagKeys.isEmpty || !state.selectedEndpoints.isEmpty
        let iconName = hasFilter
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        styleSearchControl(filterButton, icon: iconName, title: "Filter", isActive: hasFilter)
        filterButton.accessibilityLabel = hasFilter ? "Filter, active" : "Filter"
    }

    /// The title names what the tap *does*: "Group" while flat, "List" while
    /// grouped — matching the icon that was already flipping here.
    private func updateLayoutToggleIcon() {
        let grouped = currentTabState.isGroupedMode
        styleSearchControl(
            layoutToggleButton,
            icon: grouped ? "list.bullet" : "square.grid.2x2",
            title: grouped ? "List" : "Group",
            isActive: grouped
        )
    }

    //MARK: - Body search (BODY-SEARCH)
    //
    // The normal list search is index-backed and never touches bodies, because
    // `requestData`/`responseData` are disk-backed (one file read per access).
    // Body search is therefore **opt-in**, and it has exactly one entry point:
    // the **Advanced** button, which opens `AdvancedSearchSheetViewController`
    // with the Response body / Request body switches (plus case sensitivity,
    // whole-body scanning and media inclusion).
    //
    //   1. turning a body switch on arms the tab for that `BodySearchSide`,
    //   2. scans come from `ResponseBodySearch.scan`, run once per side with
    //      only that side's flag set — off the main thread, byte-capped,
    //      cancellable, and memoised per (query, transaction) by BodySearchCache,
    //   3. a scan only starts from an explicit act: flipping a switch in the
    //      sheet, or hitting Search/Return while armed. Typing alone never reads
    //      a body — it just reschedules the debounced rescan for an armed tab.
    //
    // Hits are merged into the same list the metadata search produced — see
    // `applyFilter()` — and those rows render with the normal result card plus
    // one extra snippet line and a REQUEST/RESPONSE badge. While a scan runs the
    // floating progress banner is the in-list feedback; the Advanced button's
    // active pill is what says body search is on at all.

    private func updateAdvancedSearchButton() {
        // "Active" means the search is doing something beyond plain matching, so
        // the developer can tell at a glance why results look unusual.
        let on = currentTabState.advanced != AdvancedSearchOptions()
        styleSearchControl(advancedSearchButton, icon: "slider.horizontal.3",
                           title: "Advanced", isActive: on)
        advancedSearchButton.accessibilityLabel = on
            ? "Advanced search, customised" : "Advanced search"
        advancedSearchButton.accessibilityHint =
            "Double tap to choose what the search looks inside and how it matches"
    }

    /// Opens the Advanced Search sheet. Every toggle applies immediately: options
    /// are part of `ResponseBodySearch.Options.cacheKey`, so a change invalidates
    /// the cached hits and the affected sides are rescanned.
    @objc private func didTapAdvancedSearch() {
        let state = currentTabState
        let sheet = AdvancedSearchSheetViewController(options: state.advanced)
        sheet.onChange = { [weak self] updated in
            guard let self else { return }
            let previous = state.advanced
            state.advanced = updated
            self.applyAdvancedSearchChange(from: previous, to: updated, state: state)
        }
        let nav = SwiftyDebugNavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Reconciles the list with a change made in the Advanced sheet.
    private func applyAdvancedSearchChange(from previous: AdvancedSearchOptions,
                                           to updated: AdvancedSearchOptions,
                                           state: TabFilterState) {
        updateAdvancedSearchButton()

        // The sheet's two body switches ARE the scopes — keep them in step.
        state.setScope(.response, on: updated.searchResponseBodies)
        state.setScope(.request, on: updated.searchRequestBodies)

        guard updated.searchesAnyBody else {
            disarmBodySearch()
            return
        }
        state.isBodySearchEnabled = true

        // Anything that changes HOW bodies are read invalidates every count we
        // hold; only the scope switches can reuse them.
        let matchingRulesChanged = previous.caseSensitive != updated.caseSensitive
            || previous.includeMedia != updated.includeMedia
            || previous.scanWholeBodies != updated.scanWholeBodies
        if matchingRulesChanged { state.resetScanResults() }

        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let stale = BodySearchSide.allCases.filter {
            state.isScopeOn($0) && (state.scannedQuery != query || state.countsBySide[$0] == nil)
        }
        if stale.isEmpty {
            applyFilter()
            tableView.reloadData()
        } else {
            startBodySearch(query: query, sides: stale)
        }
    }

    /// Turns body scanning off for this tab and returns the list to the
    /// index-backed view. Called when the Advanced sheet's last body switch goes
    /// off — "armed but no scope chosen" is a state that would scan nothing.
    private func disarmBodySearch() {
        let state = currentTabState
        state.isBodySearchEnabled = false
        cancelActiveScan()
        cancelPendingAutoScan()
        state.resetBodySearch()
        updateAdvancedSearchButton()
        applyFilter()
        tableView.reloadData()
    }

    /// Called on `.allLogsCleared`: every transaction id the hits point at is
    /// gone, so all tabs are reset.
    private func discardAllBodyResults() {
        cancelActiveScan()
        cancelPendingAutoScan()
        for (_, state) in Self.tabStates { state.resetBodySearch() }
        applyFilter()
        tableView.reloadData()
    }

    /// A query is active, so every row renders as a search result card (match
    /// snippet + REQUEST/RESPONSE badge) instead of the plain capture row.
    /// Trimmed, so a field holding only spaces is not "searching".
    private var isSearching: Bool {
        return !currentTabState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Scan lifecycle

    /// Debounced auto-scan. Only ever scheduled while the tab is armed, and only
    /// for sides that have no fresh count — a repeat query costs nothing.
    /// Cancels any pending debounced scan.
    private func cancelPendingAutoScan() {
        scanDebounceTimer?.invalidate()
        scanDebounceTimer = nil
        pendingScanQuery = nil
    }

    private func scheduleAutoScan() {
        let state = currentTabState
        guard state.isBodySearchEnabled else { cancelPendingAutoScan(); return }
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { cancelPendingAutoScan(); return }

        // A timer already pending for THIS query keeps its deadline. Typing
        // changes the query on every keystroke, so the typing debounce is
        // unaffected; a capture arriving with the query unchanged no longer
        // resets the clock.
        if scanDebounceTimer?.isValid == true, pendingScanQuery == query { return }

        cancelPendingAutoScan()
        pendingScanQuery = query

        scanDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scanDebounceInterval, repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            self.scanDebounceTimer = nil
            self.pendingScanQuery = nil
            let state = self.currentTabState
            let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.isBodySearchEnabled, query.count >= 2 else { return }

            let currentIds = Set(
                self.searchCandidates(from: self.cacheModels ?? []).map(ResponseBodySearch.identifier(for:))
            )
            let sides: [BodySearchSide] = BodySearchSide.allCases.filter { side in
                // Armed scopes only. This is reached from a tab switch and from
                // capture as well as from typing, and scanning a side the user
                // never turned on reads that side's bodies off disk and pops the
                // progress banner for a scope the list ignores.
                guard state.isScopeOn(side) else { return false }
                if state.scannedQuery != query || state.countsBySide[side] == nil { return true }
                // The scan only ever saw the tab as it was when it started, so a
                // transaction captured since has no verdict and its hit could
                // never be merged. Anything it did not cover makes the side
                // stale again; the (query, transaction) cache makes the rescan
                // cost only the genuinely new bodies.
                return !(state.scannedIdsBySide[side] ?? []).isSuperset(of: currentIds)
            }
            guard !sides.isEmpty else { return }
            // A rescan the USER did not ask for — the query is unchanged and the
            // side already has counts, so it is stale only because a new request
            // arrived — runs silently. Under steady traffic this fires once a
            // second, and tearing down and re-showing the banner over the list
            // (plus a full reload) every time made the results unreadable.
            let silent = sides.allSatisfy { side in
                state.scannedQuery == query && state.countsBySide[side] != nil
            }
            self.startBodySearch(query: query, sides: sides, silent: silent)
        }
    }

    /// One `ResponseBodySearch.scan` per side, each with only that side's flag
    /// set, so the two counts are genuinely independent.
    private func startBodySearch(query rawQuery: String,
                                 sides rawSides: [BodySearchSide],
                                 silent: Bool = false) {
        let state = currentTabState
        // The scope filter belongs here, not at the callers: Return and the
        // debounced auto-scan both ask for both sides unconditionally, and a
        // scan of a side the user never armed reads every body of that side off
        // disk and then overwrites the banner's summary with its own numbers.
        let sides = rawSides.filter { state.isScopeOn($0) }
        guard SwiftyDebugRuntime.isActive, !sides.isEmpty else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // A different query invalidates every count and hit we hold.
        if state.scannedQuery != query { state.resetScanResults() }

        cancelActiveScan()

        // Snapshot of the current tab's transactions — the scan never touches the
        // live store, so new captures can keep arriving while it runs.
        let candidates = searchCandidates(from: cacheModels ?? [])
        let candidateIds = Set(candidates.map(ResponseBodySearch.identifier(for:)))
        guard !candidates.isEmpty else {
            state.scannedQuery = query
            for side in sides {
                state.countsBySide[side] = 0
                state.scannedIdsBySide[side] = []
            }
            state.bodySearchSummary = "Nothing to scan on this tab."
            return
        }

        let token = BodySearchCancellationToken()
        activeScanToken = token
        activeScanState = state
        pendingScanSides = sides.count
        scanProgress = [:]
        scanTotal = candidates.count * sides.count
        state.scanningSides = Set(sides)
        if !silent { showScanBanner(total: scanTotal) }

        for side in sides {
            ResponseBodySearch.scan(
                transactions: candidates,
                query: query,
                options: state.advanced.engineOptions(for: side),
                token: token,
                progress: { [weak self] done, _ in
                    guard let self = self, self.activeScanToken === token else { return }
                    self.scanProgress[side] = done
                    self.scanBanner?.update(
                        done: self.scanProgress.values.reduce(0, +), total: self.scanTotal
                    )
                },
                completion: { [weak self] outcome in
                    guard let self = self, self.activeScanToken === token else { return }
                    self.finishScan(outcome, side: side, query: query, state: state,
                                    scannedIds: candidateIds, silent: silent)
                }
            )
        }
    }

    private func cancelActiveScan() {
        activeScanToken?.cancel()
        activeScanToken = nil
        activeScanState?.scanningSides.removeAll()
        activeScanState = nil
        pendingScanSides = 0
        scanProgress = [:]
        // The banner is the only thing claiming a scan is running, so it has to
        // go the moment the scan dies — including when its own Cancel killed it.
        hideScanBanner()
    }

    private func finishScan(_ outcome: ResponseBodySearch.Outcome,
                            side: BodySearchSide,
                            query: String,
                            state: TabFilterState,
                            scannedIds: Set<String>,
                            silent: Bool = false) {
        state.scanningSides.remove(side)
        pendingScanSides -= 1
        let isLastSide = pendingScanSides <= 0
        if isLastSide {
            activeScanToken = nil
            activeScanState = nil
        }

        guard !outcome.wasCancelled else {
            if isLastSide { hideScanBanner() }
            return
        }

        state.scannedQuery = query
        state.matchesBySide[side] = Dictionary(
            outcome.matches.map { ($0.transactionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        state.countsBySide[side] = outcome.matches.count
        // What this snapshot covered, so a later capture can be recognised as
        // unscanned instead of silently missing from the merged list.
        state.scannedIdsBySide[side] = scannedIds
        // The cap actually used, not the default: "Scan whole bodies" lifts it,
        // and a summary that still announced "first 2 MB each" read as the
        // toggle having been ignored.
        state.bodySearchSummary = Self.summaryText(
            for: outcome,
            byteCap: state.advanced.engineOptions(for: side).byteCap
        )

        // With every side done, the banner stops reporting progress and reports
        // the result instead — the per-side hit counts used to live on the
        // inline scope card, and this is now the only place they surface.
        if isLastSide, !silent { showScanResultInBanner(for: state) }
        if isLastSide, silent { hideScanBanner() }

        // Keep the user's place. A rescan that lands while they are reading
        // results must not scroll the list out from under them.
        let offset = tableView.contentOffset
        applyFilter()
        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
        }
        let maxY = max(0, tableView.contentSize.height - tableView.bounds.height
                          + tableView.adjustedContentInset.bottom)
        tableView.contentOffset = CGPoint(x: offset.x, y: min(offset.y, maxY))
    }

    /// Per-side hit counts for the query the scan just finished, e.g.
    /// "Response body 4 · Request body 0".
    private func scanCountsText(for state: TabFilterState) -> String {
        let parts: [String] = [BodySearchSide.response, .request].compactMap { side in
            guard state.isScopeOn(side), let count = state.countsBySide[side] else { return nil }
            let name = side == .response ? "Response body" : "Request body"
            return "\(name) \(count)"
        }
        return parts.isEmpty ? "Scan finished" : parts.joined(separator: " \u{00B7} ")
    }

    private static func summaryText(for outcome: ResponseBodySearch.Outcome,
                                    byteCap: Int) -> String {
        var parts: [String] = ["\(outcome.scannedCount) bodies read"]
        if outcome.cacheHitCount > 0 { parts.append("\(outcome.cacheHitCount) cached") }
        if outcome.skippedCount > 0 { parts.append("\(outcome.skippedCount) skipped") }
        if outcome.truncatedCount > 0 { parts.append("\(outcome.truncatedCount) capped") }
        parts.append(byteCap == .max
                     ? "whole bodies"
                     : "first \(ResponseBodySearch.byteCapDescription) each")
        return parts.joined(separator: " · ")
    }

    // MARK: Progress banner

    private func showScanBanner(total: Int) {
        let banner = scanBanner ?? {
            let created = BodySearchProgressBanner()
            created.translatesAutoresizingMaskIntoConstraints = false
            created.onCancel = { [weak self] in self?.cancelActiveScan() }
            view.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                created.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                created.bottomAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -(Self.followButtonSize + 20)
                ),
            ])
            created.forceLTR()
            scanBanner = created
            return created
        }()
        // Any auto-dismiss scheduled by a previous scan's result must not close
        // the banner this scan just re-opened.
        bannerGeneration &+= 1
        view.bringSubviewToFront(banner)
        banner.isHidden = false
        banner.update(done: 0, total: total)
    }

    /// Flips the banner from "scanning" to the result of the scan, then closes
    /// it on its own so it never sits on top of the results the user came for.
    private func showScanResultInBanner(for state: TabFilterState) {
        guard let banner = scanBanner, !banner.isHidden else { return }
        bannerGeneration &+= 1
        let generation = bannerGeneration
        banner.showResult(counts: scanCountsText(for: state), detail: state.bodySearchSummary)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerResultDuration) { [weak self] in
            guard let self = self, self.bannerGeneration == generation else { return }
            self.hideScanBanner()
        }
    }

    private func hideScanBanner() {
        bannerGeneration &+= 1
        scanBanner?.isHidden = true
    }

    //MARK: - Grouped models

    /// Groups the visible rows by their resolved tag.
    ///
    /// One pass over the traffic, grouping by `NetworkTag.key`, rather than two
    /// passes (allow-list URLs, then leftover hosts) with two different matchers.
    /// Because the grouping key IS the tag, a group header, the pills inside it
    /// and the filter sheet row all name the same thing. (See TAGS-FILTER.)
    private func buildGroupedModels(from models: [NetworkTransaction]) -> [NetworkGroup] {
        var order: [String] = []
        var byKey: [String: (tag: NetworkTag, models: [NetworkTransaction])] = [:]

        for model in models {
            guard let tag = TagResolver.tag(for: model.url) else { continue }
            if byKey[tag.key] == nil {
                order.append(tag.key)
                byKey[tag.key] = (tag: tag, models: [])
            }
            byKey[tag.key]!.models.append(model)
        }

        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            // The subtitle describes the GROUP, not the first row in it.
            //
            // `matchedKeyword` is what the tag matched, and for a catalog or
            // user tag that is one member's own host — so a group spanning
            // several hosts was labelled with whichever of them happened to be
            // captured first, and the header changed between launches. An
            // allow-list or host-derived tag IS the group's identity, so those
            // keep it.
            let subtitle: String
            switch entry.tag.origin {
            case .allowListURL, .derivedHost:
                subtitle = entry.tag.matchedKeyword
            case .knownAPI, .userTag:
                let hosts = Set(entry.models.compactMap {
                    $0.url?.host.map(TagResolver.normalizeHost)
                })
                subtitle = hosts.count == 1 ? (hosts.first ?? entry.tag.matchedKeyword)
                                            : "\(hosts.count) hosts"
            }
            return NetworkGroup(key: key,
                                displayName: entry.tag.label,
                                fullURL: subtitle,
                                tag: entry.tag.label,
                                isPathFilter: entry.tag.origin == .userTag,
                                count: entry.models.count,
                                models: entry.models)
        }
    }

    //MARK: - Filter UI

    @objc func didTapFilter() {
        let entries = buildFilterEntries()
        let tabbedModels = tabModels(from: cacheModels ?? [])

        let state = currentTabState
        let sheet = NetworkFilterSheetController()
        sheet.entries = entries.map { entry in
            NetworkFilterSheetController.Row(tag: entry.tag,
                                             count: entry.count,
                                             isWeb: tagHasWebTraffic(entry.tag.key, in: tabbedModels))
        }
        sheet.tempTagKeys = state.selectedTagKeys
        sheet.tempEndpoints = state.selectedEndpoints

        sheet.endpointProvider = { [weak self, weak sheet] in
            guard let self = self, let sheet = sheet else { return [] }
            return self.uniqueEndpointsForFilters(tagKeys: sheet.tempTagKeys)
        }

        sheet.onApply = { [weak self] tagKeys, endpoints in
            guard let self = self else { return }
            let s = self.currentTabState
            s.selectedTagKeys = tagKeys
            s.selectedEndpoints = endpoints
            self.applyFilter()
            self.updateFilterButtonIcon()
            self.tableView.reloadData()
        }

        sheet.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let sheetPC = sheet.sheetPresentationController {
                sheetPC.detents = [.medium(), .large()]
            }
        }
        present(sheet, animated: true)
    }

    //MARK: - private
    func reloadHttp() {
        // `snapshot()` copies under the store's lock. Bridging the store's live
        // NSMutableArray here instead enumerated it on the main thread while the
        // URLProtocol threads were still adding to it — "Collection was mutated
        // while being enumerated", in the host app, just for having this screen open.
        self.models = NetworkRequestStore.shared.snapshot()
        self.cacheModels = self.models

        applyFilter()

        // The finished scan only knows the transactions it was handed, so a
        // request captured after it landed can never contribute a body hit —
        // its row silently loses its snippet, and drops out of the list
        // entirely when its URL alone does not match. The debounce coalesces
        // bursts and the (query, transaction) cache means the rescan reads only
        // the genuinely new bodies; on an unarmed tab this is a no-op.
        scheduleAutoScan()

        if isAutoFollowing && !isShowingDetail {
            self.tableView.reloadData()
            if self.tableView.window != nil {
                self.tableView.layoutIfNeeded()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let actualCount = self.tableView.numberOfRows(inSection: 0)
                guard actualCount > 0 else { return }
                let lastIndexPath = IndexPath(row: actualCount - 1, section: 0)
                self.tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: false)
            }
        } else {
            let savedOffset = self.tableView.contentOffset
            UIView.performWithoutAnimation {
                self.tableView.reloadData()
                if self.tableView.window != nil {
                    self.tableView.layoutIfNeeded()
                }
                self.tableView.contentOffset = savedOffset
            }
        }
    }

    //MARK: - init
    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()

        let tap = UITapGestureRecognizer.init(target: self, action: #selector(didTapView))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        naviItemTitleLabel = UILabel.init(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        naviItemTitleLabel?.textAlignment = .center
        naviItemTitleLabel?.textColor = DebugTheme.accentColor
        naviItemTitleLabel?.font = .boldSystemFont(ofSize: 20)
        navigationItem.titleView = naviItemTitleLabel
        naviItemTitleLabel?.text = "\u{1f680}[0]"

        // Nav bar buttons: trash + tools menu (Compare / Import cURL).
        deleteItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(tapTrashButton(_:)))
        deleteItem.tintColor = DebugTheme.accentColor

        toolsItem = UIBarButtonItem(
            image: UIImage(systemName: "wrench.and.screwdriver"),
            menu: makeToolsMenu()
        )
        toolsItem.tintColor = DebugTheme.accentColor
        toolsItem.accessibilityLabel = "Network tools"

        // Single owner of `rightBarButtonItems` — see `updateNavigationItems()`.
        updateNavigationItems()

        // Paused-requests button — only visible while something is actually on
        // hold at a breakpoint, so held requests are impossible to miss.
        // (See BREAKPOINTS.)
        observers.add(forName: .breakpointsDidChange) { [weak self] _ in
            self?.refreshBreakpointBadge()
        }
        refreshBreakpointBadge()

        // Search bar styling
        searchBar.searchBarStyle = .minimal
        searchBar.barTintColor = .clear
        searchBar.isTranslucent = true
        searchBar.tintColor = DebugTheme.accentColor
        searchBar.backgroundImage = UIImage()

        let tf = searchBar.searchTextField
        tf.textColor = .white
        tf.font = .systemFont(ofSize: 14, weight: .regular)
        tf.layer.cornerRadius = 10
        tf.layer.masksToBounds = true

        if floatingHeader != nil {
            // Glass header: fully clear so liquid glass shows through
            tf.backgroundColor = .clear
            tf.layer.borderWidth = 0
        } else {
            tf.backgroundColor = UIColor(white: 0.11, alpha: 1)
            tf.layer.borderWidth = 1
            tf.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        }
        tf.attributedPlaceholder = NSAttributedString(
            string: "Search URL, header:, status:, param:…",
            attributes: [.foregroundColor: UIColor(white: 0.4, alpha: 1)]
        )
        tf.leftView?.tintColor = UIColor(white: 0.4, alpha: 1)

        // Keyboard dismiss toolbar
        let kbToolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        kbToolbar.barTintColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        kbToolbar.isTranslucent = false
        kbToolbar.clipsToBounds = true
        let kbChevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        kbToolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: kbChevron, style: .plain, target: self, action: #selector(dismissKeyboard))
        ]
        kbToolbar.items?.last?.tintColor = UIColor(white: 0.6, alpha: 1)
        tf.inputAccessoryView = kbToolbar

        searchBar.delegate = self

        // Restore saved state from previous debug VC session
        searchBar.text = currentTabState.searchText.isEmpty ? nil : currentTabState.searchText

        // Hide filter/layout on Pinned tab
        let isPinned = currentTab == .pinned
        filterButton.isHidden = isPinned
        layoutToggleButton.isHidden = isPinned

        updateFilterButtonIcon()
        updateLayoutToggleIcon()
        updateAdvancedSearchButton()

        //notification
        observers.add(forName: .networkRequestCompleted) { [weak self] _ in
            self?.reloadHttp()
        }

        // A clear wipes every transaction id the body-search results point at, so
        // drop the parked results (the shared BodySearchCache clears itself too).
        observers.add(forName: .allLogsCleared) { [weak self] _ in
            guard let self = self else { return }
            self.discardAllBodyResults()
            // ...and then re-read the store. A clear performed anywhere else —
            // the App tab's "Clear Pinned Requests", which deletes the pinned
            // models AND their files — otherwise left `cacheModels` holding them,
            // so the Pinned tab kept rendering rows for requests that no longer
            // existed in memory or on disk, and tapping one opened a detail
            // screen for an already-erased body. Nothing corrected it until an
            // unrelated request happened to complete.
            self.reloadHttp()
        }

        tableView.tableFooterView = UIView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.register(NetworkCell.self, forCellReuseIdentifier: "NetworkCell")
        tableView.register(NetworkGroupCell.self, forCellReuseIdentifier: "NetworkGroupCell")
        tableView.register(NetworkSearchResultCell.self, forCellReuseIdentifier: NetworkSearchResultCell.reuseId)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        if floatingHeader == nil {
            tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        } else {
            tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        }
        tableView.showsVerticalScrollIndicator = false

        // Always start at bottom with auto-follow enabled when debug VC opens
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: false)

        reloadHttp()
        view.forceLTR()
    }

    /// Re-applies the filter whenever this tab is shown again.
    ///
    /// The settings that gate this list live on a SIBLING tab, and the tab bar
    /// keeps one long-lived `NetworkViewController`. Nothing re-ran `applyFilter`
    /// on return, so flipping "Network Requests" and walking back left the list
    /// showing whatever it had — and once an unrelated request emptied it, an
    /// idle app left it blank indefinitely with the switch reading ON.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Returning from a pushed detail screen must not move the list. This runs
        // on every appearance, including that one, and an unconditional reload
        // threw away the scroll position the user came back to.
        let offset = tableView.contentOffset
        applyFilter()
        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
        }
        let maxY = max(0, tableView.contentSize.height - tableView.bounds.height
                          + tableView.adjustedContentInset.bottom)
        // Clamp the LOW end to the top content inset, not to 0: a list sitting
        // at the top has a negative offset.y equal to that inset, and clamping
        // it to 0 pulled the list up under the search bar on every return from a
        // detail screen.
        tableView.contentOffset = CGPoint(
            x: offset.x,
            y: min(max(-tableView.adjustedContentInset.top, offset.y), maxY))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isShowingDetail {
            // Returning from detail — don't scroll, just clear flag
            isShowingDetail = false
            return
        }
    }

    private func setupUI() {
        view.backgroundColor = .black

        // --- Create shared elements ---
        createSegmentControl()
        createSearchRow()
        createTableView()
        createFollowButton()

        // --- Layout: iOS 26+ floating glass header vs legacy stacked ---
        if #available(iOS 26, *) {
            setupFloatingGlassLayout()
        } else {
            setupLegacyLayout()
        }
    }

    private func createSegmentControl() {
        segmentControl = UISegmentedControl(items: [
            Self.makeSegmentImage(systemName: "iphone", title: "App"),
            Self.makeSegmentImage(systemName: "globe", title: "Web"),
            Self.makeSegmentImage(systemName: "pin.fill", title: "Pinned"),
        ])
        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        segmentControl.selectedSegmentIndex = currentTab.rawValue
        segmentControl.selectedSegmentTintColor = DebugTheme.accentColor
        segmentControl.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
        ], for: .normal)
        segmentControl.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        ], for: .selected)
        segmentControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
    }

    /// Search field on top, the three controls on their own row underneath.
    ///
    /// The controls used to be three unlabelled glyphs squeezed in beside the
    /// field; three *labelled* controls plus a usable field do not fit on a
    /// phone, so they get their own row. Every action and every state is
    /// unchanged — only the wording is new.
    private func createSearchRow() {
        searchRow = UIView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        searchBar = UISearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchBar)

        // Body search has no control of its own: "Advanced" owns it, together
        // with the rest of the search options, so the results list stays nothing
        // but results. (See BODY-SEARCH.)
        advancedSearchButton = makeSearchControl(action: #selector(didTapAdvancedSearch))
        filterButton = makeSearchControl(action: #selector(didTapFilter))
        layoutToggleButton = makeSearchControl(action: #selector(didTapLayoutToggle))

        // A stack collapses whatever is hidden (the Pinned tab hides two of the
        // three) instead of leaving a gap.
        let controlsRow = UIStackView(arrangedSubviews: [advancedSearchButton, filterButton, layoutToggleButton])
        controlsRow.axis = .horizontal
        controlsRow.alignment = .center
        controlsRow.spacing = 8
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(controlsRow)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: searchRow.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 44),

            controlsRow.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 2),
            controlsRow.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 10),
            controlsRow.trailingAnchor.constraint(lessThanOrEqualTo: searchRow.trailingAnchor, constant: -10),
            controlsRow.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            controlsRow.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// Icon + word, in a pill that can also read as "active".
    private func makeSearchControl(action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12, weight: .semibold)
            return attributes
        }
        button.configuration = config

        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 1
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func styleSearchControl(_ button: UIButton, icon: String, title: String, isActive: Bool) {
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.title = title
        config.baseForegroundColor = isActive ? .black : DebugTheme.accentColor
        button.configuration = config
        button.backgroundColor = isActive ? DebugTheme.accentColor : UIColor(white: 0.16, alpha: 1)
        button.layer.borderColor = isActive
            ? DebugTheme.accentColor.cgColor
            : UIColor(white: 0.28, alpha: 1).cgColor
    }

    private func createTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func createFollowButton() {
        let btnSize = Self.followButtonSize
        followButton = UIButton(type: .system)
        followButton.translatesAutoresizingMaskIntoConstraints = false
        followButton.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        followButton.layer.cornerRadius = btnSize / 2
        followButton.clipsToBounds = true
        followButton.layer.borderWidth = 1
        followButton.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        followButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: chevronConfig), for: .normal)
        followButton.tintColor = DebugTheme.accentColor
        followButton.alpha = 0
        followButton.addTarget(self, action: #selector(followButtonTapped), for: .touchUpInside)
    }

    // MARK: - iOS 26+ Floating Glass Layout

    @available(iOS 26, *)
    private func setupFloatingGlassLayout() {
        // Table view goes first (behind everything)
        tableView.contentInsetAdjustmentBehavior = .never
        view.addSubview(tableView)

        // Floating glass header
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 16
        glass.layer.cornerCurve = .continuous
        floatingHeader = glass
        view.addSubview(glass)

        // Add segment + search row inside glass contentView
        let content = glass.contentView
        segmentControl.backgroundColor = .clear
        content.addSubview(segmentControl)
        searchRow.backgroundColor = .clear
        content.addSubview(searchRow)

        // Follow button on top
        view.addSubview(followButton)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            // Table view: full screen (scrolls under glass nav bar + header)
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Glass header: floats at top
            glass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            // Segment inside glass
            segmentControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            segmentControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            segmentControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            segmentControl.heightAnchor.constraint(equalToConstant: 32),

            // Search row inside glass (height comes from the field + control row)
            searchRow.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            searchRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            // Follow button
            followButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            followButton.widthAnchor.constraint(equalToConstant: btnSize),
            followButton.heightAnchor.constraint(equalToConstant: btnSize),
        ])
    }

    // MARK: - Legacy Layout (< iOS 26)

    private func setupLegacyLayout() {
        segmentControl.backgroundColor = UIColor(white: 0.15, alpha: 1)
        searchRow.backgroundColor = .black
        view.addSubview(segmentControl)
        view.addSubview(searchRow)
        view.addSubview(tableView)
        view.addSubview(followButton)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            // Segment control
            segmentControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            segmentControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            segmentControl.heightAnchor.constraint(equalToConstant: 32),

            // Search row (height comes from the field + control row)
            searchRow.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),

            // Table view
            tableView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Follow button
            followButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            followButton.widthAnchor.constraint(equalToConstant: btnSize),
            followButton.heightAnchor.constraint(equalToConstant: btnSize),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = floatingHeader {
            let topInset = header.frame.maxY + 8
            let bottomInset = view.safeAreaInsets.bottom + Self.followButtonSize + 12
            if tableView.contentInset.top != topInset || tableView.contentInset.bottom != bottomInset {
                tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
                tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topInset, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
            }
        }
    }

    deinit {
        activeScanToken?.cancel()
        cancelPendingAutoScan()
        // Selector-based registrations only. The block-based ones are the bag's,
        // and it unregisters them when it deallocates with this controller.
        NotificationCenter.default.removeObserver(self)
    }

    //MARK: - Navigation bar items

    /// The **only** place `navigationItem.rightBarButtonItems` is assigned.
    ///
    /// It used to be written from three sites (viewDidLoad plus both branches of
    /// the breakpoint badge), so anything added to one of them vanished the next
    /// time a breakpoint fired. Everything that wants to change the bar now goes
    /// through here.
    private func updateNavigationItems() {
        var items: [UIBarButtonItem] = [deleteItem, toolsItem]

        // "N paused" appears only while requests are actually held at a
        // breakpoint (the app is genuinely waiting on them). (See BREAKPOINTS.)
        let paused = BreakpointCenter.shared.count
        if paused > 0 {
            let item = UIBarButtonItem(
                title: "⏸ \(paused)", style: .plain,
                target: self, action: #selector(openPausedRequests))
            item.tintColor = .systemOrange
            item.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .normal)
            item.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .highlighted)
            items.append(item)
        }

        navigationItem.rightBarButtonItems = items
    }

    //MARK: - Breakpoints

    private func refreshBreakpointBadge() {
        updateNavigationItems()
    }

    @objc private func openPausedRequests() {
        let inbox = BreakpointInboxViewController()
        navigationController?.pushViewController(inbox, animated: true)
    }

    //MARK: - Tools menu (compare + cURL import)

    /// Action handlers read the capture store when they run, so one menu built
    /// at load time always operates on the current traffic.
    private func makeToolsMenu() -> UIMenu {
        let compare = UIAction(
            title: "Compare Requests…",
            image: UIImage(systemName: "arrow.left.arrow.right")
        ) { [weak self] _ in
            self?.openRequestDiffPicker()
        }
        let importCurl = UIAction(
            title: "Import cURL…",
            image: UIImage(systemName: "terminal")
        ) { [weak self] _ in
            self?.openCurlImport()
        }
        return UIMenu(title: "Tools", children: [compare, importCurl])
    }

    /// Pick two requests, then diff them.
    private func openRequestDiffPicker() {
        // Newest first: the request you just watched land is the one you want to
        // compare against.
        let candidates = Array(tabModels(from: cacheModels ?? []).reversed())
        guard candidates.count >= 2 else {
            showToolsAlert(
                title: "Nothing to compare",
                message: "Capture at least two requests on this tab first."
            )
            return
        }
        let picker = RequestDiffPickerViewController(transactions: candidates)
        isShowingDetail = true
        navigationController?.pushViewController(picker, animated: true)
    }

    /// Paste a cURL command to replay it or turn it into an intercept rule.
    /// Presented modally so the importer owns the keyboard and the full height.
    private func openCurlImport() {
        let importer = CurlImportViewController()
        let nav = SwiftyDebugNavigationController(rootViewController: importer)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func showToolsAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    //MARK: - target action
    @objc func tapTrashButton(_ sender: UIBarButtonItem) {
        NetworkRequestStore.shared.reset()

        // Reload from store so pinned requests remain visible
        let remaining = NetworkRequestStore.shared.snapshot()
        cacheModels = remaining
        groupedModels = []
        // DO NOT clear filters — they persist across clears
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: false)

        applyFilter()
        self.tableView.reloadData()

        let pinnedCount = remaining.count
        self.naviItemTitleLabel?.text = "\u{1f680}[\(pinnedCount)]"

        NotificationCenter.default.post(name: .allLogsCleared, object: nil, userInfo: ["pinnedCount": pinnedCount])
    }

    @objc func didTapView() {
        view.endEditing(true)
    }

    @objc private func dismissKeyboard() {
        searchBar.resignFirstResponder()
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        // Save current tab's scroll position
        let oldState = currentTabState
        oldState.savedContentOffset = tableView.contentOffset

        // A scan belongs to the tab it was started on — leaving the tab cancels it.
        cancelActiveScan()
        cancelPendingAutoScan()

        currentTab = NetworkTab(rawValue: sender.selectedSegmentIndex) ?? .app
        NetworkViewController.savedTab = currentTab
        let newState = currentTabState

        searchBar.text = newState.searchText
        updateLayoutToggleIcon()
        updateFilterButtonIcon()
        updateAdvancedSearchButton()

        // Hide filter/layout buttons on Pinned tab (not relevant there)
        let isPinned = currentTab == .pinned
        filterButton.isHidden = isPinned
        layoutToggleButton.isHidden = isPinned

        applyFilter()
        tableView.reloadData()
        tableView.layoutIfNeeded()

        // Leaving a tab cancelled its scan above, which left `scannedQuery`
        // empty while the scopes and the Advanced pill still claimed body
        // search was on. Nothing else re-armed it, so the tab sat with dead
        // scopes until the query was retyped.
        scheduleAutoScan()

        // Restore new tab's scroll position & follow state
        if newState.isAutoFollowing {
            let count = tableView.numberOfRows(inSection: 0)
            if count > 0 {
                let last = IndexPath(row: count - 1, section: 0)
                tableView.scrollToRow(at: last, at: .bottom, animated: false)
            }
            setFollowButtonVisible(false, animated: false)
        } else {
            tableView.contentOffset = newState.savedContentOffset
            setFollowButtonVisible(true, animated: false)
        }
    }

    @objc private func didTapLayoutToggle() {
        currentTabState.isGroupedMode.toggle()
        updateLayoutToggleIcon()
        applyFilter()
        tableView.reloadData()

        // When switching to list mode, start at bottom with auto-follow
        if !currentTabState.isGroupedMode {
            isAutoFollowing = true
            setFollowButtonVisible(false, animated: false)
            tableView.layoutIfNeeded()
            let count = tableView.numberOfRows(inSection: 0)
            if count > 0 {
                let last = IndexPath(row: count - 1, section: 0)
                tableView.scrollToRow(at: last, at: .bottom, animated: false)
            }
        }
    }

    // MARK: - Follow button

    @objc private func followButtonTapped() {
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        let count = tableView.numberOfRows(inSection: 0)
        if count > 0 {
            let lastIndexPath = IndexPath(row: count - 1, section: 0)
            tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: false)
        }
    }

    private func setFollowButtonVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard followButton.alpha != target else { return }
        if animated {
            UIView.animate(withDuration: 0.25) {
                self.followButton.alpha = target
            }
        } else {
            followButton.alpha = target
        }
    }

    private func checkIfScrolledToBottom() {
        let offset = tableView.contentOffset.y
        let visibleHeight = tableView.bounds.height
        let contentHeight = tableView.contentSize.height
        let bottomInset = tableView.contentInset.bottom

        if offset + visibleHeight + bottomInset >= contentHeight - 60 {
            isAutoFollowing = true
            setFollowButtonVisible(false, animated: true)
        }
    }
}

//MARK: - UISearchBarDelegate
extension NetworkViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let state = currentTabState
        state.searchText = searchText
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typing never reads a body. It only drops hits that belonged to another
        // query — the chosen scopes are deliberately sticky.
        if state.scannedQuery != query, !state.scannedQuery.isEmpty {
            cancelActiveScan()
            state.resetScanResults()
        }

        // Symmetric, because clearing the field with its own clear button or by
        // backspacing goes through here and nowhere else — these search bars are
        // built by hand rather than by a `UISearchController`, so there is no
        // Cancel button and `searchBarCancelButtonClicked` never fires. A
        // one-sided `if` left auto-follow off and the chevron on screen for a
        // list that was no longer filtered at all.
        if !searchText.isEmpty {
            isAutoFollowing = false
            setFollowButtonVisible(true, animated: true)
        } else {
            isAutoFollowing = true
            setFollowButtonVisible(false, animated: true)
        }
        applyFilter()
        tableView.reloadData()

        // Following again only means "stick to the bottom from the next request
        // on", so without this the restored list stays parked wherever the
        // filtered one left it until new traffic happens to arrive.
        if searchText.isEmpty {
            let count = tableView.numberOfRows(inSection: 0)
            if count > 0 {
                tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0),
                                      at: .bottom, animated: false)
            }
        }

        // The scan itself is debounced, and only when the tab is armed.
        scheduleAutoScan()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        // Submitting re-scans immediately, but still only when the user has
        // armed body search — Return alone must never touch the disk.
        guard currentTabState.isBodySearchEnabled else { return }
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        cancelPendingAutoScan()
        startBodySearch(query: query, sides: [.response, .request])
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        currentTabState.searchText = ""
        searchBar.resignFirstResponder()
        cancelActiveScan()
        cancelPendingAutoScan()
        currentTabState.resetScanResults()
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        applyFilter()
        tableView.reloadData()
    }
}

//MARK: - UITableViewDataSource
extension NetworkViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let dataCount = currentTabState.isGroupedMode ? groupedModels.count : (models?.count ?? 0)
        let hasBodyHits = rowMatches.contains { $0 != nil }
        naviItemTitleLabel?.text = hasBodyHits ? "\u{1f50e}[\(dataCount)]" : "\u{1f680}[\(dataCount)]"
        // Rows map 1:1 onto the data — the list is nothing but results.
        return dataCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dataIndex = indexPath.row

        if currentTabState.isGroupedMode {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkGroupCell", for: indexPath) as! NetworkGroupCell
            guard groupedModels.indices.contains(dataIndex) else { return cell }
            cell.configure(with: groupedModels[dataIndex])
            return cell
        }

        // While searching every row uses the search card: same layout as the
        // normal row, plus the extra snippet line when this row matched inside a
        // body. `rowMatches` was built by `applyFilter()` — no disk read here.
        if isSearching {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NetworkSearchResultCell.reuseId, for: indexPath
            ) as! NetworkSearchResultCell
            guard let models = models, models.indices.contains(dataIndex) else { return cell }
            let match = rowMatches.indices.contains(dataIndex) ? rowMatches[dataIndex] : nil
            cell.configure(
                with: models[dataIndex],
                index: dataIndex,
                query: currentTabState.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                match: match
            )
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkCell", for: indexPath) as! NetworkCell
        guard let models = models, models.indices.contains(dataIndex) else { return cell }
        cell.index = dataIndex
        cell.httpModel = models[dataIndex]
        return cell
    }
}

//MARK: - UITableViewDelegate
extension NetworkViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let dataIndex = indexPath.row

        if currentTabState.isGroupedMode {
            guard groupedModels.indices.contains(dataIndex) else { return }
            let group = groupedModels[dataIndex]
            let vc = NetworkGroupDetailVC()
            vc.title = group.displayName
            vc.models = group.models
            vc.groupKey = group.key
            vc.isPathFilter = group.isPathFilter
            // The drill-down re-reads the store for live traffic, and the tag
            // key alone does not carry the App/Web split this tab applied.
            vc.isWebViewGroup = currentTab == .web
            // Carry the list's applied filters in, by VALUE — capturing `self`
            // here would keep this controller alive behind the pushed screen.
            let endpoints = currentTabState.selectedEndpoints
            let query = currentTabState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            vc.parentPredicate = { model in
                if !endpoints.isEmpty {
                    guard let key = Self.endpointKey(for: model.url as URL?),
                          endpoints.contains(key) else { return false }
                }
                guard !query.isEmpty else { return true }
                // Metadata/URL match only. A row that matched solely inside a
                // body cannot be reproduced without the scan results, and this
                // is the same fallback `applyFilter` uses when no scan is fresh.
                if let index = model.searchIndex { return index.matches(query) }
                return (model.url?.absoluteString ?? "").lowercased().contains(query)
            }
            isShowingDetail = true
            navigationController?.pushViewController(vc, animated: true)
        } else {
            reachEnd = false
            guard let models = models, models.indices.contains(dataIndex) else { return }

            models[dataIndex].isViewed = true
            tableView.reloadRows(at: [indexPath], with: .none)

            let vc = NetworkDetailViewController()
            vc.httpModels = models
            vc.httpModel = models[dataIndex]
            isShowingDetail = true
            self.navigationController?.pushViewController(vc, animated: true)

            vc.justCancelCallback = { [weak self] in
                guard let self = self else { return }
                self.isShowingDetail = false
                let savedOffset = self.tableView.contentOffset
                UIView.performWithoutAnimation {
                    self.tableView.reloadData()
                    self.tableView.layoutIfNeeded()
                    if !self.isAutoFollowing {
                        self.tableView.contentOffset = savedOffset
                    }
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Only in flat (non-grouped) mode.
        guard !currentTabState.isGroupedMode else { return nil }
        let dataIndex = indexPath.row
        guard let models = models, models.indices.contains(dataIndex) else { return nil }

        let model = models[dataIndex]
        let title = model.isPinned ? "Unpin" : "Pin"
        let iconName = model.isPinned ? "pin.slash.fill" : "pin.fill"

        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            model.isPinned.toggle()
            if model.isPinned {
                model.savePinToDisk()
            } else {
                model.removePinFromDisk()
            }
            // On the Pinned tab, re-filter so unpinned row disappears
            if self?.currentTab == .pinned {
                self?.applyFilter()
                tableView.reloadData()
            } else {
                tableView.reloadRows(at: [indexPath], with: .none)
            }
            completion(true)
        }
        action.backgroundColor = UIColor(red: 0.16, green: 0.50, blue: 0.47, alpha: 1)
        action.image = UIImage(systemName: iconName)
        return UISwipeActionsConfiguration(actions: [action])
    }
}

//MARK: - UIScrollViewDelegate
extension NetworkViewController: UIScrollViewDelegate {

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        reachEnd = false
        if isAutoFollowing {
            isAutoFollowing = false
            setFollowButtonVisible(true, animated: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if !isAutoFollowing { checkIfScrolledToBottom() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !isAutoFollowing && !decelerate { checkIfScrolledToBottom() }
    }
}

//MARK: - Body search palette

private enum BodySearchStyle {
    static let cardBG = UIColor(white: 0.13, alpha: 1)
    static let cardBorder = UIColor(white: 0.24, alpha: 1)
    static let caption = UIColor(white: 0.45, alpha: 1)
    static let value = UIColor(white: 0.85, alpha: 1)
    static let snippet = UIColor(white: 0.74, alpha: 1)
    static let requestBadge = UIColor(red: 0.60, green: 0.65, blue: 0.95, alpha: 1)
}

//MARK: - Body search progress banner (determinate + cancellable)

/// Floating card that reports "Scanning 42/210…" while a scan runs, then the
/// hit counts once it lands. It sits above the follow button and leaves the rest
/// of the screen interactive, so the list stays scrollable and new captures keep
/// landing while the scan works.
private final class BodySearchProgressBanner: UIView {

    var onCancel: (() -> Void)?

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = BodySearchStyle.cardBG
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = BodySearchStyle.cardBorder.cgColor

        titleLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        titleLabel.textColor = BodySearchStyle.caption
        titleLabel.text = "SCANNING BODIES"

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.systemRed, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = BodySearchStyle.value
        countLabel.numberOfLines = 0

        // What the scan cost, shown only once it has finished.
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = BodySearchStyle.caption
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = true

        progressView.progressTintColor = DebugTheme.accentColor
        progressView.trackTintColor = UIColor(white: 0.24, alpha: 1)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), cancelButton])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, countLabel, detailLabel, progressView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    func update(done: Int, total: Int) {
        titleLabel.text = "SCANNING BODIES"
        countLabel.text = "Scanning \(done)/\(total)\u{2026}"
        detailLabel.isHidden = true
        progressView.isHidden = false
        cancelButton.isHidden = false
        progressView.progress = total > 0 ? Float(done) / Float(total) : 0
    }

    /// End state: what was found and what it cost. There is nothing left to
    /// cancel, so the Cancel button and the progress bar go away.
    func showResult(counts: String, detail: String) {
        titleLabel.text = "BODY SEARCH"
        countLabel.text = counts
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
        progressView.isHidden = true
        cancelButton.isHidden = true
    }

    @objc private func cancelTapped() { onCancel?() }
}

// MARK: - Block-observer ownership

/// Holds block-based `NotificationCenter` registrations and takes them back when
/// it deallocates.
///
/// `addObserver(forName:object:queue:using:)` registers the *token it returns*,
/// not the object that called it, so the usual `removeObserver(self)` in `deinit`
/// silently unregisters nothing and the block outlives its owner. Inside an SDK
/// embedded in someone else's app that is not a slow leak — the debug UI can be
/// opened and closed dozens of times in a session, and every leaked registration
/// keeps hopping onto the main queue for every request forever after.
///
/// Any view controller in this SDK that registers a block observer should own one
/// of these instead of holding the tokens by hand.
final class NotificationObserverBag {

    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Live registrations. Read by tests; there is no other reason to look.
    var count: Int { tokens.count }

    @discardableResult
    func add(_ center: NotificationCenter = .default,
             forName name: Notification.Name,
             object: Any? = nil,
             queue: OperationQueue? = .main,
             using block: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let token = center.addObserver(forName: name, object: object, queue: queue, using: block)
        tokens.append((center, token))
        return token
    }

    func removeAll() {
        for entry in tokens { entry.center.removeObserver(entry.token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}
