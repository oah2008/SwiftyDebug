//
//  MockProfileEditorViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Full-screen editor for one mock profile: its name/note, the endpoints it mocks,
/// and whether it is the active scenario.
///
/// Entries are added by pushing `MockResponseEditorViewController`, which carries the
/// `MockResponse.scenarios` presets and the body editor — this screen never edits a
/// response itself.
class MockProfileEditorViewController: UITableViewController {

    // MARK: - Input

    var profileId: String = ""

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case info = 0
        case entries = 1
        case actions = 2
    }

    // MARK: - State

    private var profile: MockProfile?
    private var isActive: Bool = false

    private lazy var nameField: UITextField = makeField(placeholder: "Logged out")
    private lazy var noteField: UITextField = makeField(placeholder: "Optional note")

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Profile"
        view.backgroundColor = .black

        let dynamicTable = UITableView(frame: .zero, style: .grouped)
        dynamicTable.dataSource = self
        dynamicTable.delegate = self
        self.tableView = dynamicTable

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.keyboardDismissMode = .interactive
        tableView.register(MockEntryCell.self, forCellReuseIdentifier: "EntryCell")

        nameField.addTarget(self, action: #selector(nameEditingEnded), for: .editingDidEnd)
        noteField.addTarget(self, action: #selector(noteEditingEnded), for: .editingDidEnd)

        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        profile = MockProfileStore.shared.profile(id: profileId)
        isActive = MockProfileStore.shared.isActive(id: profileId)
        title = profile?.name ?? "Profile"
        nameField.text = profile?.name
        noteField.text = profile?.note
        tableView.reloadData()
    }

    private var entries: [MockProfileEntry] {
        return profile?.entries ?? []
    }

    // MARK: - Actions

    @objc private func nameEditingEnded() {
        let name = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty, name != profile?.name else { return }
        MockProfileStore.shared.rename(id: profileId, to: name)
        profile?.name = name
        title = name
    }

    @objc private func noteEditingEnded() {
        guard var current = profile else { return }
        let note = noteField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let newNote: String? = note.isEmpty ? nil : note
        guard newNote != current.note else { return }
        current.note = newNote
        MockProfileStore.shared.addOrUpdate(current)
        profile = current
    }

    @objc private func addEntryTapped() {
        view.endEditing(true)
        pushEntryEditor(for: MockProfileEntry())
    }

    private func pushEntryEditor(for entry: MockProfileEntry) {
        let editor = MockResponseEditorViewController()
        editor.editingProfileId = profileId
        editor.editingEntry = entry
        navigationController?.pushViewController(editor, animated: true)
    }

    private func setEntry(id entryId: String, enabled: Bool) {
        guard var entry = entries.first(where: { $0.id == entryId }) else { return }
        entry.isEnabled = enabled
        MockProfileStore.shared.updateEntry(entry, inProfileId: profileId)
        profile = MockProfileStore.shared.profile(id: profileId)
    }

    private func activateTapped() {
        MockProfileStore.shared.toggleActive(id: profileId)
        reload()
    }

    private func deleteProfileTapped() {
        let alert = UIAlertController(title: "Delete Profile?",
                                      message: "“\(profile?.name ?? "")” and its \(entries.count) mock\(entries.count == 1 ? "" : "s") will be removed.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            MockProfileStore.shared.remove(id: self.profileId)
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - Cell factory

    private func makeField(placeholder: String) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = UIColor(white: 0.88, alpha: 1)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
        )
        field.autocorrectionType = .no
        field.keyboardAppearance = .dark
        field.tintColor = DebugTheme.accentColor
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// The fields are controller-owned (cells here are built fresh each time), so
    /// re-parenting them into the new cell is intentional.
    private func makeFieldCell(title: String, field: UITextField, id: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: id)
        cell.selectionStyle = .none
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(label)

        field.removeFromSuperview()
        cell.contentView.addSubview(field)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
        cell.forceLTR()
        return cell
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .info:    return 2
        case .entries: return max(entries.count, 1)  // one empty-state row when there are none
        case .actions: return 2
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {

        case .info:
            return indexPath.row == 0
                ? makeFieldCell(title: "Name", field: nameField, id: "NameCell")
                : makeFieldCell(title: "Note", field: noteField, id: "NoteCell")

        case .entries:
            // Empty state: `max(count, 1)` above means this row can exist with no entry behind it.
            guard entries.indices.contains(indexPath.row) else {
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "EmptyEntryCell")
                cell.selectionStyle = .none
                cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
                cell.textLabel?.text = "No mocks in this profile"
                cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                cell.textLabel?.textColor = UIColor(white: 0.6, alpha: 1)
                cell.detailTextLabel?.text = "Tap Add to pick a preset or paste a body."
                cell.detailTextLabel?.font = .systemFont(ofSize: 11)
                cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
                cell.detailTextLabel?.numberOfLines = 2
                cell.forceLTR()
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "EntryCell", for: indexPath) as! MockEntryCell
            // Cells are reused — capture the entry's id, never the row index.
            let entryId = entries[indexPath.row].id
            cell.configure(with: entries[indexPath.row])
            cell.onToggle = { [weak self] isEnabled in
                self?.setEntry(id: entryId, enabled: isEnabled)
            }
            return cell

        case .actions:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ActionCell")
            cell.selectionStyle = .default
            cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            cell.textLabel?.textAlignment = .center
            cell.detailTextLabel?.font = .systemFont(ofSize: 11)
            cell.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
            cell.detailTextLabel?.textAlignment = .center
            if indexPath.row == 0 {
                cell.textLabel?.text = isActive ? "Deactivate Profile" : "Activate Profile"
                cell.textLabel?.textColor = isActive ? .systemOrange : DebugTheme.accentColor
                cell.detailTextLabel?.text = isActive
                    ? "Currently answering matching requests"
                    : "Activating turns off any other profile"
            } else {
                cell.textLabel?.text = "Delete Profile"
                cell.textLabel?.textColor = .systemRed
                cell.detailTextLabel?.text = nil
            }
            cell.forceLTR()
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .entries:
            guard entries.indices.contains(indexPath.row) else { return }
            pushEntryEditor(for: entries[indexPath.row])
        case .actions:
            indexPath.row == 0 ? activateTapped() : deleteProfileTapped()
        case .info:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return Section(rawValue: indexPath.section) == .entries && entries.indices.contains(indexPath.row)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        MockProfileStore.shared.removeEntry(id: entries[indexPath.row].id, fromProfileId: profileId)
        profile = MockProfileStore.shared.profile(id: profileId)
        // Deleting the last entry swaps the row for the empty state, so reload instead of animating it away.
        if entries.isEmpty {
            tableView.reloadSections(IndexSet([Section.entries.rawValue]), with: .automatic)
        } else {
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sec = Section(rawValue: section), sec != .actions else { return nil }

        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = DebugTheme.accentColor
        label.text = sec == .info ? "PROFILE" : "MOCKS\(entries.isEmpty ? "" : " (\(entries.count))")"
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        if sec == .entries {
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
            addButton.setImage(UIImage(systemName: "plus", withConfiguration: iconConfig)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal), for: .normal)
            addButton.setTitle("Add", for: .normal)
            addButton.addTarget(self, action: #selector(addEntryTapped), for: .touchUpInside)

            header.addSubview(addButton)
            NSLayoutConstraint.activate([
                addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
                addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return Section(rawValue: section) == .actions ? 20 : 40
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 0 }
}

// MARK: - Entry Cell

private class MockEntryCell: UITableViewCell {

    private let cardView = UIView()
    private let modeLabel = UILabel()
    private let statusLabel = UILabel()
    private let patternLabel = UILabel()
    private let summaryLabel = UILabel()
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

        modeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        modeLabel.textAlignment = .center
        modeLabel.layer.cornerRadius = 4
        modeLabel.clipsToBounds = true
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(modeLabel)

        statusLabel.font = .systemFont(ofSize: 11, weight: .bold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLabel)

        patternLabel.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        patternLabel.textColor = .white
        patternLabel.numberOfLines = 1
        patternLabel.lineBreakMode = .byTruncatingMiddle
        patternLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(patternLabel)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = UIColor(white: 0.5, alpha: 1)
        summaryLabel.numberOfLines = 1
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(summaryLabel)

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

            modeLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            modeLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            modeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            modeLabel.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),

            patternLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            patternLabel.trailingAnchor.constraint(equalTo: enableSwitch.leadingAnchor, constant: -12),
            patternLabel.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 4),

            summaryLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            summaryLabel.trailingAnchor.constraint(equalTo: enableSwitch.leadingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: patternLabel.bottomAnchor, constant: 3),
            summaryLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),

            enableSwitch.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            enableSwitch.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
        ])

        forceLTR()
    }

    func configure(with entry: MockProfileEntry) {
        modeLabel.text = " \(entry.matchMode.displayName) "
        let modeColor: UIColor
        switch entry.matchMode {
        case .exact:      modeColor = .systemOrange
        case .normalized: modeColor = DebugTheme.accentColor
        case .host:       modeColor = .systemPurple
        case .global:     modeColor = .systemPink
        }
        modeLabel.textColor = modeColor
        modeLabel.backgroundColor = modeColor.withAlphaComponent(0.15)

        statusLabel.text = "\(entry.mock.statusCode)"
        statusLabel.textColor = MockResponseEditorViewController.color(forStatusCode: entry.mock.statusCode)

        patternLabel.text = entry.displayPattern
        summaryLabel.text = entry.mock.summaryText

        enableSwitch.isOn = entry.isEnabled
        contentView.alpha = entry.isEnabled ? 1 : 0.5
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
