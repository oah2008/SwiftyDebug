//
//  InterceptRuleListViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Shows all intercept rules that match a given request path (both exact and normalized).
/// Supports enable/disable, reorder, delete, and creating new rules.
class InterceptRuleListViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?

    // MARK: - Derived

    private var requestPath: String = ""
    private var normalizedPath: String = ""

    // MARK: - State

    private var ruleList: [InterceptRule] = []
    /// Kept so the share sheet has a popover anchor on iPad.
    private var transferItem: UIBarButtonItem?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Intercept Rules"
        view.backgroundColor = .black

        requestPath = httpModel?.url?.path ?? ""
        normalizedPath = EndpointNormalizer.normalize(requestPath)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

        let addItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addRuleTapped)
        )
        addItem.tintColor = DebugTheme.accentColor

        let editItem = UIBarButtonItem(
            title: "Reorder", style: .plain, target: self, action: #selector(toggleEdit)
        )
        editItem.tintColor = DebugTheme.accentColor

        // Export / import moves *every* rule on the device, not just the ones matching
        // this request — a menu keeps that out of the way of the per-request actions.
        let transferItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"), menu: makeTransferMenu()
        )
        transferItem.tintColor = DebugTheme.accentColor
        self.transferItem = transferItem

        navigationItem.rightBarButtonItems = [addItem, transferItem, editItem]

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.register(InterceptRuleCell.self, forCellReuseIdentifier: "RuleCell")

        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadRules()
    }

    private func reloadRules() {
        if let url = httpModel?.url as URL? {
            ruleList = InterceptRuleStore.shared.matchingRules(forURL: url)
        } else {
            ruleList = InterceptRuleStore.shared.matchingRules(forPath: requestPath)
        }
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    /// Scope chooser for a new rule. Uses `OptionPickerSheetViewController` rather
    /// than a system action sheet so the endpoint/host each option matches can be
    /// shown in full — an alert row truncates them. (See INTERCEPT-UX.)
    @objc private func addRuleTapped() {
        let openEditor: (EndpointMatchMode) -> Void = { [weak self] mode in
            guard let self = self else { return }
            let editor = InterceptRuleEditorViewController()
            editor.httpModel = self.httpModel
            editor.initialMatchMode = mode
            self.navigationController?.pushViewController(editor, animated: true)
        }

        let host = httpModel?.url?.host ?? ""

        OptionPickerSheetViewController.present(
            from: self,
            title: "New Rule",
            message: "Choose what the new rule should apply to.",
            options: [
                .init(title: "Intercept Endpoint",
                      subtitle: endpointOptionSubtitle,
                      symbol: "point.topleft.down.curvedto.point.bottomright.up",
                      tint: DebugTheme.accentColor) { openEditor(.normalized) },
                .init(title: "Intercept Host",
                      subtitle: host.isEmpty
                          ? "Every request to this host"
                          : "Every request to \(host)",
                      symbol: "network", tint: .systemPurple) { openEditor(.host) },
                .init(title: "Global Rule",
                      subtitle: "Every request in the app and web views",
                      symbol: "globe", tint: .systemPink) { openEditor(.global) },
            ]
        )
    }

    /// Spells out BOTH forms of the endpoint before the user commits to a scope.
    ///
    /// It used to show only the normalized pattern, which for
    /// `/product/10289032912/20920220` reads `/product/{id}/{id}` — the user
    /// reported this as the full path being cut short. The exact path is what an
    /// EXACT rule will match, so it is shown in full, on its own line
    /// (`OptionPickerSheetViewController` sets `numberOfLines = 0`, so nothing
    /// here is truncated), next to the pattern it would become.
    private var endpointOptionSubtitle: String {
        guard !requestPath.isEmpty else { return "This endpoint only" }
        var lines = ["Exact path: \(requestPath)"]
        if normalizedPath != requestPath {
            lines.append("As a pattern: \(normalizedPath)")
        }
        lines.append("Pick exact or pattern on the next screen.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Export / import

    private func makeTransferMenu() -> UIMenu {
        let export = UIAction(
            title: "Export All Rules…",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.exportAllRules()
        }
        let importRules = UIAction(
            title: "Import Rules…",
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
            self?.presentTransferHub()
        }
        let pickRules = UIAction(
            title: "Choose Rules to Export…",
            image: UIImage(systemName: "checklist")
        ) { [weak self] _ in
            self?.presentTransferHub()
        }
        return UIMenu(title: "Rules", children: [export, pickRules, importRules])
    }

    /// One tap → a JSON file of every rule in the share sheet. Selective export and
    /// the import flows (file / pasted JSON, both previewed) live in the transfer hub.
    private func exportAllRules() {
        let rules = InterceptRuleStore.shared.allRules()
        guard !rules.isEmpty else {
            showAlert(title: "No Rules", message: "There are no intercept rules on this device to export.")
            return
        }

        let document = RuleExporter.makeDocument(from: rules)
        let url: URL
        do {
            url = try RuleExporter.writeToTemporaryFile(document)
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
            return
        }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = transferItem
        present(activity, animated: true)
    }

    private func presentTransferHub() {
        let hub = RuleTransferViewController()
        let nav = SwiftyDebugNavigationController(rootViewController: hub)
        // Full screen so this list gets `viewWillAppear` back on dismissal and picks up
        // whatever the import added — a sheet would leave the rows stale.
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func toggleEdit() {
        tableView.setEditing(!tableView.isEditing, animated: true)
        navigationItem.rightBarButtonItems?.last?.title = tableView.isEditing ? "Done" : "Reorder"
    }

    private func editRule(_ rule: InterceptRule) {
        let editor = InterceptRuleEditorViewController()
        editor.httpModel = httpModel
        editor.existingRuleId = rule.id
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        ruleList.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RuleCell", for: indexPath) as! InterceptRuleCell
        let rule = ruleList[indexPath.row]
        cell.configure(with: rule, index: indexPath.row + 1)

        // Keyed on the rule's IDENTITY, never on `indexPath.row`. A swipe-delete
        // calls `deleteRows`, which shifts the surviving cells up WITHOUT
        // re-running this method, so a row-numbered toggle would then arm or
        // disarm whichever rule inherited the old index — silently blocking
        // requests or mocking responses in somebody's app. Same defect class as
        // the `tag = indexPath.row` switch this file used to carry.
        let ruleId = rule.id
        cell.onToggle = { [weak self] isEnabled in
            guard let self = self else { return }
            // NO-OP when the id is gone: the rule was deleted between this cell
            // being rendered and the switch being tapped, and there is nothing
            // left to write.
            guard let idx = self.ruleList.firstIndex(where: { $0.id == ruleId }) else { return }
            self.ruleList[idx].isEnabled = isEnabled
            InterceptRuleStore.shared.update(self.ruleList[idx])
        }
        return cell
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        editRule(ruleList[indexPath.row])
    }

    // Swipe to delete
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, ruleList.indices.contains(indexPath.row) else { return }
        let rule = ruleList[indexPath.row]
        ruleList.remove(at: indexPath.row)
        InterceptRuleStore.shared.remove(id: rule.id)
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [indexPath], with: .automatic)
        } completion: { [weak tableView] _ in
            // Every surviving row carries a printed "RULE #n" that `deleteRows`
            // does not rebuild. Reloading afterwards re-runs `cellForRowAt` for
            // the survivors, so no row is left describing a position it no
            // longer occupies.
            tableView?.reloadData()
        }
    }

    // Reorder
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let moved = ruleList.remove(at: sourceIndexPath.row)
        ruleList.insert(moved, at: destinationIndexPath.row)
        // ONE call with the whole visible order, not one call per endpoint
        // group. The store's `reorder(ids:for:)` treats the ids as authoritative
        // and re-orders them wherever they live, and a rule's bucket now depends
        // on its mode and host pin as well as its endpoint — so per-endpoint
        // calls would hand out position 0 several times over and the list would
        // not come back in the order the user just dragged it into.
        InterceptRuleStore.shared.reorder(ids: ruleList.map(\.id), for: requestPath)
        // The printed "RULE #n" on each card is now stale for every row between
        // source and destination. Reloaded on the next turn of the run loop:
        // this is called while UIKit is still committing the move animation, and
        // reloading inside that is what makes a table view assert.
        DispatchQueue.main.async { [weak tableView] in tableView?.reloadData() }
    }

    // Section header
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = UIColor(white: 0.5, alpha: 1)
        // Host included: rules can now be pinned to a host, so "which host am I
        // looking at?" is part of reading this list.
        let host = httpModel?.url?.host ?? ""
        label.text = host.isEmpty ? requestPath : host + requestPath
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 48 }
}

// MARK: - Rule Cell

private class InterceptRuleCell: UITableViewCell {

    private let cardView = UIView()
    private let indexLabel = UILabel()
    private let matchModeLabel = UILabel()
    private let summaryLabel = UILabel()
    private let detailLabel = UILabel()
    private let enableSwitch = UISwitch()

    var onToggle: ((Bool) -> Void)?

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

        cardView.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        indexLabel.font = .systemFont(ofSize: 11, weight: .bold)
        indexLabel.textColor = UIColor(white: 0.4, alpha: 1)
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(indexLabel)

        matchModeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        matchModeLabel.textAlignment = .center
        matchModeLabel.layer.cornerRadius = 4
        matchModeLabel.clipsToBounds = true
        matchModeLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(matchModeLabel)

        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = .white
        // Two lines: a rule's name is now a sentence ("Mock 404 + Breakpoint
        // after response"), not a two-word count, and the card is self-sizing
        // from contentView top to bottom so it grows rather than truncating.
        summaryLabel.numberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(summaryLabel)

        detailLabel.font = InterceptRuleRowFormatter.detailFont
        detailLabel.textColor = UIColor(white: 0.5, alpha: 1)
        detailLabel.numberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(detailLabel)

        enableSwitch.onTintColor = DebugTheme.accentColor
        enableSwitch.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        cardView.addSubview(enableSwitch)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            indexLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            indexLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),

            matchModeLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            matchModeLabel.centerYAnchor.constraint(equalTo: indexLabel.centerYAnchor),
            matchModeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
            matchModeLabel.heightAnchor.constraint(equalToConstant: 16),

            summaryLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            summaryLabel.topAnchor.constraint(equalTo: indexLabel.bottomAnchor, constant: 2),
            summaryLabel.trailingAnchor.constraint(equalTo: enableSwitch.leadingAnchor, constant: -12),

            detailLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            detailLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(equalTo: enableSwitch.leadingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),

            enableSwitch.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            enableSwitch.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
        ])

        forceLTR()
    }

    func configure(with rule: InterceptRule, index: Int) {
        indexLabel.text = "RULE #\(index)"

        // Match mode badge
        let mode = rule.matchMode
        matchModeLabel.text = " " + InterceptRuleRowFormatter.badge(for: mode) + " "
        matchModeLabel.textColor = InterceptRuleRowFormatter.color(for: mode)
        matchModeLabel.backgroundColor = InterceptRuleRowFormatter.color(for: mode).withAlphaComponent(0.15)

        // Lead with the rule's NAME. This used to count headers and query
        // parameters only, so a rule that mocked / blocked / breakpointed /
        // redirected / rewrote counted zero of both and read "Empty rule".
        summaryLabel.text = InterceptRuleRowFormatter.title(for: rule)
        summaryLabel.textColor = InterceptRuleRowFormatter.titleColor(for: rule)

        // Scope underneath, always — two rules can now legitimately share a name
        // and differ only in which host they are pinned to.
        detailLabel.text = InterceptRuleRowFormatter.detailText(for: rule)

        enableSwitch.isOn = rule.isEnabled
        contentView.alpha = rule.isEnabled ? 1 : 0.5
    }

    @objc private func switchChanged() {
        onToggle?(enableSwitch.isOn)
        contentView.alpha = enableSwitch.isOn ? 1 : 0.5
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        contentView.alpha = 1
    }
}
