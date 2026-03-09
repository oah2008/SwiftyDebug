//
//  InterceptRuleEditorViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Editor for creating or editing a single intercept rule.
/// Supports endpoint matching (Pattern/Exact) and host-based matching.
///
/// When pushed from `InterceptRuleListViewController`, set `existingRuleId` to edit that rule.
/// When presented directly (no existing rules), it creates a new rule.
class InterceptRuleEditorViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?
    /// Set to a rule ID to edit an existing rule. Leave nil to create a new one.
    var existingRuleId: String?
    /// Set before presenting to pre-select the match mode (.normalized, .exact, or .host).
    var initialMatchMode: EndpointMatchMode?
    /// Set directly when editing from the App tab (no httpModel needed).
    var ruleToEdit: InterceptRule?

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case endpoint = 0  // For endpoint mode: mode selector + path display. For host mode: host selector.
        case action = 1
        case headers = 2
        case queryParams = 3
    }

    // MARK: - Item state

    private struct EditItem {
        var key: String
        var value: String
        var isDropped: Bool
        var isKeyEditable: Bool
    }

    // MARK: - State

    private var requestPath: String = ""
    private var normalizedPath: String = ""
    private var requestHost: String = ""
    private var originalURL: String = ""
    private var matchMode: EndpointMatchMode = .normalized
    private var selectedHosts: [String] = []
    private var isBlocked: Bool = false
    private var headerItems: [EditItem] = []
    private var queryParamItems: [EditItem] = []
    private var existingRule: InterceptRule?

    private var originalHeaders: [(key: String, value: String)] = []
    private var originalQueryParams: [(key: String, value: String)] = []

    /// Available hosts extracted from `SwiftyDebug.urls`.
    private var availableHosts: [String] = []

    private var displayedEndpoint: String {
        switch matchMode {
        case .exact:      return requestPath
        case .normalized: return normalizedPath
        case .host:       return selectedHosts.isEmpty ? "(no hosts selected)" : selectedHosts.joined(separator: ", ")
        }
    }

    private var isPresentedModally: Bool {
        return navigationController?.viewControllers.first === self
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = existingRuleId != nil ? "Edit Rule" : "New Rule"
        view.backgroundColor = .black

        let saveItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(saveTapped)
        )
        saveItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = saveItem

        if isPresentedModally {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        let dynamicTable = UITableView(frame: .zero, style: .grouped)
        dynamicTable.dataSource = self
        dynamicTable.delegate = self
        self.tableView = dynamicTable

        tableView.register(KeyValueEditCell.self, forCellReuseIdentifier: "KVCell")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.keyboardDismissMode = .interactive

        setupKeyboardDismissButton()
        populateFromModel()
        view.forceLTR()
    }

    // MARK: - Populate

    private func populateFromModel() {
        // Build available hosts from SwiftyDebug.urls
        availableHosts = Self.extractHosts(from: SwiftyDebug.urls)

        if let model = httpModel {
            requestPath = model.url?.path ?? ""
            normalizedPath = EndpointNormalizer.normalize(requestPath)
            requestHost = (model.url?.host ?? "").lowercased()
            originalURL = model.url?.absoluteString ?? ""

            // Ensure the current request's host is included
            if !requestHost.isEmpty && !availableHosts.contains(requestHost) {
                availableHosts.insert(requestHost, at: 0)
            }

            // Capture original request values for the picker
            if let headerFields = model.requestHeaderFields as? [String: String] {
                originalHeaders = headerFields.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending })
            }
            if let url = model.url, let components = URLComponents(url: url as URL, resolvingAgainstBaseURL: false),
               let items = components.queryItems {
                originalQueryParams = items.map { (key: $0.name, value: $0.value ?? "") }
            }

            // Load existing rule by ID if editing
            if let ruleId = existingRuleId {
                if let url = model.url as URL? {
                    existingRule = InterceptRuleStore.shared.matchingRules(forURL: url)
                        .first(where: { $0.id == ruleId })
                }
            }
        } else if let rule = ruleToEdit {
            // Editing from App tab without an httpModel
            existingRule = rule
            existingRuleId = rule.id
            if rule.matchMode == .host {
                selectedHosts = rule.matchHosts
            } else {
                requestPath = rule.matchEndpoint
                normalizedPath = rule.matchEndpoint
            }
        } else if initialMatchMode == .host {
            // Creating host rule from App tab — no model needed
        }

        if let rule = existingRule {
            matchMode = rule.matchMode
            selectedHosts = rule.matchHosts
            isBlocked = rule.isBlocked

            headerItems = rule.headerOverrides.map {
                EditItem(key: $0.key, value: $0.value, isDropped: false, isKeyEditable: false)
            }
            for removedKey in rule.removedHeaderKeys.sorted() {
                let originalValue = originalHeaders.first(where: { $0.key.lowercased() == removedKey.lowercased() })?.value ?? ""
                headerItems.append(EditItem(key: removedKey, value: originalValue, isDropped: true, isKeyEditable: false))
            }

            queryParamItems = rule.queryParamOverrides.map {
                EditItem(key: $0.key, value: $0.value, isDropped: false, isKeyEditable: false)
            }
            for removedKey in rule.removedQueryParamKeys.sorted() {
                let originalValue = originalQueryParams.first(where: { $0.key == removedKey })?.value ?? ""
                queryParamItems.append(EditItem(key: removedKey, value: originalValue, isDropped: true, isKeyEditable: false))
            }
        } else {
            matchMode = initialMatchMode ?? .normalized
            if matchMode == .host && !requestHost.isEmpty {
                selectedHosts = [requestHost]
            }
            isBlocked = false
            headerItems = []
            queryParamItems = []
        }
    }

    /// Extracts host names from the SDK URL list.
    private static func extractHosts(from urls: [String]) -> [String] {
        var hosts: [String] = []
        for entry in urls {
            if let url = URL(string: entry), let host = url.host {
                let h = host.lowercased()
                if !hosts.contains(h) { hosts.append(h) }
            } else if entry.contains(".") && !entry.contains("/") {
                // Looks like a bare hostname
                let h = entry.lowercased()
                if !hosts.contains(h) { hosts.append(h) }
            }
        }
        return hosts.sorted()
    }

    /// Collects unique header keys from captured requests matching the selected hosts.
    private func headerKeysForSelectedHosts() -> [(key: String, value: String)] {
        let models = NetworkRequestStore.shared.httpModels as? [NetworkTransaction] ?? []
        var seen = Set<String>()
        var result: [(key: String, value: String)] = []

        for model in models {
            guard let host = model.url?.host?.lowercased(), selectedHosts.contains(host) else { continue }
            guard let headers = model.requestHeaderFields as? [String: String] else { continue }
            for (key, value) in headers {
                let lk = key.lowercased()
                if !seen.contains(lk) {
                    seen.insert(lk)
                    result.append((key: key, value: value))
                }
            }
        }
        return result.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        var rule: InterceptRule
        if matchMode == .host {
            if selectedHosts.isEmpty {
                showAlert(title: "No Hosts", message: "Select at least one host.")
                return
            }
            let sorted = selectedHosts.map { $0.lowercased() }.sorted()
            let key = "host:" + sorted.joined(separator: ",")
            rule = existingRule ?? InterceptRule(matchEndpoint: key, matchMode: .host)
            rule.matchHosts = sorted
        } else {
            let matchEndpoint = matchMode == .exact ? requestPath : normalizedPath
            rule = existingRule ?? InterceptRule(matchEndpoint: matchEndpoint, matchMode: matchMode)
        }

        rule.isBlocked = isBlocked
        rule.isEnabled = true
        rule.matchMode = matchMode

        rule.headerOverrides = headerItems
            .filter { !$0.isDropped && !$0.key.isEmpty }
            .map { KVPair(key: $0.key, value: $0.value) }

        rule.removedHeaderKeys = Set(
            headerItems.filter { $0.isDropped && !$0.key.isEmpty }.map { $0.key.lowercased() }
        )

        rule.queryParamOverrides = queryParamItems
            .filter { !$0.isDropped && !$0.key.isEmpty }
            .map { KVPair(key: $0.key, value: $0.value) }

        rule.removedQueryParamKeys = Set(
            queryParamItems.filter { $0.isDropped && !$0.key.isEmpty }.map { $0.key }
        )

        let hasEffect = rule.isBlocked
            || !rule.headerOverrides.isEmpty
            || !rule.removedHeaderKeys.isEmpty
            || !rule.queryParamOverrides.isEmpty
            || !rule.removedQueryParamKeys.isEmpty

        if !hasEffect {
            showAlert(title: "Empty Rule", message: "This rule has no effect. Add headers/parameters to override or drop, or enable blocking.")
            return
        }

        // If the matchEndpoint key changed, remove the old entry first
        if let existing = existingRule, existing.matchEndpoint != rule.matchEndpoint {
            InterceptRuleStore.shared.remove(id: existing.id)
        }

        InterceptRuleStore.shared.addOrUpdate(rule)

        if isPresentedModally {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func blockToggleChanged(_ sender: UISwitch) {
        isBlocked = sender.isOn
        tableView.reloadSections(IndexSet([Section.headers.rawValue, Section.queryParams.rawValue]), with: .fade)
    }

    @objc private func removeRuleTapped() {
        if let ruleId = existingRule?.id {
            InterceptRuleStore.shared.remove(id: ruleId)
        }
        if isPresentedModally {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    // MARK: - Host picker

    @objc private func selectHostsTapped() {
        let picker = HostPickerSheetViewController()
        picker.hosts = availableHosts
        picker.selectedHosts = Set(selectedHosts)
        picker.onApply = { [weak self] applied in
            guard let self = self else { return }
            self.selectedHosts = applied
            self.tableView.reloadSections(IndexSet([Section.endpoint.rawValue]), with: .none)
        }

        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(picker, animated: true)
    }

    // MARK: - Add picker

    @objc private func addHeaderTapped() {
        let items: [(key: String, value: String)]
        if matchMode == .host {
            items = headerKeysForSelectedHosts()
        } else {
            items = originalHeaders
        }

        showAddPicker(
            title: "Add Header",
            originalItems: items,
            existingKeys: Set(headerItems.map { $0.key.lowercased() }),
            caseInsensitive: true
        ) { [weak self] item in
            guard let self = self else { return }
            self.headerItems.append(item)
            let indexPath = IndexPath(row: self.headerItems.count - 1, section: Section.headers.rawValue)
            self.tableView.insertRows(at: [indexPath], with: .automatic)
            self.reloadSectionHeader(Section.headers)
            if item.isKeyEditable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let cell = self.tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                        cell.keyField.becomeFirstResponder()
                    }
                }
            }
        }
    }

    @objc private func addQueryParamTapped() {
        if matchMode == .host {
            // Host mode: only custom params
            let item = EditItem(key: "", value: "", isDropped: false, isKeyEditable: true)
            queryParamItems.append(item)
            let indexPath = IndexPath(row: queryParamItems.count - 1, section: Section.queryParams.rawValue)
            tableView.insertRows(at: [indexPath], with: .automatic)
            reloadSectionHeader(Section.queryParams)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let cell = self.tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                    cell.keyField.becomeFirstResponder()
                }
            }
            return
        }

        showAddPicker(
            title: "Add Query Parameter",
            originalItems: originalQueryParams,
            existingKeys: Set(queryParamItems.map { $0.key }),
            caseInsensitive: false
        ) { [weak self] item in
            guard let self = self else { return }
            self.queryParamItems.append(item)
            let indexPath = IndexPath(row: self.queryParamItems.count - 1, section: Section.queryParams.rawValue)
            self.tableView.insertRows(at: [indexPath], with: .automatic)
            self.reloadSectionHeader(Section.queryParams)
            if item.isKeyEditable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let cell = self.tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                        cell.keyField.becomeFirstResponder()
                    }
                }
            }
        }
    }

    private func showAddPicker(
        title: String,
        originalItems: [(key: String, value: String)],
        existingKeys: Set<String>,
        caseInsensitive: Bool,
        completion: @escaping (EditItem) -> Void
    ) {
        let available = originalItems.filter { item in
            let k = caseInsensitive ? item.key.lowercased() : item.key
            return !existingKeys.contains(k)
        }

        let picker = KeyPickerSheetViewController()
        picker.sheetTitle = title
        picker.items = available
        picker.onItemSelected = { item in
            completion(EditItem(key: item.key, value: item.value, isDropped: false, isKeyEditable: false))
        }
        picker.onCustomSelected = {
            completion(EditItem(key: "", value: "", isDropped: false, isKeyEditable: true))
        }

        let nav = SwiftyDebugNavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(nav, animated: true)
    }

    private func reloadSectionHeader(_ section: Section) {
        if let headerView = tableView.headerView(forSection: section.rawValue) {
            if let label = headerView.viewWithTag(100) as? UILabel {
                let count: Int
                switch section {
                case .headers:     count = headerItems.count
                case .queryParams: count = queryParamItems.count
                default: return
                }
                label.text = sectionTitle(for: section, count: count)
            }
        }
    }

    private func sectionTitle(for section: Section, count: Int) -> String {
        switch section {
        case .endpoint:    return matchMode == .host ? "HOSTS" : "ENDPOINT"
        case .action:      return "ACTION"
        case .headers:     return "HEADERS\(count > 0 ? " (\(count))" : "")"
        case .queryParams: return "QUERY PARAMETERS\(count > 0 ? " (\(count))" : "")"
        }
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .endpoint:
            if matchMode == .host {
                return 1 + selectedHosts.count  // host selector button + each selected host
            }
            return 2  // mode selector + path display
        case .action:      return existingRule != nil ? 2 : 1
        case .headers:     return isBlocked ? 0 : headerItems.count
        case .queryParams: return isBlocked ? 0 : queryParamItems.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .endpoint:
            if matchMode == .host {
                if indexPath.row == 0 {
                    // "Select Hosts" button
                    let cell = UITableViewCell(style: .default, reuseIdentifier: "HostSelectCell")
                    cell.selectionStyle = .default
                    cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                    cell.textLabel?.text = selectedHosts.isEmpty ? "Select Hosts..." : "Change Hosts..."
                    cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                    cell.textLabel?.textColor = .systemPurple
                    cell.accessoryType = .disclosureIndicator
                    cell.forceLTR()
                    return cell
                } else {
                    // Display a selected host
                    let host = selectedHosts[indexPath.row - 1]
                    let cell = UITableViewCell(style: .default, reuseIdentifier: "HostCell")
                    cell.selectionStyle = .none
                    cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                    cell.textLabel?.text = host
                    cell.textLabel?.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
                    cell.textLabel?.textColor = .systemPurple
                    cell.forceLTR()
                    return cell
                }
            }

            if indexPath.row == 0 {
                // Match mode selector (Pattern / Exact) — only for endpoint modes
                let cell = UITableViewCell(style: .default, reuseIdentifier: "MatchModeCell")
                cell.selectionStyle = .none
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)

                let seg = UISegmentedControl(items: ["Pattern", "Exact"])
                seg.selectedSegmentIndex = matchMode == .normalized ? 0 : 1
                seg.addTarget(self, action: #selector(endpointModeChanged(_:)), for: .valueChanged)
                seg.translatesAutoresizingMaskIntoConstraints = false
                seg.selectedSegmentTintColor = DebugTheme.accentColor
                seg.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .selected)
                seg.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.6, alpha: 1), .font: UIFont.systemFont(ofSize: 12, weight: .medium)], for: .normal)

                cell.contentView.addSubview(seg)
                NSLayoutConstraint.activate([
                    seg.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 12),
                    seg.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -12),
                    seg.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                    seg.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                    seg.heightAnchor.constraint(equalToConstant: 32),
                ])
                cell.forceLTR()
                return cell
            } else {
                // Endpoint display
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "EndpointCell")
                cell.selectionStyle = .none
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                cell.textLabel?.text = displayedEndpoint
                cell.textLabel?.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
                cell.textLabel?.textColor = matchMode == .exact ? .systemOrange : DebugTheme.accentColor
                cell.textLabel?.numberOfLines = 3
                cell.detailTextLabel?.text = matchMode == .exact
                    ? "Matches only this exact path"
                    : "Matches all paths with this pattern (IDs replaced)"
                cell.detailTextLabel?.font = .systemFont(ofSize: 10)
                cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
                cell.detailTextLabel?.numberOfLines = 2
                cell.forceLTR()
                return cell
            }

        case .action:
            if indexPath.row == 0 {
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "BlockCell")
                cell.selectionStyle = .none
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                cell.textLabel?.text = "Block Request"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = .white
                let target = matchMode == .host ? "selected hosts" : "this endpoint"
                cell.detailTextLabel?.text = "Cancel all future requests to \(target)"
                cell.detailTextLabel?.font = .systemFont(ofSize: 11)
                cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)

                let sw = UISwitch()
                sw.isOn = isBlocked
                sw.onTintColor = .systemRed
                sw.addTarget(self, action: #selector(blockToggleChanged(_:)), for: .valueChanged)
                cell.accessoryView = sw
                cell.forceLTR()
                return cell
            } else {
                let cell = UITableViewCell(style: .default, reuseIdentifier: "RemoveCell")
                cell.selectionStyle = .default
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                cell.textLabel?.text = "Remove Rule"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = .systemRed
                cell.textLabel?.textAlignment = .center
                cell.forceLTR()
                return cell
            }

        case .headers:
            let cell = tableView.dequeueReusableCell(withIdentifier: "KVCell", for: indexPath) as! KeyValueEditCell
            let item = headerItems[indexPath.row]
            cell.configure(key: item.key, value: item.value, dropped: item.isDropped, keyEditable: item.isKeyEditable)
            cell.onKeyChanged = { [weak self] newKey in
                self?.headerItems[indexPath.row].key = newKey
            }
            cell.onValueChanged = { [weak self] newValue in
                self?.headerItems[indexPath.row].value = newValue
            }
            cell.onDropToggled = { [weak self] in
                guard let self = self else { return }
                self.headerItems[indexPath.row].isDropped.toggle()
                if let c = tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                    c.isDropped = self.headerItems[indexPath.row].isDropped
                }
            }
            return cell

        case .queryParams:
            let cell = tableView.dequeueReusableCell(withIdentifier: "KVCell", for: indexPath) as! KeyValueEditCell
            let item = queryParamItems[indexPath.row]
            cell.configure(key: item.key, value: item.value, dropped: item.isDropped, keyEditable: item.isKeyEditable)
            cell.onKeyChanged = { [weak self] newKey in
                self?.queryParamItems[indexPath.row].key = newKey
            }
            cell.onValueChanged = { [weak self] newValue in
                self?.queryParamItems[indexPath.row].value = newValue
            }
            cell.onDropToggled = { [weak self] in
                guard let self = self else { return }
                self.queryParamItems[indexPath.row].isDropped.toggle()
                if let c = tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                    c.isDropped = self.queryParamItems[indexPath.row].isDropped
                }
            }
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sec = Section(rawValue: section) else { return nil }

        let isKVSection = (sec == .headers || sec == .queryParams)
        if isKVSection && isBlocked { return nil }

        let header = UIView()
        header.backgroundColor = .clear

        let count: Int
        switch sec {
        case .headers:     count = headerItems.count
        case .queryParams: count = queryParamItems.count
        default:           count = 0
        }

        let label = UILabel()
        label.tag = 100
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = DebugTheme.accentColor
        label.text = sectionTitle(for: sec, count: count)
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        if isKVSection {
            let addButton = UIButton(type: .system)
            addButton.translatesAutoresizingMaskIntoConstraints = false
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.imagePadding = 4
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
                var attr = attr
                attr.font = .systemFont(ofSize: 12, weight: .semibold)
                return attr
            }
            config.baseForegroundColor = DebugTheme.accentColor
            addButton.configuration = config
            addButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
            addButton.layer.cornerRadius = 6
            addButton.clipsToBounds = true

            let iconConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            let icon = UIImage(systemName: "plus", withConfiguration: iconConfig)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            addButton.setImage(icon, for: .normal)
            addButton.setTitle("Add", for: .normal)

            if sec == .headers {
                addButton.addTarget(self, action: #selector(addHeaderTapped), for: .touchUpInside)
            } else {
                addButton.addTarget(self, action: #selector(addQueryParamTapped), for: .touchUpInside)
            }

            header.addSubview(addButton)
            NSLayoutConstraint.activate([
                addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
                addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }

        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .endpoint, .action: return 40
        case .headers:     return isBlocked ? 0 : 40
        case .queryParams: return isBlocked ? 0 : 40
        }
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 0 }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == Section.action.rawValue && indexPath.row == 1 {
            removeRuleTapped()
        }
        // Host selector tap
        if indexPath.section == Section.endpoint.rawValue && matchMode == .host && indexPath.row == 0 {
            selectHostsTapped()
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == Section.headers.rawValue || indexPath.section == Section.queryParams.rawValue
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }

        switch Section(rawValue: indexPath.section)! {
        case .headers:
            headerItems.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            reloadSectionHeader(.headers)
        case .queryParams:
            queryParamItems.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            reloadSectionHeader(.queryParams)
        default:
            break
        }
    }

    // MARK: - Endpoint mode change (Pattern/Exact only)

    @objc private func endpointModeChanged(_ sender: UISegmentedControl) {
        matchMode = sender.selectedSegmentIndex == 0 ? .normalized : .exact
        tableView.reloadRows(at: [IndexPath(row: 1, section: Section.endpoint.rawValue)], with: .none)
    }

    // MARK: - Keyboard dismiss

    private func setupKeyboardDismissButton() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private var _dismissKeyboardButton: UIButton?

    private var dismissKeyboardButton: UIButton {
        if let btn = _dismissKeyboardButton { return btn }
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(white: 0.22, alpha: 1)
        config.baseForegroundColor = UIColor(white: 0.7, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.image = UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: iconConfig)
        btn.configuration = config
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(dismissKeyboardTapped), for: .touchUpInside)
        btn.alpha = 0
        _dismissKeyboardButton = btn
        return btn
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard dismissKeyboardButton.superview == nil else {
            UIView.animate(withDuration: 0.2) { self.dismissKeyboardButton.alpha = 1 }
            return
        }
        guard let window = view.window else { return }
        window.addSubview(dismissKeyboardButton)

        guard let info = notification.userInfo,
              let kbFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            NSLayoutConstraint.activate([
                dismissKeyboardButton.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                dismissKeyboardButton.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            ])
            UIView.animate(withDuration: 0.25) { self.dismissKeyboardButton.alpha = 1 }
            return
        }
        NSLayoutConstraint.activate([
            dismissKeyboardButton.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            dismissKeyboardButton.bottomAnchor.constraint(equalTo: window.topAnchor, constant: kbFrame.origin.y - 12),
        ])
        UIView.animate(withDuration: 0.25) { self.dismissKeyboardButton.alpha = 1 }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        UIView.animate(withDuration: 0.2) { self.dismissKeyboardButton.alpha = 0 }
    }

    @objc private func dismissKeyboardTapped() {
        view.endEditing(true)
    }

    deinit {
        _dismissKeyboardButton?.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
    }
}
