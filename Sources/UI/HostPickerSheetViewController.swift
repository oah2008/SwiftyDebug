//
//  HostPickerSheetViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Sheet-presented multi-select host/URL picker styled exactly like the network filter sheet.
/// Builds entries from `SwiftyDebug.urls` that have active traffic, plus already-selected entries.
/// Shows tag + full URL (scheme stripped), merges same-tag entries into one row.
/// Selection stores stripped URLs — rules match by URL prefix.
class HostPickerSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Currently selected stripped URLs (lowercased).
    var selectedHosts: Set<String> = []
    var onApply: (([String]) -> Void)?

    /// An entry in the picker — mirrors the filter sheet's structure.
    private struct Entry {
        let display: String           // Tag label (or stripped URL if no tag)
        let subtitle: String?         // Stripped URL(s) shown as detail text
        let filterKeys: [String]      // Stripped URLs this entry covers
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
        let models = NetworkRequestStore.shared.httpModels as? [NetworkTransaction] ?? []

        // Collect all stripped URLs already selected in existing host rules
        var ruleSelectedKeys = Set<String>()
        for rule in InterceptRuleStore.shared.allRules() where rule.matchMode == .host {
            for key in rule.matchHosts {
                ruleSelectedKeys.insert(key.lowercased())
            }
        }
        // Also include current selection
        for key in selectedHosts {
            ruleSelectedKeys.insert(key.lowercased())
        }

        struct RawEntry {
            let display: String
            let filterKey: String // stripped URL
            /// What rows merge on. Not always the display label — see
            /// `rowIdentity(forURLString:fallback:)`.
            let mergeKey: String
        }

        var rawEntries: [RawEntry] = []
        var addedKeys = Set<String>()

        // Build entries from SwiftyDebug.urls — only those with active traffic
        for urlString in onlyURLs {
            var stripped = stripScheme(urlString)
            if stripped.hasSuffix("/") { stripped = String(stripped.dropLast()) }
            let key = stripped.lowercased()

            // Check if any captured model matches this URL prefix
            var hasMatch = false
            for model in models {
                let modelStripped = stripScheme(model.url?.absoluteString ?? "").lowercased()
                // Remove query string for comparison
                let cleanModel = modelStripped.components(separatedBy: "?").first ?? modelStripped
                if cleanModel == key || cleanModel.hasPrefix(key + "/") {
                    hasMatch = true
                    break
                }
            }

            if hasMatch {
                if addedKeys.insert(key).inserted {
                    let identity = rowIdentity(forURLString: urlString, fallback: stripped)
                    rawEntries.append(RawEntry(display: identity.display,
                                               filterKey: stripped,
                                               mergeKey: identity.mergeKey))
                }
            }
        }

        // Also include uncovered hosts from captured traffic
        var coveredHosts = Set<String>()
        for entry in rawEntries {
            let host = entry.filterKey.components(separatedBy: "/").first ?? entry.filterKey
            coveredHosts.insert(host.lowercased())
        }

        var seenTrafficHosts = Set<String>()
        for model in models {
            guard let host = model.url?.host?.lowercased(), !host.isEmpty else { continue }
            if coveredHosts.contains(host) || seenTrafficHosts.contains(host) { continue }
            seenTrafficHosts.insert(host)

            let identity = rowIdentity(forURLString: "https://" + host, fallback: host)
            if addedKeys.insert(host).inserted {
                rawEntries.append(RawEntry(display: identity.display,
                                           filterKey: host,
                                           mergeKey: identity.mergeKey))
            }
        }

        // Add rule-selected/current-selected keys ONLY if exact key not already in the list
        for key in ruleSelectedKeys {
            if !addedKeys.contains(key) {
                if addedKeys.insert(key).inserted {
                    let host = key.components(separatedBy: "/").first ?? key
                    let identity = rowIdentity(forURLString: "https://" + host, fallback: key)
                    rawEntries.append(RawEntry(display: identity.display,
                                               filterKey: key,
                                               mergeKey: identity.mergeKey))
                }
            }
        }

        // Sort alphabetically by display
        let sorted = rawEntries.sorted { $0.display.lowercased() < $1.display.lowercased() }

        // Merge on the row's merge key — the developer's own tag label, or the
        // host itself for everything else. (See `rowIdentity`.)
        var displayOrder: [(display: String, mergeKey: String)] = []
        var mergedMap: [String: [String]] = [:]

        for entry in sorted {
            let key = entry.mergeKey
            if mergedMap[key] == nil {
                displayOrder.append((entry.display, key))
                mergedMap[key] = []
            }
            mergedMap[key]!.append(entry.filterKey)
        }

        entries = displayOrder.map { (display, mergeKey) in
            let filterKeys = mergedMap[mergeKey]!
            // Show first URL as subtitle (like filter sheet)
            let subtitle: String?
            if let first = filterKeys.first, first.lowercased() != display.lowercased() {
                subtitle = filterKeys.count > 1 ? filterKeys.joined(separator: ", ") : first
            } else if filterKeys.count > 1 {
                subtitle = filterKeys.joined(separator: ", ")
            } else {
                subtitle = nil
            }
            return Entry(display: display, subtitle: subtitle, filterKeys: filterKeys)
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

    /// Labels come from the one resolver, so a host reads the same here as it
    /// does on a request row and in the network filter sheet. This screen used to
    /// carry its own first-match-over-a-dictionary copy, which returned a
    /// different answer from the rest of the SDK — and a different one between
    /// launches. Only the LABELS are shared: the `filterKeys` this sheet produces
    /// are persisted into `InterceptRule.matchHosts` and must keep their existing
    /// shape. (See TAGS-FILTER.)
    private func tagLabel(forURLString urlString: String) -> String? {
        guard let tag = TagResolver.tag(forURLString: urlString),
              tag.origin != .derivedHost else { return nil }
        return tag.label
    }

    private func tagLabel(forHost host: String) -> String? {
        tagLabel(forURLString: "https://" + host)
    }

    /// A row's display label, and the key rows are merged on.
    ///
    /// These are the same string ONLY for a tag the developer configured with
    /// `addTag(keyword:label:)` — that call is exactly the statement "these
    /// hosts are one thing to me", so merging them into one row is what it asks
    /// for. A label that came from the built-in catalog, or from an allow-list
    /// entry, was never such a statement: merging on it collapsed unrelated
    /// hosts (every Firebase service, say) into a single row, and because
    /// `didSelectRowAt` writes ALL of a row's `filterKeys` into
    /// `InterceptRule.matchHosts`, one tap armed a rule against hosts the
    /// developer never picked and could not see.
    ///
    /// So catalog- and allow-list-labelled rows keep the shared label for
    /// display — the labels still read the same here as on a request row — and
    /// merge on their own host. (See TAGS-FILTER.)
    private func rowIdentity(forURLString urlString: String,
                             fallback: String) -> (display: String, mergeKey: String) {
        guard let tag = TagResolver.tag(forURLString: urlString),
              tag.origin != .derivedHost else {
            return (fallback, fallback.lowercased())
        }
        return (tag.label,
                tag.origin == .userTag ? "tag:" + tag.label.lowercased() : fallback.lowercased())
    }

    // MARK: - UI Setup

    private func setupTopBar() {
        topBar.backgroundColor = UIColor(white: 0.15, alpha: 1)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("Clear", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        clearButton.setTitleColor(.systemRed, for: .normal)
        clearButton.addTarget(self, action: #selector(didTapClear), for: .touchUpInside)
        topBar.addSubview(clearButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.text = "Select Hosts"
        topBar.addSubview(titleLabel)

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
        let isSelected = entry.filterKeys.contains { selectedHosts.contains($0.lowercased()) }

        cell.configure(display: entry.display, subtitle: entry.subtitle, selected: isSelected)
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        let allSelected = entry.filterKeys.allSatisfy { selectedHosts.contains($0.lowercased()) }

        if allSelected {
            for key in entry.filterKeys { selectedHosts.remove(key.lowercased()) }
        } else {
            for key in entry.filterKeys { selectedHosts.insert(key.lowercased()) }
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
