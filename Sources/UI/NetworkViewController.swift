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
        guard let allCacheModels = cacheModels, !allCacheModels.isEmpty else { return [] }

        // Filter by current tab first (respecting settings toggles)
        let allModels: [NetworkTransaction]
        switch currentTab {
        case .app:
            allModels = Settings.shared.networkRequestsEnabled
                ? allCacheModels.filter { !$0.isWebViewRequest }
                : []
        case .web:
            allModels = Settings.shared.webNetworkRequestsEnabled
                ? allCacheModels.filter { $0.isWebViewRequest }
                : []
        case .pinned: allModels = allCacheModels.filter { $0.isPinned }
        }
        guard !allModels.isEmpty else { return [] }

        let onlyURLs = SwiftyDebug.urls
        var rawEntries: [(display: String, filterKey: String, isPathFilter: Bool, isWeb: Bool)] = []
        var coveredHosts = Set<String>()

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

        // Sort by priority then alphabetically
        let sorted = rawEntries.sorted {
            let priorityA = $0.isPathFilter ? 0 : ($0.isWeb ? 1 : 2)
            let priorityB = $1.isPathFilter ? 0 : ($1.isWeb ? 1 : 2)
            if priorityA != priorityB { return priorityA < priorityB }
            return $0.display.lowercased() < $1.display.lowercased()
        }

        // Deduplicate by display label — merge all filterKeys under the same tag into one row
        var displayOrder: [String] = []
        var mergedMap: [String: (filterKeys: [(key: String, isPathFilter: Bool)], isWeb: Bool)] = [:]
        for entry in sorted {
            let key = entry.display.lowercased()
            if mergedMap[key] == nil {
                displayOrder.append(entry.display)
                mergedMap[key] = (filterKeys: [], isWeb: false)
            }
            mergedMap[key]!.filterKeys.append((key: entry.filterKey, isPathFilter: entry.isPathFilter))
            if entry.isWeb { mergedMap[key]!.isWeb = true }
        }
        return displayOrder.map { display in
            let info = mergedMap[display.lowercased()]!
            return (display: display, filterKeys: info.filterKeys, isWeb: info.isWeb)
        }
    }

    /// Returns the tag label from networkTagMap whose key is a substring of the full URL,
    /// or nil if no custom tag matches.
    private func tagLabel(forURLString urlString: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        let lower = urlString.lowercased()
        // Direct key lookup first (most common case: urls key == tag keyword)
        if let label = map[urlString] { return label }
        // Substring match fallback
        for (keyword, label) in map where lower.contains(keyword.lowercased()) {
            return label
        }
        return nil
    }

    /// Returns the tag label whose keyword matches the given host, or nil.
    private func tagLabel(forHost host: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        for (keyword, label) in map where host.contains(keyword.lowercased()) {
            return label
        }
        return nil
    }

    private func uniqueEndpointsForFilters(pathFilters: Set<String>, hostFilters: Set<String>) -> [FilterableEndpoint] {
        guard let allCache = cacheModels else { return [] }
        // Filter by current tab (respecting settings toggles)
        let models: [NetworkTransaction]
        switch currentTab {
        case .app:
            models = Settings.shared.networkRequestsEnabled
                ? allCache.filter { !$0.isWebViewRequest }
                : []
        case .web:
            models = Settings.shared.webNetworkRequestsEnabled
                ? allCache.filter { $0.isWebViewRequest }
                : []
        case .pinned: models = allCache.filter { $0.isPinned }
        }
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
        let components = path.components(separatedBy: "/")
        let normalized = components.map { component -> String in
            if component.isEmpty { return component }
            if component.allSatisfy({ $0.isNumber || $0 == "-" }) && component.contains(where: { $0.isNumber }) {
                return "{id}"
            }
            if UUID(uuidString: component) != nil { return "{id}" }
            return component
        }
        return normalized.joined(separator: "/")
    }

    //MARK: - Filter logic

    private func applyFilter() {
        guard let cacheModels = cacheModels else {
            models = nil
            groupedModels = []
            return
        }

        let state = currentTabState

        // 1. Tab segment filter (respecting settings toggles)
        var filtered: [NetworkTransaction]
        switch currentTab {
        case .app:
            filtered = Settings.shared.networkRequestsEnabled
                ? cacheModels.filter { !$0.isWebViewRequest }
                : []
        case .web:
            filtered = Settings.shared.webNetworkRequestsEnabled
                ? cacheModels.filter { $0.isWebViewRequest }
                : []
        case .pinned: filtered = cacheModels.filter { $0.isPinned }
        }

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

        // 4. Search text filter
        if !state.searchText.isEmpty {
            let query = state.searchText.lowercased()
            filtered = filtered.filter { model in
                (model.url?.absoluteString ?? "").lowercased().contains(query)
            }
        }

        models = filtered

        // 5. Build groups if in grouped mode
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
        if entries.isEmpty { return }

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
            string: "Search URL...",
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

        //notification
        NotificationCenter.default.addObserver(forName: .networkRequestCompleted, object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.reloadHttp()
        }

        tableView.tableFooterView = UIView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.register(NetworkCell.self, forCellReuseIdentifier: "NetworkCell")
        tableView.register(NetworkGroupCell.self, forCellReuseIdentifier: "NetworkGroupCell")
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

    private func createSearchRow() {
        searchRow = UIView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        searchBar = UISearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchBar)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)

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
            searchBar.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor),

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
        NotificationCenter.default.removeObserver(self)
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

        currentTab = NetworkTab(rawValue: sender.selectedSegmentIndex) ?? .app
        NetworkViewController.savedTab = currentTab
        let newState = currentTabState

        searchBar.text = newState.searchText
        updateLayoutToggleIcon()
        updateFilterButtonIcon()

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
        currentTabState.searchText = searchText
        if !searchText.isEmpty {
            isAutoFollowing = false
            setFollowButtonVisible(true, animated: true)
        }
        applyFilter()
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        currentTabState.searchText = ""
        searchBar.resignFirstResponder()
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        applyFilter()
        tableView.reloadData()
    }
}

//MARK: - UITableViewDataSource
extension NetworkViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
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
