//
//  NetworkGroupDetailVC.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

/// Drill-down list showing network requests for a single group (urls prefix or host).
class NetworkGroupDetailVC: UIViewController {

    // Input
    var models: [NetworkTransaction] = []
    var groupKey: String = ""
    var isPathFilter: Bool = false

    // State
    private var filteredModels: [NetworkTransaction] = []
    private var searchText: String = ""
    private var selectedEndpoints = Set<String>()
    private var isAutoFollowing: Bool = true

    // UI
    private var tableView: UITableView!
    private var searchBar: UISearchBar!
    private var searchRow: UIView!
    private var filterButton: UIButton!
    private var followButton: UIButton!
    private static let followButtonSize: CGFloat = 40

    /// Floating glass header (iOS 26+)
    private var floatingHeader: UIView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupUI()
        setupSearchBarStyle()
        setupNavBar()

        tableView.tableFooterView = UIView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.register(NetworkCell.self, forCellReuseIdentifier: "NetworkCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        if floatingHeader == nil {
            tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        } else {
            tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Self.followButtonSize + 12, right: 0)
        }
        tableView.showsVerticalScrollIndicator = false

        applyFilter()

        // Defer scroll to after layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isAutoFollowing else { return }
            let count = self.tableView.numberOfRows(inSection: 0)
            guard count > 0 else { return }
            let last = IndexPath(row: count - 1, section: 0)
            self.tableView.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Scroll to bottom after layout is fully applied (insets ready)
        if isAutoFollowing {
            let count = tableView.numberOfRows(inSection: 0)
            guard count > 0 else { return }
            let last = IndexPath(row: count - 1, section: 0)
            tableView.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        // --- Create shared elements ---
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

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: searchRow.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor),

            filterButton.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -8),
            filterButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 34),
            filterButton.heightAnchor.constraint(equalToConstant: 34),
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

        // Add search row inside glass contentView
        let content = glass.contentView
        searchRow.backgroundColor = .clear
        content.addSubview(searchRow)

        // Follow button on top
        view.addSubview(followButton)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            // Table view: full screen (scrolls under glass header)
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Glass header: floats at top
            glass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            // Search row inside glass
            searchRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            searchRow.heightAnchor.constraint(equalToConstant: 44),
            searchRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),

            // Follow button
            followButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            followButton.widthAnchor.constraint(equalToConstant: btnSize),
            followButton.heightAnchor.constraint(equalToConstant: btnSize),
        ])
    }

    // MARK: - Legacy Layout (< iOS 26)

    private func setupLegacyLayout() {
        searchRow.backgroundColor = .black
        view.addSubview(searchRow)
        view.addSubview(tableView)
        view.addSubview(followButton)

        let btnSize = Self.followButtonSize
        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            searchRow.heightAnchor.constraint(equalToConstant: 44),

            tableView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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

    private func setupSearchBarStyle() {
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
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.barTintColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        toolbar.isTranslucent = false
        toolbar.clipsToBounds = true
        let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: chevron, style: .plain, target: self, action: #selector(dismissKeyboard))
        ]
        toolbar.items?.last?.tintColor = UIColor(white: 0.6, alpha: 1)
        tf.inputAccessoryView = toolbar

        searchBar.delegate = self
    }

    @objc private func dismissKeyboard() {
        searchBar.resignFirstResponder()
    }

    private func setupNavBar() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapView))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let deleteItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(didTapDelete))
        deleteItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = deleteItem
    }

    @objc private func didTapDelete() {
        NetworkRequestStore.shared.reset()
        let pinnedCount = NetworkRequestStore.shared.httpModels.count
        NotificationCenter.default.post(name: .networkRequestCompleted, object: nil)
        NotificationCenter.default.post(name: .allLogsCleared, object: nil, userInfo: ["pinnedCount": pinnedCount])
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Filter

    private func applyFilter() {
        var result = models

        // Endpoint filter
        if !selectedEndpoints.isEmpty {
            result = result.filter { model in
                let normalized = NetworkViewController.normalizeEndpoint(model.url?.path ?? "")
                return selectedEndpoints.contains(normalized)
            }
        }

        // Search text filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                ($0.url?.absoluteString ?? "").lowercased().contains(query)
            }
        }

        filteredModels = result
    }

    private func updateFilterButtonIcon() {
        let iconName = selectedEndpoints.isEmpty
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        filterButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
    }

    // MARK: - Endpoint filter sheet

    @objc private func didTapFilter() {
        let endpoints = buildEndpoints()
        if endpoints.isEmpty { return }

        let sheet = NetworkFilterSheetController()
        sheet.initialPage = .endpoints
        sheet.entries = []
        sheet.tempEndpoints = selectedEndpoints

        // Pre-supply endpoints directly
        sheet.endpointProvider = { endpoints }

        sheet.onApply = { [weak self] _, _, endpoints in
            guard let self = self else { return }
            self.selectedEndpoints = endpoints
            self.updateFilterButtonIcon()
            self.applyFilter()
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

    private func buildEndpoints() -> [FilterableEndpoint] {
        var seen = Set<String>()
        var entries: [FilterableEndpoint] = []

        // Compute prefix to strip for relative display paths
        var pathPrefix: String? = nil
        if isPathFilter {
            let parts = groupKey.components(separatedBy: "/")
            if parts.count > 1 {
                pathPrefix = "/" + parts.dropFirst().joined(separator: "/")
            }
        }

        let tag = self.title ?? groupKey

        for model in models {
            let fullPath = model.url?.path ?? ""
            guard !fullPath.isEmpty else { continue }
            let filterPath = NetworkViewController.normalizeEndpoint(fullPath)
            guard !filterPath.isEmpty, seen.insert(filterPath).inserted else { continue }

            // Compute relative display path (strip group prefix)
            var displayPath = fullPath
            if let prefix = pathPrefix,
               fullPath.lowercased().hasPrefix(prefix.lowercased()) {
                let relative = String(fullPath.dropFirst(prefix.count))
                displayPath = relative.isEmpty ? "/" : relative
            }
            let normalizedDisplay = NetworkViewController.normalizeEndpoint(displayPath)
            if normalizedDisplay.isEmpty || normalizedDisplay == "/" { continue }

            entries.append(FilterableEndpoint(
                displayPath: normalizedDisplay,
                filterPath: filterPath,
                tag: tag
            ))
        }

        return entries.sorted { $0.displayPath < $1.displayPath }
    }

    @objc private func didTapView() {
        view.endEditing(true)
    }

    // MARK: - Follow button

    @objc private func followButtonTapped() {
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        if !filteredModels.isEmpty {
            let last = IndexPath(row: filteredModels.count - 1, section: 0)
            tableView.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    private func setFollowButtonVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard followButton.alpha != target else { return }
        if animated {
            UIView.animate(withDuration: 0.25) { self.followButton.alpha = target }
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

// MARK: - UISearchBarDelegate

extension NetworkGroupDetailVC: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
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
        searchText = ""
        searchBar.resignFirstResponder()
        isAutoFollowing = true
        setFollowButtonVisible(false, animated: true)
        applyFilter()
        tableView.reloadData()
    }
}

// MARK: - UITableViewDataSource

extension NetworkGroupDetailVC: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredModels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkCell", for: indexPath) as! NetworkCell
        guard indexPath.row < filteredModels.count else { return cell }
        cell.index = indexPath.row
        cell.httpModel = filteredModels[indexPath.row]
        return cell
    }
}

// MARK: - UITableViewDelegate

extension NetworkGroupDetailVC: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < filteredModels.count else { return }

        filteredModels[indexPath.row].isViewed = true
        tableView.reloadRows(at: [indexPath], with: .none)

        let vc = NetworkDetailViewController()
        vc.httpModels = filteredModels
        vc.httpModel = filteredModels[indexPath.row]
        navigationController?.pushViewController(vc, animated: true)

        vc.justCancelCallback = { [weak self] in
            self?.tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < filteredModels.count else { return nil }

        let model = filteredModels[indexPath.row]
        let title = model.isPinned ? "Unpin" : "Pin"
        let iconName = model.isPinned ? "pin.slash.fill" : "pin.fill"

        let action = UIContextualAction(style: .normal, title: title) { _, _, completion in
            model.isPinned.toggle()
            if model.isPinned {
                model.savePinToDisk()
            } else {
                model.removePinFromDisk()
            }
            tableView.reloadRows(at: [indexPath], with: .none)
            completion(true)
        }
        action.backgroundColor = UIColor(red: 0.16, green: 0.50, blue: 0.47, alpha: 1)
        action.image = UIImage(systemName: iconName)
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - UIScrollViewDelegate

extension NetworkGroupDetailVC: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
