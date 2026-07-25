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
    var selectedPathFilters = Set<String>()
    var selectedHostFilters = Set<String>()
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
    // disk until either the "Bodies" control arms the tab (then scans are
    // debounced behind typing) or the user taps a scope chip on the inline
    // scope row.
    //
    // A scope being ON only means "merge these hits into the list". Counts are
    // produced by the scan and shown on the chips *before* the merge, so the
    // developer can see there are N more hits inside bodies first.

    /// The "Bodies" control is armed for this tab (auto-scan after the debounce).
    var isBodySearchEnabled: Bool = false
    /// Scope chips: hits from this side are merged into the result list.
    var enabledScopes: Set<BodySearchSide> = []
    /// Sides with a scan in flight — the chip shows "scanning…" instead of a
    /// stale or zero count.
    var scanningSides: Set<BodySearchSide> = []
    /// The (trimmed) query the counts and matches below belong to. Anything else
    /// in the search field makes them stale.
    var scannedQuery: String = ""
    /// side -> (transactionId -> hit) for the last completed scan of that side.
    var matchesBySide: [BodySearchSide: [String: BodySearchMatch]] = [:]
    /// side -> hit count. nil (absent) means "never scanned", which the chip
    /// renders as an invitation to scan rather than as zero.
    var countsBySide: [BodySearchSide: Int] = [:]
    /// One-line summary of the last scan, shown on the scope row.
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
        bodySearchSummary = ""
    }

    /// Full reset, including the chips — used when body search is disarmed or the
    /// capture store is cleared.
    ///
    /// Clears the Advanced sheet's scope switches too, since they are the same
    /// setting: leaving them on would make the sheet claim bodies are searched
    /// when nothing is. The matching options (case, media, byte cap) survive —
    /// those are preferences, not part of one search.
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
    private static let scanDebounceInterval: TimeInterval = 0.45

    /// Body hit per displayed row (nil = matched on metadata only), index-aligned
    /// with `models`. Built by `applyFilter()`, never read from disk.
    private var rowMatches: [BodySearchMatch?] = []
    /// Rows the index-backed (metadata) search alone would have produced — the
    /// "URL & headers" count on the scope row.
    private var metadataResultCount = 0

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

    private func stripScheme(_ url: String) -> String {
        var result = url
        for prefix in ["https://", "http://", "HTTPS://", "HTTP://"] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        return result
    }

    //MARK: - Filter entry building

    private func buildFilterEntries() -> [(display: String, filterKeys: [(key: String, isPathFilter: Bool)], isWeb: Bool)] {
        let allCacheModels = cacheModels ?? []

        // Filter by current tab first (respecting settings toggles). Media is
        // excluded here too, so media hosts/endpoints never pollute the sheet.
        let allModels = tabModels(from: allCacheModels)

        let onlyURLs = SwiftyDebug.urls
        var rawEntries: [(display: String, filterKey: String, isPathFilter: Bool, isWeb: Bool)] = []
        var coveredHosts = Set<String>()
        // Tracks filter keys already added (lowercased) so no duplicate rows are
        // created across the onlyURLs, path-tag, host, and selected-filter passes.
        var addedFilterKeys = Set<String>()

        for urlString in onlyURLs {
            var stripped = stripScheme(urlString)
            if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }

            let host = stripped.components(separatedBy: "/").first ?? stripped

            var hasMatch = false
            var pathIsWeb = false
            for model in allModels {
                let modelURL = stripScheme(model.url?.absoluteString ?? "").lowercased()
                let key = stripped.lowercased()
                if modelURL.hasPrefix(key + "/") || modelURL == key {
                    hasMatch = true
                    if model.isWebViewRequest { pathIsWeb = true }
                }
            }

            if hasMatch {
                let display = tagLabel(forURLString: urlString) ?? stripped
                rawEntries.append((display: display, filterKey: stripped, isPathFilter: true, isWeb: pathIsWeb))
                coveredHosts.insert(host.lowercased())
                addedFilterKeys.insert(stripped.lowercased())
            }
        }

        // Path-scoped tag keywords (e.g. "google.com/products") become their own
        // path-filter entries, distinct from a bare-host entry — this is what
        // keeps two tags that share a host but differ by path from collapsing.
        // (See TAGS-FILTER.)
        var coveredByPathTag = Set<String>()   // model URLs already claimed by a path-tag
        for (keyword, label) in SwiftyDebug._tags where keyword.contains("/") {
            let key = stripScheme(keyword).lowercased()
            let trimmedKey = key.hasSuffix("/") ? String(key.dropLast()) : key
            guard !trimmedKey.isEmpty else { continue }

            var hasMatch = false
            var isWeb = false
            for model in allModels {
                let modelURL = stripScheme(model.url?.absoluteString ?? "").lowercased()
                if modelURL.hasPrefix(trimmedKey + "/") || modelURL == trimmedKey {
                    hasMatch = true
                    coveredByPathTag.insert(modelURL)
                    if model.isWebViewRequest { isWeb = true }
                }
            }
            if hasMatch, !addedFilterKeys.contains(trimmedKey) {
                addedFilterKeys.insert(trimmedKey)
                rawEntries.append((display: label, filterKey: trimmedKey, isPathFilter: true, isWeb: isWeb))
            }
        }

        var seenHosts = Set<String>()
        for model in allModels {
            guard let host = model.url?.host, !host.isEmpty else { continue }
            let lowerHost = host.lowercased()
            if seenHosts.contains(lowerHost) { continue }
            seenHosts.insert(lowerHost)

            if !coveredHosts.contains(lowerHost) {
                let display = tagLabel(forHost: lowerHost) ?? host
                let isWeb = allModels.contains { m in
                    m.isWebViewRequest && m.url?.host?.lowercased() == lowerHost
                }
                rawEntries.append((display: display, filterKey: host, isPathFilter: false, isWeb: isWeb))
            }
        }

        // Add currently-selected filters that are not already in the list (exact match)
        let state = currentTabState

        for key in state.selectedPathFilters {
            let lower = key.lowercased()
            if !addedFilterKeys.contains(lower) {
                addedFilterKeys.insert(lower)
                // Find original URL from SwiftyDebug.urls to resolve tag correctly
                let originalURL = onlyURLs.first { stripScheme($0).lowercased().hasPrefix(lower) }
                let display = tagLabel(forURLString: originalURL ?? key) ?? tagLabel(forHost: lower.components(separatedBy: "/").first ?? lower) ?? key
                rawEntries.append((display: display, filterKey: key, isPathFilter: true, isWeb: false))
            }
        }
        for key in state.selectedHostFilters {
            let lower = key.lowercased()
            if !addedFilterKeys.contains(lower) {
                addedFilterKeys.insert(lower)
                let originalURL = onlyURLs.first { stripScheme($0).lowercased().hasPrefix(lower) }
                let display = tagLabel(forURLString: originalURL ?? key) ?? tagLabel(forHost: lower) ?? key
                rawEntries.append((display: display, filterKey: key, isPathFilter: false, isWeb: false))
            }
        }

        // Sort by priority then alphabetically
        let sorted = rawEntries.sorted {
            let priorityA = $0.isPathFilter ? 0 : ($0.isWeb ? 1 : 2)
            let priorityB = $1.isPathFilter ? 0 : ($1.isWeb ? 1 : 2)
            if priorityA != priorityB { return priorityA < priorityB }
            return $0.display.lowercased() < $1.display.lowercased()
        }

        // Merge entries into rows. Path filters are keyed by their *filterKey* so
        // two tags that share a display label but target different paths (e.g.
        // "Algolia Proxy" → /products and another → /events) stay as separate
        // rows. Host filters keep merging by display label so http/https and
        // duplicate hosts collapse as before. (See TAGS-FILTER.)
        var rowOrder: [String] = []
        var mergedMap: [String: (display: String, filterKeys: [(key: String, isPathFilter: Bool)], isWeb: Bool)] = [:]
        for entry in sorted {
            // Distinct merge key: path filters never merge across different keys.
            let mergeKey = entry.isPathFilter
                ? "path|" + entry.filterKey.lowercased()
                : "host|" + entry.display.lowercased()
            if mergedMap[mergeKey] == nil {
                rowOrder.append(mergeKey)
                mergedMap[mergeKey] = (display: entry.display, filterKeys: [], isWeb: false)
            }
            mergedMap[mergeKey]!.filterKeys.append((key: entry.filterKey, isPathFilter: entry.isPathFilter))
            if entry.isWeb { mergedMap[mergeKey]!.isWeb = true }
        }
        return rowOrder.map { mergeKey in
            let info = mergedMap[mergeKey]!
            return (display: info.display, filterKeys: info.filterKeys, isWeb: info.isWeb)
        }
    }

    /// Returns the tag label from the tag map that best matches the full URL,
    /// or nil if no custom tag matches.
    ///
    /// Matching is **deterministic** and **path-aware** (see TAGS-FILTER): when
    /// two tag keywords could match, the *longest* keyword wins (most specific),
    /// so path-scoped keywords like `google.com/products` beat a bare host
    /// keyword like `google.com`, and dictionary iteration order no longer
    /// affects the result.
    private func tagLabel(forURLString urlString: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        // Direct key lookup first (most common case: urls key == tag keyword)
        if let label = map[urlString] { return label }

        let lower = urlString.lowercased()
        // Longest-keyword-wins substring match for determinism + path awareness.
        var best: (keyword: String, label: String)?
        for (keyword, label) in map where lower.contains(keyword.lowercased()) {
            if best == nil || keyword.count > best!.keyword.count {
                best = (keyword, label)
            }
        }
        return best?.label
    }

    /// Returns the tag label whose keyword matches the given host, or nil.
    ///
    /// Only *host-scoped* keywords (those without a `/` path segment) can match a
    /// bare host; a path-scoped keyword like `google.com/products` intentionally
    /// does NOT match the bare host `google.com` (it needs the full URL — see
    /// `tagLabel(forURLString:)`). Longest keyword wins for determinism.
    private func tagLabel(forHost host: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        let lowerHost = host.lowercased()
        var best: (keyword: String, label: String)?
        for (keyword, label) in map {
            let k = keyword.lowercased()
            // Skip path-scoped keywords here — they belong to the full-URL matcher.
            if k.contains("/") { continue }
            guard lowerHost.contains(k) else { continue }
            if best == nil || keyword.count > best!.keyword.count {
                best = (keyword, label)
            }
        }
        return best?.label
    }

    private func uniqueEndpointsForFilters(pathFilters: Set<String>, hostFilters: Set<String>) -> [FilterableEndpoint] {
        guard let allCache = cacheModels else { return [] }
        // Filter by current tab (respecting settings toggles + media routing)
        let models = tabModels(from: allCache)
        if pathFilters.isEmpty && hostFilters.isEmpty { return [] }

        let onlyURLs = SwiftyDebug.urls

        // Build set of onlyURLs paths (for exclusion — already top-level filter entries).
        // Also map: lowercased stripped key → original full URL (for tag lookup).
        var onlyURLPaths = Set<String>()
        var strippedToOriginalURL: [String: String] = [:]
        for urlString in onlyURLs {
            var stripped = stripScheme(urlString)
            if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }
            strippedToOriginalURL[stripped.lowercased()] = urlString
            if let url = URL(string: urlString) {
                var path = url.path
                if path.hasSuffix("/") && path.count > 1 { path = String(path.dropLast()) }
                if !path.isEmpty && path != "/" {
                    onlyURLPaths.insert(Self.normalizeEndpoint(path).lowercased())
                }
            }
        }

        // Tag label for each selected path filter.
        var pathFilterTagMap: [String: String] = [:]
        for pf in pathFilters {
            let key = pf.lowercased()
            if let original = strippedToOriginalURL[key] {
                pathFilterTagMap[key] = tagLabel(forURLString: original) ?? pf
            } else {
                pathFilterTagMap[key] = tagLabel(forURLString: pf) ?? pf
            }
        }

        // Tag label for each selected host filter.
        var hostFilterTagMap: [String: String] = [:]
        for hf in hostFilters {
            hostFilterTagMap[hf.lowercased()] = tagLabel(forHost: hf.lowercased()) ?? hf
        }

        // Path prefix to strip per path filter so we show relative sub-paths.
        // e.g. "api.salla.dev/mahally/v2" → "/mahally/v2"
        var pathPrefixMap: [String: String] = [:]
        for pf in pathFilters {
            let subParts = Array(pf.components(separatedBy: "/").dropFirst())
            if !subParts.isEmpty {
                pathPrefixMap[pf.lowercased()] = "/" + subParts.joined(separator: "/")
            }
        }

        // Pre-build set of filterPaths that have at least one web request, so
        // we can show "· web" in the tag regardless of which model is processed first.
        var webFilterPaths = Set<String>()
        for model in models where model.isWebViewRequest {
            let fp = Self.normalizeEndpoint(model.url?.path ?? "")
            if !fp.isEmpty { webFilterPaths.insert(fp) }
        }

        var seen = Set<String>()   // dedup by filterPath (full normalized path)
        var result = [FilterableEndpoint]()
        for model in models {
            let modelURL = stripScheme(model.url?.absoluteString ?? "").lowercased()
            let host = (model.url?.host ?? "").lowercased()
            let fullPath = model.url?.path ?? ""

            var matchedPrefix: String? = nil
            var matchedTag = ""
            var matches = false
            for pf in pathFilters {
                let key = pf.lowercased()
                if modelURL.hasPrefix(key + "/") || modelURL == key {
                    matches = true
                    matchedPrefix = pathPrefixMap[key]
                    matchedTag = pathFilterTagMap[key] ?? pf
                    break
                }
            }
            if !matches {
                for hf in hostFilters {
                    if host == hf.lowercased() {
                        matches = true
                        matchedTag = hostFilterTagMap[hf.lowercased()] ?? hf
                        break
                    }
                }
            }
            if !matches { continue }

            // Skip models whose full path is itself an onlyURLs entry (already a top-level filter)
            let fullNormalized = Self.normalizeEndpoint(fullPath).lowercased()
            if fullNormalized.isEmpty || onlyURLPaths.contains(fullNormalized) { continue }

            // filterPath = full normalized path (used as key in applyFilter)
            let filterPath = Self.normalizeEndpoint(fullPath)
            if filterPath.isEmpty { continue }
            guard seen.insert(filterPath).inserted else { continue }

            // displayPath = relative sub-path (strip the onlyURLs base prefix for readability)
            var displayPath = fullPath
            if let prefix = matchedPrefix, fullPath.lowercased().hasPrefix(prefix.lowercased()) {
                let relative = String(fullPath.dropFirst(prefix.count))
                displayPath = relative.isEmpty ? "/" : relative
            }
            let normalizedDisplay = Self.normalizeEndpoint(displayPath)
            if normalizedDisplay.isEmpty || normalizedDisplay == "/" { continue }

            let isWebEndpoint = webFilterPaths.contains(filterPath)
            let endpointTag: String
            if isWebEndpoint {
                endpointTag = matchedTag.isEmpty ? "web" : "\(matchedTag) · web"
            } else {
                endpointTag = matchedTag
            }
            result.append(FilterableEndpoint(
                displayPath: normalizedDisplay,
                filterPath: filterPath,
                tag: endpointTag
            ))
        }
        return result.sorted { $0.displayPath < $1.displayPath }
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
            metadataResultCount = 0
            return
        }

        let state = currentTabState

        // 1. Tab segment filter (respecting settings toggles). Media requests are
        //    routed to the Media tab and hidden here — except on Pinned, where a
        //    pinned item is always shown.
        var filtered = tabModels(from: cacheModels)

        // 2. Path / host filters
        let pathFilters = state.selectedPathFilters
        let hostFilters = state.selectedHostFilters
        let endpoints = state.selectedEndpoints

        let hasFilterSelection = !pathFilters.isEmpty || !hostFilters.isEmpty
        if hasFilterSelection {
            filtered = filtered.filter { model in
                let modelURL = stripScheme(model.url?.absoluteString ?? "").lowercased()
                let host = (model.url?.host ?? "").lowercased()

                for pf in pathFilters {
                    let key = pf.lowercased()
                    if modelURL.hasPrefix(key + "/") || modelURL == key { return true }
                }
                for hf in hostFilters {
                    if host == hf.lowercased() { return true }
                }
                return false
            }
        }

        // 3. Endpoint filter
        if !endpoints.isEmpty {
            filtered = filtered.filter { model in
                let normalized = Self.normalizeEndpoint(model.url?.path ?? "")
                return endpoints.contains(normalized)
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
        metadataResultCount = 0
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
                if metadataHit { metadataResultCount += 1 }
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
        let hasFilter = !state.selectedPathFilters.isEmpty ||
                        !state.selectedHostFilters.isEmpty ||
                        !state.selectedEndpoints.isEmpty
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
    // Body search is therefore still **opt-in**, but it is now presented inline
    // instead of as a separate results mode:
    //
    //   1. the query row shows a scope cell as the first row of the results,
    //      with one chip per `BodySearchSide` (request / response),
    //   2. a chip carries that side's hit count, so the user can see "there are
    //      N more hits inside bodies" *before* merging them,
    //   3. counts come from `ResponseBodySearch.scan` run once per side with
    //      only that side's flag set — off the main thread, byte-capped,
    //      cancellable, and memoised per (query, transaction) by BodySearchCache,
    //   4. a scan is only started by an explicit act: arming the "Bodies"
    //      control (then debounced behind typing), tapping a chip, or hitting
    //      Search/Return while armed. Typing alone never reads a body.
    //
    // Turning a chip on merges its hits into the same list the metadata search
    // produced — see `applyFilter()` — and those rows render with the normal
    // result card plus one extra snippet line.

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

        // The scope switches in the sheet and the chips on the card are the same
        // setting shown twice — keep them in step.
        state.setScope(.response, on: updated.searchResponseBodies)
        state.setScope(.request, on: updated.searchRequestBodies)

        guard updated.searchesAnyBody else {
            disarmBodySearch()
            reloadScopeRow()
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
        guard !query.isEmpty else { reloadScopeRow(); return }

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
    /// index-backed view. Arming happens from the card's chips instead — there is
    /// no separate on/off control any more, because "armed but no scope chosen"
    /// was a state that did nothing and explained nothing.
    private func disarmBodySearch() {
        let state = currentTabState
        state.isBodySearchEnabled = false
        cancelActiveScan()
        scanDebounceTimer?.invalidate()
        state.resetBodySearch()
        updateAdvancedSearchButton()
        applyFilter()
        tableView.reloadData()
    }

    /// Called on `.allLogsCleared`: every transaction id the hits point at is
    /// gone, so all tabs are reset.
    private func discardAllBodyResults() {
        cancelActiveScan()
        scanDebounceTimer?.invalidate()
        for (_, state) in Self.tabStates { state.resetBodySearch() }
        applyFilter()
        tableView.reloadData()
    }

    // MARK: Scope row

    /// The scope cell is the first row whenever there is something to scope.
    private var showsScopeRow: Bool {
        return !currentTabState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rows the data arrays own, i.e. everything after the scope cell.
    private var rowOffset: Int { showsScopeRow ? 1 : 0 }

    private func scopeConfig(for state: TabFilterState) -> NetworkSearchScopeCell.Config {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFresh = state.scannedQuery == query && !query.isEmpty

        let scopes: [NetworkSearchScopeCell.ScopeState] = [.response, .request].map { side in
            NetworkSearchScopeCell.ScopeState(
                side: side,
                isOn: state.isScopeOn(side),
                isScanning: state.scanningSides.contains(side),
                // A count from another query is worse than no count at all.
                count: isFresh ? state.countsBySide[side] : nil
            )
        }

        return NetworkSearchScopeCell.Config(
            query: query,
            metadataCount: metadataResultCount,
            scopes: scopes,
            statusText: scopeStatusText(for: state, query: query)
        )
    }

    private func scopeStatusText(for state: TabFilterState, query: String) -> String {
        if !state.scanningSides.isEmpty {
            let done = scanProgress.values.reduce(0, +)
            return "Scanning \(done)/\(max(scanTotal, 1))\u{2026}"
        }
        if state.scannedQuery == query, !state.bodySearchSummary.isEmpty {
            return state.bodySearchSummary
        }
        return "Bodies are on disk \u{00B7} first \(ResponseBodySearch.byteCapDescription) each"
    }

    /// Refreshes just the scope cell — cheap, and it never disturbs the scroll
    /// position of the results underneath it.
    private func reloadScopeRow() {
        guard isViewLoaded, showsScopeRow,
              tableView.numberOfRows(inSection: 0) > 0 else { return }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
    }

    /// Progress ticks only touch the status line, so the chips don't flicker.
    private func updateScopeRowStatus() {
        guard isViewLoaded, showsScopeRow else { return }
        let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? NetworkSearchScopeCell
        let state = currentTabState
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        cell?.setStatus(scopeStatusText(for: state, query: query))
    }

    /// A chip tap is both the switch and the way in: it turns the scope on and,
    /// if that side has no fresh count yet, scans it (arming the tab so later
    /// queries keep their counts up to date).
    private func didToggleScope(_ side: BodySearchSide) {
        let state = currentTabState
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let turningOn = !state.isScopeOn(side)
        state.setScope(side, on: turningOn)
        // The card chips and the Advanced sheet's scope switches are one setting
        // shown in two places — mirror the change back so reopening the sheet
        // doesn't contradict the card.
        switch side {
        case .response: state.advanced.searchResponseBodies = turningOn
        case .request:  state.advanced.searchRequestBodies = turningOn
        }
        updateAdvancedSearchButton()

        if turningOn {
            state.isBodySearchEnabled = true
            // Already scanning this side: just record the choice, the running
            // scan merges itself in when it lands. Restarting here would cancel
            // the sibling side's scan for nothing.
            if state.scanningSides.contains(side) {
                reloadScopeRow()
                return
            }
            if state.scannedQuery != query || state.countsBySide[side] == nil {
                // Carry any side that is mid-scan into the new scan. One shared
                // cancellation token covers both sides, so scanning only `side`
                // would kill the sibling's in-flight scan and strand its chip on
                // "scan" with no rows and nothing scheduled to fix it.
                let sides = Array(Set(state.scanningSides).union([side]))
                startBodySearch(query: query, sides: sides)
                return   // the scan reloads once it lands
            }
        } else if BodySearchSide.allCases.allSatisfy({ !state.isScopeOn($0) }) {
            // Last chip off: stop scanning and release the cached hits rather
            // than leaving the tab armed but searching nothing.
            disarmBodySearch()
            reloadScopeRow()
            return
        }

        applyFilter()
        tableView.reloadData()
    }

    // MARK: Scan lifecycle

    /// Debounced auto-scan. Only ever scheduled while the tab is armed, and only
    /// for sides that have no fresh count — a repeat query costs nothing.
    private func scheduleAutoScan() {
        scanDebounceTimer?.invalidate()
        let state = currentTabState
        guard state.isBodySearchEnabled else { return }
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }

        scanDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scanDebounceInterval, repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            let state = self.currentTabState
            let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.isBodySearchEnabled, query.count >= 2 else { return }

            let sides: [BodySearchSide] = [.response, .request].filter {
                state.scannedQuery != query || state.countsBySide[$0] == nil
            }
            guard !sides.isEmpty else { return }
            self.startBodySearch(query: query, sides: sides)
        }
    }

    /// One `ResponseBodySearch.scan` per side, each with only that side's flag
    /// set, so the two counts are genuinely independent.
    private func startBodySearch(query rawQuery: String, sides: [BodySearchSide]) {
        guard SwiftyDebugRuntime.isActive, !sides.isEmpty else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let state = currentTabState
        // A different query invalidates every count and hit we hold.
        if state.scannedQuery != query { state.resetScanResults() }

        cancelActiveScan()

        // Snapshot of the current tab's transactions — the scan never touches the
        // live store, so new captures can keep arriving while it runs.
        let candidates = tabModels(from: cacheModels ?? [])
        guard !candidates.isEmpty else {
            state.scannedQuery = query
            for side in sides { state.countsBySide[side] = 0 }
            state.bodySearchSummary = "Nothing to scan on this tab."
            reloadScopeRow()
            return
        }

        let token = BodySearchCancellationToken()
        activeScanToken = token
        activeScanState = state
        pendingScanSides = sides.count
        scanProgress = [:]
        scanTotal = candidates.count * sides.count
        state.scanningSides = Set(sides)
        showScanBanner(total: scanTotal)
        reloadScopeRow()

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
                    self.updateScopeRowStatus()
                },
                completion: { [weak self] outcome in
                    guard let self = self, self.activeScanToken === token else { return }
                    self.finishScan(outcome, side: side, query: query, state: state)
                }
            )
        }
    }

    private func cancelActiveScan() {
        let wasScanning = activeScanToken != nil
        activeScanToken?.cancel()
        activeScanToken = nil
        activeScanState?.scanningSides.removeAll()
        activeScanState = nil
        pendingScanSides = 0
        scanProgress = [:]
        hideScanBanner()
        // The chips must stop claiming "scanning…" the moment the scan dies —
        // including when the banner's Cancel is what killed it.
        if wasScanning { reloadScopeRow() }
    }

    private func finishScan(_ outcome: ResponseBodySearch.Outcome,
                            side: BodySearchSide,
                            query: String,
                            state: TabFilterState) {
        state.scanningSides.remove(side)
        pendingScanSides -= 1
        if pendingScanSides <= 0 {
            activeScanToken = nil
            activeScanState = nil
            hideScanBanner()
        }

        guard !outcome.wasCancelled else {
            reloadScopeRow()
            return
        }

        state.scannedQuery = query
        state.matchesBySide[side] = Dictionary(
            outcome.matches.map { ($0.transactionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        state.countsBySide[side] = outcome.matches.count
        state.bodySearchSummary = Self.summaryText(for: outcome)

        applyFilter()
        tableView.reloadData()
    }

    private static func summaryText(for outcome: ResponseBodySearch.Outcome) -> String {
        var parts: [String] = ["\(outcome.scannedCount) bodies read"]
        if outcome.cacheHitCount > 0 { parts.append("\(outcome.cacheHitCount) cached") }
        if outcome.skippedCount > 0 { parts.append("\(outcome.skippedCount) skipped") }
        if outcome.truncatedCount > 0 { parts.append("\(outcome.truncatedCount) capped") }
        parts.append("first \(ResponseBodySearch.byteCapDescription) each")
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
        view.bringSubviewToFront(banner)
        banner.isHidden = false
        banner.update(done: 0, total: total)
    }

    private func hideScanBanner() {
        scanBanner?.isHidden = true
    }

    //MARK: - Grouped models

    private func buildGroupedModels(from models: [NetworkTransaction]) -> [NetworkGroup] {
        let onlyURLs = SwiftyDebug.urls
        var groups: [(key: String, display: String, tag: String?, isPath: Bool, models: [NetworkTransaction])] = []
        var assigned = Set<Int>()

        // Pass 1: onlyURLs groups
        for urlString in onlyURLs {
            var stripped = stripScheme(urlString)
            if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }
            let tag = tagLabel(forURLString: urlString)
            var matched: [NetworkTransaction] = []
            for (i, model) in models.enumerated() {
                let modelURL = stripScheme(model.url?.absoluteString ?? "").lowercased()
                let key = stripped.lowercased()
                if modelURL.hasPrefix(key + "/") || modelURL == key {
                    matched.append(model)
                    assigned.insert(i)
                }
            }
            if !matched.isEmpty {
                groups.append((key: stripped, display: tag ?? stripped, tag: tag, isPath: true, models: matched))
            }
        }

        // Pass 2: remaining models grouped by host
        var hostGroups: [String: [NetworkTransaction]] = [:]
        var hostOrder: [String] = []
        for (i, model) in models.enumerated() where !assigned.contains(i) {
            let host = (model.url?.host ?? "").lowercased()
            guard !host.isEmpty else { continue }
            if hostGroups[host] == nil { hostOrder.append(host) }
            hostGroups[host, default: []].append(model)
        }
        for host in hostOrder {
            let tag = tagLabel(forHost: host)
            let display = tag ?? host
            groups.append((key: host, display: display, tag: tag, isPath: false, models: hostGroups[host]!))
        }

        return groups.map {
            NetworkGroup(key: $0.key, displayName: $0.display, fullURL: $0.key,
                         tag: $0.tag, isPathFilter: $0.isPath,
                         count: $0.models.count, models: $0.models)
        }
    }

    //MARK: - Filter UI

    @objc func didTapFilter() {
        let entries = buildFilterEntries()

        let state = currentTabState
        let sheet = NetworkFilterSheetController()
        sheet.entries = entries
        sheet.tempPathFilters = state.selectedPathFilters
        sheet.tempHostFilters = state.selectedHostFilters
        sheet.tempEndpoints = state.selectedEndpoints

        sheet.endpointProvider = { [weak self, weak sheet] in
            guard let self = self, let sheet = sheet else { return [] }
            return self.uniqueEndpointsForFilters(
                pathFilters: sheet.tempPathFilters,
                hostFilters: sheet.tempHostFilters
            )
        }

        sheet.onApply = { [weak self] pathFilters, hostFilters, endpoints in
            guard let self = self else { return }
            let s = self.currentTabState
            s.selectedPathFilters = pathFilters
            s.selectedHostFilters = hostFilters
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
        self.models = (NetworkRequestStore.shared.httpModels as NSArray as? [NetworkTransaction])
        self.cacheModels = self.models

        applyFilter()

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
        NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
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
        NotificationCenter.default.addObserver(forName: .networkRequestCompleted, object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.reloadHttp()
        }

        // A clear wipes every transaction id the body-search results point at, so
        // drop the parked results (the shared BodySearchCache clears itself too).
        NotificationCenter.default.addObserver(forName: .allLogsCleared, object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.discardAllBodyResults()
        }

        tableView.tableFooterView = UIView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.register(NetworkCell.self, forCellReuseIdentifier: "NetworkCell")
        tableView.register(NetworkGroupCell.self, forCellReuseIdentifier: "NetworkGroupCell")
        tableView.register(NetworkSearchScopeCell.self, forCellReuseIdentifier: NetworkSearchScopeCell.reuseId)
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

        // Body search deliberately has NO control here. It lives entirely in the
        // inline card at the top of the results (NetworkSearchScopeCell), where
        // there is room to say what it searches and what it costs — an icon in
        // this row could only ever be an unlabelled mystery. (See BODY-SEARCH.)
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
        scanDebounceTimer?.invalidate()
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
        let remaining = (NetworkRequestStore.shared.httpModels as NSArray as? [NetworkTransaction]) ?? []
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
        scanDebounceTimer?.invalidate()

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
        let hadScopeRow = showsScopeRow
        state.searchText = searchText
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typing never reads a body. It only drops hits that belonged to another
        // query — the chips' on/off choice is deliberately sticky.
        if state.scannedQuery != query, !state.scannedQuery.isEmpty {
            cancelActiveScan()
            state.resetScanResults()
        }

        if !searchText.isEmpty {
            isAutoFollowing = false
            setFollowButtonVisible(true, animated: true)
        }
        applyFilter()
        tableView.reloadData()
        if hadScopeRow != showsScopeRow { updateScopeRowStatus() }

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
        scanDebounceTimer?.invalidate()
        startBodySearch(query: query, sides: [.response, .request])
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        currentTabState.searchText = ""
        searchBar.resignFirstResponder()
        cancelActiveScan()
        scanDebounceTimer?.invalidate()
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
        // +1 for the inline scope row, which is only present while searching.
        return dataCount + rowOffset
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Row 0 while searching: the scope control (BODY-SEARCH).
        if showsScopeRow, indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NetworkSearchScopeCell.reuseId, for: indexPath
            ) as! NetworkSearchScopeCell
            cell.configure(with: scopeConfig(for: currentTabState))
            // Keyed by side, never by row index — safe across reuse.
            cell.onToggle = { [weak self] side in self?.didToggleScope(side) }
            return cell
        }

        let dataIndex = indexPath.row - rowOffset

        if currentTabState.isGroupedMode {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkGroupCell", for: indexPath) as! NetworkGroupCell
            guard groupedModels.indices.contains(dataIndex) else { return cell }
            cell.configure(with: groupedModels[dataIndex])
            return cell
        }

        // While searching every row uses the search card: same layout as the
        // normal row, plus the extra snippet line when this row matched inside a
        // body. `rowMatches` was built by `applyFilter()` — no disk read here.
        if showsScopeRow {
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

        // The scope row is driven by its chips, not by selecting it.
        if showsScopeRow, indexPath.row == 0 { return }
        let dataIndex = indexPath.row - rowOffset

        if currentTabState.isGroupedMode {
            guard groupedModels.indices.contains(dataIndex) else { return }
            let group = groupedModels[dataIndex]
            let vc = NetworkGroupDetailVC()
            vc.title = group.displayName
            vc.models = group.models
            vc.groupKey = group.key
            vc.isPathFilter = group.isPathFilter
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
        // Only in flat (non-grouped) mode, and never on the scope row.
        guard !currentTabState.isGroupedMode else { return nil }
        if showsScopeRow, indexPath.row == 0 { return nil }
        let dataIndex = indexPath.row - rowOffset
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

/// Floating card that reports "Scanning 42/210…" while a scan runs. It sits
/// above the follow button and leaves the rest of the screen interactive, so the
/// list stays scrollable and new captures keep landing while the scan works.
private final class BodySearchProgressBanner: UIView {

    var onCancel: (() -> Void)?

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
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

        progressView.progressTintColor = DebugTheme.accentColor
        progressView.trackTintColor = UIColor(white: 0.24, alpha: 1)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), cancelButton])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, countLabel, progressView])
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
        countLabel.text = "Scanning \(done)/\(total)\u{2026}"
        progressView.progress = total > 0 ? Float(done) / Float(total) : 0
    }

    @objc private func cancelTapped() { onCancel?() }
}

