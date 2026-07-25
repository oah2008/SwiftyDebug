//
//  NetworkTimelineViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// **Timeline / waterfall** view of the captured session.
///
/// One row per request, each bar positioned by start time and sized by duration
/// against a single shared axis that spans the session (earliest start → latest
/// end). It answers the questions the flat Network list can't: what ran in
/// parallel, what blocked what, and where the dead time is.
///
/// Design notes:
/// - **Frozen gutter, scrolling bars.** The method/path/status column is fixed;
///   only the bar track pans horizontally. That keeps rows identifiable at any
///   zoom without a second synchronized scroll view.
/// - **Cheap redraws.** Vertical scrolling is a plain `UITableView` (cell
///   reuse); horizontal scrolling/zooming just re-frames the single bar view of
///   each *visible* cell plus two custom-drawn views (ruler + gridlines). No
///   view-per-tick, no giant backing store.
/// - **Self-contained.** Tapping a row opens a compact sheet built here; this
///   screen deliberately does not depend on `NetworkDetailViewController`.
///
/// Entry point: `NetworkTimelineViewController()` — no arguments; it reads
/// `NetworkRequestStore.shared` and live-updates itself.
final class NetworkTimelineViewController: UIViewController {

    // MARK: - Filters

    private enum Filter: Int, CaseIterable {
        case all, errors, slow

        var title: String {
            switch self {
            case .all:    return "All"
            case .errors: return "Errors"
            case .slow:   return "Slow (>1s)"
            }
        }

        var emptyMessage: String {
            switch self {
            case .all:    return "Captured requests will appear here as a waterfall."
            case .errors: return "No failed requests (4xx, 5xx or transport errors) in this session."
            case .slow:   return "No request in this session took longer than 1s."
            }
        }
    }

    // MARK: - Layout constants

    private static let chipRowHeight: CGFloat = 34
    private static let zoomRowHeight: CGFloat = 30
    private static let rulerHeight: CGFloat = 24
    private static let zoomLevels: [CGFloat] = [1, 2, 4, 8]
    private static let maxZoom: CGFloat = 16

    // MARK: - State

    /// Every drawable row in the session. The **axis is always derived from
    /// this**, not from the filtered rows, so switching filters never rescales
    /// the timeline under the user.
    private var allRows: [TimelineRow] = []
    private var rows: [TimelineRow] = []
    private var filter: Filter = .all

    private var axis = TimelineAxis()
    private var xOffset: CGFloat = 0

    /// Coalesces bursts of `.networkRequestCompleted` into one reload per
    /// run-loop tick.
    private var refreshScheduled = false
    private var completedObserver: NSObjectProtocol?
    private var clearedObserver: NSObjectProtocol?

    /// Row building runs off the main thread; this queue serialises the passes
    /// so two reloads can never interleave.
    private let buildQueue = DispatchQueue(label: "com.swiftydebug.timeline.build",
                                           qos: .userInitiated)
    /// Stale-result guard: only the newest dispatched pass is allowed to apply.
    private var generation = 0
    /// Suppresses the empty state until the first pass has actually landed, so
    /// the screen doesn't flash "No requests captured" on the way in.
    private var hasLoadedOnce = false

    // Horizontal pan / inertia
    private enum PanAxis { case horizontal, vertical }
    private var panAxisLock: PanAxis?
    private var panStartOffset: CGFloat = 0
    private var pinchStartZoom: CGFloat = 1
    private var decelLink: CADisplayLink?
    private var decelVelocity: CGFloat = 0
    private var lastDecelTime: CFTimeInterval = 0

    // MARK: - Subviews

    private let chipsStack = UIStackView()
    private var chipButtons: [UIButton] = []
    private let summaryLabel = UILabel()
    private let zoomControl = UISegmentedControl(items: NetworkTimelineViewController.zoomLevels.map { "\(Int($0))x" })
    private let zoomHint = UILabel()
    private let rulerCaption = UILabel()
    private let ruler = NetworkTimelineRulerView()
    private let grid = NetworkTimelineGridView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStack = UIStackView()
    private let emptyTitle = UILabel()
    private let emptySubtitle = UILabel()

    // MARK: - Init

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        decelLink?.invalidate()
        if let completedObserver { NotificationCenter.default.removeObserver(completedObserver) }
        if let clearedObserver { NotificationCenter.default.removeObserver(clearedObserver) }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Timeline"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        setupChips()
        setupZoomRow()
        setupRuler()
        setupTable()
        setupEmptyState()
        setupGestures()

        completedObserver = NotificationCenter.default.addObserver(
            forName: .networkRequestCompleted, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() }

        clearedObserver = NotificationCenter.default.addObserver(
            forName: .allLogsCleared, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() }

        reload()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopDeceleration()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        grid.frame = CGRect(x: NetworkTimelineRowCell.trackOriginX,
                            y: tableView.frame.minY,
                            width: NetworkTimelineRowCell.trackWidth(forWidth: view.bounds.width),
                            height: tableView.frame.height)

        let newTrackWidth = NetworkTimelineRowCell.trackWidth(forWidth: view.bounds.width)
        if abs(newTrackWidth - axis.trackWidth) > 0.5 {
            axis.trackWidth = newTrackWidth
            xOffset = clampedOffset(xOffset)
            applyHorizontalLayout()
        }
    }

    // MARK: - Setup

    private func setupChips() {
        chipsStack.axis = .horizontal
        chipsStack.spacing = 6
        chipsStack.alignment = .center
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipsStack)

        for f in Filter.allCases {
            let chip = makeChip(title: f.title, tag: f.rawValue)
            chipButtons.append(chip)
            chipsStack.addArrangedSubview(chip)
        }

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .heavy)
        summaryLabel.textColor = UIColor(white: 0.45, alpha: 1)
        summaryLabel.textAlignment = .right
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            chipsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            chipsStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            chipsStack.heightAnchor.constraint(equalToConstant: Self.chipRowHeight - 6),

            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: chipsStack.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: chipsStack.centerYAnchor),
        ])
        updateChips()
    }

    private func makeChip(title: String, tag: Int) -> UIButton {
        let chip = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 11, weight: .heavy)
            return attrs
        }
        chip.configuration = config
        chip.tag = tag
        chip.layer.cornerRadius = 13
        chip.layer.cornerCurve = .continuous
        chip.layer.borderWidth = 1
        chip.clipsToBounds = true
        chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
        return chip
    }

    private func setupZoomRow() {
        zoomControl.backgroundColor = UIColor(white: 0.13, alpha: 1)
        zoomControl.selectedSegmentTintColor = DebugTheme.accentColor
        zoomControl.setTitleTextAttributes([
            .foregroundColor: UIColor(white: 0.62, alpha: 1),
            .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
        ], for: .normal)
        zoomControl.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
        ], for: .selected)
        zoomControl.selectedSegmentIndex = 0
        zoomControl.addTarget(self, action: #selector(zoomControlChanged), for: .valueChanged)
        zoomControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomControl)

        zoomHint.text = "PINCH TO ZOOM"
        zoomHint.font = .systemFont(ofSize: 10, weight: .heavy)
        zoomHint.textColor = UIColor(white: 0.45, alpha: 1)
        zoomHint.translatesAutoresizingMaskIntoConstraints = false
        zoomHint.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.addSubview(zoomHint)

        NSLayoutConstraint.activate([
            zoomControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            zoomControl.topAnchor.constraint(equalTo: chipsStack.bottomAnchor, constant: 8),
            zoomControl.heightAnchor.constraint(equalToConstant: Self.zoomRowHeight),
            zoomControl.widthAnchor.constraint(equalToConstant: 180),

            zoomHint.leadingAnchor.constraint(greaterThanOrEqualTo: zoomControl.trailingAnchor, constant: 8),
            zoomHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            zoomHint.centerYAnchor.constraint(equalTo: zoomControl.centerYAnchor),
        ])
    }

    private func setupRuler() {
        rulerCaption.text = "ELAPSED"
        rulerCaption.font = .systemFont(ofSize: 10, weight: .heavy)
        rulerCaption.textColor = UIColor(white: 0.45, alpha: 1)
        rulerCaption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rulerCaption)

        ruler.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ruler)

        // Revealed by the first applied build — an un-configured axis would
        // otherwise draw a meaningless 1-second ruler for a frame.
        ruler.isHidden = true
        grid.isHidden = true
        rulerCaption.isHidden = true

        NSLayoutConstraint.activate([
            rulerCaption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            rulerCaption.bottomAnchor.constraint(equalTo: ruler.bottomAnchor, constant: -5),

            ruler.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                           constant: NetworkTimelineRowCell.trackOriginX),
            ruler.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                            constant: -NetworkTimelineRowCell.trackTrailingInset),
            ruler.topAnchor.constraint(equalTo: zoomControl.bottomAnchor, constant: 8),
            ruler.heightAnchor.constraint(equalToConstant: Self.rulerHeight),
        ])
    }

    private func setupTable() {
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        // Fixed row height: the waterfall is a uniform grid, and it keeps the
        // frozen gutter and the scrolling bars in lockstep.
        tableView.rowHeight = NetworkTimelineRowCell.rowHeight
        tableView.estimatedRowHeight = NetworkTimelineRowCell.rowHeight
        tableView.contentInset.bottom = 24
        // Cells must span the full width or the bars would drift out of
        // alignment with the ruler on notched devices in landscape.
        tableView.insetsContentViewsToSafeArea = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.register(NetworkTimelineRowCell.self, forCellReuseIdentifier: NetworkTimelineRowCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        view.addSubview(grid)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: ruler.bottomAnchor, constant: 2),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupEmptyState() {
        let icon = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.image = UIImage(systemName: "chart.bar.xaxis", withConfiguration: config)?
            .withTintColor(UIColor(white: 0.3, alpha: 1), renderingMode: .alwaysOriginal)
        icon.contentMode = .scaleAspectFit

        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = UIColor(white: 0.6, alpha: 1)
        emptyTitle.textAlignment = .center

        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = UIColor(white: 0.42, alpha: 1)
        emptySubtitle.textAlignment = .center
        emptySubtitle.numberOfLines = 0

        emptyStack.axis = .vertical
        emptyStack.spacing = 8
        emptyStack.alignment = .center
        emptyStack.isUserInteractionEnabled = false
        // Nothing is known until the first (off-main) build lands.
        emptyStack.isHidden = true
        emptyStack.addArrangedSubview(icon)
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptySubtitle)
        emptyStack.setCustomSpacing(12, after: icon)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStack)

        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: tableView.centerYAnchor, constant: -30),
            emptyStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            emptyStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
        ])
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        tableView.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        tableView.addGestureRecognizer(pinch)
    }

    // MARK: - Data

    /// Main-thread snapshot of the capture list.
    ///
    /// The store mutates `httpModels` from the protocol threads under
    /// `objc_sync_enter(store)`; the same lock is taken here so the bridge can
    /// never read a half-mutated `NSMutableArray`. It is held only for the copy
    /// — the scan itself runs unlocked, off this thread.
    private static func snapshotModels() -> [NetworkTransaction] {
        guard SwiftyDebugRuntime.isActive else { return [] }
        let store = NetworkRequestStore.shared
        objc_sync_enter(store)
        let models = (store.httpModels.copy() as? NSArray as? [NetworkTransaction]) ?? []
        objc_sync_exit(store)
        return models
    }

    /// Builds the drawable rows from a snapshot. **Pure and off-main**: the
    /// media test alone lowercases and substring-scans every URL, which is far
    /// too much to run on the main thread once per capture burst.
    ///
    /// Media assets are excluded to match the Network tab: a page full of
    /// sprite/avatar requests drowns out the API calls the waterfall exists to
    /// explain. Rows without a usable start timestamp are skipped outright.
    private static func buildRows(from models: [NetworkTransaction]) -> [TimelineRow] {
        var result: [TimelineRow] = []
        result.reserveCapacity(models.count)
        for model in models {
            guard !NetworkViewController.isMediaTransaction(model) else { continue }
            if let row = TimelineRow.make(from: model) { result.append(row) }
        }
        // Chronological: the waterfall reads top-to-bottom in fire order.
        return result.sorted { $0.start < $1.start }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshScheduled = false
            // Only reload while visible — no work for a backgrounded tab.
            guard self.viewIfLoaded?.window != nil else { return }
            self.reload()
        }
    }

    /// Snapshot on main → build off main → apply on main.
    private func reload() {
        let wasAtBottom = isScrolledToBottom()
        let models = Self.snapshotModels()

        generation += 1
        let token = generation

        buildQueue.async { [weak self] in
            let built = Self.buildRows(from: models)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.apply(built, wasAtBottom: wasAtBottom)
            }
        }
    }

    private func apply(_ built: [TimelineRow], wasAtBottom: Bool) {
        hasLoadedOnce = true
        allRows = built
        rows = filteredRows()
        recomputeAxis()
        updateSummary()
        updateEmptyState()
        tableView.reloadData()
        applyHorizontalLayout()

        if wasAtBottom, !rows.isEmpty {
            tableView.layoutIfNeeded()
            let last = IndexPath(row: rows.count - 1, section: 0)
            tableView.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    private func filteredRows() -> [TimelineRow] {
        switch filter {
        case .all:    return allRows
        case .errors: return allRows.filter { $0.isFailure }
        case .slow:   return allRows.filter { $0.isSlow }
        }
    }

    /// Session window = earliest start → latest end across **all** rows.
    /// Degenerate windows (single instant request, broken clocks) fall back to a
    /// 1 second span so nothing divides by zero and no bar is drawn as garbage.
    private func recomputeAxis() {
        var start = Double.greatestFiniteMagnitude
        var end = -Double.greatestFiniteMagnitude
        for row in allRows {
            start = min(start, row.start)
            end = max(end, max(row.end, row.start))
        }
        guard !allRows.isEmpty, start.isFinite, end.isFinite else {
            axis.sessionStart = 0
            axis.span = 1
            axis.trackWidth = NetworkTimelineRowCell.trackWidth(forWidth: view.bounds.width)
            xOffset = 0
            return
        }

        var span = end - start
        if !span.isFinite || span <= 0.001 { span = 1 }
        // A little headroom so the last bar isn't flush against the right edge.
        span *= 1.04

        axis.sessionStart = start
        axis.span = span
        axis.trackWidth = NetworkTimelineRowCell.trackWidth(forWidth: view.bounds.width)
        xOffset = clampedOffset(xOffset)
    }

    private func updateSummary() {
        guard !allRows.isEmpty else {
            summaryLabel.text = ""
            return
        }
        let spanText: String
        let span = axis.span
        if span < 1 {
            spanText = "\(Int((span * 1000).rounded()))ms"
        } else if span < 60 {
            spanText = String(format: "%.1fs", span)
        } else {
            spanText = String(format: "%dm%02.0fs", Int(span / 60), span.truncatingRemainder(dividingBy: 60))
        }
        summaryLabel.text = "\(rows.count)/\(allRows.count) REQ · \(spanText)"
    }

    private func updateEmptyState() {
        let isEmpty = rows.isEmpty
        emptyStack.isHidden = !isEmpty || !hasLoadedOnce
        ruler.isHidden = isEmpty
        grid.isHidden = isEmpty
        rulerCaption.isHidden = isEmpty
        guard isEmpty else { return }

        if allRows.isEmpty {
            emptyTitle.text = "No requests captured"
            emptySubtitle.text = Filter.all.emptyMessage
        } else {
            emptyTitle.text = "No requests match “\(filter.title)”"
            emptySubtitle.text = filter.emptyMessage
        }
    }

    private func isScrolledToBottom() -> Bool {
        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.bottom
        guard tableView.contentSize.height > visibleHeight else { return true }
        return tableView.contentOffset.y >= tableView.contentSize.height - tableView.bounds.height - 24
    }

    // MARK: - Chips / zoom

    private func updateChips() {
        for chip in chipButtons {
            let isSelected = chip.tag == filter.rawValue
            chip.configuration?.baseForegroundColor = isSelected ? .black : UIColor(white: 0.62, alpha: 1)
            chip.backgroundColor = isSelected ? DebugTheme.accentColor : UIColor(white: 0.13, alpha: 1)
            chip.layer.borderColor = (isSelected
                ? DebugTheme.accentColor
                : UIColor(white: 0.24, alpha: 1)).cgColor
        }
    }

    @objc private func chipTapped(_ sender: UIButton) {
        guard let newFilter = Filter(rawValue: sender.tag), newFilter != filter else { return }
        filter = newFilter
        updateChips()
        rows = filteredRows()
        updateSummary()
        updateEmptyState()
        tableView.reloadData()
        tableView.setContentOffset(.zero, animated: false)
        applyHorizontalLayout()
    }

    @objc private func zoomControlChanged() {
        let index = zoomControl.selectedSegmentIndex
        guard Self.zoomLevels.indices.contains(index) else { return }
        setZoom(Self.zoomLevels[index], anchorX: axis.trackWidth / 2)
    }

    private func syncZoomControl() {
        if let index = Self.zoomLevels.firstIndex(where: { abs($0 - axis.zoom) < 0.01 }) {
            zoomControl.selectedSegmentIndex = index
        } else {
            zoomControl.selectedSegmentIndex = UISegmentedControl.noSegment
        }
    }

    /// Rescales the axis while keeping the instant under `anchorX` pinned in
    /// place — otherwise pinching would slide the content out from under the
    /// user's fingers.
    private func setZoom(_ zoom: CGFloat, anchorX: CGFloat) {
        let clamped = min(max(zoom, 1), Self.maxZoom)
        guard clamped.isFinite else { return }

        let oldPPS = axis.pointsPerSecond
        let anchor = min(max(anchorX, 0), max(0, axis.trackWidth))
        axis.zoom = clamped

        if oldPPS > 0, axis.pointsPerSecond > 0 {
            let timeAtAnchor = Double((xOffset + anchor) / oldPPS)
            xOffset = CGFloat(timeAtAnchor) * axis.pointsPerSecond - anchor
        }
        xOffset = clampedOffset(xOffset)

        syncZoomControl()
        applyHorizontalLayout()
    }

    // MARK: - Horizontal layout

    private func clampedOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        return min(max(offset, 0), axis.maxOffset)
    }

    /// Re-frames only what moved: the ruler, the gridlines and the bar of each
    /// **visible** cell.
    private func applyHorizontalLayout() {
        ruler.update(axis: axis, offset: xOffset)
        grid.update(axis: axis, offset: xOffset)
        for cell in tableView.visibleCells {
            (cell as? NetworkTimelineRowCell)?.applyAxis(axis, offset: xOffset)
        }
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopDeceleration()
            panStartOffset = xOffset
            panAxisLock = nil

        case .changed:
            guard axis.maxOffset > 0 else { return }
            let translation = gesture.translation(in: view)
            if panAxisLock == nil, hypot(translation.x, translation.y) > 6 {
                panAxisLock = abs(translation.x) > abs(translation.y) * 1.2 ? .horizontal : .vertical
                if panAxisLock == .horizontal {
                    // Cancel the table's vertical scroll so a horizontal scrub
                    // stays a clean scrub. Re-enabled when the gesture ends.
                    tableView.panGestureRecognizer.isEnabled = false
                }
            }
            guard panAxisLock == .horizontal else { return }
            xOffset = clampedOffset(panStartOffset - translation.x)
            applyHorizontalLayout()

        case .ended, .cancelled, .failed:
            tableView.panGestureRecognizer.isEnabled = true
            if panAxisLock == .horizontal {
                startDeceleration(offsetVelocity: -gesture.velocity(in: view).x)
            }
            panAxisLock = nil

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopDeceleration()
            pinchStartZoom = axis.zoom
        case .changed:
            let anchor = gesture.location(in: view).x - NetworkTimelineRowCell.trackOriginX
            setZoom(pinchStartZoom * gesture.scale, anchorX: anchor)
        default:
            break
        }
    }

    // MARK: - Inertia

    private func startDeceleration(offsetVelocity: CGFloat) {
        stopDeceleration()
        guard abs(offsetVelocity) > 80, axis.maxOffset > 0, offsetVelocity.isFinite else { return }
        decelVelocity = offsetVelocity
        lastDecelTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepDeceleration))
        link.add(to: .main, forMode: .common)
        decelLink = link
    }

    private func stopDeceleration() {
        decelLink?.invalidate()
        decelLink = nil
        decelVelocity = 0
    }

    @objc private func stepDeceleration() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastDecelTime, 0), 1.0 / 30.0)
        lastDecelTime = now

        // Same decay UIScrollView uses for its "normal" deceleration rate.
        decelVelocity *= pow(0.998, CGFloat(dt * 1000))
        let proposed = xOffset + decelVelocity * CGFloat(dt)
        let clamped = clampedOffset(proposed)
        xOffset = clamped
        applyHorizontalLayout()

        if abs(decelVelocity) < 40 || abs(clamped - proposed) > 0.01 {
            stopDeceleration()
        }
    }
}

// MARK: - Table

extension NetworkTimelineViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NetworkTimelineRowCell.reuseID, for: indexPath) as! NetworkTimelineRowCell
        if rows.indices.contains(indexPath.row) {
            cell.configure(row: rows[indexPath.row], axis: axis, offset: xOffset)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard rows.indices.contains(indexPath.row) else { return }
        let sheet = NetworkTimelineDetailSheetViewController(row: rows[indexPath.row], axis: axis)
        let nav = SwiftyDebugNavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
            presentation.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(nav, animated: true)
    }
}

// MARK: - Gesture delegate

extension NetworkTimelineViewController: UIGestureRecognizerDelegate {

    /// The horizontal scrub and the pinch must coexist with the table's own
    /// vertical scrolling.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Detail sheet

/// Compact per-request detail for the timeline.
///
/// Deliberately standalone: the timeline must not couple to
/// `NetworkDetailViewController`, so this shows only what the waterfall itself
/// knows — URL, status, and the timing breakdown — from in-memory fields. It
/// never reads the disk-backed bodies.
private final class NetworkTimelineDetailSheetViewController: UITableViewController {

    private struct Entry {
        let caption: String
        let value: String
        let tint: UIColor
        init(_ caption: String, _ value: String, tint: UIColor = UIColor(white: 0.9, alpha: 1)) {
            self.caption = caption
            self.value = value
            self.tint = tint
        }
    }

    private let row: TimelineRow
    private let axis: TimelineAxis
    private var entries: [Entry] = []

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(row: TimelineRow, axis: TimelineAxis) {
        self.row = row
        self.axis = axis
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Request Timing"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.contentInset.bottom = 24
        tableView.register(TimelineDetailCell.self, forCellReuseIdentifier: TimelineDetailCell.reuseID)

        entries = buildEntries()
        installHeader()
        view.forceLTR()
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    // MARK: - Content

    private func buildEntries() -> [Entry] {
        let model = row.model
        let startElapsed = row.start - axis.sessionStart
        let endElapsed = row.end - axis.sessionStart

        var entries: [Entry] = []
        entries.append(Entry("URL", model.url?.absoluteString ?? "—"))
        entries.append(Entry("METHOD · STATUS",
                             "\(row.method.isEmpty ? "—" : row.method)   \(row.statusText)",
                             tint: row.barColor))
        entries.append(Entry("STARTED",
                             "+\(Self.elapsedText(startElapsed))   ·   \(Self.clockFormatter.string(from: Date(timeIntervalSince1970: row.start)))"))
        if row.isInFlight {
            entries.append(Entry("ENDED", "in flight / no end timestamp",
                                 tint: UIColor(white: 0.55, alpha: 1)))
        } else {
            entries.append(Entry("ENDED",
                                 "+\(Self.elapsedText(endElapsed))   ·   \(Self.clockFormatter.string(from: Date(timeIntervalSince1970: row.end)))"))
        }
        entries.append(Entry("DURATION", row.durationText, tint: row.barColor))

        if !row.isInFlight, axis.span > 0 {
            let share = min(100, max(0, row.duration / axis.span * 100))
            entries.append(Entry("SHARE OF SESSION", String(format: "%.1f%% of the captured window", share),
                                 tint: UIColor(white: 0.7, alpha: 1)))
        }

        if !row.host.isEmpty {
            entries.append(Entry("HOST", row.host, tint: UIColor(white: 0.8, alpha: 1)))
        }
        if let mime = model.mineType, !mime.isEmpty {
            entries.append(Entry("CONTENT TYPE", mime, tint: UIColor(white: 0.8, alpha: 1)))
        }
        entries.append(Entry("PAYLOAD",
                             "↑ \(Self.byteText(model.requestDataSize))   ↓ \(Self.byteText(model.responseDataSize))",
                             tint: UIColor(white: 0.8, alpha: 1)))

        let errorText = model.errorLocalizedDescription ?? model.errorDescription
        if let errorText, !errorText.isEmpty {
            entries.append(Entry("ERROR", errorText, tint: .systemRed))
        }
        if model.isWebViewRequest {
            entries.append(Entry("SOURCE", "WebView", tint: UIColor(white: 0.8, alpha: 1)))
        }
        return entries
    }

    /// Mini waterfall preview: where this request sits inside the session.
    private func installHeader() {
        let header = UIView()
        header.backgroundColor = .clear

        let caption = UILabel()
        caption.text = "POSITION IN SESSION"
        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textColor = UIColor(white: 0.45, alpha: 1)
        caption.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(caption)

        let preview = TimelineMiniBarView()
        preview.color = row.barColor
        if axis.span > 0 {
            let startFraction = CGFloat((row.start - axis.sessionStart) / axis.span)
            let widthFraction = CGFloat(row.duration / axis.span)
            preview.fraction = (min(max(startFraction, 0), 1), min(max(widthFraction, 0), 1))
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(preview)

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            caption.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),

            preview.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            preview.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22),
            preview.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            preview.heightAnchor.constraint(equalToConstant: 12),
            preview.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])

        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 60)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        tableView.tableHeaderView = header
    }

    // MARK: - Formatting

    private static func elapsedText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        if abs(seconds) < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        return String(format: "%.3fs", seconds)
    }

    private static func byteText(_ bytes: UInt) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: TimelineDetailCell.reuseID, for: indexPath) as! TimelineDetailCell
        let entry = entries[indexPath.row]
        cell.configure(caption: entry.caption, value: entry.value, tint: entry.tint)
        return cell
    }
}

// MARK: - Detail cell

/// Caption + value card.
///
/// The value label is pinned to **both** the top and the bottom of the card (and
/// the card to the contentView), so multi-line URLs drive the row height instead
/// of collapsing — the stock `textLabel`/`detailTextLabel` pair does not create
/// those constraints and clips.
private final class TimelineDetailCell: UITableViewCell {

    static let reuseID = "SwiftyDebugTimelineDetail"

    private let card = UIView()
    private let captionLabel = UILabel()
    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = UIColor(white: 0.45, alpha: 1)
        captionLabel.numberOfLines = 1
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(captionLabel)

        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = UIColor(white: 0.9, alpha: 1)
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byCharWrapping
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            captionLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            captionLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            captionLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),

            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            valueLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 5),
            valueLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(caption: String, value: String, tint: UIColor) {
        captionLabel.text = caption
        valueLabel.text = value
        valueLabel.textColor = tint
    }
}

// MARK: - Mini bar

/// Session-relative position preview used as the detail sheet header.
private final class TimelineMiniBarView: UIView {

    /// (start, width) as fractions of the session span.
    var fraction: (start: CGFloat, width: CGFloat) = (0, 0) { didSet { setNeedsLayout() } }
    var color: UIColor = .systemGreen { didSet { bar.backgroundColor = color } }

    private let bar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.18, alpha: 1)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        bar.backgroundColor = color
        bar.layer.cornerRadius = 6
        bar.layer.cornerCurve = .continuous
        addSubview(bar)
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(4, bounds.width * fraction.width)
        let x = min(bounds.width * fraction.start, max(0, bounds.width - width))
        bar.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
    }
}
