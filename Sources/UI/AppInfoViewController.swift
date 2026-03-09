//
//  AppInfoViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class AppInfoViewController: UITableViewController {

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case settings = 0
        case actions = 1
        case urls = 2
    }

    // MARK: - Toggle definitions

    private struct ToggleItem {
        let title: String
        let subtitle: String
        let keyPath: ReferenceWritableKeyPath<Settings, Bool>
    }

    private let toggles: [ToggleItem] = [
        ToggleItem(title: "Network Requests",
                   subtitle: "Capture native app network requests",
                   keyPath: \.networkRequestsEnabled),
        ToggleItem(title: "Web Network Requests",
                   subtitle: "Capture WKWebView network requests",
                   keyPath: \.webNetworkRequestsEnabled),
        ToggleItem(title: "Console Logs",
                   subtitle: "Capture console & print logs",
                   keyPath: \.consoleLogsEnabled),
        ToggleItem(title: "Web Logs",
                   subtitle: "Capture WKWebView console logs",
                   keyPath: \.webLogsEnabled),
        ToggleItem(title: "Monitor All Requests",
                   subtitle: "Intercept all network traffic, not just monitored URLs",
                   keyPath: \.monitorAllRequests),
        ToggleItem(title: "Monitor Media",
                   subtitle: "Intercept images, video, audio & font requests",
                   keyPath: \.monitorMediaEnabled),
    ]

    // MARK: - Data

    /// Unique captured URLs with tag info
    private var capturedURLs: [URLItem] = []

    struct URLItem {
        let url: String
        let hostTag: (label: String, color: UIColor)?
        let versionTag: String?   // e.g. "v1", "v2"
        let isBeta: Bool
    }

    // MARK: - Init

    override func viewDidLoad() {
        super.viewDidLoad()

        // Title
        let titleLabel = UILabel(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        titleLabel.textAlignment = .center
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.text = "App"
        navigationItem.titleView = titleLabel

        // Replace the inherited table view with a fresh dynamic one
        let dynamicTable = UITableView(frame: .zero, style: .grouped)
        dynamicTable.dataSource = self
        dynamicTable.delegate = self
        self.tableView = dynamicTable

        // Register cells
        tableView.register(AppURLCell.self, forCellReuseIdentifier: "AppURLCell")

        // Table styling
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        tableView.showsVerticalScrollIndicator = false

        // Notification for network updates
        NotificationCenter.default.addObserver(
            forName: .networkRequestCompleted,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadURLs()
        }
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadURLs()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Build Data

    private func reloadURLs() {
        let urls = SwiftyDebug.urls

        capturedURLs = urls.map { urlString in
            let url = URL(string: urlString)
            let host = url?.host?.lowercased() ?? ""
            let path = url?.path.lowercased() ?? ""
            let hostTag = Self.detectHostTag(urlString: urlString, host: host, path: path, isWebView: false)
            let versionTag = Self.detectVersion(path: path)
            let isBeta = host.contains(".beta.") || host.hasPrefix("beta.")
            return URLItem(url: urlString, hostTag: hostTag, versionTag: versionTag, isBeta: isBeta)
        }
        tableView.reloadData()
    }

    // MARK: - Tag Detection

    private static func detectHostTag(urlString: String, host: String, path: String, isWebView: Bool) -> (label: String, color: UIColor)? {
        // Custom tags — check full URL first, then host
        if !SwiftyDebug._tags.isEmpty {
            let lowerURL = urlString.lowercased()
            for (keyword, label) in SwiftyDebug._tags {
                let lowerKeyword = keyword.lowercased()
                if lowerURL.contains(lowerKeyword) || host.contains(lowerKeyword) {
                    return (label, colorForTag(keyword))
                }
            }
        }

        // WebView
        if isWebView {
            return ("web", colorForTag("web"))
        }

        // Known third-party
        let knownTags: [(keyword: String, label: String)] = [
            ("algolia",   "algolia"),
            ("onesignal", "one signal"),
            ("jitsu",     "jitsu"),
        ]
        for tag in knownTags {
            if host.contains(tag.keyword) {
                return (tag.label, colorForTag(tag.keyword))
            }
        }

        // Unknown third-party: abbreviated host
        return (abbreviateHost(host), colorForTag(host))
    }

    private static func detectVersion(path: String) -> String? {
        // Match /v1/, /v2/, /v1.2/, etc. in path
        let pattern = #"/v(\d+(?:\.\d+)?)(?:/|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else {
            return nil
        }
        return "v\(path[range])"
    }

    /// Deterministic color from a string key (djb2 hash → hue)
    private static func colorForTag(_ key: String) -> UIColor {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360.0
        return UIColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1)
    }

    private static func abbreviateHost(_ host: String) -> String {
        var short = host
        for prefix in ["www.", "api.", "cdn.", "m."] {
            if short.hasPrefix(prefix) {
                short = String(short.dropFirst(prefix.count))
                break
            }
        }
        for suffix in [".com", ".io", ".net", ".org", ".co"] {
            if short.hasSuffix(suffix) {
                short = String(short.dropLast(suffix.count))
                break
            }
        }
        if short.count > 12 {
            short = String(short.prefix(10)) + ".."
        }
        return short
    }

    // MARK: - Toggle actions

    @objc private func toggleChanged(_ sender: UISwitch) {
        let toggle = toggles[sender.tag]
        Settings.shared[keyPath: toggle.keyPath] = sender.isOn
    }

    private func clearPinnedRequests() {
        let alert = UIAlertController(
            title: "Clear Pinned Requests",
            message: "This will remove all pinned network requests from disk. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            NetworkRequestStore.shared.clearPinned()
        })
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .settings: return toggles.count
        case .actions:  return 1
        case .urls:     return capturedURLs.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .settings:
            let toggle = toggles[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "SettingsToggleCell")
            cell.selectionStyle = .none
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = toggle.title
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            cell.textLabel?.textColor = .white
            cell.detailTextLabel?.text = toggle.subtitle
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
            cell.detailTextLabel?.numberOfLines = 2

            let sw = UISwitch()
            sw.isOn = Settings.shared[keyPath: toggle.keyPath]
            sw.onTintColor = DebugTheme.accentColor
            sw.tag = indexPath.row
            sw.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = sw
            cell.forceLTR()
            return cell

        case .actions:
            let cell = UITableViewCell(style: .default, reuseIdentifier: "ActionCell")
            cell.selectionStyle = .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = "Clear Pinned Requests"
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            cell.forceLTR()
            return cell

        case .urls:
            let cell = tableView.dequeueReusableCell(withIdentifier: "AppURLCell", for: indexPath) as! AppURLCell
            if indexPath.row < capturedURLs.count {
                cell.configure(item: capturedURLs[indexPath.row])
            }
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let title: String?
        switch Section(rawValue: section)! {
        case .settings: title = "SETTINGS"
        case .actions:  title = "ACTIONS"
        case .urls:     title = capturedURLs.isEmpty ? nil : "MONITORED URLS (\(capturedURLs.count))"
        }

        guard let title = title else { return nil }

        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = DebugTheme.accentColor
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
        ])

        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .settings: return 40
        case .actions:  return 40
        case .urls:     return capturedURLs.isEmpty ? 0 : 40
        }
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, indentationLevelForRowAt indexPath: IndexPath) -> Int {
        return 0
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)! {
        case .settings:
            break
        case .actions:
            clearPinnedRequests()
        case .urls:
            guard indexPath.row < capturedURLs.count else { return }
            let text = capturedURLs[indexPath.row].url
            UIPasteboard.general.string = text

            let alert = UIAlertController(title: "Copied to clipboard", message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            alert.popoverPresentationController?.sourceView = view
            alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            alert.popoverPresentationController?.permittedArrowDirections = .init(rawValue: 0)
            present(alert, animated: true)
        }
    }
}

// MARK: - URLPaddedLabel (pill-shaped tag)

private class URLPaddedLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}

// MARK: - AppURLCell

private class AppURLCell: UITableViewCell {

    private let cardView = UIView()
    private let tagsStack = UIStackView()
    private let hostTagLabel = URLPaddedLabel()
    private let versionTagLabel = URLPaddedLabel()
    private let betaTagLabel = URLPaddedLabel()
    private let urlLabel = UILabel()

    /// URL top → below tags (active when tags visible)
    private var urlBelowTagsConstraint: NSLayoutConstraint!
    /// URL top → card top (active when no tags)
    private var urlToCardTopConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Card
        cardView.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // Tags row
        tagsStack.axis = .horizontal
        tagsStack.spacing = 4
        tagsStack.alignment = .center
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(tagsStack)

        // Host tag pill
        configurePill(hostTagLabel)
        tagsStack.addArrangedSubview(hostTagLabel)

        // Version tag pill
        configurePill(versionTagLabel)
        tagsStack.addArrangedSubview(versionTagLabel)

        // Beta tag pill
        configurePill(betaTagLabel)
        betaTagLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.25)
        betaTagLabel.textColor = .systemOrange
        betaTagLabel.text = "beta"
        tagsStack.addArrangedSubview(betaTagLabel)

        // URL
        urlLabel.font = UIFont(name: "Menlo", size: 11) ?? .systemFont(ofSize: 11)
        urlLabel.textColor = UIColor(white: 0.82, alpha: 1)
        urlLabel.numberOfLines = 0
        urlLabel.lineBreakMode = .byCharWrapping
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(urlLabel)

        // Switchable top constraints for URL
        urlBelowTagsConstraint = urlLabel.topAnchor.constraint(equalTo: tagsStack.bottomAnchor, constant: 6)
        urlToCardTopConstraint = urlLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

            tagsStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            tagsStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            tagsStack.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -12),

            urlLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            urlLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            urlLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -8),
        ])

        forceLTR()
    }

    private func configurePill(_ label: URLPaddedLabel) {
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func configure(item: AppInfoViewController.URLItem) {
        urlLabel.text = item.url

        // Host tag
        if let tag = item.hostTag {
            hostTagLabel.isHidden = false
            hostTagLabel.text = tag.label
            hostTagLabel.backgroundColor = tag.color.withAlphaComponent(0.25)
            hostTagLabel.textColor = tag.color
        } else {
            hostTagLabel.isHidden = true
        }

        // Version tag
        if let version = item.versionTag {
            versionTagLabel.isHidden = false
            versionTagLabel.text = version
            let color = UIColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 1)
            versionTagLabel.backgroundColor = color.withAlphaComponent(0.25)
            versionTagLabel.textColor = color
        } else {
            versionTagLabel.isHidden = true
        }

        // Beta tag
        betaTagLabel.isHidden = !item.isBeta

        // Toggle tags row and URL top constraint
        let hasTags = !(hostTagLabel.isHidden && versionTagLabel.isHidden && betaTagLabel.isHidden)
        tagsStack.isHidden = !hasTags
        urlBelowTagsConstraint.isActive = hasTags
        urlToCardTopConstraint.isActive = !hasTags
    }
}
