//
//  RuleTransferViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit
import UniformTypeIdentifiers

/// Full-screen hub for moving intercept rules between devices: pick rules and share a JSON file,
/// or bring rules in from a file / pasted blob. Nothing is written until the import preview is
/// confirmed — see `RuleImporter` for the collision policy.
class RuleTransferViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case rules = 0
        case export = 1
        case importRules = 2
    }

    private var rules: [InterceptRule] = []
    /// Keyed by rule id — rows are recreated on every reload, so an index-based selection would drift.
    private var selectedIds: Set<String> = []

    // MARK: - Lifecycle

    init() {
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Share Rules"
        view.backgroundColor = .black

        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56

        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadRules()
    }

    private func reloadRules() {
        rules = InterceptRuleStore.shared.allRules()
        let liveIds = Set(rules.map { $0.id })
        if selectedIds.isEmpty {
            selectedIds = liveIds
        } else {
            selectedIds.formIntersection(liveIds)
        }
        tableView.reloadData()
    }

    private var selectedRules: [InterceptRule] {
        return rules.filter { selectedIds.contains($0.id) }
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func toggleSelectAll() {
        if selectedIds.count == rules.count {
            selectedIds.removeAll()
        } else {
            selectedIds = Set(rules.map { $0.id })
        }
        tableView.reloadData()
    }

    private func exportTapped() {
        let chosen = selectedRules
        guard !chosen.isEmpty else {
            showAlert(title: "Nothing Selected", message: "Pick at least one rule to export.")
            return
        }

        let document = RuleExporter.makeDocument(from: chosen)
        let url: URL
        do {
            url = try RuleExporter.writeToTemporaryFile(document)
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
            return
        }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        activity.popoverPresentationController?.permittedArrowDirections = []
        present(activity, animated: true)
    }

    private func importFromFileTapped() {
        // `.plainText` as well: files handed over by chat apps often arrive without a json UTI.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.overrideUserInterfaceStyle = .dark
        present(picker, animated: true)
    }

    private func pasteTapped() {
        let paste = RulePasteViewController()
        paste.onParsed = { [weak self] document in
            self?.presentPreview(for: document)
        }
        navigationController?.pushViewController(paste, animated: true)
    }

    private func presentPreview(for document: RuleTransferDocument) {
        let plan = RuleImporter.plan(document, existing: InterceptRuleStore.shared.allRules())
        let preview = RuleImportPreviewViewController(plan: plan)
        preview.onFinish = { [weak self] outcome in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
            self.reloadRules()
            self.showAlert(title: "Import Complete", message: outcome.message)
        }
        navigationController?.pushViewController(preview, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        alert.popoverPresentationController?.permittedArrowDirections = []
        present(alert, animated: true)
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .rules:       return rules.isEmpty ? 1 : rules.count
        case .export:      return 1
        case .importRules: return 2
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .rules:
            guard rules.indices.contains(indexPath.row) else {
                return Self.makePlainCell(
                    title: "No rules yet",
                    subtitle: "Create a rule from a request, then come back to share it.",
                    color: UIColor(white: 0.5, alpha: 1)
                )
            }
            let rule = rules[indexPath.row]
            let cell = Self.makePlainCell(
                title: "",
                subtitle: RuleTransferFormatter.subtitle(for: rule),
                color: .white
            )
            cell.textLabel?.attributedText = RuleTransferFormatter.attributedTitle(for: rule)
            cell.selectionStyle = .default
            let isSelected = selectedIds.contains(rule.id)
            cell.accessoryType = isSelected ? .checkmark : .none
            cell.tintColor = DebugTheme.accentColor
            cell.contentView.alpha = isSelected ? 1 : 0.45
            return cell

        case .export:
            let count = selectedIds.count
            let cell = Self.makePlainCell(
                title: count == 0 ? "Export…" : "Export \(count) Rule\(count == 1 ? "" : "s")…",
                subtitle: "Writes \(RuleExporter.fileName(bundleId: RuleTransferDocument.AppDescriptor.current.bundleId)) and opens the share sheet",
                color: DebugTheme.accentColor
            )
            cell.selectionStyle = .default
            cell.contentView.alpha = count == 0 ? 0.45 : 1
            let icon = UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            cell.imageView?.image = icon?.withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            return cell

        case .importRules:
            let isFile = indexPath.row == 0
            let cell = Self.makePlainCell(
                title: isFile ? "Import from File…" : "Paste JSON…",
                subtitle: isFile ? "Pick a SwiftyDebug rules file" : "Paste a document a teammate sent you",
                color: .white
            )
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
            let symbol = isFile ? "folder" : "doc.on.clipboard"
            let icon = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            cell.imageView?.image = icon?.withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            return cell
        }
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)! {
        case .rules:
            guard rules.indices.contains(indexPath.row) else { return }
            let rule = rules[indexPath.row]
            if selectedIds.contains(rule.id) {
                selectedIds.remove(rule.id)
            } else {
                selectedIds.insert(rule.id)
            }
            tableView.reloadRows(at: [indexPath], with: .none)
            tableView.reloadSections(IndexSet([Section.export.rawValue]), with: .none)
            reloadRulesHeader()
        case .export:
            exportTapped()
        case .importRules:
            indexPath.row == 0 ? importFromFileTapped() : pasteTapped()
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sec = Section(rawValue: section) else { return nil }

        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.tag = 100
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = DebugTheme.accentColor
        label.text = headerTitle(for: sec)
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        if sec == .rules && !rules.isEmpty {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(selectedIds.count == rules.count ? "Select None" : "Select All", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.setTitleColor(DebugTheme.accentColor, for: .normal)
            button.addTarget(self, action: #selector(toggleSelectAll), for: .touchUpInside)
            header.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
                button.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }

        header.forceLTR()
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 40 }
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 8 }

    private func headerTitle(for section: Section) -> String {
        switch section {
        case .rules:       return rules.isEmpty ? "RULES" : "RULES (\(selectedIds.count)/\(rules.count))"
        case .export:      return "EXPORT"
        case .importRules: return "IMPORT"
        }
    }

    private func reloadRulesHeader() {
        guard let headerView = tableView.headerView(forSection: Section.rules.rawValue),
              let label = headerView.viewWithTag(100) as? UILabel else { return }
        label.text = headerTitle(for: .rules)
    }

    // MARK: - Cell factory

    static func makePlainCell(title: String, subtitle: String?, color: UIColor) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cell.textLabel?.text = title
        cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        cell.textLabel?.textColor = color
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = subtitle
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.numberOfLines = 3
        cell.forceLTR()
        return cell
    }
}

// MARK: - Document picker

extension RuleTransferViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // `asCopy: true` still hands back a security-scoped URL on some iOS versions.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let document = try RuleTransferDocument.decode(data)
            presentPreview(for: document)
        } catch {
            showAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Paste screen

/// Full-screen editor for a pasted document. Validates before it hands anything on, so a typo
/// surfaces here rather than half-way through applying rules.
private class RulePasteViewController: UIViewController {

    var onParsed: ((RuleTransferDocument) -> Void)?

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Paste Rules JSON"
        view.backgroundColor = .black

        let validateItem = UIBarButtonItem(title: "Validate", style: .done, target: self, action: #selector(validateTapped))
        validateItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = validateItem

        textView.backgroundColor = UIColor(white: 0.11, alpha: 1)
        textView.textColor = .white
        textView.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.layer.cornerRadius = 10
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        let hint = UILabel()
        hint.text = "Paste a SwiftyDebug rules document, then tap Validate."
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.5, alpha: 1)
        hint.numberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])

        if let pasted = UIPasteboard.general.string, pasted.contains("\"rules\"") {
            textView.text = pasted
        }

        view.forceLTR()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if textView.text.isEmpty { textView.becomeFirstResponder() }
    }

    @objc private func validateTapped() {
        view.endEditing(true)
        do {
            let document = try RuleTransferDocument.decode(textView.text ?? "")
            onParsed?(document)
        } catch {
            let alert = UIAlertController(title: "Invalid Document", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

// MARK: - Shared formatting

enum RuleTransferFormatter {

    /// "PATTERN  /api/users/{id}" with the mode badge tinted, matching the App tab's rule rows.
    static func attributedTitle(for rule: InterceptRule) -> NSAttributedString {
        let scope: String
        switch rule.matchMode {
        case .global: scope = "All Requests"
        case .host:   scope = rule.matchHosts.joined(separator: ", ")
        default:      scope = rule.matchEndpoint
        }

        let title = NSMutableAttributedString(string: "\(badge(for: rule.matchMode))  ", attributes: [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: color(for: rule.matchMode),
        ])
        title.append(NSAttributedString(string: scope, attributes: [
            .font: UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.white,
        ]))
        return title
    }

    static func subtitle(for rule: InterceptRule) -> String {
        if rule.isBlocked { return "Blocks the request" }
        var parts: [String] = []
        let headers = rule.headerOverrides.count + rule.removedHeaderKeys.count
        let params = rule.queryParamOverrides.count + rule.removedQueryParamKeys.count
        if headers > 0 { parts.append("\(headers) header\(headers == 1 ? "" : "s")") }
        if params > 0 { parts.append("\(params) param\(params == 1 ? "" : "s")") }
        if !rule.isEnabled { parts.append("disabled") }
        return parts.isEmpty ? "Empty rule" : parts.joined(separator: ", ")
    }

    static func badge(for mode: EndpointMatchMode) -> String {
        switch mode {
        case .exact:      return "EXACT"
        case .normalized: return "PATTERN"
        case .host:       return "HOST"
        case .global:     return "GLOBAL"
        }
    }

    static func color(for mode: EndpointMatchMode) -> UIColor {
        switch mode {
        case .exact:      return .systemOrange
        case .normalized: return DebugTheme.accentColor
        case .host:       return .systemPurple
        case .global:     return .systemPink
        }
    }
}
