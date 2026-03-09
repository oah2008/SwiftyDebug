//
//  LogViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class LogViewController: UIViewController {

    // MARK: - UI

    private static var savedSegmentIndex: Int = 0
    private var segmentControl: UISegmentedControl!
    private var defaultSearchBar: UISearchBar!
    private var deleteItem: UIBarButtonItem!

    /// Console tab: compact table view (cells flush together like a continuous console)
    private var consoleTableView: UITableView!

    /// Third Party / Web tabs: card-based table view
    private var defaultTableView: UITableView!

    /// Floating "scroll to bottom" button — shown when auto-follow is off
    private var followButton: UIButton!
    private static let followButtonSize: CGFloat = 40

    /// Match navigation bar (console search)
    private var matchBar: UIView!
    private var matchLabel: UILabel!
    private var matchUpButton: UIButton!
    private var matchDownButton: UIButton!
    private var consoleTableTopConstraint: NSLayoutConstraint!

    /// Floating glass header (iOS 26+)
    private var floatingHeader: UIView?

    // MARK: - Console data (SQLite-backed virtual scrolling)

    /// Current total count of entries (unfiltered), updated via notification
    private var consoleTotalCount: Int = 0

    /// Current search query (lowercased), nil if no search active
    private var consoleSearchQuery: String?

    /// Count of entries matching current search (for match bar display only)
    private var consoleSearchCount: Int = 0

    /// Current match navigation state
    private var currentMatchIndex: Int?
    private var currentMatchRowid: Int64?

    /// Cache of ConsoleLineCache objects keyed by display row index
    private let entryCache: NSCache<NSNumber, ConsoleLineCache> = {
        let cache = NSCache<NSNumber, ConsoleLineCache>()
        cache.countLimit = 2000
        cache.totalCostLimit = 5 * 1024 * 1024 // 5 MB
        return cache
    }()

    /// Serial OperationQueue for on-demand highlighting
    private let highlightQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.swiftydebug.vc.highlight"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Auto-follow: scroll to bottom on new logs (default on, off when user scrolls up)
    private var isAutoFollowing: Bool = true

    /// Search debounce work item (for performConsoleSearch)
    private var searchDebounceWorkItem: DispatchWorkItem?
    /// Separate recount work item (for debounceSearchRecount — must not cancel search)
    private var recountWorkItem: DispatchWorkItem?
    /// Lock to prevent overlapping jump-to-match scrolls
    private var isJumpingToMatch = false

    /// Multi-cell text selection (long press + drag)
    private var selectionAnchorRow: Int?
    private var selectionEndRow: Int?
    private var selectionCopyButton: UIButton?

    private var selectionRange: ClosedRange<Int>? {
        guard let a = selectionAnchorRow, let e = selectionEndRow else { return nil }
        return min(a, e)...max(a, e)
    }

    /// Reference to the database
    private var consoleDB: ConsoleLogDB { ConsoleLogDB.shared }

    /// The effective row count for the console table (always shows all entries)
    private var consoleRowCount: Int {
        return consoleTotalCount
    }

    // MARK: - Table data (Third Party & Web — SQLite-backed virtual scrolling)

    /// Reference to the LogModel database
    private var logModelDB: LogModelDB { LogModelDB.shared }

    /// Current total count of entries for the active non-console tab
    private var defaultTotalCount: Int = 0

    /// Cache of LogRecord objects keyed by display row index
    private let defaultEntryCache: NSCache<NSNumber, LogRecord> = {
        let cache = NSCache<NSNumber, LogRecord>()
        cache.countLimit = 500
        return cache
    }()

    /// Current search query for Third Party / Web tabs (nil = no filter)
    private var defaultSearchQuery: String?

    /// Auto-follow state for defaultTableView
    private var isDefaultAutoFollowing: Bool = true

    /// Floating "scroll to bottom" button for defaultTableView
    private var defaultFollowButton: UIButton!

    // MARK: - Helpers

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

    private var isConsoleTab: Bool {
        return (segmentControl?.selectedSegmentIndex ?? 0) == 0
    }

    private var selectedSource: SwiftyDebugLogSource {
        switch segmentControl?.selectedSegmentIndex ?? 0 {
        case 1:  return .thirdParty
        case 2:  return .web
        default: return .app
        }
    }

    private var currentSearchWord: String?

    // MARK: - viewDidLoad

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapView))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // Nav bar title
        let titleLabel = UILabel()
        titleLabel.text = "Logs"
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.textColor = DebugTheme.accentColor
        navigationItem.titleView = titleLabel

        // Nav bar buttons
        deleteItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(resetLogs(_:)))
        deleteItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItems = [deleteItem]

        // Segment control — restore last selected tab (resets on app relaunch)
        segmentControl.selectedSegmentIndex = Self.savedSegmentIndex
        segmentControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)

        // Default table view (Third Party & Web)
        defaultTableView.register(LogCell.self, forCellReuseIdentifier: "LogCell")
        defaultTableView.tableFooterView = UIView()
        defaultTableView.delegate = self
        defaultTableView.dataSource = self
        defaultTableView.backgroundColor = .black
        defaultTableView.separatorStyle = .none
        defaultTableView.rowHeight = UITableView.automaticDimension
        defaultTableView.estimatedRowHeight = 80
        if floatingHeader == nil {
            defaultTableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        } else {
            defaultTableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        }
        defaultTableView.showsVerticalScrollIndicator = false
        defaultTableView.prefetchDataSource = self

        // Console table view
        consoleTableView.register(ConsoleCell.self, forCellReuseIdentifier: "ConsoleCell")
        consoleTableView.tableFooterView = UIView()
        consoleTableView.delegate = self
        consoleTableView.dataSource = self
        consoleTableView.prefetchDataSource = self
        consoleTableView.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        consoleTableView.separatorStyle = .none
        consoleTableView.rowHeight = UITableView.automaticDimension
        consoleTableView.estimatedRowHeight = 16
        consoleTableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        consoleTableView.showsVerticalScrollIndicator = true
        consoleTableView.indicatorStyle = .white

        // Long press for multi-cell text selection
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleConsoleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        consoleTableView.addGestureRecognizer(longPress)

        // Search bar
        defaultSearchBar.delegate = self
        defaultSearchBar.text = currentSearchWord
        defaultSearchBar.searchBarStyle = .minimal
        defaultSearchBar.barTintColor = .clear
        defaultSearchBar.isTranslucent = true
        defaultSearchBar.tintColor = DebugTheme.accentColor
        defaultSearchBar.backgroundImage = UIImage()

        let tf = defaultSearchBar.searchTextField
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
            string: "Search logs...",
            attributes: [.foregroundColor: UIColor(white: 0.4, alpha: 1)]
        )
        tf.leftView?.tintColor = UIColor(white: 0.4, alpha: 1)
        tf.returnKeyType = .default

        // Keyboard dismiss toolbar
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.barTintColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        toolbar.isTranslucent = false
        toolbar.clipsToBounds = true // hide top separator
        let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: chevron, style: .plain, target: self, action: #selector(dismissKeyboard))
        ]
        toolbar.items?.last?.tintColor = UIColor(white: 0.6, alpha: 1)
        tf.inputAccessoryView = toolbar

        // Notifications
        NotificationCenter.default.addObserver(
            forName: .consoleOutputReceived,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleConsoleOutput(note)
        }

        NotificationCenter.default.addObserver(
            forName: .logEntriesUpdated,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isConsoleTab else { return }
            self.handleDefaultLogUpdate()
        }

        // Load initial console count from DB
        rebuildConsoleEntries()

        updateVisibility()
        if !isConsoleTab {
            rebuildDefaultEntries()
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .black

        // --- Create shared elements ---
        createSegmentControl()
        createSearchBar()
        createTableViews()
        createMatchBar()
        createFollowButtons()

        // --- Layout: iOS 26+ floating glass header vs legacy stacked ---
        if #available(iOS 26, *) {
            setupFloatingGlassLayout()
        } else {
            setupLegacyLayout()
        }
    }

    private func createSegmentControl() {
        segmentControl = UISegmentedControl(items: [
            Self.makeSegmentImage(systemName: "text.alignleft", title: "Console"),
            Self.makeSegmentImage(systemName: "shippingbox", title: "Third Party"),
            Self.makeSegmentImage(systemName: "globe", title: "Web"),
        ])
        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        segmentControl.selectedSegmentTintColor = DebugTheme.accentColor
        segmentControl.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
        ], for: .normal)
        segmentControl.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        ], for: .selected)
    }

    private func createSearchBar() {
        defaultSearchBar = UISearchBar()
        defaultSearchBar.translatesAutoresizingMaskIntoConstraints = false
    }

    private func createTableViews() {
        consoleTableView = UITableView(frame: .zero, style: .plain)
        consoleTableView.translatesAutoresizingMaskIntoConstraints = false

        defaultTableView = UITableView(frame: .zero, style: .plain)
        defaultTableView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func createMatchBar() {
        matchBar = UIView()
        matchBar.translatesAutoresizingMaskIntoConstraints = false
        matchBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        matchBar.isHidden = true

        matchLabel = UILabel()
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        matchLabel.textColor = UIColor(white: 0.7, alpha: 1)
        matchLabel.textAlignment = .center
        matchBar.addSubview(matchLabel)

        let navConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        matchUpButton = UIButton(type: .system)
        matchUpButton.translatesAutoresizingMaskIntoConstraints = false
        matchUpButton.setImage(UIImage(systemName: "chevron.up", withConfiguration: navConfig), for: .normal)
        matchUpButton.tintColor = DebugTheme.accentColor
        matchUpButton.addTarget(self, action: #selector(matchUpTapped), for: .touchUpInside)
        matchBar.addSubview(matchUpButton)

        matchDownButton = UIButton(type: .system)
        matchDownButton.translatesAutoresizingMaskIntoConstraints = false
        matchDownButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: navConfig), for: .normal)
        matchDownButton.tintColor = DebugTheme.accentColor
        matchDownButton.addTarget(self, action: #selector(matchDownTapped), for: .touchUpInside)
        matchBar.addSubview(matchDownButton)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 0.2, alpha: 1)
        matchBar.addSubview(separator)

        NSLayoutConstraint.activate([
            matchLabel.leadingAnchor.constraint(equalTo: matchBar.leadingAnchor, constant: 12),
            matchLabel.centerYAnchor.constraint(equalTo: matchBar.centerYAnchor),

            matchDownButton.trailingAnchor.constraint(equalTo: matchBar.trailingAnchor, constant: -8),
            matchDownButton.centerYAnchor.constraint(equalTo: matchBar.centerYAnchor),
            matchDownButton.widthAnchor.constraint(equalToConstant: 36),
            matchDownButton.heightAnchor.constraint(equalToConstant: 36),

            matchUpButton.trailingAnchor.constraint(equalTo: matchDownButton.leadingAnchor),
            matchUpButton.centerYAnchor.constraint(equalTo: matchBar.centerYAnchor),
            matchUpButton.widthAnchor.constraint(equalToConstant: 36),
            matchUpButton.heightAnchor.constraint(equalToConstant: 36),

            separator.leadingAnchor.constraint(equalTo: matchBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: matchBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: matchBar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func createFollowButtons() {
        let btnSize = Self.followButtonSize
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)

        followButton = UIButton(type: .system)
        followButton.translatesAutoresizingMaskIntoConstraints = false
        followButton.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        followButton.layer.cornerRadius = btnSize / 2
        followButton.clipsToBounds = true
        followButton.layer.borderWidth = 1
        followButton.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        followButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: chevronConfig), for: .normal)
        followButton.tintColor = DebugTheme.accentColor
        followButton.alpha = 0
        followButton.addTarget(self, action: #selector(followButtonTapped), for: .touchUpInside)

        defaultFollowButton = UIButton(type: .system)
        defaultFollowButton.translatesAutoresizingMaskIntoConstraints = false
        defaultFollowButton.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        defaultFollowButton.layer.cornerRadius = btnSize / 2
        defaultFollowButton.clipsToBounds = true
        defaultFollowButton.layer.borderWidth = 1
        defaultFollowButton.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        defaultFollowButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: chevronConfig), for: .normal)
        defaultFollowButton.tintColor = DebugTheme.accentColor
        defaultFollowButton.alpha = 0
        defaultFollowButton.addTarget(self, action: #selector(defaultFollowButtonTapped), for: .touchUpInside)
    }

    // MARK: - iOS 26+ Floating Glass Layout

    @available(iOS 26, *)
    private func setupFloatingGlassLayout() {
        // Table views go first (behind everything)
        consoleTableView.contentInsetAdjustmentBehavior = .never
        defaultTableView.contentInsetAdjustmentBehavior = .never
        view.addSubview(consoleTableView)
        view.addSubview(defaultTableView)

        // Match bar (floats between glass header and console table)
        view.addSubview(matchBar)

        // Floating glass header
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 16
        glass.layer.cornerCurve = .continuous
        floatingHeader = glass
        view.addSubview(glass)

        // Add segment + search bar inside glass contentView
        let content = glass.contentView
        segmentControl.backgroundColor = .clear
        content.addSubview(segmentControl)
        defaultSearchBar.backgroundColor = .clear
        content.addSubview(defaultSearchBar)

        // Follow buttons on top
        view.addSubview(followButton)
        view.addSubview(defaultFollowButton)

        // Console table top constraint (not used in glass layout but needed for setMatchBarVisible)
        consoleTableTopConstraint = consoleTableView.topAnchor.constraint(equalTo: view.topAnchor)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            // Table views: full screen (scroll under glass nav bar + header)
            consoleTableView.topAnchor.constraint(equalTo: view.topAnchor),
            consoleTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            consoleTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            consoleTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            defaultTableView.topAnchor.constraint(equalTo: view.topAnchor),
            defaultTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            defaultTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            defaultTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Glass header: floats at top
            glass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            // Segment inside glass
            segmentControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            segmentControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            segmentControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            segmentControl.heightAnchor.constraint(equalToConstant: 32),

            // Search bar inside glass
            defaultSearchBar.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 4),
            defaultSearchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            defaultSearchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            defaultSearchBar.heightAnchor.constraint(equalToConstant: 44),
            defaultSearchBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            // Match bar: below glass header
            matchBar.topAnchor.constraint(equalTo: glass.bottomAnchor, constant: 4),
            matchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            matchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            matchBar.heightAnchor.constraint(equalToConstant: 36),

            // Follow buttons
            followButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            followButton.widthAnchor.constraint(equalToConstant: btnSize),
            followButton.heightAnchor.constraint(equalToConstant: btnSize),

            defaultFollowButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            defaultFollowButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            defaultFollowButton.widthAnchor.constraint(equalToConstant: btnSize),
            defaultFollowButton.heightAnchor.constraint(equalToConstant: btnSize),
        ])
    }

    // MARK: - Legacy Layout (< iOS 26)

    private func setupLegacyLayout() {
        segmentControl.backgroundColor = UIColor(white: 0.15, alpha: 1)
        view.addSubview(segmentControl)
        view.addSubview(defaultSearchBar)
        view.addSubview(consoleTableView)
        view.addSubview(defaultTableView)
        view.addSubview(matchBar)
        view.addSubview(followButton)
        view.addSubview(defaultFollowButton)

        // Console table top constraint (switches between searchBar and matchBar)
        consoleTableTopConstraint = consoleTableView.topAnchor.constraint(equalTo: defaultSearchBar.bottomAnchor)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            segmentControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            segmentControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            segmentControl.heightAnchor.constraint(equalToConstant: 32),

            defaultSearchBar.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 8),
            defaultSearchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            defaultSearchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            defaultSearchBar.heightAnchor.constraint(equalToConstant: 48),

            // Match bar between search bar and console table
            matchBar.topAnchor.constraint(equalTo: defaultSearchBar.bottomAnchor),
            matchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            matchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            matchBar.heightAnchor.constraint(equalToConstant: 36),

            consoleTableTopConstraint,
            consoleTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            consoleTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            consoleTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            defaultTableView.topAnchor.constraint(equalTo: defaultSearchBar.bottomAnchor),
            defaultTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            defaultTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            defaultTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Follow button (console): bottom-right, above safe area
            followButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            followButton.widthAnchor.constraint(equalToConstant: btnSize),
            followButton.heightAnchor.constraint(equalToConstant: btnSize),

            // Follow button (default table): same position
            defaultFollowButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            defaultFollowButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            defaultFollowButton.widthAnchor.constraint(equalToConstant: btnSize),
            defaultFollowButton.heightAnchor.constraint(equalToConstant: btnSize),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = floatingHeader {
            let topInset = header.frame.maxY + 8
            let bottomInset = view.safeAreaInsets.bottom + Self.followButtonSize + 12
            let scrollBottom = view.safeAreaInsets.bottom
            let insets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
            let scrollInsets = UIEdgeInsets(top: topInset, left: 0, bottom: scrollBottom, right: 0)
            if consoleTableView.contentInset != insets {
                consoleTableView.contentInset = insets
                consoleTableView.verticalScrollIndicatorInsets = scrollInsets
            }
            if defaultTableView.contentInset != insets {
                defaultTableView.contentInset = insets
                defaultTableView.verticalScrollIndicatorInsets = scrollInsets
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLogHook.debugUIVisible = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Scroll to bottom after layout is fully applied (insets ready)
        if isConsoleTab {
            scrollConsoleToBottomIfNeeded()
        } else if isDefaultAutoFollowing {
            scrollDefaultToBottomIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NSLogHook.debugUIVisible = false
        defaultSearchBar.resignFirstResponder()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        entryCache.removeAllObjects()
        defaultEntryCache.removeAllObjects()
        highlightQueue.cancelAllOperations()
    }

    deinit {
        searchDebounceWorkItem?.cancel()
        recountWorkItem?.cancel()
        reloadDebounceItem?.cancel()
        highlightQueue.cancelAllOperations()
        entryCache.removeAllObjects()
        defaultEntryCache.removeAllObjects()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility

    private func updateVisibility() {
        consoleTableView.isHidden = !isConsoleTab
        defaultTableView.isHidden = isConsoleTab
        followButton.isHidden = !isConsoleTab
        defaultFollowButton.isHidden = isConsoleTab
        if !isConsoleTab {
            setMatchBarVisible(false)
        }
    }

    private func setMatchBarVisible(_ visible: Bool) {
        guard matchBar.isHidden == visible else { return } // already correct state
        matchBar.isHidden = !visible

        if floatingHeader == nil {
            // Legacy layout: console table anchors to searchBar or matchBar
            consoleTableTopConstraint.isActive = false
            if visible {
                consoleTableTopConstraint = consoleTableView.topAnchor.constraint(equalTo: matchBar.bottomAnchor)
            } else {
                consoleTableTopConstraint = consoleTableView.topAnchor.constraint(equalTo: defaultSearchBar.bottomAnchor)
            }
            consoleTableTopConstraint.isActive = true
        }
        // Glass layout: table is full-screen, content inset handled by viewDidLayoutSubviews
        view.layoutIfNeeded()
    }

    private func updateMatchLabel() {
        if let idx = currentMatchIndex, consoleSearchCount > 0 {
            matchLabel.text = "\(idx + 1) of \(consoleSearchCount)"
        } else if consoleSearchCount == 0, consoleSearchQuery != nil {
            matchLabel.text = "No matches"
        } else {
            matchLabel.text = "\(consoleSearchCount) matches"
        }
        let hasMatches = consoleSearchCount > 0
        matchUpButton.isEnabled = hasMatches
        matchDownButton.isEnabled = hasMatches
        matchUpButton.alpha = hasMatches ? 1 : 0.3
        matchDownButton.alpha = hasMatches ? 1 : 0.3
    }

    // MARK: - Console output (count-based updates from SQLite)

    private func handleConsoleOutput(_ note: Notification) {
        guard let totalCount = note.userInfo?["totalCount"] as? Int else { return }

        guard isConsoleTab else {
            consoleTotalCount = totalCount
            return
        }

        let previousCount = consoleTotalCount
        consoleTotalCount = totalCount

        let newRows = totalCount - previousCount
        guard newRows > 0 else { return }

        if newRows > 500 {
            consoleTableView.reloadData()
        } else {
            let indexPaths = (previousCount..<totalCount).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                self.consoleTableView.insertRows(at: indexPaths, with: .none)
            }
        }

        // Update match count if search is active
        if let query = consoleSearchQuery {
            debounceSearchRecount(query: query)
        }

        if isAutoFollowing && totalCount > 0 {
            scrollToConsoleBottom(animated: false)
        }
    }

    /// Rebuild console from DB (tab switch, search change, initial load)
    private func rebuildConsoleEntries() {
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: false)
        entryCache.removeAllObjects()
        highlightQueue.cancelAllOperations()

        consoleTotalCount = consoleDB.cachedTotalCount

        let search = (currentSearchWord ?? "").lowercased()
        if search.isEmpty {
            consoleSearchQuery = nil
            consoleSearchCount = 0
            currentMatchIndex = nil
            currentMatchRowid = nil
            setMatchBarVisible(false)
        } else {
            consoleSearchQuery = search
            consoleSearchCount = consoleDB.searchCount(query: search)
            currentMatchIndex = nil
            currentMatchRowid = nil
            setMatchBarVisible(true)
            updateMatchLabel()
        }

        consoleTableView.reloadData()
        scrollConsoleToBottomIfNeeded()
    }

    private func scrollConsoleToBottomIfNeeded() {
        guard consoleRowCount > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.consoleRowCount > 0 else { return }
            self.scrollToConsoleBottom(animated: false)
        }
    }

    private func scrollToConsoleBottom(animated: Bool, forceReload: Bool = false) {
        let count = consoleRowCount
        guard count > 0 else { return }

        if forceReload {
            // Reset all height estimates so UIKit only measures the last ~20 visible rows
            entryCache.removeAllObjects()
            consoleTableView.reloadData()
        }

        let lastIndexPath = IndexPath(row: count - 1, section: 0)
        consoleTableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: animated)
    }

    // MARK: - Console highlighting (on-demand)

    private func cacheCost(for entry: ConsoleLineCache) -> Int {
        var cost = 232
        cost += entry.text.utf8.count
        if let attr = entry.attributedText {
            cost += attr.length * 4
        }
        return cost
    }

    // Batched highlight results — accumulate on highlight queue, flush to main together
    private var pendingHighlights: [(displayIndex: Int, rowid: Int64, attributed: NSAttributedString)] = []
    private let highlightLock = NSLock()
    private var highlightFlushScheduled = false

    private func enqueueHighlight(for entry: ConsoleLineCache, displayIndex: Int) {
        guard entry.attributedText == nil else { return }

        let isError = (entry.color == .systemRed)
        let text = entry.text
        let rowid = entry.rowid

        highlightQueue.addOperation { [weak self] in
            let highlighted = ConsoleCell.highlightConsoleText(text, isError: isError)

            guard let self = self else { return }
            self.highlightLock.lock()
            self.pendingHighlights.append((displayIndex: displayIndex, rowid: rowid, attributed: highlighted))
            let needsFlush = !self.highlightFlushScheduled
            if needsFlush { self.highlightFlushScheduled = true }
            self.highlightLock.unlock()

            if needsFlush {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingHighlights()
                }
            }
        }
    }

    private func flushPendingHighlights() {
        highlightLock.lock()
        let batch = pendingHighlights
        pendingHighlights.removeAll(keepingCapacity: true)
        highlightFlushScheduled = false
        highlightLock.unlock()

        guard !batch.isEmpty else { return }

        var reloadPaths: [IndexPath] = []
        let visibleRows = consoleTableView.indexPathsForVisibleRows

        for item in batch {
            let key = NSNumber(value: item.displayIndex)
            if let cached = entryCache.object(forKey: key), cached.rowid == item.rowid {
                cached.attributedText = item.attributed
                entryCache.setObject(cached, forKey: key, cost: cacheCost(for: cached))

                let indexPath = IndexPath(row: item.displayIndex, section: 0)
                if visibleRows?.contains(indexPath) == true {
                    reloadPaths.append(indexPath)
                }
            }
        }

        if !reloadPaths.isEmpty {
            consoleTableView.reloadRows(at: reloadPaths, with: .none)
        }
    }

    // MARK: - Console search (jump-to-match, no filtering)

    private func performConsoleSearch(_ searchText: String) {
        searchDebounceWorkItem?.cancel()
        recountWorkItem?.cancel()

        if searchText.isEmpty {
            consoleSearchQuery = nil
            consoleSearchCount = 0
            currentMatchIndex = nil
            currentMatchRowid = nil
            setMatchBarVisible(false)
            // Only reload visible cells to remove highlights — no full reload, no scroll
            reloadVisibleConsoleCells()
        } else {
            let query = searchText.lowercased()
            consoleSearchQuery = query

            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.consoleSearchCount = self.consoleDB.searchCount(query: query)
                self.currentMatchIndex = nil
                self.currentMatchRowid = nil
                self.setMatchBarVisible(true)
                self.updateMatchLabel()
                // Only reload visible cells to apply highlights — no full reload, no scroll
                self.reloadVisibleConsoleCells()
            }
            searchDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func reloadVisibleConsoleCells() {
        guard let visible = consoleTableView.indexPathsForVisibleRows, !visible.isEmpty else { return }
        consoleTableView.reloadRows(at: visible, with: .none)
    }

    /// Re-query match count when new entries arrive during active search
    private func debounceSearchRecount(query: String) {
        recountWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.consoleSearchQuery == query else { return }
            let newCount = self.consoleDB.searchCount(query: query)
            if newCount != self.consoleSearchCount {
                self.consoleSearchCount = newCount
                if let idx = self.currentMatchIndex, idx >= newCount {
                    self.currentMatchIndex = max(0, newCount - 1)
                }
                self.updateMatchLabel()
            }
        }
        recountWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Match navigation

    @objc private func matchUpTapped() {
        guard !isJumpingToMatch else { return }
        guard let query = consoleSearchQuery, consoleSearchCount > 0 else { return }
        let current = currentMatchIndex ?? 0
        let newIndex = (current - 1 + consoleSearchCount) % consoleSearchCount
        jumpToMatch(index: newIndex, query: query)
    }

    @objc private func matchDownTapped() {
        guard !isJumpingToMatch else { return }
        guard let query = consoleSearchQuery, consoleSearchCount > 0 else { return }
        let current = currentMatchIndex ?? -1
        let newIndex = (current + 1) % consoleSearchCount
        jumpToMatch(index: newIndex, query: query)
    }

    private func jumpToMatch(index: Int, query: String) {
        isJumpingToMatch = true

        let previousRowid = currentMatchRowid
        currentMatchIndex = index
        updateMatchLabel()

        guard let rowid = consoleDB.matchRowid(query: query, matchIndex: index) else {
            isJumpingToMatch = false
            return
        }
        currentMatchRowid = rowid
        let displayRow = consoleDB.displayRow(forRowid: rowid)
        guard displayRow < consoleTotalCount else {
            isJumpingToMatch = false
            return
        }

        isAutoFollowing = false
        setFollowButtonVisible(true, animated: true)

        let indexPath = IndexPath(row: displayRow, section: 0)
        consoleTableView.scrollToRow(at: indexPath, at: .middle, animated: true)

        // Reload previous and new current match cells to update highlight
        var reloadPaths = [indexPath]
        if let prevRowid = previousRowid, prevRowid != rowid {
            let prevRow = consoleDB.displayRow(forRowid: prevRowid)
            if prevRow < consoleTotalCount {
                reloadPaths.append(IndexPath(row: prevRow, section: 0))
            }
        }
        consoleTableView.reloadRows(at: reloadPaths, with: .none)
    }

    // MARK: - Table data (Third Party & Web — virtual scrolling from LogModelDB)

    private var reloadDebounceItem: DispatchWorkItem?

    /// Handle new log entries from LogModelDB (called via refreshLogs notification)
    private func handleDefaultLogUpdate() {
        let source = selectedSource.rawValue
        let newCount: Int
        if let query = defaultSearchQuery {
            newCount = logModelDB.searchCount(source: source, query: query)
        } else {
            newCount = logModelDB.cachedCount[source] ?? logModelDB.readCount(source: source)
        }

        let previousCount = defaultTotalCount
        defaultTotalCount = newCount

        let newRows = newCount - previousCount
        if newRows < 0 {
            // Rows were deleted (e.g. trash with pinned remaining) — full reload
            defaultEntryCache.removeAllObjects()
            defaultTableView.reloadData()
            return
        }
        guard newRows > 0 else { return }

        if newRows > 500 {
            defaultTableView.reloadData()
        } else {
            let indexPaths = (previousCount..<newCount).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                self.defaultTableView.insertRows(at: indexPaths, with: .none)
            }
        }

        if isDefaultAutoFollowing && newCount > 0 {
            scrollDefaultToBottom(animated: false)
        }
    }

    /// Full rebuild of default table (tab switch, clear, search change)
    private func rebuildDefaultEntries() {
        defaultEntryCache.removeAllObjects()

        let source = selectedSource.rawValue
        let search = (currentSearchWord ?? "").lowercased()
        if search.isEmpty {
            defaultSearchQuery = nil
            defaultTotalCount = logModelDB.cachedCount[source] ?? logModelDB.readCount(source: source)
        } else {
            defaultSearchQuery = search
            defaultTotalCount = logModelDB.searchCount(source: source, query: search)
        }

        defaultTableView.reloadData()

        if isDefaultAutoFollowing {
            scrollDefaultToBottomIfNeeded()
        }
    }

    private func scrollDefaultToBottomIfNeeded() {
        guard defaultTotalCount > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.defaultTotalCount > 0 else { return }
            self.scrollDefaultToBottom(animated: false)
        }
    }

    private func scrollDefaultToBottom(animated: Bool) {
        guard defaultTotalCount > 0 else { return }
        let lastIndexPath = IndexPath(row: defaultTotalCount - 1, section: 0)
        defaultTableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: animated)
    }

    // MARK: - Actions

    @objc func segmentChanged(_ sender: UISegmentedControl) {
        dismissSelection()
        Self.savedSegmentIndex = sender.selectedSegmentIndex
        defaultSearchBar.text = currentSearchWord
        updateVisibility()

        if isConsoleTab {
            rebuildConsoleEntries()
        } else {
            // Reset auto-follow on tab switch
            isDefaultAutoFollowing = true
            setDefaultFollowButtonVisible(false, animated: false)
            rebuildDefaultEntries()
        }
    }

    @objc func resetLogs(_ sender: Any) {
        defaultSearchBar.resignFirstResponder()

        if isConsoleTab {
            dismissSelection()
            LogStore.shared.clearConsole()
            entryCache.removeAllObjects()
            highlightQueue.cancelAllOperations()
            consoleTotalCount = 0
            consoleSearchCount = 0
            consoleSearchQuery = nil
            currentMatchIndex = nil
            currentMatchRowid = nil
            isAutoFollowing = true
            setFollowButtonVisible(false, animated: false)
            setMatchBarVisible(false)
            consoleTableView.reloadData()
        } else {
            let source = selectedSource.rawValue
            logModelDB.deleteAll(source: source)
            defaultEntryCache.removeAllObjects()
            defaultSearchQuery = nil
            isDefaultAutoFollowing = true
            setDefaultFollowButtonVisible(false, animated: false)
            defaultSearchBar.text = nil
            currentSearchWord = nil
            // Set count to 0 now; onCountChanged callback will update with
            // actual remaining count (pinned rows) and trigger rebuild
            defaultTotalCount = 0
            defaultTableView.reloadData()
        }
    }

    @objc func didTapView() {
        defaultSearchBar.resignFirstResponder()
        dismissSelection()
    }

    @objc private func dismissKeyboard() {
        defaultSearchBar.resignFirstResponder()
    }

    // MARK: - Multi-cell text selection (long press + drag)

    @objc private func handleConsoleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: consoleTableView)
        let indexPath = consoleTableView.indexPathForRow(at: location)

        switch gesture.state {
        case .began:
            guard let row = indexPath?.row else { return }
            dismissCopyButton()
            selectionAnchorRow = row
            selectionEndRow = row
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateSelectionHighlights()

        case .changed:
            guard let row = indexPath?.row else { return }
            guard row != selectionEndRow else { return }
            selectionEndRow = row
            updateSelectionHighlights()

        case .ended, .cancelled:
            if selectionRange != nil {
                showCopyButton()
            }

        default: break
        }
    }

    private func updateSelectionHighlights() {
        let range = selectionRange
        for cell in consoleTableView.visibleCells {
            guard let indexPath = consoleTableView.indexPath(for: cell) else { continue }
            cell.contentView.backgroundColor = (range?.contains(indexPath.row) == true)
                ? UIColor.systemBlue.withAlphaComponent(0.2)
                : nil
        }
    }

    private func showCopyButton() {
        guard let range = selectionRange else { return }
        dismissCopyButton()

        let count = range.count
        let btn = UIButton(type: .system)
        btn.setTitle("Copy \(count) line\(count == 1 ? "" : "s")", for: .normal)
        btn.backgroundColor = UIColor.systemBlue
        btn.layer.cornerRadius = 16
        var btnConfig = UIButton.Configuration.plain()
        btnConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        btnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 13, weight: .semibold)
            return attr
        }
        btnConfig.baseForegroundColor = .white
        btn.configuration = btnConfig
        btn.addTarget(self, action: #selector(copySelectionTapped), for: .touchUpInside)
        btn.sizeToFit()

        // Position above the first visible selected cell
        if let firstIP = consoleTableView.indexPathsForVisibleRows?.first(where: { range.contains($0.row) }),
           let cell = consoleTableView.cellForRow(at: firstIP) {
            let cellFrame = consoleTableView.convert(cell.frame, to: view)
            let y = max(view.safeAreaInsets.top + 20, cellFrame.minY - 24)
            btn.center = CGPoint(x: view.bounds.midX, y: y)
        } else {
            btn.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 60)
        }

        view.addSubview(btn)
        selectionCopyButton = btn
    }

    @objc private func copySelectionTapped() {
        guard let range = selectionRange else { return }

        // Fetch text for all rows in range (prefer cache, fall back to DB)
        var lines: [String] = []
        lines.reserveCapacity(range.count)

        var allCached = true
        for row in range {
            let key = NSNumber(value: row)
            if let entry = entryCache.object(forKey: key) {
                lines.append(entry.text)
            } else {
                allCached = false
                break
            }
        }

        if !allCached {
            lines = consoleDB.fetchRange(offset: range.lowerBound, limit: range.count).map(\.text)
        }

        UIPasteboard.general.string = lines.joined(separator: "\n")
        dismissSelection()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func dismissSelection() {
        selectionAnchorRow = nil
        selectionEndRow = nil
        dismissCopyButton()
        updateSelectionHighlights()
    }

    private func dismissCopyButton() {
        selectionCopyButton?.removeFromSuperview()
        selectionCopyButton = nil
    }

    @objc private func followButtonTapped() {
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        guard consoleRowCount > 0 else { return }
        scrollToConsoleBottom(animated: false, forceReload: true)
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

    // MARK: - Default table follow button

    @objc private func defaultFollowButtonTapped() {
        isDefaultAutoFollowing = true
        setDefaultFollowButtonVisible(false, animated: true)
        scrollDefaultToBottom(animated: false)
    }

    private func setDefaultFollowButtonVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard defaultFollowButton.alpha != target else { return }
        if animated {
            UIView.animate(withDuration: 0.25) {
                self.defaultFollowButton.alpha = target
            }
        } else {
            defaultFollowButton.alpha = target
        }
    }

    private func checkIfDefaultScrolledToBottom() {
        let offset = defaultTableView.contentOffset.y
        let visibleHeight = defaultTableView.bounds.height
        let contentHeight = defaultTableView.contentSize.height
        let bottomInset = defaultTableView.contentInset.bottom

        if offset + visibleHeight + bottomInset >= contentHeight - 60 {
            isDefaultAutoFollowing = true
            setDefaultFollowButtonVisible(false, animated: true)
        }
    }
}

// MARK: - UITableViewDataSource

extension LogViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == consoleTableView {
            return consoleRowCount
        }
        return defaultTotalCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView == consoleTableView {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ConsoleCell", for: indexPath) as! ConsoleCell

            let key = NSNumber(value: indexPath.row)
            if let entry = entryCache.object(forKey: key) {
                let isCurrent = (entry.rowid == currentMatchRowid)
                cell.configure(with: entry, searchQuery: consoleSearchQuery, isCurrentMatch: isCurrent)
            } else {
                let rows = consoleDB.fetchRange(offset: indexPath.row, limit: 1)

                if let row = rows.first {
                    let color: UIColor = (row.colorCode == 1) ? .systemRed : .white
                    let entry = ConsoleLineCache(rowid: row.rowid, text: row.text, color: color)
                    entryCache.setObject(entry, forKey: key, cost: cacheCost(for: entry))
                    let isCurrent = (entry.rowid == currentMatchRowid)
                    cell.configure(with: entry, searchQuery: consoleSearchQuery, isCurrentMatch: isCurrent)
                    enqueueHighlight(for: entry, displayIndex: indexPath.row)
                }
            }

            // Apply multi-cell selection highlight for recycled cells
            cell.contentView.backgroundColor = (selectionRange?.contains(indexPath.row) == true)
                ? UIColor.systemBlue.withAlphaComponent(0.2)
                : nil

            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "LogCell", for: indexPath) as! LogCell

        let key = NSNumber(value: indexPath.row)
        let logModel: LogRecord
        if let cached = defaultEntryCache.object(forKey: key) {
            logModel = cached
        } else {
            let source = selectedSource.rawValue
            let models: [LogRecord]
            if let query = defaultSearchQuery {
                models = logModelDB.searchFetchRange(source: source, query: query, offset: indexPath.row, limit: 1)
            } else {
                models = logModelDB.fetchRange(source: source, offset: indexPath.row, limit: 1)
            }
            if let model = models.first {
                defaultEntryCache.setObject(model, forKey: key)
                logModel = model
            } else {
                return cell
            }
        }

        cell.index = indexPath.row
        cell.model = logModel

        cell.onShowFull = { [weak self] in
            guard let self = self else { return }
            if let json = LogCell.extractJSON(from: logModel) {
                self.pushJSONViewerOrFallback(with: json)
            }
        }

        cell.onCopy = { [weak logModel] in
            guard let logModel = logModel else { return }
            let text: String
            if let data = logModel.contentData, let str = String(data: data, encoding: .utf8) {
                text = str
            } else {
                text = logModel.content ?? ""
            }
            UIPasteboard.general.string = text
        }

        return cell
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension LogViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        if tableView == consoleTableView {
            // Console prefetching
            var missedIndices: [Int] = []
            for indexPath in indexPaths {
                let key = NSNumber(value: indexPath.row)
                if entryCache.object(forKey: key) == nil {
                    missedIndices.append(indexPath.row)
                }
            }

            guard !missedIndices.isEmpty else { return }

            let minIdx = missedIndices.min()!
            let maxIdx = missedIndices.max()!
            let offset = minIdx
            let limit = maxIdx - minIdx + 1

            let rows = consoleDB.fetchRange(offset: offset, limit: limit)

            for (i, row) in rows.enumerated() {
                let displayIndex = offset + i
                let key = NSNumber(value: displayIndex)
                guard entryCache.object(forKey: key) == nil else { continue }

                let color: UIColor = (row.colorCode == 1) ? .systemRed : .white
                let entry = ConsoleLineCache(rowid: row.rowid, text: row.text, color: color)
                entryCache.setObject(entry, forKey: key, cost: cacheCost(for: entry))
                enqueueHighlight(for: entry, displayIndex: displayIndex)
            }
        } else {
            // Default table prefetching (Third Party / Web)
            var missedIndices: [Int] = []
            for indexPath in indexPaths {
                let key = NSNumber(value: indexPath.row)
                if defaultEntryCache.object(forKey: key) == nil {
                    missedIndices.append(indexPath.row)
                }
            }

            guard !missedIndices.isEmpty else { return }

            let minIdx = missedIndices.min()!
            let maxIdx = missedIndices.max()!
            let offset = minIdx
            let limit = maxIdx - minIdx + 1
            let source = selectedSource.rawValue

            let models: [LogRecord]
            if let query = defaultSearchQuery {
                models = logModelDB.searchFetchRange(source: source, query: query, offset: offset, limit: limit)
            } else {
                models = logModelDB.fetchRange(source: source, offset: offset, limit: limit)
            }

            for (i, model) in models.enumerated() {
                let displayIndex = offset + i
                let key = NSNumber(value: displayIndex)
                guard defaultEntryCache.object(forKey: key) == nil else { continue }
                defaultEntryCache.setObject(model, forKey: key)
            }
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // NSCache handles eviction automatically; no action needed
    }
}

// MARK: - UITableViewDelegate

extension LogViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        defaultSearchBar.resignFirstResponder()

        // Console tab: copy to clipboard on tap
        if tableView == consoleTableView {
            // If multi-cell selection is active, dismiss it instead of copying
            if selectionRange != nil {
                dismissSelection()
                return
            }

            let key = NSNumber(value: indexPath.row)
            guard let entry = entryCache.object(forKey: key) else { return }
            UIPasteboard.general.string = entry.text.trimmingCharacters(in: .newlines)

            // Brief flash feedback
            if let cell = tableView.cellForRow(at: indexPath) {
                let original = cell.contentView.backgroundColor
                UIView.animate(withDuration: 0.15, animations: {
                    cell.contentView.backgroundColor = UIColor(white: 0.20, alpha: 1)
                }) { _ in
                    UIView.animate(withDuration: 0.3) {
                        cell.contentView.backgroundColor = original
                    }
                }
            }
            return
        }

        let key = NSNumber(value: indexPath.row)
        guard let logModel = defaultEntryCache.object(forKey: key) else { return }
        logModel.isViewed = true

        let logTitleString: String
        switch logModel.logSource {
        case .app:        logTitleString = "App Log"
        case .thirdParty: logTitleString = "Third Party Log"
        case .web:        logTitleString = "Web Log"
        @unknown default: logTitleString = "Log"
        }

        if let json = LogCell.extractJSON(from: logModel) {
            logModel.isSelected = true
            defaultTableView.reloadRows(at: [indexPath], with: .none)
            pushJSONViewerOrFallback(with: json)
            return
        }

        let vc = JsonViewController()
        vc.editType = .log
        vc.logTitleString = logTitleString
        vc.logModel = logModel
        navigationController?.pushViewController(vc, animated: true)

        vc.justCancelCallback = { tableView.reloadData() }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Only for default table (Third Party / Web), not console
        guard tableView == defaultTableView else { return nil }

        let key = NSNumber(value: indexPath.row)
        guard let logModel = defaultEntryCache.object(forKey: key) else { return nil }

        let title = logModel.isPinned ? "Unpin" : "Pin"
        let iconName = logModel.isPinned ? "pin.slash.fill" : "pin.fill"

        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            logModel.isPinned.toggle()
            self?.logModelDB.togglePin(rowid: logModel.dbRowid, pinned: logModel.isPinned)
            tableView.reloadRows(at: [indexPath], with: .none)
            completion(true)
        }
        action.backgroundColor = UIColor(red: 0.16, green: 0.50, blue: 0.47, alpha: 1)
        action.image = UIImage(systemName: iconName)
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - UIScrollViewDelegate

extension LogViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        defaultSearchBar.resignFirstResponder()

        if scrollView == consoleTableView {
            // User interrupted animated scroll — unlock jump navigation
            isJumpingToMatch = false

            // Hide copy button during scroll (selection highlights persist)
            dismissCopyButton()

            // User manually dragging — disable auto-follow
            if isAutoFollowing {
                isAutoFollowing = false
                setFollowButtonVisible(true, animated: true)
            }
        } else if scrollView == defaultTableView {
            if isDefaultAutoFollowing {
                isDefaultAutoFollowing = false
                setDefaultFollowButtonVisible(true, animated: true)
            }
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView == consoleTableView {
            isJumpingToMatch = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView == consoleTableView {
            if !isAutoFollowing { checkIfScrolledToBottom() }
            if selectionRange != nil { showCopyButton() }
        } else if scrollView == defaultTableView {
            if !isDefaultAutoFollowing { checkIfDefaultScrolledToBottom() }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView == consoleTableView {
            if !isAutoFollowing && !decelerate { checkIfScrolledToBottom() }
            if !decelerate && selectionRange != nil { showCopyButton() }
        } else if scrollView == defaultTableView {
            if !isDefaultAutoFollowing && !decelerate { checkIfDefaultScrolledToBottom() }
        }
    }

    /// Re-enable auto-follow if user scrolled back to the bottom
    private func checkIfScrolledToBottom() {
        let offset = consoleTableView.contentOffset.y
        let visibleHeight = consoleTableView.bounds.height
        let contentHeight = consoleTableView.contentSize.height
        let bottomInset = consoleTableView.contentInset.bottom

        // Consider "at bottom" if within 60pt of the end
        if offset + visibleHeight + bottomInset >= contentHeight - 60 {
            isAutoFollowing = true
            setFollowButtonVisible(false, animated: true)
        }
    }
}

// MARK: - UISearchBarDelegate

extension LogViewController: UISearchBarDelegate {

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        if isConsoleTab { matchDownTapped() }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        currentSearchWord = searchText

        if isConsoleTab {
            performConsoleSearch(searchText)
        } else {
            defaultEntryCache.removeAllObjects()
            let source = selectedSource.rawValue
            if searchText.isEmpty {
                defaultSearchQuery = nil
                defaultTotalCount = logModelDB.cachedCount[source] ?? logModelDB.readCount(source: source)
                isDefaultAutoFollowing = true
                setDefaultFollowButtonVisible(false, animated: true)
            } else {
                let query = searchText.lowercased()
                defaultSearchQuery = query
                defaultTotalCount = logModelDB.searchCount(source: source, query: query)
                isDefaultAutoFollowing = false
                setDefaultFollowButtonVisible(true, animated: true)
            }
            defaultTableView.reloadData()
        }
    }
}
