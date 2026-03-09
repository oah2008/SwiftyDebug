//
//  InterceptRuleListViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Shows all intercept rules for a given endpoint.
/// Supports enable/disable, reorder, delete, and creating new rules.
class InterceptRuleListViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?
    var normalizedEndpoint: String = ""

    // MARK: - State

    private var ruleList: [InterceptRule] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Intercept Rules"
        view.backgroundColor = .black

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

        navigationItem.rightBarButtonItems = [addItem, editItem]

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
        ruleList = InterceptRuleStore.shared.rules(for: normalizedEndpoint)
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func addRuleTapped() {
        let editor = InterceptRuleEditorViewController()
        editor.httpModel = httpModel
        editor.existingRuleId = nil
        navigationController?.pushViewController(editor, animated: true)
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
        cell.onToggle = { [weak self] isEnabled in
            guard let self = self else { return }
            self.ruleList[indexPath.row].isEnabled = isEnabled
            InterceptRuleStore.shared.update(self.ruleList[indexPath.row])
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
        guard editingStyle == .delete else { return }
        let rule = ruleList[indexPath.row]
        ruleList.remove(at: indexPath.row)
        InterceptRuleStore.shared.remove(id: rule.id)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // Reorder
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let moved = ruleList.remove(at: sourceIndexPath.row)
        ruleList.insert(moved, at: destinationIndexPath.row)
        InterceptRuleStore.shared.reorder(ids: ruleList.map(\.id), for: normalizedEndpoint)
    }

    // Section header
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = UIColor(white: 0.5, alpha: 1)
        label.text = normalizedEndpoint
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

        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = .white
        summaryLabel.numberOfLines = 1
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(summaryLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = UIColor(white: 0.5, alpha: 1)
        detailLabel.numberOfLines = 2
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

        if rule.isBlocked {
            summaryLabel.text = "Block Request"
            summaryLabel.textColor = .systemRed
        } else {
            var parts: [String] = []
            let headerCount = rule.headerOverrides.count + rule.removedHeaderKeys.count
            let paramCount = rule.queryParamOverrides.count + rule.removedQueryParamKeys.count
            if headerCount > 0 { parts.append("\(headerCount) header\(headerCount == 1 ? "" : "s")") }
            if paramCount > 0 { parts.append("\(paramCount) param\(paramCount == 1 ? "" : "s")") }
            summaryLabel.text = parts.isEmpty ? "Empty rule" : parts.joined(separator: ", ")
            summaryLabel.textColor = .white
        }

        var details: [String] = []
        if !rule.headerOverrides.isEmpty {
            details.append("Override: " + rule.headerOverrides.map(\.key).joined(separator: ", "))
        }
        if !rule.removedHeaderKeys.isEmpty {
            details.append("Drop: " + rule.removedHeaderKeys.sorted().joined(separator: ", "))
        }
        detailLabel.text = details.isEmpty ? "Tap to edit" : details.joined(separator: " · ")

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
