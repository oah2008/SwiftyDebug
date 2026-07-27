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
        case simulation = 1
        case interceptRules = 2
        case actions = 3
        case urls = 4
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
        ToggleItem(title: "Full Stop on Disable",
                   subtitle: "When on, shaking to disable fully stops all capture (0 CPU). When off, shake only hides the overlay.",
                   keyPath: \.fullStopOnDisable),
    ]

    // MARK: - Inspector rows (ACTIONS section)

    /// The storage/file inspectors, in order. "Clear Pinned Requests" is always
    /// rendered after these.
    private struct InspectorRow {
        let title: String
        let symbol: String
        /// Optional live one-liner under the title. Evaluated in `cellForRowAt`, so it
        /// must stay cheap — in-memory state only, never a disk read.
        let subtitle: (() -> String)?
        let make: () -> UIViewController

        init(title: String, symbol: String,
             subtitle: (() -> String)? = nil,
             make: @escaping () -> UIViewController) {
            self.title = title
            self.symbol = symbol
            self.subtitle = subtitle
            self.make = make
        }
    }

    private static let inspectorRows: [InspectorRow] = [
        InspectorRow(title: "Web View Storage", symbol: "externaldrive.badge.person.crop") {
            WebViewStoragePickerViewController(style: .plain)
        },
        InspectorRow(title: "App Container Files", symbol: "folder") {
            AppContainerBrowserViewController(directory: nil, title: "App Container", showsCloseButton: true)
        },
        InspectorRow(title: "User Defaults", symbol: "slider.horizontal.3") {
            UserDefaultsBrowserViewController()
        },
        InspectorRow(title: "Keychain", symbol: "key.fill") {
            KeychainBrowserViewController()
        },
        InspectorRow(title: "Timeline", symbol: "chart.bar.xaxis") {
            NetworkTimelineViewController()
        },
        InspectorRow(title: "Insights", symbol: "chart.pie.fill") {
            NetworkInsightsViewController()
        },
        InspectorRow(title: "Auth Tokens", symbol: "person.badge.key.fill") {
            AuthTokenInspectorViewController()
        },
        InspectorRow(title: "Paused Requests", symbol: "pause.circle.fill") {
            BreakpointInboxViewController()
        },
        InspectorRow(
            title: "Share Rules",
            symbol: "square.and.arrow.up.on.square",
            subtitle: { "Export intercept rules as JSON, or import a teammate's" }
        ) {
            RuleTransferViewController()
        },
    ]

    // MARK: - Data

    private var interceptRules: [InterceptRule] = []

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
        interceptRules = InterceptRuleStore.shared.allRules()

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

    /// Presents an action sheet to pick a fixed Network Link Conditioner preset.
    /// Latency-only simulation, off by default. (See NETWORK-SIM.)
    private func presentNetworkSimPicker() {
        let current = Settings.shared.networkConditionerPreset
        let alert = UIAlertController(
            title: "Slow Network Simulation",
            message: "Adds a fixed latency to every captured request so you can test loader / spinner states. Matches iOS Network Link Conditioner presets.",
            preferredStyle: .actionSheet
        )
        for preset in NetworkConditionerPreset.allCases {
            let checkmark = (preset == current) ? "  ✓" : ""
            let title = preset == .off
                ? "Off\(checkmark)"
                : "\(preset.displayName) — \(preset.subtitle)\(checkmark)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                Settings.shared.networkConditionerPreset = preset
                let indexPath = IndexPath(row: 0, section: Section.simulation.rawValue)
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    /// Presents an inspector **full screen** (these are screens you work in —
    /// browse, edit, drill down — not quick sheets).
    ///
    /// Because a full-screen modal has no swipe-to-dismiss, this guarantees a
    /// Close button exists: the view is loaded first so the screen's own
    /// `viewDidLoad` can install its bar items, and one is only added when the
    /// screen didn't provide its own.
    private func presentInspector(_ vc: UIViewController) {
        // Build the navigation controller FIRST, then force `viewDidLoad`.
        //
        // Order matters: force-loading a screen while `navigationController` is
        // still nil crashed the UserDefaults inspector, which assigns
        // `navigationItem.searchController` in viewDidLoad — UIKit was told to
        // hoist a search bar into a navigation bar that didn't exist yet.
        // Wrapping first means the nav relationship is already established.
        let nav = SwiftyDebugNavigationController(rootViewController: vc)
        _ = vc.view   // now safe: its own bar items get installed before we look

        if vc.navigationItem.leftBarButtonItem == nil {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain,
                                        target: self, action: #selector(dismissInspector))
            close.tintColor = DebugTheme.accentColor
            vc.navigationItem.leftBarButtonItem = close
        }
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func dismissInspector() {
        presentedViewController?.dismiss(animated: true)
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
        case .settings:       return toggles.count
        case .simulation:     return 1 // network conditioner preset row
        case .interceptRules: return interceptRules.count + 1 // rules + "Add Rule" button
        case .actions:        return Self.inspectorRows.count + 1 // inspectors + Clear Pinned
        case .urls:           return capturedURLs.count
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

        case .simulation:
            let preset = Settings.shared.networkConditionerPreset
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "NetworkSimCell")
            cell.selectionStyle = .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = "Slow Network Simulation"
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            cell.textLabel?.textColor = .white
            cell.detailTextLabel?.text = preset.isActive
                ? "\(preset.displayName) · \(preset.subtitle)"
                : "Off · adds latency to every request to test loaders"
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
            cell.detailTextLabel?.numberOfLines = 2

            // Show current preset name on the right (with a chevron glyph, since
            // an accessoryView overrides the system disclosure indicator).
            let valueLabel = UILabel()
            valueLabel.text = "\(preset.displayName)  ›"
            valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            valueLabel.textColor = preset.isActive ? DebugTheme.accentColor : UIColor(white: 0.5, alpha: 1)
            valueLabel.sizeToFit()
            cell.accessoryView = valueLabel
            cell.forceLTR()
            return cell

        case .interceptRules:
            if indexPath.row == interceptRules.count {
                // "Add Rule" button
                let cell = UITableViewCell(style: .default, reuseIdentifier: "AddRuleCell")
                cell.selectionStyle = .default
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                let iconConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                cell.imageView?.image = UIImage(systemName: "plus.circle.fill", withConfiguration: iconConfig)?
                    .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
                cell.textLabel?.text = "Add Rule"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                cell.textLabel?.textColor = DebugTheme.accentColor
                cell.accessoryType = .disclosureIndicator
                cell.forceLTR()
                return cell
            }
            let rule = interceptRules[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "InterceptRuleCell")
            cell.selectionStyle = .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)

            // Mode badge color
            let modeColor: UIColor
            let modeText: String
            switch rule.matchMode {
            case .exact:      modeColor = .systemOrange;  modeText = "EXACT"
            case .normalized: modeColor = DebugTheme.accentColor; modeText = "PATTERN"
            case .host:       modeColor = .systemPurple;  modeText = "HOST"
            case .global:     modeColor = .systemPink;    modeText = "GLOBAL"
            }

            // Summary
            var summary: String
            if rule.isBlocked {
                summary = "Block"
            } else {
                var parts: [String] = []
                let hc = rule.headerOverrides.count + rule.removedHeaderKeys.count
                let pc = rule.queryParamOverrides.count + rule.removedQueryParamKeys.count
                if hc > 0 { parts.append("\(hc) header\(hc == 1 ? "" : "s")") }
                if pc > 0 { parts.append("\(pc) param\(pc == 1 ? "" : "s")") }
                summary = parts.isEmpty ? "Empty rule" : parts.joined(separator: ", ")
            }

            // Title: [MODE] endpoint/hosts
            let endpoint: String
            if rule.matchMode == .host {
                endpoint = rule.matchHosts.joined(separator: ", ")
            } else if rule.matchMode == .global {
                endpoint = "All Requests"
            } else {
                endpoint = rule.matchEndpoint
            }

            let titleAttr = NSMutableAttributedString()
            let badgeAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: modeColor,
            ]
            titleAttr.append(NSAttributedString(string: "\(modeText)  ", attributes: badgeAttr))
            titleAttr.append(NSAttributedString(string: endpoint, attributes: [
                .font: UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.white,
            ]))
            cell.textLabel?.attributedText = titleAttr
            cell.textLabel?.numberOfLines = 2

            cell.detailTextLabel?.text = summary
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = rule.isBlocked ? .systemRed : UIColor(white: 0.55, alpha: 1)

            // Enable/disable switch
            let sw = UISwitch()
            sw.isOn = rule.isEnabled
            sw.onTintColor = DebugTheme.accentColor
            sw.tag = indexPath.row
            sw.addTarget(self, action: #selector(ruleToggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = sw
            cell.contentView.alpha = rule.isEnabled ? 1 : 0.5
            cell.forceLTR()
            return cell

        case .actions:
            // Subtitle style only where a row actually has one — a `.subtitle` cell with
            // an empty detail label lays its title out differently.
            let inspector = indexPath.row < Self.inspectorRows.count ? Self.inspectorRows[indexPath.row] : nil
            let hasSubtitle = inspector?.subtitle != nil
            let cell = UITableViewCell(style: hasSubtitle ? .subtitle : .default,
                                       reuseIdentifier: hasSubtitle ? "ActionSubtitleCell" : "ActionCell")
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.forceLTR()
            cell.selectionStyle = .default
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

            if let row = inspector {
                cell.imageView?.image = UIImage(systemName: row.symbol, withConfiguration: iconConfig)?
                    .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
                cell.textLabel?.text = row.title
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = .white
                cell.textLabel?.textAlignment = .natural
                cell.detailTextLabel?.text = row.subtitle?()
                cell.detailTextLabel?.font = .systemFont(ofSize: 11)
                cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
                cell.detailTextLabel?.numberOfLines = 2
                cell.accessoryType = .disclosureIndicator
            } else {
                // Clear Pinned Requests (always last)
                cell.imageView?.image = nil
                cell.textLabel?.text = "Clear Pinned Requests"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = .systemRed
                cell.textLabel?.textAlignment = .center
                cell.accessoryType = .none
            }
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
        case .settings:       title = "SETTINGS"
        case .simulation:     title = "NETWORK SIMULATION"
        case .interceptRules: title = "INTERCEPT RULES\(interceptRules.isEmpty ? "" : " (\(interceptRules.count))")"
        case .actions:        title = "ACTIONS"
        case .urls:           title = capturedURLs.isEmpty ? nil : "MONITORED URLS (\(capturedURLs.count))"
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
        case .settings:       return 40
        case .simulation:     return 40
        case .interceptRules: return 40
        case .actions:        return 40
        case .urls:           return capturedURLs.isEmpty ? 0 : 40
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
        case .simulation:
            presentNetworkSimPicker()
        case .interceptRules:
            if indexPath.row == interceptRules.count {
                addRuleTapped()
            } else {
                editRuleFromAppTab(interceptRules[indexPath.row])
            }
        case .actions:
            if indexPath.row < Self.inspectorRows.count {
                presentInspector(Self.inspectorRows[indexPath.row].make())
            } else {
                clearPinnedRequests()
            }
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

    // Swipe to delete rules
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard Section(rawValue: indexPath.section) == .interceptRules else { return false }
        return indexPath.row < interceptRules.count
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              Section(rawValue: indexPath.section) == .interceptRules,
              indexPath.row < interceptRules.count else { return }
        let rule = interceptRules[indexPath.row]
        interceptRules.remove(at: indexPath.row)
        InterceptRuleStore.shared.remove(id: rule.id)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // MARK: - Intercept Rule actions

    @objc private func ruleToggleChanged(_ sender: UISwitch) {
        guard sender.tag < interceptRules.count else { return }
        interceptRules[sender.tag].isEnabled = sender.isOn
        InterceptRuleStore.shared.update(interceptRules[sender.tag])
        // Update opacity
        let indexPath = IndexPath(row: sender.tag, section: Section.interceptRules.rawValue)
        if let cell = tableView.cellForRow(at: indexPath) {
            cell.contentView.alpha = sender.isOn ? 1 : 0.5
        }
    }

    private func editRuleFromAppTab(_ rule: InterceptRule) {
        let editor = InterceptRuleEditorViewController()
        editor.existingRuleId = rule.id

        // Create a minimal model so the editor can look up the rule
        // For host rules we don't need a real request model — set httpModel to nil
        // and look up the rule from the store directly
        editor.ruleToEdit = rule
        let nav = SwiftyDebugNavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    private func addRuleTapped() {
        let alert = UIAlertController(title: "New Rule", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Host Rule", style: .default) { [weak self] _ in
            let editor = InterceptRuleEditorViewController()
            editor.initialMatchMode = .host
            let nav = SwiftyDebugNavigationController(rootViewController: editor)
            self?.present(nav, animated: true)
        })

        alert.addAction(UIAlertAction(title: "Global Rule", style: .default) { [weak self] _ in
            let editor = InterceptRuleEditorViewController()
            editor.initialMatchMode = .global
            let nav = SwiftyDebugNavigationController(rootViewController: editor)
            self?.present(nav, animated: true)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
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
