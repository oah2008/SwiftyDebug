//
//  InterceptRuleEditorViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Editor for creating or editing a single intercept rule.
/// Headers and query params start empty. The user taps "Add" to pick from the original request
/// values or add a custom entry. Each item can be edited or toggled to "drop" (remove from request).
///
/// When pushed from `InterceptRuleListViewController`, set `existingRuleId` to edit that rule.
/// When presented directly (no existing rules), it creates a new rule.
class InterceptRuleEditorViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?
    /// Set to a rule ID to edit an existing rule. Leave nil to create a new one.
    var existingRuleId: String?

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case endpoint = 0
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

    private var normalizedEndpoint: String = ""
    private var originalURL: String = ""
    private var isBlocked: Bool = false
    private var headerItems: [EditItem] = []
    private var queryParamItems: [EditItem] = []
    private var existingRule: InterceptRule?

    private var originalHeaders: [(key: String, value: String)] = []
    private var originalQueryParams: [(key: String, value: String)] = []

    /// Whether this editor was presented modally (no rules existed) vs pushed from the list.
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

        // Show cancel only when presented modally
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

        populateFromModel()
        view.forceLTR()
    }

    // MARK: - Populate

    private func populateFromModel() {
        guard let model = httpModel else { return }

        originalURL = model.url?.absoluteString ?? ""
        normalizedEndpoint = EndpointNormalizer.normalize(model.url?.path ?? "")

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
            existingRule = InterceptRuleStore.shared.rules(for: normalizedEndpoint)
                .first(where: { $0.id == ruleId })
        }

        if let rule = existingRule {
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
            isBlocked = false
            headerItems = []
            queryParamItems = []
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        var rule = existingRule ?? InterceptRule(normalizedEndpoint: normalizedEndpoint)
        rule.isBlocked = isBlocked
        rule.isEnabled = true

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

        InterceptRuleStore.shared.addOrUpdate(rule)

        if isPresentedModally {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
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

    // MARK: - Add picker

    @objc private func addHeaderTapped() {
        showAddPicker(
            title: "Add Header",
            originalItems: originalHeaders,
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
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

        let available = originalItems.filter { item in
            let k = caseInsensitive ? item.key.lowercased() : item.key
            return !existingKeys.contains(k)
        }

        for item in available {
            let displayTitle = "\(item.key): \(item.value.prefix(50))"
            alert.addAction(UIAlertAction(title: displayTitle, style: .default) { _ in
                completion(EditItem(key: item.key, value: item.value, isDropped: false, isKeyEditable: false))
            })
        }

        alert.addAction(UIAlertAction(title: "Add Custom", style: .default) { _ in
            completion(EditItem(key: "", value: "", isDropped: false, isKeyEditable: true))
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
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
        case .endpoint:    return "ENDPOINT PATTERN"
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
        case .endpoint:    return 1
        case .action:      return existingRule != nil ? 2 : 1
        case .headers:     return isBlocked ? 0 : headerItems.count
        case .queryParams: return isBlocked ? 0 : queryParamItems.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .endpoint:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "EndpointCell")
            cell.selectionStyle = .none
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = normalizedEndpoint
            cell.textLabel?.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
            cell.textLabel?.textColor = DebugTheme.accentColor
            cell.textLabel?.numberOfLines = 3
            cell.detailTextLabel?.text = originalURL
            cell.detailTextLabel?.font = .systemFont(ofSize: 10)
            cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
            cell.detailTextLabel?.numberOfLines = 2
            cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
            cell.forceLTR()
            return cell

        case .action:
            if indexPath.row == 0 {
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "BlockCell")
                cell.selectionStyle = .none
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                cell.textLabel?.text = "Block Request"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = .white
                cell.detailTextLabel?.text = "Cancel all future requests to this endpoint"
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
}
