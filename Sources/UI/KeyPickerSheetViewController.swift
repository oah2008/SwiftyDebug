//
//  KeyPickerSheetViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Sheet-presented picker for selecting header/parameter keys.
/// Shows available keys from the original request plus an "Add Custom" option.
class KeyPickerSheetViewController: UITableViewController {

    var sheetTitle: String = "Select Key"
    var items: [(key: String, value: String)] = []
    var onItemSelected: (((key: String, value: String)) -> Void)?
    var onCustomSelected: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = sheetTitle
        view.backgroundColor = .black

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50
        view.forceLTR()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? items.count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: "CustomCell")
            cell.selectionStyle = .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = "Add Custom"
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            cell.textLabel?.textColor = DebugTheme.accentColor
            cell.textLabel?.textAlignment = .center
            cell.forceLTR()
            return cell
        }

        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "KeyCell")
        cell.selectionStyle = .default
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cell.textLabel?.text = item.key
        cell.textLabel?.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        cell.textLabel?.textColor = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
        cell.detailTextLabel?.text = item.value
        cell.detailTextLabel?.font = UIFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
        cell.detailTextLabel?.numberOfLines = 1
        cell.detailTextLabel?.lineBreakMode = .byTruncatingTail
        cell.forceLTR()
        return cell
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        dismiss(animated: true) { [self] in
            if indexPath.section == 1 {
                onCustomSelected?()
            } else {
                onItemSelected?(items[indexPath.row])
            }
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 0, !items.isEmpty else { return nil }
        let header = UIView()
        header.backgroundColor = .clear
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = UIColor(white: 0.5, alpha: 1)
        label.text = "FROM REQUEST"
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
        ])
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 && !items.isEmpty ? 32 : 8
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 0 }
}
