//
//  HostPickerSheetViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Sheet-presented multi-select host picker styled like the network filter sheet.
/// Groups hosts by their tag — selecting a tag selects all hosts under it.
class HostPickerSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Raw list of available hosts.
    var hosts: [String] = []
    /// Currently selected hosts.
    var selectedHosts: Set<String> = []
    var onApply: (([String]) -> Void)?

    /// An entry in the picker — may represent a single host or a group with a tag.
    private struct Entry {
        let display: String
        let subtitle: String?
        let hosts: [String]
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

    // MARK: - Build grouped entries

    private func buildEntries() {
        let tags = SwiftyDebug._tags
        var grouped: [(tag: String, hosts: [String])] = []
        var tagOrder: [String] = []
        var tagMap: [String: [String]] = [:]
        var assignedHosts = Set<String>()

        // Group hosts by matching tag keyword
        for host in hosts {
            var matched = false
            for (keyword, label) in tags {
                if host.contains(keyword.lowercased()) {
                    let key = label.lowercased()
                    if tagMap[key] == nil {
                        tagOrder.append(label)
                        tagMap[key] = []
                    }
                    tagMap[key]!.append(host)
                    assignedHosts.insert(host)
                    matched = true
                    break
                }
            }
            if !matched {
                // No tag — standalone entry
            }
        }

        // Tagged groups first
        for label in tagOrder {
            let groupHosts = tagMap[label.lowercased()] ?? []
            if !groupHosts.isEmpty {
                grouped.append((tag: label, hosts: groupHosts))
            }
        }

        // Then ungrouped hosts
        for host in hosts where !assignedHosts.contains(host) {
            grouped.append((tag: host, hosts: [host]))
        }

        entries = grouped.map { group in
            if group.hosts.count == 1 && group.tag == group.hosts[0] {
                // Single ungrouped host
                return Entry(display: group.tag, subtitle: nil, hosts: group.hosts)
            } else {
                // Tagged group
                return Entry(
                    display: group.tag,
                    subtitle: group.hosts.joined(separator: ", "),
                    hosts: group.hosts
                )
            }
        }
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
        // Return selected hosts preserving original order
        let result = hosts.filter { selectedHosts.contains($0) }
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
            // Deselect all hosts in this group
            for host in entry.hosts { selectedHosts.remove(host) }
        } else {
            // Select all hosts in this group
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
