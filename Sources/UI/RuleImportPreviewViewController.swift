//
//  RuleImportPreviewViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Shows exactly what an import would do before anything is written: where the document came from,
/// how many rules are new / already present / clashing on id, and the two ways to apply it.
class RuleImportPreviewViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case source = 0
        case warnings = 1
        case rules = 2
        case actions = 3
    }

    private let plan: RuleImportPlan
    private var sourceRows: [(String, String)] = []

    var onFinish: ((RuleImportOutcome) -> Void)?

    init(plan: RuleImportPlan) {
        self.plan = plan
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Import Preview"
        view.backgroundColor = .black

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56

        buildSourceRows()
        view.forceLTR()
    }

    private func buildSourceRows() {
        let document = plan.document
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        sourceRows = [
            ("Summary", plan.summary),
            ("From", document.app.bundleId),
            ("App", [document.app.name, document.app.version, document.app.build.isEmpty ? "" : "(\(document.app.build))"]
                .filter { !$0.isEmpty }.joined(separator: " ")),
            ("Exported", formatter.string(from: document.exportedAt)),
            ("Schema", "v\(document.schemaVersion)"),
            ("On this device", "\(plan.existingCount) rule\(plan.existingCount == 1 ? "" : "s")"),
        ]
    }

    // MARK: - Apply

    private func mergeTapped() {
        let outcome = RuleImporter.apply(plan, strategy: .merge)
        onFinish?(outcome)
    }

    private func replaceTapped() {
        let alert = UIAlertController(
            title: "Replace All Rules?",
            message: "This deletes the \(plan.existingCount) rule\(plan.existingCount == 1 ? "" : "s") on this device and installs the \(plan.planned.count) from the file.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Replace", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let outcome = RuleImporter.apply(self.plan, strategy: .replace)
            self.onFinish?(outcome)
        })
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        alert.popoverPresentationController?.permittedArrowDirections = []
        present(alert, animated: true)
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .source:   return sourceRows.count
        case .warnings: return plan.document.warnings.count
        case .rules:    return plan.planned.count
        case .actions:  return 2
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .source:
            guard sourceRows.indices.contains(indexPath.row) else { return UITableViewCell() }
            let row = sourceRows[indexPath.row]
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = row.0
            cell.textLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            cell.textLabel?.textColor = UIColor(white: 0.6, alpha: 1)
            cell.detailTextLabel?.text = row.1
            cell.detailTextLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.detailTextLabel?.textColor = indexPath.row == 0 ? DebugTheme.accentColor : .white
            cell.detailTextLabel?.numberOfLines = 2
            cell.forceLTR()
            return cell

        case .warnings:
            guard plan.document.warnings.indices.contains(indexPath.row) else { return UITableViewCell() }
            let cell = RuleTransferViewController.makePlainCell(
                title: plan.document.warnings[indexPath.row],
                subtitle: nil,
                color: .systemYellow
            )
            cell.textLabel?.numberOfLines = 0
            return cell

        case .rules:
            guard plan.planned.indices.contains(indexPath.row) else { return UITableViewCell() }
            let item = plan.planned[indexPath.row]
            let rule = item.transferRule.rule
            let cell = RuleTransferViewController.makePlainCell(
                title: "",
                subtitle: RuleTransferFormatter.subtitle(for: rule),
                color: .white
            )
            cell.textLabel?.attributedText = RuleTransferFormatter.attributedTitle(for: rule)
            let badge = RuleImportPreviewViewController.dispositionBadge(item.disposition)
            let label = UILabel()
            label.text = " \(badge.text) "
            label.font = .systemFont(ofSize: 9, weight: .bold)
            label.textColor = badge.color
            label.backgroundColor = badge.color.withAlphaComponent(0.15)
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
            label.sizeToFit()
            label.frame = CGRect(x: 0, y: 0, width: label.frame.width + 4, height: 16)
            label.textAlignment = .center
            label.forceLTR()
            cell.accessoryView = label
            cell.contentView.alpha = item.disposition == .duplicate ? 0.5 : 1
            return cell

        case .actions:
            let isMerge = indexPath.row == 0
            let added = plan.planned.count - plan.duplicates.count
            let cell = RuleTransferViewController.makePlainCell(
                title: isMerge ? "Merge" : "Replace All",
                subtitle: isMerge
                    ? "Keeps your \(plan.existingCount) rule\(plan.existingCount == 1 ? "" : "s"), adds \(added), re-numbers \(plan.idCollisions.count) clashing id\(plan.idCollisions.count == 1 ? "" : "s")"
                    : "Deletes everything on this device, then installs the \(plan.planned.count) from the file",
                color: isMerge ? DebugTheme.accentColor : .systemRed
            )
            cell.selectionStyle = .default
            return cell
        }
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .actions else { return }
        indexPath.row == 0 ? mergeTapped() : replaceTapped()
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sec = Section(rawValue: section), tableView.numberOfRows(inSection: section) > 0 else { return nil }

        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = sec == .warnings ? .systemYellow : DebugTheme.accentColor
        label.text = headerTitle(for: sec)
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        header.forceLTR()
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return tableView.numberOfRows(inSection: section) > 0 ? 40 : 0
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 8 }

    private func headerTitle(for section: Section) -> String {
        switch section {
        case .source:   return "DOCUMENT"
        case .warnings: return "WARNINGS"
        case .rules:    return "RULES IN FILE (\(plan.planned.count))"
        case .actions:  return "APPLY"
        }
    }

    private static func dispositionBadge(_ disposition: RuleImportDisposition) -> (text: String, color: UIColor) {
        switch disposition {
        case .new:         return ("NEW", DebugTheme.accentColor)
        case .duplicate:   return ("EXISTS", UIColor(white: 0.5, alpha: 1))
        case .idCollision: return ("ID CLASH", .systemOrange)
        }
    }
}
