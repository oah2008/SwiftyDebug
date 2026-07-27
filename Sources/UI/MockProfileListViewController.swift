//
//  MockProfileListViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Full-screen list of mock profiles: create, rename, duplicate, delete, activate.
///
/// Set `onProfilePicked` to reuse this screen as a picker (see
/// `MockResponseEditorViewController`'s "Add to Profile…"); in that mode tapping a
/// row hands the profile back instead of opening the editor.
class MockProfileListViewController: UITableViewController {

    // MARK: - Input

    /// Non-nil switches the screen into picker mode and is shown as the section header.
    var pickerPrompt: String?
    var onProfilePicked: ((MockProfile) -> Void)?

    private var isPickerMode: Bool { return onProfilePicked != nil }

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case status = 0
        case profiles = 1
    }

    // MARK: - State

    private var profiles: [MockProfile] = []
    private var activeId: String?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = isPickerMode ? "Add to Profile" : "Mock Profiles"
        view.backgroundColor = .black

        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(createProfileTapped))
        addItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = addItem

        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        let dynamicTable = UITableView(frame: .zero, style: .grouped)
        dynamicTable.dataSource = self
        dynamicTable.delegate = self
        self.tableView = dynamicTable

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.register(MockProfileCell.self, forCellReuseIdentifier: "ProfileCell")

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .mockProfilesDidChange, object: nil)

        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reload() {
        profiles = MockProfileStore.shared.allProfiles()
        activeId = MockProfileStore.shared.activeProfileId()
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func createProfileTapped() {
        promptForName(title: "New Profile", initial: "") { [weak self] name in
            guard let self = self else { return }
            let profile = MockProfileStore.shared.createProfile(name: name)
            self.reload()
            if self.isPickerMode {
                self.onProfilePicked?(profile)
            } else {
                self.openEditor(for: profile)
            }
        }
    }

    private func openEditor(for profile: MockProfile) {
        let editor = MockProfileEditorViewController()
        editor.profileId = profile.id
        navigationController?.pushViewController(editor, animated: true)
    }

    private func promptForName(title: String, initial: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: "Name this scenario.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Logged out"
            field.text = initial
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            completion(name.isEmpty ? "Untitled" : name)
        })
        present(alert, animated: true)
    }

    private func toggleActive(_ profile: MockProfile) {
        MockProfileStore.shared.toggleActive(id: profile.id)
        reload()
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return isPickerMode ? 1 : Section.allCases.count
    }

    /// Picker mode drops the status section, so section indexes shift by one.
    private func section(at index: Int) -> Section {
        return isPickerMode ? .profiles : (Section(rawValue: index) ?? .profiles)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch self.section(at: section) {
        case .status:   return 1
        case .profiles: return max(profiles.count, 1)  // one empty-state row when there are none
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if section(at: indexPath.section) == .status {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "StatusCell")
            cell.selectionStyle = activeId == nil ? .none : .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            if let active = profiles.first(where: { $0.id == activeId }) {
                cell.textLabel?.text = active.name
                cell.textLabel?.textColor = DebugTheme.accentColor
                cell.detailTextLabel?.text = "\(active.enabledEntryCount) mock\(active.enabledEntryCount == 1 ? "" : "s") active — tap to turn off"
            } else {
                cell.textLabel?.text = "No profile active"
                cell.textLabel?.textColor = UIColor(white: 0.6, alpha: 1)
                cell.detailTextLabel?.text = "Requests hit the network as normal"
            }
            cell.textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
            cell.forceLTR()
            return cell
        }

        // Empty state: `max(count, 1)` above means this row can exist with no profile behind it.
        guard profiles.indices.contains(indexPath.row) else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "EmptyCell")
            cell.selectionStyle = .none
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.text = "No profiles yet"
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            cell.textLabel?.textColor = UIColor(white: 0.6, alpha: 1)
            cell.detailTextLabel?.text = "Tap + to group a set of mocks into one scenario."
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
            cell.detailTextLabel?.numberOfLines = 2
            cell.forceLTR()
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath) as! MockProfileCell
        let profile = profiles[indexPath.row]
        cell.configure(with: profile, isActive: profile.id == activeId, showsActivateButton: !isPickerMode)
        cell.onActivateTapped = { [weak self] in
            self?.toggleActive(profile)
        }
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if section(at: indexPath.section) == .status {
            if activeId != nil {
                MockProfileStore.shared.deactivate()
                reload()
            }
            return
        }

        guard profiles.indices.contains(indexPath.row) else { return }
        let profile = profiles[indexPath.row]
        if let picked = onProfilePicked {
            picked(profile)
        } else {
            openEditor(for: profile)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard section(at: indexPath.section) == .profiles,
              profiles.indices.contains(indexPath.row) else { return nil }
        let profile = profiles[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            MockProfileStore.shared.remove(id: profile.id)
            self?.reload()
            done(true)
        }

        let duplicate = UIContextualAction(style: .normal, title: "Duplicate") { [weak self] _, _, done in
            MockProfileStore.shared.duplicate(id: profile.id)
            self?.reload()
            done(true)
        }
        duplicate.backgroundColor = UIColor(white: 0.3, alpha: 1)

        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, done in
            self?.promptForName(title: "Rename Profile", initial: profile.name) { newName in
                MockProfileStore.shared.rename(id: profile.id, to: newName)
                self?.reload()
            }
            done(true)
        }
        rename.backgroundColor = DebugTheme.accentColor

        return UISwipeActionsConfiguration(actions: [delete, duplicate, rename])
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let title: String
        switch self.section(at: section) {
        case .status:   title = "ACTIVE PROFILE"
        case .profiles: title = pickerPrompt?.uppercased() ?? "PROFILES\(profiles.isEmpty ? "" : " (\(profiles.count))")"
        }

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
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 40 }
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 0 }
}

// MARK: - Profile Cell

private class MockProfileCell: UITableViewCell {

    private let cardView = UIView()
    private let activateButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    var onActivateTapped: (() -> Void)?

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
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = UIColor.clear.cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        activateButton.translatesAutoresizingMaskIntoConstraints = false
        activateButton.addTarget(self, action: #selector(activateTapped), for: .touchUpInside)
        cardView.addSubview(activateButton)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(nameLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = UIColor(white: 0.5, alpha: 1)
        detailLabel.numberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            activateButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            activateButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            activateButton.widthAnchor.constraint(equalToConstant: 32),
            activateButton.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: activateButton.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            nameLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            detailLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    func configure(with profile: MockProfile, isActive: Bool, showsActivateButton: Bool) {
        nameLabel.text = profile.name

        var details: [String] = []
        if let note = profile.note, !note.isEmpty { details.append(note) }
        let count = profile.entries.count
        details.append("\(count) mock\(count == 1 ? "" : "s")")
        detailLabel.text = details.joined(separator: " · ")

        activateButton.isHidden = !showsActivateButton
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let iconName = isActive ? "checkmark.circle.fill" : "circle"
        let tint = isActive ? DebugTheme.accentColor : UIColor(white: 0.32, alpha: 1)
        activateButton.setImage(UIImage(systemName: iconName, withConfiguration: iconConfig)?
            .withTintColor(tint, renderingMode: .alwaysOriginal), for: .normal)

        cardView.layer.borderColor = (isActive ? DebugTheme.accentColor : UIColor.clear).cgColor
    }

    @objc private func activateTapped() {
        onActivateTapped?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivateTapped = nil
        cardView.layer.borderColor = UIColor.clear.cgColor
    }
}
