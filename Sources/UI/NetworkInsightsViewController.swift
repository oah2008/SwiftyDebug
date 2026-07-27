//
//  NetworkInsightsViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Insights dashboard — an aggregated read of everything captured this session.
///
/// Sections: overview, status breakdown, per host, per endpoint, slowest
/// requests, largest responses. Every number comes from `NetworkInsightsEngine`,
/// which runs **off the main thread** (the store can hold hundreds of
/// transactions) and never touches the disk-backed request/response bodies.
///
/// Entry point: `NetworkInsightsViewController()` — no arguments. Push it onto
/// any `SwiftyDebugNavigationController` (or present it inside one).
final class NetworkInsightsViewController: UITableViewController {

    // MARK: - Sections

    private enum Section {
        case empty
        case overview
        case status
        case hosts
        case endpoints
        case slowest
        case largest

        var title: String? {
            switch self {
            case .empty:     return nil
            case .overview:  return "OVERVIEW"
            case .status:    return "STATUS BREAKDOWN"
            case .hosts:     return "BY HOST"
            case .endpoints: return "BY ENDPOINT"
            case .slowest:   return "SLOWEST REQUESTS"
            case .largest:   return "LARGEST RESPONSES"
            }
        }
    }

    // MARK: - Config

    /// How many endpoints are listed before the "show all" row appears.
    private static let endpointPreviewCount = 20
    /// Live-update coalescing window — captures arrive in bursts.
    private static let coalesceInterval: TimeInterval = 0.8

    // MARK: - State

    private var snapshot: InsightsSnapshot = .empty(scope: .all)
    private var sections: [Section] = [.empty]
    private var scope: InsightsScope = .all
    private var expandedHosts: Set<String> = []
    private var showAllEndpoints = false

    private var isVisible = false
    private var hasPendingUpdate = false
    private var coalesceItem: DispatchWorkItem?
    /// Guards against an older background pass landing after a newer one.
    private var generation = 0

    private let aggregationQueue = DispatchQueue(label: "com.swiftydebug.insights.aggregate",
                                                 qos: .userInitiated)

    private let scopeControl = UISegmentedControl(items: InsightsScope.allCases.map { $0.title })
    /// Container for `scopeControl`. A `tableHeaderView` is *not* laid out by the
    /// table's own constraints — it keeps whatever frame we give it — so it is
    /// sized explicitly here and re-sized in `viewDidLayoutSubviews`.
    private let scopeHeader = UIView()
    /// Width the header frame was last computed for (rotation / split-view guard).
    private var scopeHeaderWidth: CGFloat = -1
    /// Vertical padding around the segmented control inside the header.
    private static let scopeHeaderPadding: CGFloat = 11
    /// Horizontal inset of the control from the table's readable edges.
    private static let scopeHeaderInset: CGFloat = 12
    private static let scopeControlHeight: CGFloat = 32

    // MARK: - Init

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        coalesceItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Insights"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        let refresh = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                                      style: .plain, target: self, action: #selector(refreshTapped))
        refresh.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = refresh

        setupScopeHeader()

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        tableView.estimatedSectionHeaderHeight = 36
        tableView.contentInset.bottom = 24
        tableView.register(InsightsMetricGridCell.self, forCellReuseIdentifier: InsightsMetricGridCell.reuseID)
        tableView.register(InsightsStatusBarCell.self, forCellReuseIdentifier: InsightsStatusBarCell.reuseID)
        tableView.register(InsightsHostCell.self, forCellReuseIdentifier: InsightsHostCell.reuseID)
        tableView.register(InsightsEndpointCell.self, forCellReuseIdentifier: InsightsEndpointCell.reuseID)
        tableView.register(InsightsRequestCell.self, forCellReuseIdentifier: InsightsRequestCell.reuseID)
        tableView.register(InsightsActionCell.self, forCellReuseIdentifier: InsightsActionCell.reuseID)
        tableView.register(InsightsMessageCell.self, forCellReuseIdentifier: InsightsMessageCell.reuseID)

        NotificationCenter.default.addObserver(
            self, selector: #selector(networkRequestCompleted),
            name: .networkRequestCompleted, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(logsCleared),
            name: .allLogsCleared, object: nil)

        rebuild()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        // Anything captured while we were off screen is folded in now.
        if hasPendingUpdate {
            hasPendingUpdate = false
            rebuild()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        coalesceItem?.cancel()
        coalesceItem = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The table hands the header its width but never its height, and never
        // re-runs the header's own sizing. Do it here so rotation / iPad split
        // keeps the control inside the table.
        sizeScopeHeaderIfNeeded()
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.sizeScopeHeaderIfNeeded()
        }
    }

    private func setupScopeHeader() {
        scopeControl.selectedSegmentIndex = scope.rawValue
        scopeControl.selectedSegmentTintColor = DebugTheme.accentColor
        scopeControl.backgroundColor = UIColor(white: 0.13, alpha: 1)
        scopeControl.setTitleTextAttributes([
            .foregroundColor: UIColor(white: 0.65, alpha: 1),
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
        ], for: .normal)
        scopeControl.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
        ], for: .selected)
        scopeControl.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        scopeControl.apportionsSegmentWidthsByContent = false

        // The control is pinned to the *header* with real constraints (against
        // the safe area, so a notch in landscape can't clip it). The header
        // itself stays frame-based — that is the only sizing a tableHeaderView
        // understands — and its frame is recomputed in `sizeScopeHeaderIfNeeded`.
        scopeHeader.backgroundColor = .black
        scopeHeader.autoresizingMask = [.flexibleWidth]
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeHeader.addSubview(scopeControl)

        let guide = scopeHeader.safeAreaLayoutGuide
        let inset = Self.scopeHeaderInset
        let pad = Self.scopeHeaderPadding
        // Leading/trailing are `equalTo` so the control always spans the full
        // width minus the inset; the width constraint is a low-priority floor
        // that only matters before the header has a real width.
        let minWidth = scopeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        minWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            scopeControl.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            scopeControl.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            scopeControl.topAnchor.constraint(equalTo: scopeHeader.topAnchor, constant: pad),
            scopeControl.bottomAnchor.constraint(equalTo: scopeHeader.bottomAnchor, constant: -pad),
            scopeControl.heightAnchor.constraint(equalToConstant: Self.scopeControlHeight),
            minWidth,
        ])
        scopeHeader.forceLTR()

        // `view.bounds` is not final in viewDidLoad — this is only a placeholder
        // wide enough to keep the constraints satisfiable until the first
        // `viewDidLayoutSubviews` installs the real width.
        let seedWidth = view.bounds.width > 0 ? view.bounds.width : 320
        scopeHeader.frame = CGRect(x: 0, y: 0, width: seedWidth, height: Self.scopeHeaderHeight)
        tableView.tableHeaderView = scopeHeader
    }

    private static var scopeHeaderHeight: CGFloat {
        scopeControlHeight + scopeHeaderPadding * 2
    }

    /// Gives the table header an explicit frame matching the current table
    /// width. Re-assigning `tableHeaderView` is what makes the table adopt a new
    /// header height; it is only done when something actually changed, otherwise
    /// it would re-trigger layout forever.
    private func sizeScopeHeaderIfNeeded() {
        guard isViewLoaded, tableView.tableHeaderView === scopeHeader else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = Self.scopeHeaderHeight
        guard abs(scopeHeaderWidth - width) > 0.5
                || abs(scopeHeader.frame.height - height) > 0.5 else { return }

        scopeHeaderWidth = width
        scopeHeader.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scopeHeader.setNeedsLayout()
        scopeHeader.layoutIfNeeded()
        tableView.tableHeaderView = scopeHeader
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        hasPendingUpdate = false
        rebuild()
    }

    @objc private func scopeChanged() {
        scope = InsightsScope(rawValue: scopeControl.selectedSegmentIndex) ?? .all
        expandedHosts.removeAll()
        showAllEndpoints = false
        rebuild()
    }

    // MARK: - Live updates

    @objc private func networkRequestCompleted() {
        // The capture path posts from network threads.
        guard SwiftyDebugRuntime.isActive else { return }
        onMain { [weak self] in
            guard let self else { return }
            self.hasPendingUpdate = true
            guard self.isVisible else { return }   // no work while off screen
            self.scheduleCoalescedRebuild()
        }
    }

    @objc private func logsCleared() {
        onMain { [weak self] in
            guard let self else { return }
            self.hasPendingUpdate = false
            self.coalesceItem?.cancel()
            self.coalesceItem = nil
            self.expandedHosts.removeAll()
            self.showAllEndpoints = false
            self.rebuild()
        }
    }

    /// Bursts of captures collapse into one aggregation pass.
    private func scheduleCoalescedRebuild() {
        guard coalesceItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coalesceItem = nil
            guard self.isVisible, self.hasPendingUpdate else { return }
            self.hasPendingUpdate = false
            self.rebuild()
        }
        coalesceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: item)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Aggregation

    /// Snapshots the store on the main thread, aggregates on a background queue,
    /// applies the result back on main.
    private func rebuild() {
        // The store mutates `httpModels` from network threads under
        // `objc_sync_enter(store)`; take the same lock for the copy so the
        // bridge can't read a half-mutated NSMutableArray. Held only for the
        // copy — the aggregation itself runs unlocked, off this thread.
        let store = NetworkRequestStore.shared
        objc_sync_enter(store)
        let models = (store.httpModels.copy() as? NSArray as? [NetworkTransaction]) ?? []
        objc_sync_exit(store)

        let scope = self.scope
        generation += 1
        let token = generation

        aggregationQueue.async { [weak self] in
            let result = NetworkInsightsEngine.snapshot(from: models, scope: scope)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ new: InsightsSnapshot) {
        snapshot = new
        let liveHosts = Set(new.hosts.map { $0.host })
        expandedHosts.formIntersection(liveHosts)

        if new.isEmpty {
            sections = [.empty]
        } else {
            sections = [.overview, .status, .hosts, .endpoints]
            if !new.slowest.isEmpty { sections.append(.slowest) }
            if !new.largest.isEmpty { sections.append(.largest) }
        }
        tableView.reloadData()
    }

    // MARK: - Derived counts

    private var visibleEndpointCount: Int {
        showAllEndpoints
            ? snapshot.endpoints.count
            : min(Self.endpointPreviewCount, snapshot.endpoints.count)
    }

    private var endpointsNeedToggle: Bool {
        snapshot.endpoints.count > Self.endpointPreviewCount
    }

    // MARK: - Table data source

    /// Every data-source/delegate entry point goes through this: UIKit can ask
    /// about a section index from *before* an async rebuild replaced `sections`.
    private func section(at index: Int) -> Section? {
        guard index >= 0, index < sections.count else { return nil }
        return sections[index]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let kind = self.section(at: section) else { return 0 }
        switch kind {
        case .empty, .overview, .status:
            return 1
        case .hosts:
            return snapshot.hosts.count
        case .endpoints:
            return visibleEndpointCount + (endpointsNeedToggle ? 1 : 0)
        case .slowest:
            return snapshot.slowest.count
        case .largest:
            return snapshot.largest.count
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let kind = self.section(at: section), let title = kind.title else { return nil }
        return InsightsSectionHeader(title: title, detail: headerDetail(for: kind))
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let kind = self.section(at: section), kind.title != nil else { return .leastNormalMagnitude }
        return 38
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    private func headerDetail(for section: Section) -> String? {
        switch section {
        case .hosts:
            return snapshot.hosts.count == 1 ? "1 HOST" : "\(snapshot.hosts.count) HOSTS"
        case .endpoints:
            let total = snapshot.endpoints.count
            if endpointsNeedToggle && !showAllEndpoints {
                return "TOP \(Self.endpointPreviewCount) OF \(total)"
            }
            return total == 1 ? "1 PATH" : "\(total) PATHS"
        case .slowest, .largest:
            return "TOP \(NetworkInsightsEngine.topRequestCount)"
        default:
            return nil
        }
    }

    /// Typed dequeue that never force-casts (a stale/duplicate registration
    /// elsewhere in the debugger must not take the host app down).
    private func dequeue<T: UITableViewCell>(_ type: T.Type,
                                             id: String,
                                             at indexPath: IndexPath) -> T? {
        tableView.dequeueReusableCell(withIdentifier: id, for: indexPath) as? T
    }

    private func blankCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let kind = section(at: indexPath.section) else { return blankCell() }
        switch kind {

        case .empty:
            guard let cell = dequeue(InsightsMessageCell.self,
                                     id: InsightsMessageCell.reuseID, at: indexPath) else { return blankCell() }
            cell.configure(title: "Nothing captured yet",
                           body: emptyStateBody)
            return cell

        case .overview:
            guard let cell = dequeue(InsightsMetricGridCell.self,
                                     id: InsightsMetricGridCell.reuseID, at: indexPath) else { return blankCell() }
            cell.configure(metrics: overviewMetrics, columns: 3)
            return cell

        case .status:
            guard let cell = dequeue(InsightsStatusBarCell.self,
                                     id: InsightsStatusBarCell.reuseID, at: indexPath) else { return blankCell() }
            cell.configure(slices: snapshot.statusSlices, total: snapshot.overview.totalRequests)
            return cell

        case .hosts:
            guard indexPath.row >= 0, indexPath.row < snapshot.hosts.count,
                  let cell = dequeue(InsightsHostCell.self,
                                     id: InsightsHostCell.reuseID, at: indexPath) else { return blankCell() }
            let host = snapshot.hosts[indexPath.row]
            cell.configure(host: host, expanded: expandedHosts.contains(host.host))
            return cell

        case .endpoints:
            if indexPath.row >= visibleEndpointCount {
                guard let cell = dequeue(InsightsActionCell.self,
                                         id: InsightsActionCell.reuseID, at: indexPath) else { return blankCell() }
                cell.configure(title: showAllEndpoints
                    ? "SHOW TOP \(Self.endpointPreviewCount)"
                    : "SHOW ALL \(snapshot.endpoints.count) ENDPOINTS")
                return cell
            }
            guard indexPath.row >= 0, indexPath.row < snapshot.endpoints.count,
                  let cell = dequeue(InsightsEndpointCell.self,
                                     id: InsightsEndpointCell.reuseID, at: indexPath) else { return blankCell() }
            cell.configure(endpoint: snapshot.endpoints[indexPath.row], rank: indexPath.row + 1)
            return cell

        case .slowest:
            guard indexPath.row >= 0, indexPath.row < snapshot.slowest.count,
                  let cell = dequeue(InsightsRequestCell.self,
                                     id: InsightsRequestCell.reuseID, at: indexPath) else { return blankCell() }
            let stat = snapshot.slowest[indexPath.row]
            cell.configure(stat: stat, rank: indexPath.row + 1,
                           highlight: InsightsFormat.duration(ms: stat.durationMs),
                           highlightTint: InsightsPalette.durationTint(ms: stat.durationMs))
            return cell

        case .largest:
            guard indexPath.row >= 0, indexPath.row < snapshot.largest.count,
                  let cell = dequeue(InsightsRequestCell.self,
                                     id: InsightsRequestCell.reuseID, at: indexPath) else { return blankCell() }
            let stat = snapshot.largest[indexPath.row]
            cell.configure(stat: stat, rank: indexPath.row + 1,
                           highlight: InsightsFormat.bytes(stat.responseBytes),
                           highlightTint: DebugTheme.accentColor)
            return cell
        }
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        // A rebuild can land between the touch starting and this callback, so
        // the index is re-validated against the *current* snapshot, never
        // trusted because the row was tappable a moment ago.
        guard let kind = section(at: indexPath.section) else { return }
        switch kind {
        case .hosts:
            guard indexPath.row >= 0, indexPath.row < snapshot.hosts.count else { return }
            let host = snapshot.hosts[indexPath.row].host
            if expandedHosts.contains(host) {
                expandedHosts.remove(host)
            } else {
                expandedHosts.insert(host)
            }
            reload(rowAt: indexPath)
        case .endpoints:
            guard indexPath.row >= visibleEndpointCount else { return }
            showAllEndpoints.toggle()
            reload(sectionAt: indexPath.section)
        default:
            break
        }
    }

    /// `reloadRows` traps when the path no longer exists in the table's own
    /// bookkeeping; fall back to a full reload in that case.
    private func reload(rowAt indexPath: IndexPath) {
        guard indexPath.section >= 0, indexPath.section < tableView.numberOfSections,
              indexPath.row >= 0,
              indexPath.row < tableView.numberOfRows(inSection: indexPath.section) else {
            tableView.reloadData()
            return
        }
        tableView.reloadRows(at: [indexPath], with: .fade)
    }

    private func reload(sectionAt index: Int) {
        guard index >= 0, index < tableView.numberOfSections, index < sections.count else {
            tableView.reloadData()
            return
        }
        tableView.reloadSections(IndexSet(integer: index), with: .automatic)
    }

    // MARK: - Content builders

    private var emptyStateBody: String {
        switch scope {
        case .all: return "Make some network requests and they will be summarised here."
        case .app: return "No app (URLSession) traffic captured in this session yet."
        case .web: return "No web-view traffic captured in this session yet."
        }
    }

    private var overviewMetrics: [InsightsMetric] {
        let o = snapshot.overview
        let errorTint: UIColor = o.errorCount > 0 ? .systemRed : UIColor(white: 0.92, alpha: 1)
        return [
            InsightsMetric(caption: "REQUESTS",
                           value: InsightsFormat.count(o.totalRequests),
                           tint: DebugTheme.accentColor),
            InsightsMetric(caption: "ERRORS",
                           value: "\(InsightsFormat.count(o.errorCount))",
                           tint: errorTint),
            InsightsMetric(caption: "ERROR RATE",
                           value: InsightsFormat.percent(o.errorRate),
                           tint: errorTint),
            InsightsMetric(caption: "SENT", value: InsightsFormat.bytes(o.bytesSent)),
            InsightsMetric(caption: "RECEIVED", value: InsightsFormat.bytes(o.bytesReceived)),
            InsightsMetric(caption: "SESSION",
                           value: InsightsFormat.elapsed(seconds: o.sessionDuration)),
            InsightsMetric(caption: "AVG",
                           value: InsightsFormat.duration(ms: o.averageDurationMs),
                           tint: InsightsPalette.durationTint(ms: o.averageDurationMs)),
            InsightsMetric(caption: "P50",
                           value: InsightsFormat.duration(ms: o.p50DurationMs),
                           tint: InsightsPalette.durationTint(ms: o.p50DurationMs)),
            InsightsMetric(caption: "P95",
                           value: InsightsFormat.duration(ms: o.p95DurationMs),
                           tint: InsightsPalette.durationTint(ms: o.p95DurationMs)),
        ]
    }
}

// MARK: - Palette

/// Shared colors for the dashboard. Matches the rest of the debugger: black
/// canvas, dark cards, teal accent, semantic status colors.
enum InsightsPalette {
    static let cardBackground = UIColor(white: 0.13, alpha: 1)
    static let cardHighlight = UIColor(white: 0.20, alpha: 1)
    static let cardBorder = UIColor(white: 0.24, alpha: 1)
    static let caption = UIColor(white: 0.45, alpha: 1)
    static let value = UIColor(white: 0.92, alpha: 1)
    static let secondary = UIColor(white: 0.55, alpha: 1)
    static let separator = UIColor(white: 0.22, alpha: 1)

    static func color(for bucket: InsightsStatusBucket) -> UIColor {
        switch bucket {
        case .success:     return .systemGreen
        case .redirect:    return .systemBlue
        case .clientError: return .systemOrange
        case .serverError: return .systemRed
        case .failed:      return UIColor.systemRed.withAlphaComponent(0.55)
        }
    }

    /// Green under 300ms, orange under 1s, red beyond.
    static func durationTint(ms: Double) -> UIColor {
        guard ms > 0 else { return value }
        if ms < 300 { return .systemGreen }
        if ms < 1000 { return .systemOrange }
        return .systemRed
    }

    static func errorRateTint(_ rate: Double) -> UIColor {
        if rate <= 0 { return .systemGreen }
        if rate < 0.1 { return .systemOrange }
        return .systemRed
    }
}

// MARK: - Display clamping

/// Captured hosts / paths are arbitrary length. Clamping the *displayed* string
/// keeps a pathological URL from producing a row thousands of points tall (the
/// labels wrap by character, so nothing overflows — it just grows).
private func insightsClamped(_ text: String, max limit: Int = 240) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
}

// MARK: - Metric model

struct InsightsMetric {
    let caption: String
    let value: String
    let tint: UIColor

    init(caption: String, value: String, tint: UIColor = InsightsPalette.value) {
        self.caption = caption
        self.value = value
        self.tint = tint
    }
}

// MARK: - Section header

/// Caption-style section header (title + optional trailing detail).
private final class InsightsSectionHeader: UIView {

    init(title: String, detail: String?) {
        super.init(frame: .zero)
        backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        titleLabel.textColor = InsightsPalette.caption
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        detailLabel.textColor = DebugTheme.accentColor.withAlphaComponent(0.8)
        detailLabel.textAlignment = .right
        detailLabel.numberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        // High, not required: an unexpectedly long detail must truncate rather
        // than break the trailing constraint and spill past the edge.
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Base card cell

/// Base for every insights row: one card inset 12 from the edges, with a
/// vertical `body` stack pinned to **both** the card's top and bottom so the
/// content drives the row height (stock textLabel + automaticDimension does not
/// create those constraints and collapses/clips — see KeyValueCardCell).
class InsightsCardCell: UITableViewCell {

    let card = UIView()
    let body = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCard()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupCard() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = InsightsPalette.cardBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = InsightsPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        body.axis = .vertical
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
        ])
        forceLTR()
    }

    // MARK: Shared builders

    /// Caption over monospaced value, used as a tile inside metric grids.
    static func tile(_ metric: InsightsMetric, valueSize: CGFloat = 15) -> UIView {
        let caption = UILabel()
        caption.text = metric.caption
        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textColor = InsightsPalette.caption
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.8

        let value = UILabel()
        value.text = metric.value
        value.font = .monospacedSystemFont(ofSize: valueSize, weight: .semibold)
        value.textColor = metric.tint
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.7
        value.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [caption, value])
        stack.axis = .vertical
        stack.spacing = 3
        stack.semanticContentAttribute = .forceLeftToRight
        return stack
    }

    /// Rows of equally sized tiles (padded with spacers so columns line up).
    static func metricRows(_ metrics: [InsightsMetric],
                           columns: Int,
                           valueSize: CGFloat = 15) -> [UIView] {
        guard columns > 0, !metrics.isEmpty else { return [] }
        var rows: [UIView] = []
        var index = 0
        while index < metrics.count {
            let slice = Array(metrics[index..<min(index + columns, metrics.count)])
            var views: [UIView] = slice.map { tile($0, valueSize: valueSize) }
            while views.count < columns { views.append(UIView()) }
            let row = UIStackView(arrangedSubviews: views)
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.alignment = .fill
            row.spacing = 10
            row.semanticContentAttribute = .forceLeftToRight
            rows.append(row)
            index += columns
        }
        return rows
    }

    static func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = InsightsPalette.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Removes every arranged subview from `body` (cells rebuild on configure).
    func resetBody() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

// MARK: - Tappable card cell

/// Card cell that highlights on press (selectionStyle is `.none`).
class InsightsTappableCardCell: InsightsCardCell {
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.12) {
            self.card.backgroundColor = highlighted
                ? InsightsPalette.cardHighlight
                : InsightsPalette.cardBackground
        }
    }
}

// MARK: - Overview grid

/// The OVERVIEW card: a grid of caption/value tiles.
final class InsightsMetricGridCell: InsightsCardCell {

    static let reuseID = "InsightsMetricGrid"

    func configure(metrics: [InsightsMetric], columns: Int) {
        resetBody()
        body.spacing = 14
        for row in Self.metricRows(metrics, columns: columns) {
            body.addArrangedSubview(row)
        }
        forceLTR()
    }
}

// MARK: - Status breakdown

/// Proportional horizontal bar + legend.
final class InsightsStatusBarCell: InsightsCardCell {

    static let reuseID = "InsightsStatusBar"

    private let bar = InsightsProportionBar()
    private let legend = UIStackView()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        body.spacing = 12

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        legend.axis = .vertical
        legend.spacing = 7

        body.addArrangedSubview(bar)
        body.addArrangedSubview(legend)
    }

    func configure(slices: [InsightsStatusSlice], total: Int) {
        buildIfNeeded()
        bar.set(segments: slices
            .filter { $0.count > 0 }
            .map { (InsightsPalette.color(for: $0.bucket), CGFloat($0.fraction)) })

        for view in legend.arrangedSubviews {
            legend.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for slice in slices where slice.count > 0 {
            legend.addArrangedSubview(makeLegendRow(slice))
        }
        if legend.arrangedSubviews.isEmpty {
            let empty = UILabel()
            empty.text = "No responses yet"
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = InsightsPalette.caption
            legend.addArrangedSubview(empty)
        }
        forceLTR()
    }

    private func makeLegendRow(_ slice: InsightsStatusSlice) -> UIView {
        let dot = UIView()
        dot.backgroundColor = InsightsPalette.color(for: slice.bucket)
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        let dotHolder = UIView()
        dotHolder.addSubview(dot)
        dotHolder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotHolder.widthAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: dotHolder.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: dotHolder.centerYAnchor),
            dot.topAnchor.constraint(greaterThanOrEqualTo: dotHolder.topAnchor),
            dot.bottomAnchor.constraint(lessThanOrEqualTo: dotHolder.bottomAnchor),
        ])

        let name = UILabel()
        name.text = slice.bucket.title
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = UIColor(white: 0.78, alpha: 1)

        let count = UILabel()
        count.text = "\(InsightsFormat.count(slice.count))  ·  \(InsightsFormat.percent(slice.fraction))"
        count.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        count.textColor = InsightsPalette.secondary
        count.textAlignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [dotHolder, name, UIView(), count])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.semanticContentAttribute = .forceLeftToRight
        return row
    }
}

/// A single rounded bar split into proportional colored segments. Frame-based
/// on purpose — proportional widths inside a stack view need one multiplier
/// constraint per segment, which is heavier and re-breaks on every reuse.
final class InsightsProportionBar: UIView {

    private var segments: [(color: UIColor, fraction: CGFloat)] = []
    private var segmentViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.20, alpha: 1)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(segments: [(UIColor, CGFloat)]) {
        let model = segments.map { (color: $0.0, fraction: $0.1) }
        segmentViews.forEach { $0.removeFromSuperview() }
        var views: [UIView] = []
        views.reserveCapacity(model.count)
        for segment in model {
            let view = UIView()
            view.backgroundColor = segment.color
            addSubview(view)
            views.append(view)
        }
        // Both arrays are swapped in together: `layoutSubviews` walks them in
        // lockstep and must never see a half-updated pair.
        self.segments = model
        self.segmentViews = views
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = Swift.min(segments.count, segmentViews.count)
        guard count > 0 else { return }
        let total = segments.prefix(count).reduce(CGFloat(0)) { $0 + max($1.fraction, 0) }
        guard total > 0, bounds.width > 0 else { return }
        var x: CGFloat = 0
        for index in 0..<count {
            let share = max(segments[index].fraction, 0) / total
            var width = (bounds.width * share).rounded()
            // Never let a non-zero class disappear entirely.
            if share > 0 { width = max(width, 3) }
            if index == count - 1 { width = max(bounds.width - x, 0) }
            segmentViews[index].frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }
}

// MARK: - Host card

/// One host: counts + p95 + bytes, tappable to expand its endpoint breakdown.
final class InsightsHostCell: InsightsTappableCardCell {

    static let reuseID = "InsightsHost"

    private let hostLabel = UILabel()
    private let chevron = UIImageView()
    private let headerRow = UIStackView()
    private let metricsStack = UIStackView()
    private let detailStack = UIStackView()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        body.spacing = 12

        hostLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        hostLabel.textColor = DebugTheme.accentColor
        hostLabel.numberOfLines = 0
        // Hostnames have no spaces: without char wrapping a long one is laid out
        // as a single unbreakable line and pushed past the card edge.
        hostLabel.lineBreakMode = .byCharWrapping
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 14).isActive = true

        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        headerRow.addArrangedSubview(hostLabel)
        headerRow.addArrangedSubview(chevron)

        metricsStack.axis = .vertical
        metricsStack.spacing = 12

        detailStack.axis = .vertical
        detailStack.spacing = 9

        body.addArrangedSubview(headerRow)
        body.addArrangedSubview(metricsStack)
        body.addArrangedSubview(detailStack)
    }

    func configure(host: InsightsHostStat, expanded: Bool) {
        buildIfNeeded()
        hostLabel.text = insightsClamped(host.host, max: 120)

        let symbol = expanded ? "chevron.up" : "chevron.down"
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        chevron.image = UIImage(systemName: symbol, withConfiguration: cfg)?
            .withTintColor(InsightsPalette.caption, renderingMode: .alwaysOriginal)

        for view in metricsStack.arrangedSubviews {
            metricsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let metrics = [
            InsightsMetric(caption: "REQUESTS", value: InsightsFormat.count(host.count)),
            InsightsMetric(caption: "ERROR RATE",
                           value: InsightsFormat.percent(host.errorRate),
                           tint: InsightsPalette.errorRateTint(host.errorRate)),
            InsightsMetric(caption: "P95",
                           value: InsightsFormat.duration(ms: host.p95DurationMs),
                           tint: InsightsPalette.durationTint(ms: host.p95DurationMs)),
            InsightsMetric(caption: "BYTES", value: InsightsFormat.bytes(host.totalBytes)),
        ]
        for row in Self.metricRows(metrics, columns: 2, valueSize: 13) {
            metricsStack.addArrangedSubview(row)
        }

        for view in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        detailStack.isHidden = !expanded
        guard expanded else { forceLTR(); return }

        detailStack.addArrangedSubview(Self.makeSeparator())
        let caption = UILabel()
        caption.text = "TOP ENDPOINTS"
        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textColor = InsightsPalette.caption
        detailStack.addArrangedSubview(caption)

        if host.topEndpoints.isEmpty {
            let none = UILabel()
            none.text = "No endpoints"
            none.font = .systemFont(ofSize: 12)
            none.textColor = InsightsPalette.caption
            detailStack.addArrangedSubview(none)
        }
        for endpoint in host.topEndpoints {
            detailStack.addArrangedSubview(makeEndpointRow(endpoint))
        }
        forceLTR()
    }

    private func makeEndpointRow(_ endpoint: InsightsEndpointStat) -> UIView {
        let path = UILabel()
        path.text = insightsClamped(endpoint.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.textColor = UIColor(white: 0.78, alpha: 1)
        path.numberOfLines = 0
        path.lineBreakMode = .byCharWrapping
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let meta = UILabel()
        meta.text = "×\(endpoint.count)  ·  \(InsightsFormat.duration(ms: endpoint.p95DurationMs))"
        meta.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        meta.textColor = endpoint.errorCount > 0
            ? .systemOrange
            : InsightsPalette.secondary
        meta.textAlignment = .right
        meta.numberOfLines = 1
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        meta.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [path, meta])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.semanticContentAttribute = .forceLeftToRight
        return row
    }
}

// MARK: - Endpoint card

/// One normalized path with its counts, percentiles and average payload.
final class InsightsEndpointCell: InsightsCardCell {

    static let reuseID = "InsightsEndpoint"

    private let pathLabel = UILabel()
    private let rankLabel = UILabel()
    private let headerRow = UIStackView()
    private let metricsStack = UIStackView()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        body.spacing = 12

        rankLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        rankLabel.textColor = InsightsPalette.caption
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)
        rankLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        pathLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        pathLabel.textColor = InsightsPalette.value
        pathLabel.numberOfLines = 0
        // Endpoint paths are one long token — wrap by character so they can
        // never be laid out wider than the card.
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerRow.axis = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 8
        headerRow.addArrangedSubview(rankLabel)
        headerRow.addArrangedSubview(pathLabel)

        metricsStack.axis = .vertical
        metricsStack.spacing = 12

        body.addArrangedSubview(headerRow)
        body.addArrangedSubview(metricsStack)
    }

    func configure(endpoint: InsightsEndpointStat, rank: Int) {
        buildIfNeeded()
        rankLabel.text = String(format: "%02d", rank)
        pathLabel.text = insightsClamped(endpoint.path)

        for view in metricsStack.arrangedSubviews {
            metricsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let metrics = [
            InsightsMetric(caption: "REQUESTS", value: InsightsFormat.count(endpoint.count)),
            InsightsMetric(caption: "ERROR RATE",
                           value: InsightsFormat.percent(endpoint.errorRate),
                           tint: InsightsPalette.errorRateTint(endpoint.errorRate)),
            InsightsMetric(caption: "AVG SIZE",
                           value: InsightsFormat.bytes(endpoint.averageResponseBytes)),
            InsightsMetric(caption: "P50",
                           value: InsightsFormat.duration(ms: endpoint.p50DurationMs),
                           tint: InsightsPalette.durationTint(ms: endpoint.p50DurationMs)),
            InsightsMetric(caption: "P95",
                           value: InsightsFormat.duration(ms: endpoint.p95DurationMs),
                           tint: InsightsPalette.durationTint(ms: endpoint.p95DurationMs)),
        ]
        for row in Self.metricRows(metrics, columns: 3, valueSize: 13) {
            metricsStack.addArrangedSubview(row)
        }
        forceLTR()
    }
}

// MARK: - Request row (slowest / largest)

/// Method + status pills, the highlighted metric, host and path.
final class InsightsRequestCell: InsightsCardCell {

    static let reuseID = "InsightsRequest"

    private let rankLabel = UILabel()
    private let methodPill = InsightsPillLabel()
    private let statusPill = InsightsPillLabel()
    private let highlightLabel = UILabel()
    private let pathLabel = UILabel()
    private let hostLabel = UILabel()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        body.spacing = 8

        rankLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        rankLabel.textColor = InsightsPalette.caption
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)
        rankLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        highlightLabel.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        highlightLabel.textAlignment = .right
        highlightLabel.numberOfLines = 1
        highlightLabel.lineBreakMode = .byTruncatingTail
        highlightLabel.setContentHuggingPriority(.required, for: .horizontal)
        highlightLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // The pills carry captured text (a bridged web-view "method" can be
        // anything), so they truncate under pressure instead of forcing the row
        // wider than the card.
        for pill in [methodPill, statusPill] {
            pill.lineBreakMode = .byTruncatingTail
            pill.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        }

        let header = UIStackView(arrangedSubviews: [rankLabel, methodPill, statusPill, UIView(), highlightLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 7
        header.semanticContentAttribute = .forceLeftToRight

        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = UIColor(white: 0.85, alpha: 1)
        pathLabel.numberOfLines = 0
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hostLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        hostLabel.textColor = InsightsPalette.caption
        hostLabel.numberOfLines = 1
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        body.addArrangedSubview(header)
        body.addArrangedSubview(pathLabel)
        body.addArrangedSubview(hostLabel)
        body.setCustomSpacing(4, after: pathLabel)
    }

    func configure(stat: InsightsRequestStat, rank: Int, highlight: String, highlightTint: UIColor) {
        buildIfNeeded()
        rankLabel.text = String(format: "%02d", rank)
        methodPill.configure(text: insightsClamped(stat.method, max: 10),
                             textColor: DebugTheme.accentColor,
                             background: DebugTheme.accentColor.withAlphaComponent(0.16))
        let statusColor = InsightsPalette.color(for: stat.bucket)
        statusPill.configure(text: insightsClamped(stat.statusCode, max: 8),
                             textColor: statusColor,
                             background: statusColor.withAlphaComponent(0.16))
        highlightLabel.text = highlight
        highlightLabel.textColor = highlightTint
        pathLabel.text = stat.path.isEmpty ? "/" : insightsClamped(stat.path)
        hostLabel.text = insightsClamped(stat.host, max: 120)
        forceLTR()
    }
}

/// Small rounded pill label with internal padding (a plain UILabel has none,
/// and a UIButton would bring hit-testing we don't want inside a row).
final class InsightsPillLabel: UILabel {

    private let insets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        clipsToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, textColor: UIColor, background: UIColor) {
        self.text = text
        self.textColor = textColor
        self.backgroundColor = background
        invalidateIntrinsicContentSize()
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}

// MARK: - Action row ("show all")

final class InsightsActionCell: InsightsTappableCardCell {

    static let reuseID = "InsightsAction"

    private let titleLabel = UILabel()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .heavy)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        body.addArrangedSubview(titleLabel)
    }

    func configure(title: String) {
        buildIfNeeded()
        titleLabel.text = title
        forceLTR()
    }
}

// MARK: - Empty state

final class InsightsMessageCell: InsightsCardCell {

    static let reuseID = "InsightsMessage"

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private var didBuild = false

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true
        body.spacing = 8

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.62, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = InsightsPalette.caption
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        body.addArrangedSubview(titleLabel)
        body.addArrangedSubview(bodyLabel)
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    }

    func configure(title: String, body text: String) {
        buildIfNeeded()
        titleLabel.text = title
        bodyLabel.text = text
        forceLTR()
    }
}
