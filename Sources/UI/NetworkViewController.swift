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
    // Opt-in, per tab. `isBodySearchEnabled` only arms the mode — nothing is read
    // from disk until the user *submits* a query, at which point the results are
    // parked in `bodyMatches` and the list switches to results mode.

    /// The "Search in bodies" scope button is ON for this tab.
    var isBodySearchEnabled: Bool = false
    /// The query the parked results belong to (used to detect a stale result set).
    var bodySearchQuery: String = ""
    /// transactionId -> hit, for the last completed scan on this tab.
    var bodyMatches: [String: BodySearchMatch] = [:]
    /// The list is currently rendering body-search results rather than the normal list.
    var isShowingBodyResults: Bool = false
    /// Footer/info-line summary of the last scan.
    var bodySearchSummary: String = ""
}

class NetworkViewController: UIViewController {

    var reachEnd: Bool = true

    var models: [NetworkTransaction]?
    var cacheModels: [NetworkTransaction]?

    var naviItemTitleLabel: UILabel?

    private var tableView: UITableView!
    private var searchBar: UISearchBar!
    private var deleteItem: UIBarButtonItem!

    // Segment tabs
    private var segmentControl: UISegmentedControl!
    private static var savedTab: NetworkTab = .app
    private static var tabStates: [NetworkTab: TabFilterState] = [
        .app: TabFilterState(), .web: TabFilterState(), .pinned: TabFilterState()
    ]
    private var currentTab: NetworkTab = NetworkViewController.savedTab
    private var currentTabState: TabFilterState { Self.tabStates[currentTab]! }

    // Filter + layout toggle (inline with search bar)
    private var filterButton: UIButton!
    private var layoutToggleButton: UIButton!
    /// Scope button that arms body search (BODY-SEARCH). Default OFF.
    private var bodySearchButton: UIButton!

    // Body search UI + scan bookkeeping (BODY-SEARCH)
    private var bodyInfoBar: BodySearchInfoBar?
    private var scanBanner: BodySearchProgressBanner?
    private var activeScanToken: BodySearchCancellationToken?
    /// Hits for the rows currently displayed, index-aligned with `models`.
    private var displayedMatches: [BodySearchMatch] = []
    private var isShowingBodyResults: Bool { currentTabState.isShowingBodyResults }

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

        // 4. Body-search results mode (BODY-SEARCH). The hits were computed once
        //    against the submitted query, so the index-backed text filter is
        //    skipped here — a body hit legitimately has nothing in its index.
        //    Tab/path/endpoint filters still apply, and rows keep list order.
        if state.isShowingBodyResults {
            var orderedModels: [NetworkTransaction] = []
            var orderedMatches: [BodySearchMatch] = []
            for model in filtered {
                guard let match = state.bodyMatches[ResponseBodySearch.identifier(for: model)] else { continue }
                orderedModels.append(model)
                orderedMatches.append(match)
            }
            models = orderedModels
            displayedMatches = orderedMatches
            groupedModels = []
            return
        }
        displayedMatches = []

        // 5. Search text filter — index-backed rich search over URL parts,
        //    method, status, header names, query params, and response-derived
        //    metadata (see SEARCH). Falls back to a plain URL contains for any
        //    model that predates the index.
        if !state.searchText.isEmpty {
            let raw = state.searchText
            let plain = raw.lowercased()
            filtered = filtered.filter { model in
                if let index = model.searchIndex {
                    return index.matches(raw)
                }
                return (model.url?.absoluteString ?? "").lowercased().contains(plain)
            }
        }

        models = filtered

        // 6. Build groups if in grouped mode
        if state.isGroupedMode {
            groupedModels = buildGroupedModels(from: filtered)
        } else {
            groupedModels = []
        }
    }

    private func updateFilterButtonIcon() {
        let state = currentTabState
        let hasFilter = !state.selectedPathFilters.isEmpty ||
                        !state.selectedHostFilters.isEmpty ||
                        !state.selectedEndpoints.isEmpty
        let iconName = hasFilter
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        filterButton.setImage(UIImage(systemName: iconName), for: .normal)
    }

    private func updateLayoutToggleIcon() {
        let iconName = currentTabState.isGroupedMode ? "list.bullet" : "square.grid.2x2"
        layoutToggleButton.setImage(UIImage(systemName: iconName), for: .normal)
    }

    //MARK: - Body search (BODY-SEARCH)
    //
    // The normal list search is index-backed and never touches bodies, because
    // `requestData`/`responseData` are disk-backed (one file read per access).
    // Body search is therefore **explicitly opt-in and explicitly submitted**:
    //
    //   1. the user arms the scope button (default OFF — plain typing stays instant),
    //   2. types a term and hits Search / Return (never per keystroke),
    //   3. `ResponseBodySearch` reads every candidate body once on a background
    //      queue, reporting determinate progress into a cancellable banner,
    //   4. results are parked per tab and rendered as snippet rows.
    //
    // Nothing here blocks `.networkRequestCompleted`: the scan owns a snapshot
    // array, the main thread only receives progress ticks.

    private func updateBodySearchButton() {
        let on = currentTabState.isBodySearchEnabled
        bodySearchButton.tintColor = on ? .black : UIColor(white: 0.45, alpha: 1)
        bodySearchButton.backgroundColor = on ? DebugTheme.accentColor : .clear
    }

    @objc private func didTapBodySearchToggle() {
        let state = currentTabState
        state.isBodySearchEnabled.toggle()

        if !state.isBodySearchEnabled {
            // Turning the scope off drops any parked results and returns the list
            // to the normal index-backed view.
            cancelActiveScan()
            clearBodyResults(for: state)
            applyFilter()
            tableView.reloadData()
        }

        updateBodySearchButton()
        refreshBodyInfoBar()
    }

    /// Drops parked results for one tab (keeps the scope button state).
    private func clearBodyResults(for state: TabFilterState) {
        state.isShowingBodyResults = false
        state.bodyMatches = [:]
        state.bodySearchQuery = ""
        state.bodySearchSummary = ""
        displayedMatches = []
    }

    /// Called on `.allLogsCleared`: every transaction id the results point at is
    /// gone, so all tabs are reset.
    private func discardAllBodyResults() {
        cancelActiveScan()
        for (_, state) in Self.tabStates { clearBodyResults(for: state) }
        applyFilter()
        refreshBodyInfoBar()
        tableView.reloadData()
    }

    // MARK: Scan lifecycle

    private func startBodySearch(query: String) {
        guard SwiftyDebugRuntime.isActive else { return }
        let state = currentTabState
        guard state.isBodySearchEnabled else { return }

        cancelActiveScan()

        // Snapshot of the current tab's transactions — the scan never touches the
        // live store, so new captures can keep arriving while it runs.
        let candidates = tabModels(from: cacheModels ?? [])
        guard !candidates.isEmpty else {
            state.bodySearchSummary = "Nothing to scan on this tab."
            refreshBodyInfoBar()
            return
        }

        var options = ResponseBodySearch.Options()
        // Media never carries a searchable body — reuse the list's own rule so the
        // two can't disagree.
        options.skipTransaction = { NetworkViewController.isMediaTransaction($0) }

        let token = BodySearchCancellationToken()
        activeScanToken = token
        showScanBanner(total: candidates.count)

        ResponseBodySearch.scan(
            transactions: candidates,
            query: query,
            options: options,
            token: token,
            progress: { [weak self] done, total in
                self?.scanBanner?.update(done: done, total: total)
            },
            completion: { [weak self] outcome in
                guard let self = self, self.activeScanToken === token else { return }
                self.activeScanToken = nil
                self.hideScanBanner()
                guard !outcome.wasCancelled else { return }
                self.applyBodySearchOutcome(outcome, query: query)
            }
        )
    }

    private func cancelActiveScan() {
        activeScanToken?.cancel()
        activeScanToken = nil
        hideScanBanner()
    }

    private func applyBodySearchOutcome(_ outcome: ResponseBodySearch.Outcome, query: String) {
        let state = currentTabState
        state.bodySearchQuery = query
        state.bodyMatches = Dictionary(
            outcome.matches.map { ($0.transactionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        state.isShowingBodyResults = true
        state.bodySearchSummary = Self.summaryText(for: outcome)

        // Results are a static answer — auto-follow would yank the user to the
        // bottom on the next capture.
        isAutoFollowing = false
        setFollowButtonVisible(false, animated: false)

        applyFilter()
        refreshBodyInfoBar()
        tableView.reloadData()
        tableView.layoutIfNeeded()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: false)
    }

    private static func summaryText(for outcome: ResponseBodySearch.Outcome) -> String {
        let hits = outcome.matches.count
        var parts: [String] = [
            hits == 1 ? "1 MATCH" : "\(hits) MATCHES",
            "\(outcome.totalCount) requests",
            "\(outcome.scannedCount) bodies read",
        ]
        if outcome.cacheHitCount > 0 { parts.append("\(outcome.cacheHitCount) cached") }
        if outcome.skippedCount > 0 { parts.append("\(outcome.skippedCount) skipped (media/binary/empty)") }
        if outcome.truncatedCount > 0 { parts.append("\(outcome.truncatedCount) capped") }
        parts.append("first \(ResponseBodySearch.byteCapDescription) per body")
        return parts.joined(separator: " · ")
    }

    // MARK: Info line (states the cap + the scan summary)

    private func refreshBodyInfoBar() {
        let state = currentTabState
        guard state.isBodySearchEnabled else {
            bodyInfoBar = nil
            if tableView?.tableHeaderView != nil { tableView.tableHeaderView = nil }
            return
        }

        let bar: BodySearchInfoBar
        if let existing = bodyInfoBar {
            bar = existing
        } else {
            let created = BodySearchInfoBar()
            created.onClear = { [weak self] in
                guard let self = self else { return }
                self.cancelActiveScan()
                self.clearBodyResults(for: self.currentTabState)
                self.applyFilter()
                self.refreshBodyInfoBar()
                self.tableView.reloadData()
            }
            bodyInfoBar = created
            bar = created
        }

        if state.isShowingBodyResults {
            bar.configure(
                title: "BODY RESULTS · \u{201C}\(state.bodySearchQuery)\u{201D}",
                detail: state.bodySearchSummary,
                showsClear: true
            )
        } else {
            bar.configure(
                title: "BODY SEARCH ARMED",
                detail: state.bodySearchSummary.isEmpty
                    ? "Type a term, then tap Search / Return to scan. Each body is read once, first \(ResponseBodySearch.byteCapDescription) only; media and binary bodies are skipped. Request bodies are searched too."
                    : state.bodySearchSummary,
                showsClear: false
            )
        }

        layoutBodyInfoBar()
        if tableView.tableHeaderView !== bar { tableView.tableHeaderView = bar }
    }

    /// `tableHeaderView` is frame-driven, so measure the card against the table
    /// width and re-assign whenever the size changes.
    private func layoutBodyInfoBar() {
        guard let bar = bodyInfoBar else { return }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        guard width > 0 else { return }
        let height = bar.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let newFrame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        guard bar.frame != newFrame else { return }
        bar.frame = newFrame
        if tableView.tableHeaderView === bar { tableView.tableHeaderView = bar }
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

        // Nav bar button: trash only
        deleteItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(tapTrashButton(_:)))
        deleteItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItems = [deleteItem]

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
        updateBodySearchButton()

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
        tableView.register(BodySearchMatchCell.self, forCellReuseIdentifier: "BodySearchMatchCell")
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
        refreshBodyInfoBar()
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

    private func createSearchRow() {
        searchRow = UIView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        searchBar = UISearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchBar)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)

        // Body-search scope button (BODY-SEARCH). Off by default so plain typing
        // stays index-only and instant.
        bodySearchButton = UIButton(type: .system)
        bodySearchButton.translatesAutoresizingMaskIntoConstraints = false
        bodySearchButton.setImage(UIImage(systemName: "doc.text.magnifyingglass", withConfiguration: iconConfig), for: .normal)
        bodySearchButton.tintColor = UIColor(white: 0.45, alpha: 1)
        bodySearchButton.layer.cornerRadius = 8
        bodySearchButton.layer.cornerCurve = .continuous
        bodySearchButton.addTarget(self, action: #selector(didTapBodySearchToggle), for: .touchUpInside)
        searchRow.addSubview(bodySearchButton)

        filterButton = UIButton(type: .system)
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.setImage(UIImage(systemName: "line.3.horizontal.decrease.circle", withConfiguration: iconConfig), for: .normal)
        filterButton.tintColor = DebugTheme.accentColor
        filterButton.addTarget(self, action: #selector(didTapFilter), for: .touchUpInside)
        searchRow.addSubview(filterButton)

        layoutToggleButton = UIButton(type: .system)
        layoutToggleButton.translatesAutoresizingMaskIntoConstraints = false
        layoutToggleButton.setImage(UIImage(systemName: "square.grid.2x2", withConfiguration: iconConfig), for: .normal)
        layoutToggleButton.tintColor = DebugTheme.accentColor
        layoutToggleButton.addTarget(self, action: #selector(didTapLayoutToggle), for: .touchUpInside)
        searchRow.addSubview(layoutToggleButton)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: searchRow.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: bodySearchButton.leadingAnchor),

            bodySearchButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            bodySearchButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -2),
            bodySearchButton.widthAnchor.constraint(equalToConstant: 32),
            bodySearchButton.heightAnchor.constraint(equalToConstant: 32),

            filterButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 34),
            filterButton.heightAnchor.constraint(equalToConstant: 34),

            layoutToggleButton.leadingAnchor.constraint(equalTo: filterButton.trailingAnchor, constant: 2),
            layoutToggleButton.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -8),
            layoutToggleButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            layoutToggleButton.widthAnchor.constraint(equalToConstant: 34),
            layoutToggleButton.heightAnchor.constraint(equalToConstant: 34),
        ])
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

            // Search row inside glass
            searchRow.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            searchRow.heightAnchor.constraint(equalToConstant: 44),
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

            // Search row
            searchRow.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            searchRow.heightAnchor.constraint(equalToConstant: 44),

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
        layoutBodyInfoBar()
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
        NotificationCenter.default.removeObserver(self)
    }

    //MARK: - Breakpoints

    /// Shows a "N paused" button in the nav bar while requests are held at a
    /// breakpoint (the app is genuinely waiting on them), and hides it otherwise.
    private func refreshBreakpointBadge() {
        let count = BreakpointCenter.shared.count
        guard count > 0 else {
            navigationItem.rightBarButtonItems = [deleteItem]
            return
        }
        let item = UIBarButtonItem(
            title: "⏸ \(count)", style: .plain,
            target: self, action: #selector(openPausedRequests))
        item.tintColor = .systemOrange
        item.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .normal)
        item.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .highlighted)
        navigationItem.rightBarButtonItems = [deleteItem, item]
    }

    @objc private func openPausedRequests() {
        let inbox = BreakpointInboxViewController()
        navigationController?.pushViewController(inbox, animated: true)
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

        currentTab = NetworkTab(rawValue: sender.selectedSegmentIndex) ?? .app
        NetworkViewController.savedTab = currentTab
        let newState = currentTabState

        searchBar.text = newState.searchText
        updateLayoutToggleIcon()
        updateFilterButtonIcon()
        updateBodySearchButton()
        refreshBodyInfoBar()

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
        state.searchText = searchText

        // Typing never reads a body. It only invalidates parked results once the
        // text no longer matches the query they were computed for.
        var didDropResults = false
        if state.isShowingBodyResults, searchText != state.bodySearchQuery {
            cancelActiveScan()
            clearBodyResults(for: state)
            didDropResults = true
        }

        if !searchText.isEmpty {
            isAutoFollowing = false
            setFollowButtonVisible(true, animated: true)
        }
        applyFilter()
        if didDropResults { refreshBodyInfoBar() }
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        // Submitting is the *only* trigger for a body scan.
        guard currentTabState.isBodySearchEnabled else { return }
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        startBodySearch(query: query)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        currentTabState.searchText = ""
        searchBar.resignFirstResponder()
        cancelActiveScan()
        clearBodyResults(for: currentTabState)
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        applyFilter()
        refreshBodyInfoBar()
        tableView.reloadData()
    }
}

//MARK: - UITableViewDataSource
extension NetworkViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isShowingBodyResults {
            let count = displayedMatches.count
            naviItemTitleLabel?.text = "\u{1f50e}[\(count)]"
            return count
        }
        if currentTabState.isGroupedMode {
            let count = groupedModels.count
            naviItemTitleLabel?.text = "\u{1f680}[\(count)]"
            return count
        } else {
            let count = models?.count ?? 0
            naviItemTitleLabel?.text = "\u{1f680}[\(count)]"
            return count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isShowingBodyResults {
            let cell = tableView.dequeueReusableCell(withIdentifier: "BodySearchMatchCell", for: indexPath) as! BodySearchMatchCell
            guard let models = models,
                  indexPath.row < models.count,
                  indexPath.row < displayedMatches.count else { return cell }
            cell.configure(
                model: models[indexPath.row],
                match: displayedMatches[indexPath.row],
                rank: indexPath.row + 1
            )
            return cell
        }
        if currentTabState.isGroupedMode {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkGroupCell", for: indexPath) as! NetworkGroupCell
            guard indexPath.row < groupedModels.count else { return cell }
            cell.configure(with: groupedModels[indexPath.row])
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkCell", for: indexPath) as! NetworkCell
            guard let models = models, indexPath.row < models.count else { return cell }
            cell.index = indexPath.row
            cell.httpModel = models[indexPath.row]
            return cell
        }
    }
}

//MARK: - UITableViewDelegate
extension NetworkViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if isShowingBodyResults {
            guard let models = models, indexPath.row < models.count else { return }
            models[indexPath.row].isViewed = true
            tableView.reloadRows(at: [indexPath], with: .none)

            let vc = NetworkDetailViewController()
            vc.httpModels = models
            vc.httpModel = models[indexPath.row]
            isShowingDetail = true
            navigationController?.pushViewController(vc, animated: true)
            return
        }

        if currentTabState.isGroupedMode {
            guard indexPath.row < groupedModels.count else { return }
            let group = groupedModels[indexPath.row]
            let vc = NetworkGroupDetailVC()
            vc.title = group.displayName
            vc.models = group.models
            vc.groupKey = group.key
            vc.isPathFilter = group.isPathFilter
            isShowingDetail = true
            navigationController?.pushViewController(vc, animated: true)
        } else {
            reachEnd = false
            guard let models = models, indexPath.row < models.count else { return }

            models[indexPath.row].isViewed = true
            tableView.reloadRows(at: [indexPath], with: .none)

            let vc = NetworkDetailViewController()
            vc.httpModels = models
            vc.httpModel = models[indexPath.row]
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
        // Only in flat (non-grouped) mode
        guard !currentTabState.isGroupedMode,
              let models = models,
              indexPath.row < models.count else { return nil }

        let model = models[indexPath.row]
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

//MARK: - Body search info line (states the 2 MB cap + last-scan summary)

/// Card shown as the list's `tableHeaderView` while body search is armed.
/// Explains the scan rules before the first scan, and summarises the last scan
/// afterwards (with a Clear button to drop the results).
private final class BodySearchInfoBar: UIView {

    var onClear: (() -> Void)?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let clearButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = .clear

        card.backgroundColor = BodySearchStyle.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = BodySearchStyle.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = BodySearchStyle.caption
        detailLabel.numberOfLines = 0

        clearButton.setImage(
            UIImage(systemName: "xmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal
        )
        clearButton.tintColor = BodySearchStyle.caption
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, clearButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    func configure(title: String, detail: String, showsClear: Bool) {
        titleLabel.text = title
        detailLabel.text = detail
        clearButton.isHidden = !showsClear
    }

    @objc private func clearTapped() { onClear?() }
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

//MARK: - Body search result row

/// One body hit: request identity on top, then the snippet with the matched term
/// highlighted in context.
///
/// Content is pinned with real constraints to **both** the top and the bottom of
/// `contentView` (card → stack → labels), so the multi-line snippet drives the
/// row height under `automaticDimension` instead of collapsing.
private final class BodySearchMatchCell: UITableViewCell {

    private let card = UIView()
    private let statusLine = UIView()

    private let rankLabel = UILabel()
    private let methodLabel = UILabel()
    private let sideBadge = BodySearchBadgeLabel()
    private let occurrenceLabel = UILabel()
    private let cappedBadge = BodySearchBadgeLabel()
    private let statusLabel = UILabel()
    private let urlLabel = UILabel()
    private let snippetLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = BodySearchStyle.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = BodySearchStyle.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLine)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        rankLabel.textColor = UIColor(white: 0.55, alpha: 1)
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        methodLabel.font = .systemFont(ofSize: 11, weight: .bold)
        methodLabel.textColor = UIColor(white: 0.55, alpha: 1)
        methodLabel.setContentHuggingPriority(.required, for: .horizontal)

        occurrenceLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        occurrenceLabel.textColor = BodySearchStyle.caption
        occurrenceLabel.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        statusLabel.textAlignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [
            rankLabel, methodLabel, sideBadge, occurrenceLabel, cappedBadge, spacer, statusLabel,
        ])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        urlLabel.font = .systemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = BodySearchStyle.value
        urlLabel.numberOfLines = 2
        urlLabel.lineBreakMode = .byTruncatingMiddle

        snippetLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        snippetLabel.textColor = BodySearchStyle.snippet
        snippetLabel.numberOfLines = 3
        snippetLabel.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [topRow, urlLabel, snippetLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            statusLine.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: card.topAnchor),
            statusLine.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            statusLine.widthAnchor.constraint(equalToConstant: 3),

            stack.leadingAnchor.constraint(equalTo: statusLine.trailingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    func configure(model: NetworkTransaction, match: BodySearchMatch, rank: Int) {
        rankLabel.text = String(rank)
        methodLabel.text = model.method.map { "[\($0)]" } ?? ""

        let code = model.statusCode ?? "0"
        let statusColor = NetworkCell.colorForStatusCode(code)
        statusLabel.text = code == "0" ? "\u{274C}" : code
        statusLabel.textColor = statusColor
        statusLine.backgroundColor = statusColor

        // Which side matched — the whole point of the badge.
        switch match.side {
        case .response:
            sideBadge.apply(text: "RESPONSE", color: DebugTheme.accentColor)
        case .request:
            sideBadge.apply(text: "REQUEST", color: BodySearchStyle.requestBadge)
        }

        occurrenceLabel.text = match.occurrences > 1 ? "\(match.occurrences)\u{00D7}" : nil
        occurrenceLabel.isHidden = match.occurrences <= 1

        cappedBadge.isHidden = !match.isTruncatedScan
        if match.isTruncatedScan {
            cappedBadge.apply(text: "CAPPED", color: .systemOrange)
        }

        urlLabel.text = model.url?.absoluteString ?? ""
        snippetLabel.attributedText = Self.highlighted(match: match)
    }

    /// Snippet with the matched term picked out in the accent color.
    private static func highlighted(match: BodySearchMatch) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: match.snippet,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: BodySearchStyle.snippet,
            ]
        )
        let full = NSRange(location: 0, length: text.length)
        let range = match.highlightRange
        guard range.length > 0, NSIntersectionRange(range, full).length == range.length else {
            return text
        }
        text.addAttributes([
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: DebugTheme.accentColor,
            .backgroundColor: DebugTheme.accentColor.withAlphaComponent(0.18),
        ], range: range)
        return text
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        snippetLabel.attributedText = nil
        occurrenceLabel.text = nil
        cappedBadge.isHidden = true
    }
}

//MARK: - Small pill label used by the result row

private final class BodySearchBadgeLabel: UILabel {

    private let insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 9, weight: .heavy)
        textAlignment = .center
        layer.cornerRadius = 4
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func apply(text: String, color: UIColor) {
        self.text = text
        textColor = color
        backgroundColor = color.withAlphaComponent(0.20)
        isHidden = false
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: ceil(size.width) + insets.left + insets.right,
                      height: ceil(size.height) + insets.top + insets.bottom)
    }
}
