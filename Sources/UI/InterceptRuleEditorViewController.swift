//
//  InterceptRuleEditorViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Modal editor for creating/editing intercept rules.
/// Shows endpoint info, block toggle, and editable key-value tables for headers and query params.
class InterceptRuleEditorViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case endpoint = 0
        case action = 1
        case headers = 2
        case queryParams = 3
    }

    // MARK: - State

    private var normalizedEndpoint: String = ""
    private var originalURL: String = ""
    private var isBlocked: Bool = false
    private var headers: [KVPair] = []
    private var queryParams: [KVPair] = []
    private var existingRule: InterceptRule?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Intercept Rule"
        view.backgroundColor = .black

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        let saveItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(saveTapped)
        )
        saveItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = saveItem
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

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

        // Check for existing rule
        existingRule = InterceptRuleStore.shared.rule(for: normalizedEndpoint)

        if let rule = existingRule {
            isBlocked = rule.isBlocked
            headers = rule.headerOverrides
            queryParams = rule.queryParamOverrides
        } else {
            // Pre-populate from the current request
            isBlocked = false

            // Headers from request
            if let headerFields = model.requestHeaderFields as? [String: String] {
                headers = headerFields.sorted(by: { $0.key < $1.key }).map {
                    KVPair(key: $0.key, value: $0.value)
                }
            }

            // Query params from URL
            if let url = model.url, let components = URLComponents(url: url as URL, resolvingAgainstBaseURL: false),
               let items = components.queryItems {
                queryParams = items.map { KVPair(key: $0.name, value: $0.value ?? "") }
            }
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        var rule = existingRule ?? InterceptRule(normalizedEndpoint: normalizedEndpoint)
        rule.isBlocked = isBlocked
        rule.headerOverrides = headers.filter { !$0.key.isEmpty }
        rule.queryParamOverrides = queryParams.filter { !$0.key.isEmpty }
        rule.isEnabled = true

        // Compute removed keys by comparing with original request
        if let model = httpModel {
            // Removed headers: keys in original that are no longer in overrides
            if let originalHeaders = model.requestHeaderFields as? [String: String] {
                let currentKeys = Set(rule.headerOverrides.map { $0.key.lowercased() })
                rule.removedHeaderKeys = Set(
                    originalHeaders.keys.filter { !currentKeys.contains($0.lowercased()) }
                        .map { $0.lowercased() }
                )
            }

            // Removed query params
            if let url = model.url, let components = URLComponents(url: url as URL, resolvingAgainstBaseURL: false),
               let items = components.queryItems {
                let currentKeys = Set(rule.queryParamOverrides.map { $0.key })
                rule.removedQueryParamKeys = Set(
                    items.map(\.name).filter { !currentKeys.contains($0) }
                )
            }
        }

        InterceptRuleStore.shared.addOrUpdate(rule)
        dismiss(animated: true)
    }

    @objc private func blockToggleChanged(_ sender: UISwitch) {
        isBlocked = sender.isOn
        // Animate sections visibility
        tableView.reloadSections(IndexSet([Section.headers.rawValue, Section.queryParams.rawValue]), with: .fade)
    }

    @objc private func removeRuleTapped() {
        InterceptRuleStore.shared.remove(normalizedEndpoint: normalizedEndpoint)
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .endpoint:    return 1
        case .action:      return existingRule != nil ? 2 : 1  // block toggle + remove button (if editing)
        case .headers:     return isBlocked ? 0 : headers.count
        case .queryParams: return isBlocked ? 0 : queryParams.count
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
                // Block toggle
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
                // Remove rule button
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
            let pair = headers[indexPath.row]
            cell.configure(key: pair.key, value: pair.value)
            cell.onKeyChanged = { [weak self] newKey in
                self?.headers[indexPath.row].key = newKey
            }
            cell.onValueChanged = { [weak self] newValue in
                self?.headers[indexPath.row].value = newValue
            }
            return cell

        case .queryParams:
            let cell = tableView.dequeueReusableCell(withIdentifier: "KVCell", for: indexPath) as! KeyValueEditCell
            let pair = queryParams[indexPath.row]
            cell.configure(key: pair.key, value: pair.value)
            cell.onKeyChanged = { [weak self] newKey in
                self?.queryParams[indexPath.row].key = newKey
            }
            cell.onValueChanged = { [weak self] newValue in
                self?.queryParams[indexPath.row].value = newValue
            }
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let title: String?
        switch Section(rawValue: section)! {
        case .endpoint:    title = "ENDPOINT PATTERN"
        case .action:      title = "ACTION"
        case .headers:     title = isBlocked ? nil : "HEADERS (\(headers.count))"
        case .queryParams: title = isBlocked ? nil : "QUERY PARAMETERS (\(queryParams.count))"
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
        case .endpoint, .action: return 40
        case .headers:     return isBlocked ? 0 : 40
        case .queryParams: return isBlocked ? 0 : (queryParams.isEmpty ? 0 : 40)
        }
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard !isBlocked else { return nil }

        let isHeaderSection = (section == Section.headers.rawValue)
        let isParamSection = (section == Section.queryParams.rawValue)
        guard isHeaderSection || isParamSection else { return nil }

        let footer = UIView()
        footer.backgroundColor = .clear

        let addButton = UIButton(type: .system)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.imagePadding = 5
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        config.baseForegroundColor = DebugTheme.accentColor
        addButton.configuration = config
        addButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        addButton.layer.cornerRadius = 6
        addButton.clipsToBounds = true

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let icon = UIImage(systemName: "plus", withConfiguration: iconConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        addButton.setImage(icon, for: .normal)
        addButton.setTitle("Add", for: .normal)
        addButton.tag = section
        addButton.addTarget(self, action: #selector(addPairTapped(_:)), for: .touchUpInside)

        footer.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            addButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 4),
            addButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4),
        ])

        return footer
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard !isBlocked else { return 0 }
        if section == Section.headers.rawValue || section == Section.queryParams.rawValue {
            return 36
        }
        return 0
    }

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
            headers.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            // Update header count
            if let header = tableView.headerView(forSection: indexPath.section) {
                if let label = header.subviews.compactMap({ $0 as? UILabel }).first {
                    label.text = "HEADERS (\(headers.count))"
                }
            }
        case .queryParams:
            queryParams.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
        default:
            break
        }
    }

    // MARK: - Add pair

    @objc private func addPairTapped(_ sender: UIButton) {
        let section = Section(rawValue: sender.tag)!
        let newPair = KVPair(key: "", value: "")

        switch section {
        case .headers:
            headers.append(newPair)
            let indexPath = IndexPath(row: headers.count - 1, section: section.rawValue)
            tableView.insertRows(at: [indexPath], with: .automatic)
            // Focus the key field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let cell = self.tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                    cell.keyField.becomeFirstResponder()
                }
            }
        case .queryParams:
            queryParams.append(newPair)
            let indexPath = IndexPath(row: queryParams.count - 1, section: section.rawValue)
            tableView.insertRows(at: [indexPath], with: .automatic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let cell = self.tableView.cellForRow(at: indexPath) as? KeyValueEditCell {
                    cell.keyField.becomeFirstResponder()
                }
            }
        default:
            break
        }
    }
}
