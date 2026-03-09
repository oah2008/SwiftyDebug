//
//  NetworkFilterSheetController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit


/// UITableViewCell subclass that uses the .subtitle style for 2-line display.
private final class FilterSubtitleCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError() }
}

//MARK: - Filter Sheet Controller

class NetworkFilterSheetController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    enum Page { case hosts, endpoints }

    // Data
    var initialPage: Page = .hosts
    var page: Page = .hosts
    var entries: [(display: String, filterKeys: [(key: String, isPathFilter: Bool)], isWeb: Bool)] = []
    var tempPathFilters = Set<String>()
    var tempHostFilters = Set<String>()
    var tempEndpoints = Set<String>()
    var endpointProvider: (() -> [FilterableEndpoint])?

    // Callbacks
    var onApply: ((Set<String>, Set<String>, Set<String>) -> Void)?

    // UI
    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let applyButton = UIButton(type: .system)
    private let leftButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    private var endpoints: [FilterableEndpoint] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)

        page = initialPage
        setupTopBar()
        setupTableView()
        refreshEndpoints()
        view.forceLTR()
    }

    private func setupTopBar() {
        topBar.backgroundColor = UIColor(white: 0.15, alpha: 1)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // Left button (Clear on hosts page, Back on endpoints page)
        leftButton.translatesAutoresizingMaskIntoConstraints = false
        leftButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        leftButton.addTarget(self, action: #selector(didTapLeft), for: .touchUpInside)
        topBar.addSubview(leftButton)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        topBar.addSubview(titleLabel)

        // Apply button
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.setTitle("Apply", for: .normal)
        applyButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        applyButton.setTitleColor(.black, for: .normal)
        applyButton.backgroundColor = DebugTheme.accentColor
        applyButton.layer.cornerRadius = 14
        var applyConfig = UIButton.Configuration.plain()
        applyConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        applyButton.configuration = applyConfig
        applyButton.addTarget(self, action: #selector(didTapApply), for: .touchUpInside)
        topBar.addSubview(applyButton)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            leftButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            leftButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            applyButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            applyButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        updateTopBar()
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        tableView.separatorColor = UIColor(white: 0.25, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FilterSubtitleCell.self, forCellReuseIdentifier: "FilterCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updateTopBar() {
        switch page {
        case .hosts:
            titleLabel.text = "Filter by Host"
            leftButton.setTitle("Clear", for: .normal)
            leftButton.setTitleColor(.systemRed, for: .normal)
        case .endpoints:
            titleLabel.text = "Filter by Endpoint"
            if initialPage == .endpoints {
                // Opened directly on endpoints (e.g. from grouped list) — no hosts page to go back to
                leftButton.setTitle("Clear", for: .normal)
                leftButton.setTitleColor(.systemRed, for: .normal)
            } else {
                leftButton.setTitle("\u{25C0} Back", for: .normal)
                leftButton.setTitleColor(DebugTheme.accentColor, for: .normal)
            }
        }
    }

    private func refreshEndpoints() {
        endpoints = endpointProvider?() ?? []
    }

    // MARK: Actions

    @objc private func didTapLeft() {
        switch page {
        case .hosts:
            // Clear all
            tempPathFilters.removeAll()
            tempHostFilters.removeAll()
            tempEndpoints.removeAll()
            onApply?(tempPathFilters, tempHostFilters, tempEndpoints)
            dismiss(animated: true)
        case .endpoints:
            if initialPage == .endpoints {
                // Clear endpoints (no hosts page to go back to)
                tempEndpoints.removeAll()
                onApply?(tempPathFilters, tempHostFilters, tempEndpoints)
                dismiss(animated: true)
            } else {
                // Back to hosts
                page = .hosts
                updateTopBar()
                tableView.reloadData()
            }
        }
    }

    @objc private func didTapApply() {
        onApply?(tempPathFilters, tempHostFilters, tempEndpoints)
        dismiss(animated: true)
    }

    // MARK: Table View

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch page {
        case .hosts:
            let hasSelectedHosts = !tempPathFilters.isEmpty || !tempHostFilters.isEmpty
            return entries.count + (hasSelectedHosts ? 1 : 0) // +1 for "Filter Endpoints..."
        case .endpoints:
            return endpoints.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FilterCell", for: indexPath)
        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 15)
        cell.selectionStyle = .none
        cell.tintColor = DebugTheme.accentColor

        switch page {
        case .hosts:
            cell.detailTextLabel?.text = nil
            cell.detailTextLabel?.numberOfLines = 2
            if indexPath.row < entries.count {
                let entry = entries[indexPath.row]
                let isSelected = entry.filterKeys.contains { pair in
                    pair.isPathFilter ? tempPathFilters.contains(pair.key) : tempHostFilters.contains(pair.key)
                }
                cell.textLabel?.text = entry.display
                cell.textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
                // Show underlying URL/host as subtitle
                if let firstKey = entry.filterKeys.first {
                    let webSuffix = entry.isWeb ? " \u{00B7} web" : ""
                    cell.detailTextLabel?.text = firstKey.key + webSuffix
                    cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
                    cell.detailTextLabel?.font = .systemFont(ofSize: 12)
                }
                cell.accessoryType = isSelected ? .checkmark : .none
            } else {
                // "Filter Endpoints..." row
                cell.textLabel?.text = "Filter Endpoints..."
                cell.textLabel?.textColor = DebugTheme.accentColor
                cell.accessoryType = .disclosureIndicator
            }

        case .endpoints:
            let entry = endpoints[indexPath.row]
            let isSelected = tempEndpoints.contains(entry.filterPath)
            cell.textLabel?.text = entry.displayPath
            if !entry.tag.isEmpty {
                cell.detailTextLabel?.text = entry.tag
                cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
                cell.detailTextLabel?.font = .systemFont(ofSize: 12)
            }
            cell.accessoryType = isSelected ? .checkmark : .none
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch page {
        case .hosts:
            if indexPath.row < entries.count {
                let entry = entries[indexPath.row]
                let isSelected = entry.filterKeys.contains { pair in
                    pair.isPathFilter ? tempPathFilters.contains(pair.key) : tempHostFilters.contains(pair.key)
                }
                for pair in entry.filterKeys {
                    if pair.isPathFilter {
                        if isSelected { tempPathFilters.remove(pair.key) } else { tempPathFilters.insert(pair.key) }
                    } else {
                        if isSelected { tempHostFilters.remove(pair.key) } else { tempHostFilters.insert(pair.key) }
                    }
                }
                tempEndpoints.removeAll()
                refreshEndpoints()
                tableView.reloadData()
            } else {
                // Switch to endpoints page
                refreshEndpoints()
                if endpoints.isEmpty { return }
                page = .endpoints
                updateTopBar()
                tableView.reloadData()
            }

        case .endpoints:
            let entry = endpoints[indexPath.row]
            if tempEndpoints.contains(entry.filterPath) {
                tempEndpoints.remove(entry.filterPath)
            } else {
                tempEndpoints.insert(entry.filterPath)
            }
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}
