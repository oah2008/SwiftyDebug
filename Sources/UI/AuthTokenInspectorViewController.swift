//
//  AuthTokenInspectorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - Palette

private enum AuthPalette {
    static let cardBG      = UIColor(white: 0.13, alpha: 1)
    static let cardHiBG    = UIColor(white: 0.20, alpha: 1)
    static let cardBorder  = UIColor(white: 0.24, alpha: 1)
    static let caption     = UIColor(white: 0.45, alpha: 1)
    static let value       = UIColor(white: 0.88, alpha: 1)
    static let dim         = UIColor(white: 0.55, alpha: 1)
    static let pillBG      = UIColor(white: 0.22, alpha: 1)

    static func statusColor(_ code: String) -> UIColor {
        let n = Int(code) ?? 0
        switch n {
        case 200..<300: return .systemGreen
        case 300..<400: return DebugTheme.accentColor
        case 400..<500: return .systemOrange
        case 500...:    return .systemRed
        default:        return n == 0 ? .systemRed : AuthPalette.dim
        }
    }
}

// MARK: - Precomputed per-credential aggregates

/// Everything the list cell and the header need that `AuthCredential` derives by
/// walking its usage list.
///
/// `AuthCredential.hosts` / `.endpointCounts` / `.expiredUsageCount` /
/// `.firstSeen` / `.lastSeen` are all O(requests-using-this-token) computed
/// properties, so reading them straight from `cellForRowAt` would put a scan of
/// the whole capture list on the main thread on every reload. They are built
/// once instead, on the scan queue, from the same background pass that produced
/// the credentials.
private struct AuthCredentialSummary {

    let hosts: [String]
    /// Pre-rendered endpoint lines (top 3 + "+N more"), so the cell only assigns.
    let endpointLines: [String]
    let expiredUsageCount: Int
    let firstSeen: Date?
    let lastSeen: Date?
    let valueLength: Int

    /// One pass over the usage list. Call this OFF the main thread.
    init(credential: AuthCredential) {
        var first: Date?
        var last: Date?
        var expired = 0
        var seenHosts = Set<String>()
        var hostList: [String] = []
        var counts: [String: Int] = [:]
        var order: [String] = []

        for usage in credential.usages {
            if usage.sentExpired { expired += 1 }
            if let date = usage.startedAt {
                if first == nil || date < first! { first = date }
                if last == nil || date > last! { last = date }
            }
            if !usage.host.isEmpty, seenHosts.insert(usage.host).inserted {
                hostList.append(usage.host)
            }
            let key = usage.endpointLabel
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }

        // Written out longhand: the chained map/sorted form with a labelled
        // tuple blows past the type-checker's time budget.
        var ranked: [(endpoint: String, count: Int)] = []
        ranked.reserveCapacity(order.count)
        for key in order {
            ranked.append((endpoint: key, count: counts[key] ?? 0))
        }
        ranked.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.endpoint < rhs.endpoint
        }

        var lines: [String] = []
        for entry in ranked.prefix(3) {
            lines.append(entry.endpoint + "  ×" + String(entry.count))
        }
        let extra = ranked.count - lines.count
        if extra > 0 {
            let plural = extra == 1 ? "" : "s"
            lines.append("+" + String(extra) + " more endpoint" + plural)
        }

        self.hosts = hostList
        self.endpointLines = lines
        self.expiredUsageCount = expired
        self.firstSeen = first
        self.lastSeen = last
        self.valueLength = credential.value.count
    }

    /// Summaries keyed by `AuthCredential.id`. Call this OFF the main thread.
    static func build(for credentials: [AuthCredential]) -> [String: AuthCredentialSummary] {
        var out: [String: AuthCredentialSummary] = [:]
        out.reserveCapacity(credentials.count)
        for credential in credentials {
            out[credential.id] = AuthCredentialSummary(credential: credential)
        }
        return out
    }
}

// MARK: - Auth & token inspector

/// Session-wide credential inspector.
///
/// Scans every captured request for `Authorization` headers, common API-key
/// headers and auth-looking cookies, then groups them by **distinct token
/// value**: one card per credential with the requests that used it, decoded JWT
/// claims, a live expiry countdown, and — the reason this screen exists — a red
/// flag on any request that was sent with an **already-expired** token.
///
/// Entry point: `AuthTokenInspectorViewController()` — no arguments; push it on
/// any `UINavigationController`.
final class AuthTokenInspectorViewController: UIViewController {

    // MARK: State

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var credentials: [AuthCredential] = []
    /// Aggregates for `credentials`, built on `scanQueue` — never on main.
    private var summaries: [String: AuthCredentialSummary] = [:]
    /// Total "sent after expiry" requests across all credentials, precomputed
    /// with `summaries` so the header never re-walks the usage lists.
    private var totalExpiredSends = 0
    /// Token ids the user tapped "reveal" on (kept here so cell reuse can't leak
    /// a revealed value onto another row).
    private var revealedIDs = Set<String>()
    /// Compare mode: pick two credentials, then diff their claims.
    private var isCompareMode = false
    private var selectedIDs: [String] = []

    private var countdownTimer: Timer?
    /// Coalesces the burst of `.networkRequestCompleted` notifications.
    private var rescanScheduled = false
    private var isScanning = false

    private let scanQueue = DispatchQueue(label: "com.swiftydebug.authscan", qos: .userInitiated)

    // Header
    private let headerContainer = UIView()
    private let headerCard = UIView()
    private let summaryLabel = UILabel()
    private let warningLabel = UILabel()
    private let hintLabel = UILabel()
    private var lastHeaderWidth: CGFloat = 0

    private lazy var emptyView = AuthEmptyStateView()

    // MARK: Init

    /// No-argument entry point. The screen reads `NetworkRequestStore.shared`
    /// itself and refreshes as new requests are captured.
    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        countdownTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Auth & Tokens"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        let compareItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.left.arrow.right"),
            style: .plain, target: self, action: #selector(compareTapped))
        let refreshItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain, target: self, action: #selector(refreshTapped))
        compareItem.tintColor = DebugTheme.accentColor
        refreshItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItems = [refreshItem, compareItem]

        buildHeader()

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 180
        tableView.contentInset.bottom = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AuthTokenCardCell.self, forCellReuseIdentifier: AuthTokenCardCell.reuseID)
        emptyView.isHidden = true
        tableView.backgroundView = emptyView
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(capturedRequestsChanged),
            name: .networkRequestCompleted, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(logsCleared),
            name: .allLogsCleared, object: nil)

        rescan()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdown()
        rescan()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.bounds.width != lastHeaderWidth {
            lastHeaderWidth = tableView.bounds.width
            sizeHeader()
        }
    }

    // MARK: Header

    private func buildHeader() {
        headerCard.backgroundColor = AuthPalette.cardBG
        headerCard.layer.cornerRadius = 14
        headerCard.layer.cornerCurve = .continuous
        headerCard.layer.borderWidth = 1
        headerCard.layer.borderColor = AuthPalette.cardBorder.cgColor
        headerCard.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerCard)

        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = .white
        summaryLabel.numberOfLines = 0

        warningLabel.font = .systemFont(ofSize: 12, weight: .bold)
        warningLabel.textColor = .systemRed
        warningLabel.numberOfLines = 0

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = AuthPalette.caption
        hintLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [summaryLabel, warningLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(stack)

        NSLayoutConstraint.activate([
            headerCard.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            headerCard.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -12),
            headerCard.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 10),
            headerCard.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -6),

            stack.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -12),
        ])
        headerContainer.forceLTR()
    }

    private func updateHeader() {
        let requests = credentials.reduce(0) { $0 + $1.requestCount }
        let expiredSends = totalExpiredSends
        let expiredTokens = credentials.filter {
            if case .expired = $0.expiryState { return true }
            return false
        }.count

        var parts = ["\(credentials.count) token\(credentials.count == 1 ? "" : "s")",
                     "\(requests) request\(requests == 1 ? "" : "s")"]
        if expiredTokens > 0 { parts.append("\(expiredTokens) expired") }
        summaryLabel.text = parts.joined(separator: "  ·  ")

        if expiredSends > 0 {
            warningLabel.text = "⚠︎ \(expiredSends) request\(expiredSends == 1 ? " was" : "s were") sent with an already-expired token"
            warningLabel.isHidden = false
        } else {
            warningLabel.isHidden = true
        }

        if isCompareMode {
            hintLabel.text = "Compare mode — pick 2 tokens (\(selectedIDs.count)/2 selected)"
            hintLabel.textColor = DebugTheme.accentColor
        } else {
            hintLabel.text = "Tap a token for claims & requests. Tap the value to reveal it."
            hintLabel.textColor = AuthPalette.caption
        }

        headerCard.layer.borderColor = (isCompareMode
            ? DebugTheme.accentColor.withAlphaComponent(0.7)
            : (expiredSends > 0 ? UIColor.systemRed.withAlphaComponent(0.55) : AuthPalette.cardBorder)).cgColor

        sizeHeader()
    }

    private func sizeHeader() {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width
        guard width > 0 else { return }
        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        headerContainer.setNeedsLayout()
        headerContainer.layoutIfNeeded()
        let height = headerContainer.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        headerContainer.frame.size.height = height
        tableView.tableHeaderView = credentials.isEmpty ? nil : headerContainer
    }

    // MARK: Scanning

    @objc private func capturedRequestsChanged() {
        guard SwiftyDebugRuntime.isActive else { return }
        guard !rescanScheduled else { return }
        rescanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            guard self.view.window != nil else { return }
            self.rescan()
        }
    }

    @objc private func logsCleared() {
        credentials = []
        summaries = [:]
        totalExpiredSends = 0
        selectedIDs = []
        revealedIDs = []
        reloadUI()
    }

    @objc private func refreshTapped() { rescan() }

    /// Snapshot of the capture list that is safe to hand to a background queue.
    ///
    /// `AuthTokenScanner.liveTransactions()` bridges the store's live
    /// `NSMutableArray` without copying it, and a verbatim bridge can keep that
    /// same mutable array as its backing storage — so enumerating the result on
    /// `scanQueue` while a network thread appends is a data race. The store
    /// serialises its own mutations with `objc_sync_enter(store)`, so take the
    /// same lock, just long enough to copy.
    private static func snapshotTransactions() -> [NetworkTransaction] {
        let store = NetworkRequestStore.shared
        objc_sync_enter(store)
        let models = (store.httpModels.copy() as? NSArray as? [NetworkTransaction]) ?? []
        objc_sync_exit(store)
        return models
    }

    /// Snapshots the live store on the main thread, then groups AND summarises
    /// off-thread — the main thread only ever assigns the finished result.
    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let snapshot = Self.snapshotTransactions()
        scanQueue.async { [weak self] in
            let result = AuthTokenScanner.scan(snapshot)
            let summaries = AuthCredentialSummary.build(for: result)
            let expiredSends = summaries.values.reduce(0) { $0 + $1.expiredUsageCount }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                self.credentials = result
                self.summaries = summaries
                self.totalExpiredSends = expiredSends
                let alive = Set(result.map { $0.id })
                self.selectedIDs = self.selectedIDs.filter { alive.contains($0) }
                self.reloadUI()
            }
        }
    }

    private func reloadUI() {
        emptyView.isHidden = !credentials.isEmpty
        updateHeader()
        tableView.reloadData()
    }

    // MARK: Countdown

    private func startCountdown() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// Updates only the visible countdown labels — a full `reloadData` would
    /// fight scrolling and drop the reveal state animation.
    @objc private func tick() {
        for cell in tableView.visibleCells {
            (cell as? AuthTokenCardCell)?.tickCountdown()
        }
    }

    // MARK: Compare mode

    @objc private func compareTapped() {
        isCompareMode.toggle()
        selectedIDs.removeAll()
        updateHeader()
        tableView.reloadData()
    }

    private func toggleSelection(_ credential: AuthCredential) {
        if let idx = selectedIDs.firstIndex(of: credential.id) {
            selectedIDs.remove(at: idx)
        } else {
            selectedIDs.append(credential.id)
            if selectedIDs.count > 2 { selectedIDs.removeFirst() }
        }
        updateHeader()
        tableView.reloadData()

        if selectedIDs.count == 2,
           let a = credentials.first(where: { $0.id == selectedIDs[0] }),
           let b = credentials.first(where: { $0.id == selectedIDs[1] }) {
            isCompareMode = false
            selectedIDs.removeAll()
            updateHeader()
            tableView.reloadData()
            navigationController?.pushViewController(
                AuthTokenCompareViewController(left: a, right: b), animated: true)
        }
    }
}

// MARK: - Table data source / delegate

extension AuthTokenInspectorViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        credentials.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: AuthTokenCardCell.reuseID, for: indexPath) as! AuthTokenCardCell
        let credential = credentials[indexPath.row]
        // Always populated by `rescan`; the fallback only exists so a summary
        // that somehow went missing degrades instead of trapping.
        let summary = summaries[credential.id] ?? AuthCredentialSummary(credential: credential)
        cell.configure(credential: credential,
                       summary: summary,
                       revealed: revealedIDs.contains(credential.id),
                       selectionMode: isCompareMode,
                       isSelected: selectedIDs.contains(credential.id))
        cell.onToggleReveal = { [weak self, weak tableView] in
            guard let self else { return }
            if self.revealedIDs.contains(credential.id) {
                self.revealedIDs.remove(credential.id)
            } else {
                self.revealedIDs.insert(credential.id)
            }
            // The list can be re-scanned between configuring and tapping.
            guard indexPath.row < self.credentials.count else { return }
            tableView?.reloadRows(at: [indexPath], with: .fade)
        }
        cell.onCopy = { [weak self] in
            UIPasteboard.general.string = credential.rawValue
            self?.presentAuthToast("Copied token")
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < credentials.count else { return }
        let credential = credentials[indexPath.row]
        if isCompareMode {
            toggleSelection(credential)
        } else {
            navigationController?.pushViewController(
                AuthTokenDetailViewController(credential: credential), animated: true)
        }
    }
}

// MARK: - Empty state

private final class AuthEmptyStateView: UIView {

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        let icon = UIImageView(image: UIImage(
            systemName: "key.slash",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular))?
            .withTintColor(UIColor(white: 0.28, alpha: 1), renderingMode: .alwaysOriginal))
        icon.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = "No auth credentials seen"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = UIColor(white: 0.5, alpha: 1)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Nothing captured so far carried an Authorization header, an API-key header or an auth cookie."
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = UIColor(white: 0.35, alpha: 1)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.setCustomSpacing(14, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Padded pill

private final class AuthPill: UILabel {
    private let inset = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 9, weight: .heavy)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        clipsToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color: UIColor, background: UIColor) {
        self.text = text
        self.textColor = color
        self.backgroundColor = background
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}

// MARK: - Credential card cell

/// One distinct credential.
///
/// Everything sits in a vertical stack pinned to BOTH the top and bottom of the
/// card (and the card to both edges of `contentView`), so the text drives the
/// row height — stock cell labels do not self-size here.
private final class AuthTokenCardCell: UITableViewCell {

    static let reuseID = "AuthTokenCard"

    var onToggleReveal: (() -> Void)?
    var onCopy: (() -> Void)?

    private let card = UIView()
    private let kindPill = AuthPill()
    private let expiryPill = AuthPill()
    private let selectionIcon = UIImageView()
    private let revealButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let valueLabel = UILabel()
    private let metaLabel = UILabel()
    private let hostsLabel = UILabel()
    private let endpointsLabel = UILabel()
    private let alertLabel = UILabel()
    private let seenLabel = UILabel()
    private let stack = UIStackView()

    /// Retained so the 1s tick can re-render the countdown without a reload.
    private var expiryState: AuthCredential.ExpiryState = .none
    private var isJWT = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        selectionIcon.contentMode = .scaleAspectFit
        selectionIcon.setContentHuggingPriority(.required, for: .horizontal)
        selectionIcon.isHidden = true

        configureIconButton(revealButton, symbol: "eye")
        configureIconButton(copyButton, symbol: "doc.on.doc")
        revealButton.addTarget(self, action: #selector(revealTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        let pillRow = UIStackView(arrangedSubviews: [kindPill, expiryPill, UIView(),
                                                     selectionIcon, revealButton, copyButton])
        pillRow.axis = .horizontal
        pillRow.spacing = 8
        pillRow.alignment = .center

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = AuthPalette.value
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byCharWrapping
        valueLabel.isUserInteractionEnabled = true
        valueLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(revealTapped)))

        metaLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        metaLabel.textColor = DebugTheme.accentColor
        metaLabel.numberOfLines = 0

        hostsLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hostsLabel.textColor = AuthPalette.dim
        hostsLabel.numberOfLines = 2

        endpointsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        endpointsLabel.textColor = UIColor(white: 0.5, alpha: 1)
        endpointsLabel.numberOfLines = 0

        alertLabel.font = .systemFont(ofSize: 11, weight: .bold)
        alertLabel.textColor = .systemRed
        alertLabel.numberOfLines = 0

        seenLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        seenLabel.textColor = AuthPalette.caption
        seenLabel.numberOfLines = 0

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        [pillRow, valueLabel, metaLabel, hostsLabel, endpointsLabel, alertLabel, seenLabel]
            .forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(9, after: pillRow)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            // Content drives the height: pinned top AND bottom.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            selectionIcon.widthAnchor.constraint(equalToConstant: 20),
            selectionIcon.heightAnchor.constraint(equalToConstant: 20),
            revealButton.widthAnchor.constraint(equalToConstant: 30),
            revealButton.heightAnchor.constraint(equalToConstant: 26),
            copyButton.widthAnchor.constraint(equalToConstant: 30),
            copyButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureIconButton(_ button: UIButton, symbol: String) {
        button.setImage(UIImage(systemName: symbol,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
                        for: .normal)
        button.tintColor = DebugTheme.accentColor
        button.backgroundColor = AuthPalette.pillBG
        button.layer.cornerRadius = 7
        button.layer.cornerCurve = .continuous
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleReveal = nil
        onCopy = nil
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.12) {
            self.card.backgroundColor = highlighted ? AuthPalette.cardHiBG : AuthPalette.cardBG
        }
    }

    @objc private func revealTapped() { onToggleReveal?() }
    @objc private func copyTapped() { onCopy?() }

    // MARK: Configure

    /// `summary` carries every usage-list aggregate, already computed off the
    /// main thread — this method must stay free of scans.
    func configure(credential: AuthCredential, summary: AuthCredentialSummary,
                   revealed: Bool, selectionMode: Bool, isSelected: Bool) {
        isJWT = credential.isJWT
        expiryState = credential.expiryState

        // Kind pill
        switch credential.kind {
        case .bearer:
            kindPill.set(text: credential.isJWT ? "BEARER · JWT" : "BEARER",
                         color: .black, background: DebugTheme.accentColor)
        case .apiKey:
            kindPill.set(text: credential.kind.label, color: DebugTheme.accentColor,
                         background: DebugTheme.accentColor.withAlphaComponent(0.20))
        default:
            kindPill.set(text: credential.kind.label, color: .white, background: AuthPalette.pillBG)
        }

        renderExpiryPill()

        valueLabel.text = revealed ? credential.value : credential.maskedValue
        valueLabel.textColor = revealed ? AuthPalette.value : UIColor(white: 0.72, alpha: 1)
        revealButton.setImage(UIImage(systemName: revealed ? "eye.slash" : "eye",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
                              for: .normal)

        var meta = ["\(credential.requestCount) request\(credential.requestCount == 1 ? "" : "s")"]
        let hosts = summary.hosts
        if hosts.count > 1 { meta.append("\(hosts.count) hosts") }
        meta.append("\(summary.valueLength) chars")
        if let basic = credential.basic { meta.append("user: \(basic.username)") }
        metaLabel.text = meta.joined(separator: "  ·  ")

        hostsLabel.text = hosts.isEmpty ? nil : hosts.prefix(3).joined(separator: ", ")
        hostsLabel.isHidden = hosts.isEmpty

        endpointsLabel.isHidden = summary.endpointLines.isEmpty
        endpointsLabel.text = summary.endpointLines.joined(separator: "\n")

        let expiredSends = summary.expiredUsageCount
        if expiredSends > 0 {
            alertLabel.isHidden = false
            alertLabel.text = "⚠︎ \(expiredSends) request\(expiredSends == 1 ? "" : "s") sent AFTER this token expired"
        } else {
            alertLabel.isHidden = true
        }

        if let first = summary.firstSeen, let last = summary.lastSeen {
            seenLabel.isHidden = false
            seenLabel.text = "FIRST \(DebugJWT.absolute(first))    LAST \(DebugJWT.absolute(last))"
        } else {
            seenLabel.isHidden = true
        }

        // Selection / alert border
        selectionIcon.isHidden = !selectionMode
        if selectionMode {
            let symbol = isSelected ? "checkmark.circle.fill" : "circle"
            selectionIcon.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
                .withTintColor(isSelected ? DebugTheme.accentColor : UIColor(white: 0.35, alpha: 1),
                               renderingMode: .alwaysOriginal)
        }

        let border: UIColor
        if selectionMode && isSelected { border = DebugTheme.accentColor }
        else if expiredSends > 0 { border = UIColor.systemRed.withAlphaComponent(0.65) }
        else if case .expired = credential.expiryState { border = UIColor.systemRed.withAlphaComponent(0.4) }
        else { border = AuthPalette.cardBorder }
        card.layer.borderColor = border.cgColor
    }

    /// Re-renders just the countdown pill (called once a second).
    func tickCountdown() { renderExpiryPill() }

    private func renderExpiryPill() {
        switch expiryState {
        case .valid(let exp):
            let remaining = exp.timeIntervalSinceNow
            let urgent = remaining < 60
            let color: UIColor = urgent ? .systemOrange : .systemGreen
            expiryPill.set(text: "EXPIRES IN \(DebugJWT.compactDuration(remaining))",
                           color: .black, background: color)
        case .expired(let exp):
            expiryPill.set(text: "EXPIRED \(DebugJWT.compactDuration(exp.timeIntervalSinceNow)) AGO",
                           color: .white, background: .systemRed)
        case .none:
            expiryPill.set(text: isJWT ? "NO EXPIRY" : "OPAQUE",
                           color: UIColor(white: 0.65, alpha: 1), background: AuthPalette.pillBG)
        }
    }
}

// MARK: - Detail screen

/// Everything known about one credential: value, expiry, Basic user/pass,
/// decoded JWT header + claims, and every request that used it.
private final class AuthTokenDetailViewController: UITableViewController {

    private enum Row {
        case value(caption: String, value: String, secret: Bool, copy: String)
        case expiry
        case code(String)
        case usage(AuthTokenUsage)
    }

    private struct Section {
        let title: String
        let rows: [Row]
    }

    private let credential: AuthCredential
    /// Walked once here, not per `cellForRowAt`.
    private let expiredSendCount: Int
    private var sections: [Section] = []
    /// Row-keyed reveal state (token value, Basic password).
    private var revealed = Set<String>()
    private var countdownTimer: Timer?

    init(credential: AuthCredential) {
        self.credential = credential
        self.expiredSendCount = credential.expiredUsageCount
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { countdownTimer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = credential.isJWT ? "JWT Token" : credential.kind.label.capitalized
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        let copyItem = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"),
                                       style: .plain, target: self, action: #selector(copyAllTapped))
        copyItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = copyItem

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
        tableView.contentInset.bottom = 28
        tableView.register(AuthValueCell.self, forCellReuseIdentifier: AuthValueCell.reuseID)
        tableView.register(AuthExpiryCell.self, forCellReuseIdentifier: AuthExpiryCell.reuseID)
        tableView.register(AuthCodeCell.self, forCellReuseIdentifier: AuthCodeCell.reuseID)
        tableView.register(AuthUsageCell.self, forCellReuseIdentifier: AuthUsageCell.reuseID)

        buildSections()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    @objc private func tick() {
        for cell in tableView.visibleCells { (cell as? AuthExpiryCell)?.tickCountdown() }
    }

    @objc private func copyAllTapped() {
        UIPasteboard.general.string = credential.rawValue
        presentAuthToast("Copied token")
    }

    private func buildSections() {
        var result: [Section] = []

        // TOKEN
        var tokenRows: [Row] = [
            .value(caption: credential.kind.label, value: credential.value,
                   secret: true, copy: credential.rawValue)
        ]
        if !credential.sources.isEmpty {
            tokenRows.append(.value(caption: "SEEN IN",
                                    value: credential.sources.joined(separator: ", "),
                                    secret: false, copy: credential.sources.joined(separator: ", ")))
        }
        if let alg = credential.jwt?.algorithm {
            tokenRows.append(.value(caption: "ALGORITHM", value: alg, secret: false, copy: alg))
        }
        result.append(Section(title: "TOKEN", rows: tokenRows))

        // EXPIRY (only meaningful for JWTs)
        if credential.jwt != nil {
            result.append(Section(title: "EXPIRY", rows: [.expiry]))
        }

        // BASIC
        if let basic = credential.basic {
            result.append(Section(title: "BASIC CREDENTIALS", rows: [
                .value(caption: "USERNAME", value: basic.username, secret: false, copy: basic.username),
                .value(caption: "PASSWORD", value: basic.password.isEmpty ? "(empty)" : basic.password,
                       secret: !basic.password.isEmpty, copy: basic.password),
            ]))
        }

        // KEY CLAIMS + all claims
        if let jwt = credential.jwt {
            var keyRows: [Row] = []
            for key in DebugJWT.highlightedClaimOrder {
                guard let raw = jwt.payload[key] else { continue }
                let display = jwt.displayValue(forClaim: key, raw: raw)
                keyRows.append(.value(caption: key.uppercased(), value: display,
                                      secret: false, copy: DebugJWT.stringify(raw)))
            }
            if !keyRows.isEmpty {
                result.append(Section(title: "KEY CLAIMS", rows: keyRows))
            }

            let otherClaims = jwt.orderedClaims().filter {
                !DebugJWT.highlightedClaimOrder.contains($0.key)
            }
            if !otherClaims.isEmpty {
                result.append(Section(title: "OTHER CLAIMS", rows: otherClaims.map {
                    .value(caption: $0.key, value: $0.value, secret: false, copy: $0.value)
                }))
            }
            if !jwt.headerJSON.isEmpty {
                result.append(Section(title: "HEADER (JSON)", rows: [.code(jwt.headerJSON)]))
            }
            if !jwt.payloadJSON.isEmpty {
                result.append(Section(title: "PAYLOAD (JSON)", rows: [.code(jwt.payloadJSON)]))
            }
        } else {
            result.append(Section(title: "FORMAT", rows: [
                .value(caption: "OPAQUE VALUE",
                       value: "Not a JWT — nothing to decode. Shown as-is.",
                       secret: false, copy: credential.value)
            ]))
        }

        // REQUESTS
        let expired = expiredSendCount
        let title = expired > 0
            ? "REQUESTS (\(credential.requestCount)) · \(expired) SENT EXPIRED"
            : "REQUESTS (\(credential.requestCount))"
        result.append(Section(title: title, rows: credential.usages.map { .usage($0) }))

        sections = result
        tableView.reloadData()
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        AuthSectionHeader.make(title: sections[section].title,
                               isAlert: sections[section].title.contains("SENT EXPIRED"))
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 34 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .value(let caption, let value, let secret, let copy):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: AuthValueCell.reuseID, for: indexPath) as! AuthValueCell
            let key = "\(indexPath.section).\(indexPath.row)"
            cell.configure(caption: caption, value: value,
                           secret: secret, revealed: revealed.contains(key))
            cell.onToggleReveal = { [weak self, weak tableView] in
                guard let self else { return }
                if self.revealed.contains(key) { self.revealed.remove(key) } else { self.revealed.insert(key) }
                guard indexPath.section < self.sections.count,
                      indexPath.row < self.sections[indexPath.section].rows.count else { return }
                tableView?.reloadRows(at: [indexPath], with: .fade)
            }
            cell.onCopy = { [weak self] in
                UIPasteboard.general.string = copy
                self?.presentAuthToast("Copied")
            }
            return cell

        case .expiry:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: AuthExpiryCell.reuseID, for: indexPath) as! AuthExpiryCell
            cell.configure(credential: credential, expiredSendCount: expiredSendCount)
            return cell

        case .code(let text):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: AuthCodeCell.reuseID, for: indexPath) as! AuthCodeCell
            cell.configure(text: text)
            cell.onCopy = { [weak self] in
                UIPasteboard.general.string = text
                self?.presentAuthToast("Copied JSON")
            }
            return cell

        case .usage(let usage):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: AuthUsageCell.reuseID, for: indexPath) as! AuthUsageCell
            cell.configure(usage: usage)
            return cell
        }
    }
}

// MARK: - Compare screen

/// Claim-by-claim diff of two selected credentials.
private final class AuthTokenCompareViewController: UITableViewController {

    private let left: AuthCredential
    private let right: AuthCredential
    private var allDiffs: [AuthTokenScanner.ClaimDiff] = []
    private var rows: [AuthTokenScanner.ClaimDiff] = []
    private var differencesOnly = true
    private let segment = UISegmentedControl(items: ["Differences", "All claims"])

    init(left: AuthCredential, right: AuthCredential) {
        self.left = left
        self.right = right
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Compare Tokens"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        tableView.contentInset.bottom = 28
        tableView.register(AuthDiffCell.self, forCellReuseIdentifier: AuthDiffCell.reuseID)
        tableView.register(AuthValueCell.self, forCellReuseIdentifier: AuthValueCell.reuseID)

        allDiffs = AuthTokenScanner.compare(left, right)
        buildHeader()
        applyFilter()
        view.forceLTR()
    }

    private func buildHeader() {
        let container = UIView()

        let card = UIView()
        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)

        let stack = UIStackView(arrangedSubviews: [
            sideRow(tag: "A", credential: left),
            sideRow(tag: "B", credential: right),
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        segment.selectedSegmentIndex = 0
        segment.selectedSegmentTintColor = DebugTheme.accentColor
        segment.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1)], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        segment.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        segment.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(segment)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            segment.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            segment.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            segment.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 10),
            segment.heightAnchor.constraint(equalToConstant: 32),
            segment.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        container.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        let height = container.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        container.frame.size.height = height
        container.forceLTR()
        tableView.tableHeaderView = container
    }

    private func sideRow(tag: String, credential: AuthCredential) -> UIView {
        let pill = AuthPill()
        pill.set(text: tag, color: .black, background: DebugTheme.accentColor)

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = AuthPalette.value

        var line = credential.maskedValue
        if let sub = credential.jwt?.sub { line += "\nsub: \(sub)" }
        switch credential.expiryState {
        case .valid(let exp):   line += "\nexpires \(DebugJWT.absolute(exp))"
        case .expired(let exp): line += "\nEXPIRED \(DebugJWT.absolute(exp))"
        case .none:             line += credential.isJWT ? "\nno exp claim" : "\nopaque value"
        }
        label.text = line

        let row = UIStackView(arrangedSubviews: [pill, label])
        row.axis = .horizontal
        row.spacing = 9
        row.alignment = .top
        return row
    }

    @objc private func filterChanged() {
        differencesOnly = segment.selectedSegmentIndex == 0
        applyFilter()
    }

    private func applyFilter() {
        rows = differencesOnly ? allDiffs.filter { $0.isDifferent } : allDiffs
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(rows.count, 1)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let diffCount = allDiffs.filter { $0.isDifferent }.count
        return AuthSectionHeader.make(
            title: differencesOnly ? "\(diffCount) DIFFERING CLAIM\(diffCount == 1 ? "" : "S")"
                                   : "\(allDiffs.count) CLAIM\(allDiffs.count == 1 ? "" : "S")",
            isAlert: false)
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 34 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if rows.isEmpty {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: AuthValueCell.reuseID, for: indexPath) as! AuthValueCell
            let hasClaims = left.isJWT || right.isJWT
            cell.configure(caption: hasClaims ? "NO DIFFERENCES" : "NOTHING TO COMPARE",
                           value: hasClaims
                               ? "Both tokens carry identical claims."
                               : "Neither token is a JWT, so there are no claims to diff.",
                           secret: false, revealed: false, showsCopy: false)
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: AuthDiffCell.reuseID, for: indexPath) as! AuthDiffCell
        cell.configure(diff: rows[indexPath.row])
        return cell
    }
}

// MARK: - Section header

private enum AuthSectionHeader {
    static func make(title: String, isAlert: Bool) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .heavy)
        label.textColor = isAlert ? .systemRed : AuthPalette.caption
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        container.forceLTR()
        return container
    }
}

// MARK: - Value cell (caption + value, optional reveal + copy)

private final class AuthValueCell: UITableViewCell {

    static let reuseID = "AuthValue"

    var onToggleReveal: (() -> Void)?
    var onCopy: (() -> Void)?

    private let card = UIView()
    private let captionLabel = UILabel()
    private let valueLabel = UILabel()
    private let revealButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = AuthPalette.caption
        captionLabel.numberOfLines = 1

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = AuthPalette.value
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byCharWrapping
        valueLabel.isUserInteractionEnabled = true
        valueLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(revealTapped)))

        configureIconButton(revealButton, symbol: "eye")
        configureIconButton(copyButton, symbol: "doc.on.doc")
        revealButton.addTarget(self, action: #selector(revealTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        let captionRow = UIStackView(arrangedSubviews: [captionLabel, UIView(), revealButton, copyButton])
        captionRow.axis = .horizontal
        captionRow.spacing = 8
        captionRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [captionRow, valueLabel])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            // Value text drives the height.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),

            revealButton.widthAnchor.constraint(equalToConstant: 30),
            revealButton.heightAnchor.constraint(equalToConstant: 24),
            copyButton.widthAnchor.constraint(equalToConstant: 30),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configureIconButton(_ button: UIButton, symbol: String) {
        button.setImage(UIImage(systemName: symbol,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
                        for: .normal)
        button.tintColor = DebugTheme.accentColor
        button.backgroundColor = AuthPalette.pillBG
        button.layer.cornerRadius = 6
        button.layer.cornerCurve = .continuous
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleReveal = nil
        onCopy = nil
    }

    @objc private func revealTapped() { onToggleReveal?() }
    @objc private func copyTapped() { onCopy?() }

    func configure(caption: String, value: String, secret: Bool, revealed: Bool,
                   showsCopy: Bool = true) {
        captionLabel.text = caption.uppercased()
        if secret && !revealed {
            valueLabel.text = AuthCredential.mask(value)
            valueLabel.textColor = UIColor(white: 0.72, alpha: 1)
        } else {
            valueLabel.text = value
            valueLabel.textColor = AuthPalette.value
        }
        revealButton.isHidden = !secret
        revealButton.setImage(UIImage(systemName: revealed ? "eye.slash" : "eye",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
                              for: .normal)
        copyButton.isHidden = !showsCopy
    }
}

// MARK: - Expiry cell (the headline)

private final class AuthExpiryCell: UITableViewCell {

    static let reuseID = "AuthExpiry"

    private let card = UIView()
    private let statusLabel = UILabel()
    private let countdownLabel = UILabel()
    private let detailLabel = UILabel()
    private let alertLabel = UILabel()

    private var state: AuthCredential.ExpiryState = .none
    private var isJWT = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        statusLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        statusLabel.textColor = AuthPalette.caption

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        countdownLabel.textColor = .systemGreen
        countdownLabel.numberOfLines = 0

        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = AuthPalette.dim
        detailLabel.numberOfLines = 0

        alertLabel.font = .systemFont(ofSize: 12, weight: .bold)
        alertLabel.textColor = .systemRed
        alertLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [statusLabel, countdownLabel, detailLabel, alertLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(8, after: countdownLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `expiredSendCount` is passed in already computed — this method runs from
    /// `cellForRowAt` and must not walk the usage list.
    func configure(credential: AuthCredential, expiredSendCount: Int) {
        state = credential.expiryState
        isJWT = credential.isJWT

        var lines: [String] = []
        if let jwt = credential.jwt {
            if let exp = jwt.exp { lines.append("exp  \(DebugJWT.absolute(exp))") }
            if let iat = jwt.iat { lines.append("iat  \(DebugJWT.absolute(iat))") }
            if let nbf = jwt.nbf { lines.append("nbf  \(DebugJWT.absolute(nbf))") }
            if let iat = jwt.iat, let exp = jwt.exp, exp > iat {
                lines.append("life \(DebugJWT.compactDuration(exp.timeIntervalSince(iat)))")
            }
        }
        detailLabel.text = lines.joined(separator: "\n")
        detailLabel.isHidden = lines.isEmpty

        let expiredSends = expiredSendCount
        if expiredSends > 0 {
            alertLabel.isHidden = false
            alertLabel.text = "⚠︎ \(expiredSends) of \(credential.requestCount) request\(credential.requestCount == 1 ? "" : "s") went out AFTER exp — see the request list below."
        } else {
            alertLabel.isHidden = true
        }

        tickCountdown()
    }

    func tickCountdown() {
        switch state {
        case .valid(let exp):
            let remaining = exp.timeIntervalSinceNow
            statusLabel.text = "VALID · EXPIRES IN"
            statusLabel.textColor = AuthPalette.caption
            countdownLabel.text = DebugJWT.compactDuration(remaining)
            countdownLabel.textColor = remaining < 60 ? .systemOrange : .systemGreen
            card.layer.borderColor = (remaining < 60
                ? UIColor.systemOrange.withAlphaComponent(0.6)
                : AuthPalette.cardBorder).cgColor
        case .expired(let exp):
            statusLabel.text = "EXPIRED"
            statusLabel.textColor = .systemRed
            countdownLabel.text = "\(DebugJWT.compactDuration(exp.timeIntervalSinceNow)) ago"
            countdownLabel.textColor = .systemRed
            card.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.65).cgColor
        case .none:
            statusLabel.text = "EXPIRY"
            statusLabel.textColor = AuthPalette.caption
            countdownLabel.text = isJWT ? "No exp claim" : "Opaque token"
            countdownLabel.textColor = AuthPalette.dim
            card.layer.borderColor = AuthPalette.cardBorder.cgColor
        }
    }
}

// MARK: - Code cell (pretty JSON)

private final class AuthCodeCell: UITableViewCell {

    static let reuseID = "AuthCode"

    var onCopy: (() -> Void)?

    private let card = UIView()
    private let codeLabel = UILabel()
    private let copyButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        codeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeLabel.textColor = AuthPalette.value
        codeLabel.numberOfLines = 0
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(codeLabel)

        copyButton.setImage(UIImage(systemName: "doc.on.doc",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
                            for: .normal)
        copyButton.tintColor = DebugTheme.accentColor
        copyButton.backgroundColor = AuthPalette.pillBG
        copyButton.layer.cornerRadius = 6
        copyButton.layer.cornerCurve = .continuous
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(copyButton)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            // Code text drives the height.
            codeLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            codeLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            codeLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            codeLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -10),

            copyButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            copyButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            copyButton.widthAnchor.constraint(equalToConstant: 30),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCopy = nil
    }

    @objc private func copyTapped() { onCopy?() }

    func configure(text: String) { codeLabel.text = text }
}

// MARK: - Usage cell (one request that used the credential)

private final class AuthUsageCell: UITableViewCell {

    static let reuseID = "AuthUsage"

    private let card = UIView()
    private let methodPill = AuthPill()
    private let statusPill = AuthPill()
    private let expiredPill = AuthPill()
    private let pathLabel = UILabel()
    private let hostLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = AuthPalette.value
        pathLabel.numberOfLines = 0
        pathLabel.lineBreakMode = .byCharWrapping

        hostLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hostLabel.textColor = AuthPalette.dim
        hostLabel.numberOfLines = 1

        timeLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        timeLabel.textColor = AuthPalette.caption

        let pills = UIStackView(arrangedSubviews: [methodPill, statusPill, expiredPill, UIView()])
        pills.axis = .horizontal
        pills.spacing = 6
        pills.alignment = .center

        let stack = UIStackView(arrangedSubviews: [pills, pathLabel, hostLabel, timeLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(8, after: pills)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(usage: AuthTokenUsage) {
        methodPill.set(text: usage.method.isEmpty ? "GET" : usage.method,
                       color: .black, background: DebugTheme.accentColor)

        let statusText = usage.statusCode.isEmpty || usage.statusCode == "0" ? "—" : usage.statusCode
        statusPill.set(text: statusText, color: .black,
                       background: AuthPalette.statusColor(usage.statusCode))

        expiredPill.isHidden = !usage.sentExpired
        if usage.sentExpired {
            expiredPill.set(text: "SENT EXPIRED", color: .white, background: .systemRed)
        }

        pathLabel.text = usage.path.isEmpty ? usage.urlString : usage.path
        hostLabel.text = usage.host
        hostLabel.isHidden = usage.host.isEmpty
        timeLabel.text = usage.startedAt.map { DebugJWT.absolute($0) }
        timeLabel.isHidden = (usage.startedAt == nil)

        card.layer.borderColor = (usage.sentExpired
            ? UIColor.systemRed.withAlphaComponent(0.65)
            : AuthPalette.cardBorder).cgColor
    }
}

// MARK: - Claim diff cell

private final class AuthDiffCell: UITableViewCell {

    static let reuseID = "AuthDiff"

    private let card = UIView()
    private let claimLabel = UILabel()
    private let statePill = AuthPill()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = AuthPalette.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = AuthPalette.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        claimLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        claimLabel.textColor = AuthPalette.caption

        for label in [leftLabel, rightLabel] {
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = AuthPalette.value
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
        }

        let topRow = UIStackView(arrangedSubviews: [claimLabel, UIView(), statePill])
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, leftLabel, rightLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(9, after: topRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(diff: AuthTokenScanner.ClaimDiff) {
        claimLabel.text = diff.claim.uppercased()

        leftLabel.text = "A  " + (diff.left ?? "— (absent)")
        rightLabel.text = "B  " + (diff.right ?? "— (absent)")
        leftLabel.textColor = diff.left == nil ? UIColor(white: 0.4, alpha: 1) : AuthPalette.value
        rightLabel.textColor = diff.right == nil ? UIColor(white: 0.4, alpha: 1) : AuthPalette.value

        if diff.isDifferent {
            statePill.set(text: "DIFFERENT", color: .black, background: .systemOrange)
            card.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.55).cgColor
        } else {
            statePill.set(text: "SAME", color: UIColor(white: 0.65, alpha: 1), background: AuthPalette.pillBG)
            card.layer.borderColor = AuthPalette.cardBorder.cgColor
        }
    }
}

// MARK: - Toast

private extension UIViewController {

    /// Small transient confirmation (copy actions). Self-removing.
    func presentAuthToast(_ message: String) {
        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .black
        label.backgroundColor = DebugTheme.accentColor
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            label.heightAnchor.constraint(equalToConstant: 36),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
        label.forceLTR()

        UIView.animate(withDuration: 0.15) { label.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.9) { label.alpha = 0 } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }
}
