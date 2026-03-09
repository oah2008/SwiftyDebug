//
//  HostPickerSheetViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Sheet-presented multi-select host picker styled exactly like the network filter sheet.
/// Builds entries from `SwiftyDebug.urls`, strips scheme, groups by tag, shows full URL as subtitle.
/// Selecting a tagged group selects all hosts under it.
class HostPickerSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Currently selected hosts (lowercased).
    var selectedHosts: Set<String> = []
    var onApply: (([String]) -> Void)?

    /// An entry in the picker — mirrors the filter sheet's structure.
    private struct Entry {
        let display: String       // Tag label (or stripped URL if no tag)
        let subtitle: String?     // First stripped URL (shown as detail text)
        let hosts: [String]       // All unique hosts covered by this entry
    }

    private var entries: [Entry] = []

    // UI
    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let applyButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)

        buildEntries()
        setupTopBar()
        setupTableView()
        view.forceLTR()
    }

    // MARK: - Build entries (same pattern as filter sheet)

    private func buildEntries() {
        let onlyURLs = SwiftyDebug.urls

        // Raw entries: (display = tag or stripped URL, strippedURL, host)
        struct RawEntry {
            let display: String
            let strippedURL: String
            let host: String
        }

        var rawEntries: [RawEntry] = []
        var coveredHosts = Set<String>()

        for urlString in onlyURLs {
            var stripped = stripScheme(urlString)
            if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }

            let host = stripped.components(separatedBy: "/").first ?? stripped
            let lowerHost = host.lowercased()

            let display = tagLabel(forURLString: urlString) ?? stripped
            rawEntries.append(RawEntry(display: display, strippedURL: stripped, host: lowerHost))
            coveredHosts.insert(lowerHost)
        }

        // Also include hosts from captured network traffic that aren't covered by SDK URLs
        let models = NetworkRequestStore.shared.httpModels as? [NetworkTransaction] ?? []
        var seenTrafficHosts = Set<String>()
        for model in models {
            guard let host = model.url?.host?.lowercased(), !host.isEmpty else { continue }
            if coveredHosts.contains(host) || seenTrafficHosts.contains(host) { continue }
            seenTrafficHosts.insert(host)

            let display = tagLabel(forHost: host) ?? host
            rawEntries.append(RawEntry(display: display, strippedURL: host, host: host))
        }

        // Sort alphabetically by display
        let sorted = rawEntries.sorted { $0.display.lowercased() < $1.display.lowercased() }

        // Merge by display label (same tag → one row, like filter sheet)
        var displayOrder: [String] = []
        var mergedMap: [String: (strippedURLs: [String], hosts: Set<String>)] = [:]

        for entry in sorted {
            let key = entry.display.lowercased()
            if mergedMap[key] == nil {
                displayOrder.append(entry.display)
                mergedMap[key] = (strippedURLs: [], hosts: [])
            }
            mergedMap[key]!.strippedURLs.append(entry.strippedURL)
            mergedMap[key]!.hosts.insert(entry.host)
        }

        entries = displayOrder.map { display in
            let info = mergedMap[display.lowercased()]!
            let subtitle = info.strippedURLs.first
            // If display == subtitle, no need to show subtitle
            let showSubtitle = (subtitle != nil && subtitle!.lowercased() != display.lowercased()) ? subtitle : nil
            return Entry(
                display: display,
                subtitle: showSubtitle ?? (info.strippedURLs.count > 1 ? info.strippedURLs.joined(separator: ", ") : nil),
                hosts: Array(info.hosts).sorted()
            )
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

    private func tagLabel(forURLString urlString: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        let lower = urlString.lowercased()
        if let label = map[urlString] { return label }
        for (keyword, label) in map where lower.contains(keyword.lowercased()) {
            return label
        }
        return nil
    }

    private func tagLabel(forHost host: String) -> String? {
        let map = SwiftyDebug._tags
        guard !map.isEmpty else { return nil }
        for (keyword, label) in map where host.contains(keyword.lowercased()) {
            return label
        }
        return nil
    }

    // MARK: - UI Setup

    private func setupTopBar() {
        topBar.backgroundColor = UIColor(white: 0.15, alpha: 1)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // Clear button
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("Clear", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        clearButton.setTitleColor(.systemRed, for: .normal)
        clearButton.addTarget(self, action: #selector(didTapClear), for: .touchUpInside)
        topBar.addSubview(clearButton)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.text = "Select Hosts"
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

            clearButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            clearButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            applyButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            applyButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        tableView.separatorColor = UIColor(white: 0.25, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(HostPickerCell.self, forCellReuseIdentifier: "HostCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func didTapClear() {
        selectedHosts.removeAll()
        tableView.reloadData()
    }

    @objc private func didTapApply() {
        let result = Array(selectedHosts).sorted()
        onApply?(result)
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HostCell", for: indexPath) as! HostPickerCell
        let entry = entries[indexPath.row]
        let isSelected = entry.hosts.allSatisfy { selectedHosts.contains($0) }

        cell.configure(display: entry.display, subtitle: entry.subtitle, selected: isSelected)
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        let allSelected = entry.hosts.allSatisfy { selectedHosts.contains($0) }

        if allSelected {
            for host in entry.hosts { selectedHosts.remove(host) }
        } else {
            for host in entry.hosts { selectedHosts.insert(host) }
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}

// MARK: - Cell

private class HostPickerCell: UITableViewCell {

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        selectionStyle = .none
        tintColor = DebugTheme.accentColor
        textLabel?.textColor = .white
        textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
        detailTextLabel?.font = .systemFont(ofSize: 12)
        detailTextLabel?.numberOfLines = 2
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(display: String, subtitle: String?, selected: Bool) {
        textLabel?.text = display
        detailTextLabel?.text = subtitle
        accessoryType = selected ? .checkmark : .none
    }
}
