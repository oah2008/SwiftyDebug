//
//  MockResponseEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Configures a canned response for a rule: pick a ready-made scenario (401,
/// 404, 500, empty list…) or build your own status + JSON body in the full
/// editor. (See MOCK.)
final class MockResponseEditorViewController: UITableViewController {

    private var mock: MockResponse
    /// The endpoint's real response, offered as a starting point.
    private let currentResponseText: String?
    var onSave: ((MockResponse) -> Void)?

    private enum Section: Int, CaseIterable {
        case toggle, scenario, status, body, delay
    }

    init(mock: MockResponse, currentResponseText: String?) {
        self.mock = mock
        self.currentResponseText = currentResponseText
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Mock Response"
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
        view.forceLTR()
    }

    @objc private func saveTapped() {
        onSave?(mock)
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .body: return currentResponseText?.isEmpty == false ? 2 : 1
        default:    return 1
        }
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

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = cell()
        switch Section(rawValue: ip.section)! {
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
            value.textColor = statusColor(mock.statusCode)
            value.sizeToFit()
            c.accessoryView = value

        case .body:
            if ip.row == 0 {
                c.textLabel?.text = "Edit body"
                let preview = mock.body.trimmingCharacters(in: .whitespacesAndNewlines)
                c.detailTextLabel?.text = preview.isEmpty
                    ? "Empty — tap to build a JSON body"
                    : String(preview.prefix(160))
                c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                c.accessoryType = .disclosureIndicator
            } else {
                c.textLabel?.text = "Start from the real response"
                c.textLabel?.textColor = DebugTheme.accentColor
                c.detailTextLabel?.text = "Copy this endpoint's actual response, then edit it."
            }

        case .delay:
            c.textLabel?.text = "Delay"
            c.detailTextLabel?.text = "Simulate a slow endpoint before the mock returns."
            let value = UILabel()
            value.text = mock.delay > 0 ? String(format: "%.1fs", mock.delay) : "None"
            value.font = .systemFont(ofSize: 14, weight: .semibold)
            value.textColor = mock.delay > 0 ? DebugTheme.accentColor : UIColor(white: 0.5, alpha: 1)
            value.sizeToFit()
            c.accessoryView = value
        }
        return c
    }

    private func statusColor(_ code: Int) -> UIColor {
        switch code {
        case 200..<300: return .systemGreen
        case 300..<400: return .systemTeal
        case 400..<500: return .systemOrange
        default:        return .systemRed
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch Section(rawValue: ip.section)! {
        case .toggle: break
        case .scenario: pickScenario()
        case .status: pickStatus()
        case .body:
            if ip.row == 0 { editBody() } else { useRealResponse() }
        case .delay: pickDelay()
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .toggle:   return nil
        case .scenario: return "SCENARIOS"
        case .status:   return "STATUS"
        case .body:     return "BODY"
        case .delay:    return "TIMING"
        }
    }

    // MARK: - Actions

    private func pickScenario() {
        let options = MockResponse.scenarios.map { s in
            OptionPickerSheetViewController.Option(
                title: s.title, subtitle: s.subtitle, symbol: nil, tint: statusColor(s.statusCode)
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
                symbol: nil, tint: statusColor(code)
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
}
