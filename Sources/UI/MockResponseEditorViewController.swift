//
//  MockResponseEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Configures a canned response: pick a ready-made scenario (401, 404, 500, empty
/// list…) or build your own status + JSON body in the full editor. (See MOCK.)
///
/// Two modes, one screen:
///
/// * **Rule mode** — `init(mock:currentResponseText:)`. The mock belongs to an
///   intercept rule; Save hands it back through `onSave`. "Add to profile…" copies
///   the mock into a `MockProfile` so it can be replayed as part of a scenario.
/// * **Profile mode** — `init()` plus `editingProfileId` / `editingEntry`. The mock
///   *is* a profile entry, so it also owns the URL match and Save writes straight to
///   `MockProfileStore`. Nothing is stored until Save, so backing out discards a new
///   entry instead of leaving a blank row behind.
final class MockResponseEditorViewController: UITableViewController {

    // MARK: - Input

    private var mock: MockResponse
    /// The endpoint's real response, offered as a starting point. Rule mode only.
    private let currentResponseText: String?
    var onSave: ((MockResponse) -> Void)?

    /// Profile mode: the profile the entry belongs to. Set together with `editingEntry`.
    var editingProfileId: String = ""
    /// Profile mode: the entry being edited (a fresh `MockProfileEntry()` for a new one).
    var editingEntry: MockProfileEntry?

    /// Rule mode: what the rule matches, used to pre-fill "Add to profile…" so the
    /// copied mock answers the same requests the rule does.
    var endpointMatchMode: EndpointMatchMode = .normalized
    var endpointPattern: String = ""

    private var isProfileMode: Bool { editingEntry != nil }

    // MARK: - Profile-entry state

    private var entryMatchMode: EndpointMatchMode = .normalized
    private var entryPattern: String = ""

    // MARK: - Rows

    private enum Row {
        case matchMode, matchPattern
        case toggle, scenario, status
        case bodyEdit, bodyFromReal
        case delay
        case addToProfile
    }

    private struct SectionModel {
        let title: String?
        let rows: [Row]
    }

    private var sections: [SectionModel] = []

    // MARK: - Init

    init(mock: MockResponse, currentResponseText: String?) {
        self.mock = mock
        self.currentResponseText = currentResponseText
        super.init(style: .grouped)
    }

    /// Profile mode. Assign `editingProfileId` and `editingEntry` before pushing.
    init() {
        self.mock = MockResponse()
        self.currentResponseText = nil
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let entry = editingEntry {
            entryMatchMode = entry.matchMode
            entryPattern = entry.matchPattern
            mock = entry.mock
            // A brand-new entry arrives with the default (disabled) mock. An entry whose
            // mock is off never answers anything, so arm it rather than shipping a no-op.
            if entry.mock == MockResponse() { mock.isEnabled = true }
        }

        let titleLabel = UILabel()
        titleLabel.text = isProfileMode ? "Profile Mock" : "Mock Response"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.register(JSONEditorCardCell.self, forCellReuseIdentifier: JSONEditorCardCell.reuseIdentifier)
        rebuildSections()
        view.forceLTR()
    }

    private func rebuildSections() {
        var models: [SectionModel] = []
        if isProfileMode {
            models.append(SectionModel(title: "MATCH", rows: [.matchMode, .matchPattern]))
        }
        models.append(SectionModel(title: nil, rows: [.toggle]))
        models.append(SectionModel(title: "SCENARIOS", rows: [.scenario]))
        models.append(SectionModel(title: "STATUS", rows: [.status]))
        var body: [Row] = [.bodyEdit]
        if currentResponseText?.isEmpty == false { body.append(.bodyFromReal) }
        models.append(SectionModel(title: "BODY", rows: body))
        models.append(SectionModel(title: "TIMING", rows: [.delay]))
        if !isProfileMode, MockProfileStore.isFeatureEnabled {
            models.append(SectionModel(title: "PROFILES", rows: [.addToProfile]))
        }
        sections = models
    }

    private func reload() {
        rebuildSections()
        tableView.reloadData()
    }

    // MARK: - Save

    @objc private func saveTapped() {
        guard isProfileMode else {
            onSave?(mock)
            navigationController?.popViewController(animated: true)
            return
        }
        guard var entry = editingEntry, !editingProfileId.isEmpty else { return }

        let pattern = entryPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entryMatchMode == .global || !pattern.isEmpty else {
            showAlert(title: "Pattern Needed",
                      message: "Set the path (or host) this mock should answer, or switch the match to Global.")
            return
        }
        entry.matchMode = entryMatchMode
        entry.matchPattern = pattern
        entry.mock = mock
        MockProfileStore.shared.updateEntry(entry, inProfileId: editingProfileId)
        navigationController?.popViewController(animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    private func cell(_ style: UITableViewCell.CellStyle = .subtitle) -> UITableViewCell {
        let c = UITableViewCell(style: style, reuseIdentifier: nil)
        c.backgroundColor = UIColor(white: 0.11, alpha: 1)
        c.selectionStyle = .default
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        c.textLabel?.textColor = .white
        c.detailTextLabel?.font = .systemFont(ofSize: 11)
        c.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        c.detailTextLabel?.numberOfLines = 0
        c.forceLTR()
        return c
    }

    /// The body row is the shared JSON card, so opening a payload for editing
    /// looks and behaves the same here as in the replay editor, the breakpoint
    /// inbox and the storage editor.
    private func bodyCardCell(_ ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: JSONEditorCardCell.reuseIdentifier, for: ip) as! JSONEditorCardCell
        // The card is the only way into the editor here — an empty mock body has
        // to stay reachable, so it never hides itself.
        cell.cardView.alwaysVisible = true
        cell.cardView.showsPreview = true
        cell.cardView.detailText = "Open the tree editor to add, rename, retype or reorder fields."
        cell.cardView.configure(text: mock.body)
        cell.cardView.onTap = { [weak self] in self?.editBody() }
        return cell
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if case .bodyEdit = sections[ip.section].rows[ip.row] { return bodyCardCell(ip) }

        let c = cell()
        switch sections[ip.section].rows[ip.row] {
        case .matchMode:
            c.textLabel?.text = "Match"
            c.detailTextLabel?.text = Self.matchModeDescription(entryMatchMode)
            let value = UILabel()
            value.text = entryMatchMode.displayName
            value.font = .systemFont(ofSize: 12, weight: .bold)
            value.textColor = Self.color(forMatchMode: entryMatchMode)
            value.sizeToFit()
            c.accessoryView = value

        case .matchPattern:
            c.textLabel?.text = "Pattern"
            if entryMatchMode == .global {
                c.selectionStyle = .none
                c.detailTextLabel?.text = "All requests — no pattern needed."
                let value = UILabel()
                value.text = "All requests"
                value.font = .systemFont(ofSize: 12, weight: .semibold)
                value.textColor = .systemPink
                value.sizeToFit()
                c.accessoryView = value
            } else {
                c.detailTextLabel?.text = entryPattern.isEmpty
                    ? Self.patternPlaceholder(entryMatchMode)
                    : entryPattern
                c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                c.detailTextLabel?.textColor = entryPattern.isEmpty
                    ? UIColor(white: 0.4, alpha: 1)
                    : DebugTheme.accentColor
                c.accessoryType = .disclosureIndicator
            }

        case .toggle:
            c.selectionStyle = .none
            c.textLabel?.text = "Return a mock response"
            c.detailTextLabel?.text = "Matching requests never reach the network."
            let sw = UISwitch()
            sw.isOn = mock.isEnabled
            sw.onTintColor = DebugTheme.accentColor
            sw.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            c.accessoryView = sw

        case .scenario:
            c.textLabel?.text = "Pick a scenario"
            c.detailTextLabel?.text = "401, 404, 500, empty list and more — one tap."
            c.accessoryType = .disclosureIndicator

        case .status:
            c.textLabel?.text = "Status code"
            let meaning = HTTPURLResponse.localizedString(forStatusCode: mock.statusCode).capitalized
            c.detailTextLabel?.text = meaning
            let value = UILabel()
            value.text = "\(mock.statusCode)"
            value.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
            value.textColor = Self.color(forStatusCode: mock.statusCode)
            value.sizeToFit()
            c.accessoryView = value

        case .bodyEdit:
            break   // handled above by bodyCardCell(_:)

        case .bodyFromReal:
            c.textLabel?.text = "Start from the real response"
            c.textLabel?.textColor = DebugTheme.accentColor
            c.detailTextLabel?.text = "Copy this endpoint's actual response, then edit it."

        case .delay:
            c.textLabel?.text = "Delay"
            c.detailTextLabel?.text = "Simulate a slow endpoint before the mock returns."
            let value = UILabel()
            value.text = mock.delay > 0 ? String(format: "%.1fs", mock.delay) : "None"
            value.font = .systemFont(ofSize: 14, weight: .semibold)
            value.textColor = mock.delay > 0 ? DebugTheme.accentColor : UIColor(white: 0.5, alpha: 1)
            value.sizeToFit()
            c.accessoryView = value

        case .addToProfile:
            c.textLabel?.text = "Add to profile…"
            c.textLabel?.textColor = DebugTheme.accentColor
            let active = MockProfileStore.shared.activeProfile()
            c.detailTextLabel?.text = active == nil
                ? "Save this mock into a named scenario you can switch on later."
                : "Save into a scenario. “\(active!.name)” is active right now."
            let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            c.imageView?.image = UIImage(systemName: "rectangle.stack.badge.plus", withConfiguration: cfg)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            c.accessoryType = .disclosureIndicator
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch sections[ip.section].rows[ip.row] {
        case .matchMode:     pickMatchMode()
        case .matchPattern:  if entryMatchMode != .global { editPattern() }
        case .toggle:        break
        case .scenario:      pickScenario()
        case .status:        pickStatus()
        case .bodyEdit:      editBody()
        case .bodyFromReal:  useRealResponse()
        case .delay:         pickDelay()
        case .addToProfile:  addToProfileTapped()
        }
    }

    // MARK: - Status / match formatting

    /// Shared with the profile list rows, which show a mock without opening it.
    static func color(forStatusCode code: Int) -> UIColor {
        switch code {
        case 200..<300: return .systemGreen
        case 300..<400: return .systemTeal
        case 400..<500: return .systemOrange
        default:        return .systemRed
        }
    }

    static func color(forMatchMode mode: EndpointMatchMode) -> UIColor {
        switch mode {
        case .exact:      return .systemOrange
        case .normalized: return DebugTheme.accentColor
        case .host:       return .systemPurple
        case .global:     return .systemPink
        }
    }

    private static func matchModeDescription(_ mode: EndpointMatchMode) -> String {
        switch mode {
        case .exact:      return "Only this exact path."
        case .normalized: return "Every path with this shape (IDs replaced)."
        case .host:       return "Any URL starting with this host / prefix."
        case .global:     return "Every request the app makes."
        }
    }

    private static func patternPlaceholder(_ mode: EndpointMatchMode) -> String {
        switch mode {
        case .exact:      return "e.g. /api/users/42/orders"
        case .normalized: return "e.g. /api/users/{id}/orders"
        case .host:       return "e.g. api.example.com/v1"
        case .global:     return "All requests"
        }
    }

    // MARK: - Actions

    private func pickMatchMode() {
        let modes: [EndpointMatchMode] = [.normalized, .exact, .host, .global]
        let options = modes.map { mode in
            OptionPickerSheetViewController.Option(
                title: mode.displayName,
                subtitle: Self.matchModeDescription(mode),
                symbol: nil,
                tint: Self.color(forMatchMode: mode)
            ) { [weak self] in
                self?.entryMatchMode = mode
                self?.reload()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Match",
            message: "How this mock decides which requests it answers.",
            options: options, selectedIndex: modes.firstIndex(of: entryMatchMode))
    }

    private func editPattern() {
        let alert = UIAlertController(title: "Pattern",
                                      message: Self.matchModeDescription(entryMatchMode),
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            guard let self = self else { return }
            field.text = self.entryPattern
            field.placeholder = Self.patternPlaceholder(self.entryMatchMode)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            self?.entryPattern = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.reload()
        })
        present(alert, animated: true)
    }

    private func pickScenario() {
        let options = MockResponse.scenarios.map { s in
            OptionPickerSheetViewController.Option(
                title: s.title, subtitle: s.subtitle, symbol: nil, tint: Self.color(forStatusCode: s.statusCode)
            ) { [weak self] in
                guard let self else { return }
                self.mock.statusCode = s.statusCode
                self.mock.body = s.body
                self.mock.isEnabled = true
                self.tableView.reloadData()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Scenario",
            message: "Sets the status code and a matching body. You can edit the body afterwards.",
            options: options)
    }

    private func pickStatus() {
        let common = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 405, 409, 410,
                      422, 429, 500, 502, 503, 504]
        var options = common.map { code in
            OptionPickerSheetViewController.Option(
                title: "\(code)",
                subtitle: HTTPURLResponse.localizedString(forStatusCode: code).capitalized,
                symbol: nil, tint: Self.color(forStatusCode: code)
            ) { [weak self] in
                self?.mock.statusCode = code
                self?.tableView.reloadData()
            }
        }
        options.append(.init(title: "Custom…", subtitle: "Type any status code", symbol: "keyboard") { [weak self] in
            self?.promptCustomStatus()
        })
        OptionPickerSheetViewController.present(
            from: self, title: "Status code", message: nil, options: options,
            selectedIndex: common.firstIndex(of: mock.statusCode))
    }

    private func promptCustomStatus() {
        let a = UIAlertController(title: "Status code", message: nil, preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad; $0.text = "\(self.mock.statusCode)" }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak a] _ in
            guard let text = a?.textFields?.first?.text, let code = Int(text), (100...599).contains(code) else { return }
            self?.mock.statusCode = code
            self?.tableView.reloadData()
        })
        present(a, animated: true)
    }

    private func editBody() {
        let editor = JSONEditorViewController(text: mock.body, title: "Mock Body")
        editor.saveButtonTitle = "Use Body"
        editor.onSave = { [weak self] doc in
            self?.mock.body = doc.prettyText()
            self?.mock.isEnabled = true
            self?.tableView.reloadData()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func useRealResponse() {
        guard let text = currentResponseText, !text.isEmpty else { return }
        mock.body = JSONDocument(text: text)?.prettyText() ?? text
        mock.isEnabled = true
        tableView.reloadData()
        editBody()
    }

    private func pickDelay() {
        let choices: [Double] = [0, 0.5, 1, 2, 3, 5, 10]
        let options = choices.map { d in
            OptionPickerSheetViewController.Option(
                title: d == 0 ? "None" : String(format: "%.1f seconds", d),
                subtitle: nil, symbol: nil, tint: .white
            ) { [weak self] in
                self?.mock.delay = d
                self?.tableView.reloadData()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Delay",
            message: "Held for this long before the mock is returned.",
            options: options, selectedIndex: choices.firstIndex(of: mock.delay))
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        mock.isEnabled = sender.isOn
    }

    // MARK: - Add to profile

    /// Copies the mock being edited into a profile — an existing one, or a new one
    /// created on the spot. The rule keeps its own mock; the profile gets a copy, so
    /// switching the profile off leaves the rule exactly as it was.
    private func addToProfileTapped() {
        let picker = MockProfileListViewController()
        picker.pickerPrompt = "Add this mock to"
        picker.onProfilePicked = { [weak self] profile in
            guard let self = self else { return }
            self.dismiss(animated: true) { self.confirmAdd(to: profile) }
        }
        let nav = SwiftyDebugNavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    private func confirmAdd(to profile: MockProfile) {
        guard endpointMatchMode != .global else {
            store(pattern: "", in: profile)
            return
        }
        let alert = UIAlertController(
            title: "Add to “\(profile.name)”",
            message: "This mock answers requests matching:\n\(Self.matchModeDescription(endpointMatchMode))",
            preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            guard let self = self else { return }
            field.text = self.endpointPattern
            field.placeholder = Self.patternPlaceholder(self.endpointMatchMode)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let pattern = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                self.showAlert(title: "Pattern Needed",
                               message: "A profile mock needs to know which requests it answers.")
                return
            }
            self.store(pattern: pattern, in: profile)
        })
        present(alert, animated: true)
    }

    private func store(pattern: String, in profile: MockProfile) {
        var copy = mock
        // A mock that is switched off would sit in the profile doing nothing.
        copy.isEnabled = true
        let entry = MockProfileEntry(matchMode: endpointMatchMode, matchPattern: pattern, mock: copy)
        MockProfileStore.shared.addEntry(entry, toProfileId: profile.id)

        let active = MockProfileStore.shared.isActive(id: profile.id)
        showAlert(title: "Added to “\(profile.name)”",
                  message: active
                      ? "The profile is active, so this mock is answering now."
                      : "Activate “\(profile.name)” in Mock Profiles to serve it.")
    }
}

// MARK: - Mock summary

extension MockResponse {

    /// One short line describing a mock for rows that show it without opening it
    /// (the profile editor's entry cells). String work only — safe in `cellForRowAt`.
    var summaryText: String {
        var parts: [String] = [HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized]
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(trimmed.isEmpty ? "empty body" : "\(trimmed.count)-char body")
        if delay > 0 { parts.append(String(format: "%.1fs delay", delay)) }
        if !isEnabled { parts.append("mock off") }
        return parts.joined(separator: " · ")
    }
}
