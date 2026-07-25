//
//  UserDefaultsBrowserViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - Model

/// One `UserDefaults.standard` entry, with its detected storage type.
private struct UserDefaultsEntry {
    let key: String
    let value: Any
    let type: UserDefaultsValueType
}

/// The concrete type a defaults value round-trips as. Editing must write the
/// *same* type back — an `Int` must never silently become a `String`.
private enum UserDefaultsValueType {
    case string, int, double, bool, data, array, dictionary, date, url

    var title: String {
        switch self {
        case .string:     return "STRING"
        case .int:        return "INT"
        case .double:     return "DOUBLE"
        case .bool:       return "BOOL"
        case .data:       return "DATA"
        case .array:      return "ARRAY"
        case .dictionary: return "DICT"
        case .date:       return "DATE"
        case .url:        return "URL"
        }
    }

    /// Only scalars can be safely re-typed from a single text field.
    var isEditable: Bool {
        switch self {
        case .string, .int, .double, .bool, .url: return true
        case .data, .array, .dictionary, .date:   return false
        }
    }

    var pillColor: UIColor {
        switch self {
        case .string:     return UIColor(red: 0.42, green: 0.66, blue: 0.98, alpha: 1)
        case .url:        return UIColor(red: 0.45, green: 0.74, blue: 0.98, alpha: 1)
        case .int:        return UIColor(red: 0.98, green: 0.72, blue: 0.35, alpha: 1)
        case .double:     return UIColor(red: 0.96, green: 0.62, blue: 0.42, alpha: 1)
        case .bool:       return UIColor(red: 0.55, green: 0.86, blue: 0.52, alpha: 1)
        case .data:       return UIColor(red: 0.78, green: 0.60, blue: 0.95, alpha: 1)
        case .array:      return UIColor(red: 0.95, green: 0.55, blue: 0.72, alpha: 1)
        case .dictionary: return UIColor(red: 0.90, green: 0.52, blue: 0.85, alpha: 1)
        case .date:       return UIColor(red: 0.60, green: 0.80, blue: 0.80, alpha: 1)
        }
    }

    /// Type sniffing that survives Foundation's NSNumber bridging: a stored
    /// `Bool` and a stored `Int` are both `NSNumber`, told apart by CFType.
    static func detect(_ value: Any) -> UserDefaultsValueType {
        if value is Data { return .data }
        if value is Date { return .date }
        if value is URL  { return .url }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool }
            switch CFNumberGetType(number) {
            case .float32Type, .float64Type, .floatType, .doubleType, .cgFloatType:
                return .double
            default:
                return .int
            }
        }
        if let string = value as? String {
            if let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty,
               url.host != nil || scheme == "file" {
                return .url
            }
            return .string
        }
        if value is [Any] || value is NSArray { return .array }
        if value is [AnyHashable: Any] || value is NSDictionary { return .dictionary }
        return .string
    }
}

// MARK: - Browser

/// Inspector / editor for the **host app's own** persisted defaults.
///
/// The listing comes from `persistentDomain(forName: Bundle.main.bundleIdentifier)`,
/// which returns exactly the app domain — no `NSGlobalDomain`, no registration
/// domain, no Apple language/locale keys. That is deliberate: reading
/// `dictionaryRepresentation()` merges all of those in and forces a prefix
/// blocklist to guess what belongs to the app.
///
/// Tapping a scalar row expands it into an inline `KeyValueCardCell` that writes
/// back with the original type. Containers (Array/Dictionary/Data/Date) expand
/// read-only, pretty-printed as JSON where possible.
final class UserDefaultsBrowserViewController: UITableViewController {

    // MARK: State

    private var entries: [UserDefaultsEntry] = []      // app domain, filtered by search
    /// Number of keys in the app domain before the search filter.
    private var domainCount = 0
    private var searchText = ""
    /// The key currently expanded for editing / read-only inspection.
    private var expandedKey: String?

    private let titleLabel = UILabel()
    private let searchController = UISearchController(searchResultsController: nil)
    private let toast = UILabel()

    /// The app's own persisted defaults, or `nil` when there is no bundle
    /// identifier / no app domain at all. Never falls back to
    /// `dictionaryRepresentation()` — that would reintroduce the system noise
    /// this screen exists to keep out.
    private static func appDomain() -> [String: Any]? {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return nil }
        guard let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return nil }
        // SwiftyDebug is embedded in the host app, so its own settings live in
        // the same domain. Hide them — this screen is for *your app's* data,
        // not the debugger's. (See SettingsKey.isSDKOwned.)
        return domain.filter { !SettingsKey.isSDKOwned($0.key) }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Init

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        titleLabel.text = "User Defaults"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped)),
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                            target: self, action: #selector(copyAllTapped)),
        ]
        navigationItem.rightBarButtonItems?.forEach { $0.tintColor = DebugTheme.accentColor }

        // Search
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Filter by key"
        searchController.searchBar.searchBarStyle = .minimal
        searchController.searchBar.tintColor = DebugTheme.accentColor
        searchController.searchBar.barStyle = .black
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.searchTextField.textColor = .white
        searchController.searchBar.searchTextField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
        tableView.register(UserDefaultsRowCell.self, forCellReuseIdentifier: UserDefaultsRowCell.reuseID)
        tableView.register(UserDefaultsReadOnlyCell.self, forCellReuseIdentifier: UserDefaultsReadOnlyCell.reuseID)
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 24, right: 0)

        // Toast
        toast.backgroundColor = UIColor(white: 0.16, alpha: 0.97)
        toast.textColor = .white
        toast.font = .systemFont(ofSize: 13, weight: .semibold)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 12
        toast.layer.cornerCurve = .continuous
        toast.clipsToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            toast.heightAnchor.constraint(equalToConstant: 38),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])

        reload()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: Loading

    private func reload() {
        // Single source of truth: the app's own persistent domain.
        let domain = Self.appDomain() ?? [:]
        domainCount = domain.count

        var rows = domain
            .map { UserDefaultsEntry(key: $0.key, value: $0.value, type: UserDefaultsValueType.detect($0.value)) }

        if !searchText.isEmpty {
            rows = rows.filter { $0.key.range(of: searchText, options: .caseInsensitive) != nil }
        }
        // App keys read alphabetically (case-insensitive so `zKey` doesn't sort
        // above `Alpha`).
        entries = rows.sorted { $0.key.compare($1.key, options: .caseInsensitive) == .orderedAscending }

        if let expanded = expandedKey, !entries.contains(where: { $0.key == expanded }) {
            expandedKey = nil
        }

        titleLabel.text = "User Defaults · \(domainCount)"
        titleLabel.sizeToFit()
        tableView.reloadData()
    }

    private func entry(forKey key: String) -> UserDefaultsEntry? {
        entries.first { $0.key == key }
    }

    // MARK: Actions

    @objc private func addTapped() {
        view.endEditing(true)
        let existing = Set((Self.appDomain() ?? [:]).keys)
        let add = UserDefaultsAddEntryViewController(existingKeys: existing)
        add.onSave = { [weak self] key, value in
            UserDefaults.standard.set(value, forKey: key)
            guard let self else { return }
            // A new key may be invisible under the current search — clear
            // the search so the user actually sees what they just added.
            self.searchText = ""
            self.searchController.searchBar.text = ""
            self.expandedKey = key
            self.reload()
            if let row = self.entries.firstIndex(where: { $0.key == key }) {
                self.tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: true)
            }
            self.showToast("Added “\(key)”")
        }

        // House nav controller: dark style, forced LTR and the iOS 26 nav-bar
        // treatment all come for free — don't hand-roll the appearance here.
        let nav = SwiftyDebugNavigationController(rootViewController: add)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    @objc private func copyAllTapped() {
        view.endEditing(true)
        var object: [String: Any] = [:]
        for entry in entries { object[entry.key] = Self.jsonSafe(entry.value) }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let pretty = JSONExporter.prettyJSONString(from: data) else {
            showToast("Nothing to copy")
            return
        }
        UIPasteboard.general.string = pretty
        showToast("Copied \(entries.count) key\(entries.count == 1 ? "" : "s")")
    }

    /// Converts a defaults value into something `JSONSerialization` accepts,
    /// losslessly where JSON allows and descriptively where it doesn't.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            // JSON blobs stored as Data inline as real JSON; anything else is
            // base64 so the export stays valid JSON.
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return object
            }
            return "<data \(data.count) bytes> " + data.base64EncodedString()
        case let date as Date:
            return isoFormatter.string(from: date)
        case let url as URL:
            return url.absoluteString
        case let string as String:
            return string
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number
        case let array as [Any]:
            return array.map { jsonSafe($0) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonSafe($0) }
        case let dictionary as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dictionary { out[String(describing: k)] = jsonSafe(v) }
            return out
        default:
            return String(describing: value)
        }
    }

    // MARK: Writing

    private enum CommitResult {
        case unchanged
        case written
        case invalid(String)
    }

    /// Writes `text` back under `entry.key` **using the original type**.
    private func commit(text: String, to entry: UserDefaultsEntry) -> CommitResult {
        guard text != Self.editableString(for: entry) else { return .unchanged }
        let defaults = UserDefaults.standard
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch entry.type {
        case .bool:
            let token = trimmed.lowercased()
            if ["true", "1", "yes", "y", "on"].contains(token) {
                defaults.set(true, forKey: entry.key)
            } else if ["false", "0", "no", "n", "off"].contains(token) {
                defaults.set(false, forKey: entry.key)
            } else {
                return .invalid("“\(trimmed)” isn’t a Bool.\nUse true / false / 1 / 0.")
            }
        case .int:
            guard let intValue = Int(trimmed) else {
                return .invalid("“\(trimmed)” isn’t a whole number.\n\(entry.key) is stored as an Int.")
            }
            defaults.set(intValue, forKey: entry.key)
        case .double:
            guard let doubleValue = Double(trimmed) else {
                return .invalid("“\(trimmed)” isn’t a number.\n\(entry.key) is stored as a Double.")
            }
            defaults.set(doubleValue, forKey: entry.key)
        case .string, .url:
            // URLs live in defaults as strings — keep them strings.
            defaults.set(text, forKey: entry.key)
        case .data, .array, .dictionary, .date:
            return .invalid("\(entry.type.title) values are read-only here.")
        }
        return .written
    }

    /// Text shown inside the editable field (round-trips through `commit`).
    private static func editableString(for entry: UserDefaultsEntry) -> String {
        switch entry.type {
        case .bool:
            return ((entry.value as? NSNumber)?.boolValue ?? false) ? "true" : "false"
        case .int:
            return "\((entry.value as? NSNumber)?.int64Value ?? 0)"
        case .double:
            return "\((entry.value as? NSNumber)?.doubleValue ?? 0)"
        case .string:
            return entry.value as? String ?? String(describing: entry.value)
        case .url:
            if let url = entry.value as? URL { return url.absoluteString }
            return entry.value as? String ?? String(describing: entry.value)
        default:
            return Self.previewString(for: entry)
        }
    }

    /// One-glance preview for the collapsed row.
    private static func previewString(for entry: UserDefaultsEntry) -> String {
        switch entry.type {
        case .bool, .int, .double, .string, .url:
            let raw = editableString(for: entry)
            return raw.count > 400 ? String(raw.prefix(400)) + "…" : raw
        case .date:
            guard let date = entry.value as? Date else { return String(describing: entry.value) }
            return dateFormatter.string(from: date)
        case .data:
            let data = entry.value as? Data ?? Data()
            return "\(data.count) byte\(data.count == 1 ? "" : "s")"
        case .array:
            let count = (entry.value as? NSArray)?.count ?? 0
            return "\(count) item\(count == 1 ? "" : "s")"
        case .dictionary:
            let count = (entry.value as? NSDictionary)?.count ?? 0
            return "\(count) key\(count == 1 ? "" : "s")"
        }
    }

    /// Full pretty-printed body for the expanded read-only card.
    private static func readOnlyBody(for entry: UserDefaultsEntry) -> String {
        switch entry.type {
        case .date:
            guard let date = entry.value as? Date else { return String(describing: entry.value) }
            return dateFormatter.string(from: date)
                + "\n" + isoFormatter.string(from: date)
                + "\nepoch \(date.timeIntervalSince1970)"
        case .data:
            let data = entry.value as? Data ?? Data()
            if let json = JSONExporter.prettyJSONString(from: data) { return json }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
            let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "\(data.count) bytes\n\(hex)\(data.count > 256 ? " …" : "")"
        case .array, .dictionary:
            let safe = jsonSafe(entry.value)
            if JSONSerialization.isValidJSONObject(safe),
               let data = try? JSONSerialization.data(withJSONObject: safe, options: []),
               let json = JSONExporter.prettyJSONString(from: data) {
                return json
            }
            return String(describing: entry.value)
        default:
            return editableString(for: entry)
        }
    }

    // MARK: Table data

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(entries.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard !entries.isEmpty else { return emptyCell() }

        let entry = entries[indexPath.row]
        let isExpanded = entry.key == expandedKey

        // Expanded + editable → the shared inline editor card.
        if isExpanded && entry.type.isEditable {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: indexPath) as! KeyValueCardCell
            cell.showsModeControl = false
            // Renaming a defaults key would mean delete+recreate; keys are locked.
            cell.configure(key: entry.key, value: Self.editableString(for: entry),
                           removing: false, keyEditable: false)
            cell.valueField.keyboardType = (entry.type == .int || entry.type == .double)
                ? .numbersAndPunctuation : .default
            cell.valueField.keyboardAppearance = .dark
            cell.valueField.delegate = self
            // Commit on *end* of editing, not per keystroke: parsing every
            // intermediate character would reject "-" or "1." mid-typing.
            cell.valueField.removeTarget(self, action: nil, for: .editingDidEnd)
            cell.valueField.addTarget(self, action: #selector(valueEditingDidEnd(_:)), for: .editingDidEnd)
            return cell
        }

        // Expanded + container → read-only pretty print.
        if isExpanded {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: UserDefaultsReadOnlyCell.reuseID, for: indexPath) as! UserDefaultsReadOnlyCell
            let body = Self.readOnlyBody(for: entry)
            cell.configure(key: entry.key, type: entry.type, body: body)
            cell.onCopy = { [weak self] in
                UIPasteboard.general.string = body
                self?.showToast("Copied value")
            }
            return cell
        }

        let cell = tableView.dequeueReusableCell(
            withIdentifier: UserDefaultsRowCell.reuseID, for: indexPath) as! UserDefaultsRowCell
        cell.configure(key: entry.key, type: entry.type, preview: Self.previewString(for: entry))
        return cell
    }

    private func emptyCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "empty")
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.textLabel?.text = searchText.isEmpty ? "No defaults" : "No key matches “\(searchText)”"
        cell.textLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        cell.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        cell.textLabel?.textAlignment = .center
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = searchText.isEmpty
            ? "This app hasn't persisted any defaults yet. Tap + to add a key."
            : "Clear the search to see every key this app stores."
        cell.detailTextLabel?.textColor = UIColor(white: 0.35, alpha: 1)
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        cell.detailTextLabel?.textAlignment = .center
        cell.detailTextLabel?.numberOfLines = 0
        cell.forceLTR()
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !entries.isEmpty, indexPath.row < entries.count else { return }
        // Flush any in-flight edit before the cell goes away.
        view.endEditing(true)

        let key = entries[indexPath.row].key
        expandedKey = (expandedKey == key) ? nil : key
        tableView.reloadData()

        guard expandedKey != nil,
              let row = entries.firstIndex(where: { $0.key == key }) else { return }
        let target = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: target, at: .middle, animated: true)
        if entries[row].type.isEditable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                (self?.tableView.cellForRow(at: target) as? KeyValueCardCell)?.valueField.becomeFirstResponder()
            }
        }
    }

    // MARK: Delete

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !entries.isEmpty && indexPath.row < entries.count
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard !entries.isEmpty, indexPath.row < entries.count else { return nil }
        let key = entries[indexPath.row].key
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(key: key, completion: done)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func confirmDelete(key: String, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Delete “\(key)”?",
            message: "This removes the key from UserDefaults.standard immediately. It can't be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            UserDefaults.standard.removeObject(forKey: key)
            completion(true)
            guard let self else { return }
            if self.expandedKey == key { self.expandedKey = nil }
            self.reload()
            self.showToast("Deleted “\(key)”")
        })
        present(alert, animated: true)
    }

    // MARK: Footer

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let domain = Bundle.main.bundleIdentifier ?? "—"
        return "Showing \(entries.count) of \(domainCount) key\(domainCount == 1 ? "" : "s") in this app's own domain (\(domain)). System and global defaults are never listed. Tap a row to edit it inline; edits are written when you finish editing and keep the original type. Swipe left to delete."
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = UIColor(white: 0.45, alpha: 1)
        footer.textLabel?.font = .systemFont(ofSize: 11)
        footer.textLabel?.numberOfLines = 0
        footer.contentView.backgroundColor = .black
        footer.forceLTR()
    }

    // MARK: Commit plumbing

    @objc private func valueEditingDidEnd(_ field: UITextField) {
        // The owning card knows the key (the key field is locked, so it's exact).
        guard let card = field.enclosingKeyValueCard(),
              let key = card.keyField.text, !key.isEmpty,
              let entry = entry(forKey: key) else { return }

        switch commit(text: field.text ?? "", to: entry) {
        case .unchanged:
            break
        case .written:
            reload()
            showToast("Saved “\(key)”")
        case .invalid(let reason):
            field.text = Self.editableString(for: entry)   // put the good value back
            let alert = UIAlertController(title: "Can't save \(entry.type.title)",
                                          message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: Toast

    private func showToast(_ message: String) {
        toast.text = "  \(message)  "
        view.bringSubviewToFront(toast)
        toast.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 1.0) { self.toast.alpha = 0 }
        }
    }
}

// MARK: - Search

extension UserDefaultsBrowserViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != searchText else { return }
        searchText = text
        reload()
    }
}

// MARK: - Keyboard

extension UserDefaultsBrowserViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()   // triggers the commit above
        return true
    }
}

// MARK: - Collapsed row card

/// Read-only summary card: key on its own line, value on its own line, with the
/// detected type as a pill.
private final class UserDefaultsRowCell: UITableViewCell {

    static let reuseID = "UserDefaultsRowCell"

    private let card = UIView()
    private let keyCaption = UILabel()
    private let keyLabel = UILabel()
    private let typePill = PillLabel()
    private let lockPill = PillLabel()
    private let separator = UIView()
    private let valueCaption = UILabel()
    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        for caption in [keyCaption, valueCaption] {
            caption.font = .systemFont(ofSize: 10, weight: .heavy)
            caption.textColor = UIColor(white: 0.45, alpha: 1)
        }
        keyCaption.text = "KEY"
        valueCaption.text = "VALUE"

        keyLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.numberOfLines = 2
        keyLabel.lineBreakMode = .byTruncatingMiddle

        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = UIColor(white: 0.88, alpha: 1)
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingTail

        lockPill.configure(text: "READ-ONLY", color: UIColor(white: 0.55, alpha: 1))

        separator.backgroundColor = UIColor(white: 0.22, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let topRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), lockPill, typePill])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [topRow, keyLabel, separator, valueCaption, valueLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(10, after: keyLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    fileprivate func configure(key: String, type: UserDefaultsValueType, preview: String) {
        keyLabel.text = key
        valueLabel.text = preview.isEmpty ? "(empty)" : preview
        valueLabel.textColor = preview.isEmpty
            ? UIColor(white: 0.40, alpha: 1) : UIColor(white: 0.88, alpha: 1)
        typePill.configure(text: type.title, color: type.pillColor)
        lockPill.isHidden = type.isEditable
    }
}

// MARK: - Expanded read-only card

/// Container values (Array / Dictionary / Data / Date) pretty-printed and
/// clearly marked read-only.
private final class UserDefaultsReadOnlyCell: UITableViewCell {

    static let reuseID = "UserDefaultsReadOnlyCell"

    var onCopy: (() -> Void)?

    private let card = UIView()
    private let keyCaption = UILabel()
    private let keyLabel = UILabel()
    private let typePill = PillLabel()
    private let lockPill = PillLabel()
    private let separator = UIView()
    private let valueCaption = UILabel()
    private let bodyLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let note = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        for caption in [keyCaption, valueCaption] {
            caption.font = .systemFont(ofSize: 10, weight: .heavy)
            caption.textColor = UIColor(white: 0.45, alpha: 1)
        }
        keyCaption.text = "KEY"
        valueCaption.text = "VALUE"

        keyLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.numberOfLines = 0

        bodyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        bodyLabel.textColor = UIColor(white: 0.88, alpha: 1)
        bodyLabel.numberOfLines = 0

        lockPill.configure(text: "READ-ONLY", color: UIColor(white: 0.55, alpha: 1))

        note.font = .systemFont(ofSize: 10, weight: .medium)
        note.textColor = UIColor(white: 0.45, alpha: 1)
        note.numberOfLines = 0
        note.text = "Structured values can't be safely retyped from a text field — inspect only."

        separator.backgroundColor = UIColor(white: 0.22, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        var config = UIButton.Configuration.plain()
        config.title = "COPY"
        config.baseForegroundColor = DebugTheme.accentColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 10, weight: .heavy)
            return attrs
        }
        copyButton.configuration = config
        copyButton.backgroundColor = UIColor(white: 0.23, alpha: 1)
        copyButton.layer.cornerRadius = 9
        copyButton.clipsToBounds = true
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), lockPill, typePill])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        let valueRow = UIStackView(arrangedSubviews: [valueCaption, UIView(), copyButton])
        valueRow.axis = .horizontal
        valueRow.alignment = .center
        valueRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [topRow, keyLabel, separator, valueRow, bodyLabel, note])
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(10, after: keyLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(10, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    @objc private func copyTapped() { onCopy?() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCopy = nil
    }

    fileprivate func configure(key: String, type: UserDefaultsValueType, body: String) {
        keyLabel.text = key
        typePill.configure(text: type.title, color: type.pillColor)
        // Very long dumps would blow up row height — cap what we render.
        bodyLabel.text = body.count > 6000 ? String(body.prefix(6000)) + "\n… truncated" : body
    }
}

// MARK: - Pill

/// Tiny rounded type badge.
private final class PillLabel: UILabel {

    private let inset = UIEdgeInsets(top: 2.5, left: 7, bottom: 2.5, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 9, weight: .heavy)
        textColor = .black
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, color: UIColor) {
        self.text = text
        backgroundColor = color
        isHidden = false
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + inset.left + inset.right,
                      height: size.height + inset.top + inset.bottom)
    }
}

// MARK: - Add sheet

/// Custom "add a key" sheet. Deliberately **not** a `UIAlertController`: alert
/// text fields truncate long values and can't host a type picker.
final class UserDefaultsAddEntryViewController: UIViewController {

    /// Called with the key and an already-correctly-typed value.
    var onSave: ((_ key: String, _ value: Any) -> Void)?

    private let existingKeys: Set<String>

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let typeSegment = UISegmentedControl(items: ["String", "Int", "Double", "Bool"])
    private let keyField = UITextField()
    private let valueTextView = UITextView()
    private let valueCard = UIView()
    private let boolRow = UIView()
    private let boolSwitch = UISwitch()
    private let boolLabel = UILabel()
    private let errorLabel = UILabel()
    private let hintLabel = UILabel()

    private enum EntryType: Int { case string, int, double, bool }
    private var entryType: EntryType { EntryType(rawValue: typeSegment.selectedSegmentIndex) ?? .string }

    init(existingKeys: Set<String>) {
        self.existingKeys = existingKeys
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "New Default"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem?.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -12),
        ])

        buildTypeSection()
        buildKeySection()
        buildValueSection()
        buildFooter()

        updateForType()
        registerKeyboardObservers()
        view.forceLTR()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.keyField.becomeFirstResponder()
        }
    }

    // MARK: Building blocks

    private func makeCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        return card
    }

    private func makeCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 10, weight: .heavy)
        label.textColor = UIColor(white: 0.45, alpha: 1)
        return label
    }

    private func embed(_ inner: UIView, in card: UIView) {
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    private func buildTypeSection() {
        typeSegment.selectedSegmentIndex = 0
        typeSegment.selectedSegmentTintColor = DebugTheme.accentColor
        typeSegment.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1)], for: .normal)
        typeSegment.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        typeSegment.addTarget(self, action: #selector(typeChanged), for: .valueChanged)

        let card = makeCard()
        let stack = UIStackView(arrangedSubviews: [makeCaption("TYPE"), typeSegment])
        stack.axis = .vertical
        stack.spacing = 8
        embed(stack, in: card)
        typeSegment.heightAnchor.constraint(equalToConstant: 32).isActive = true
        contentStack.addArrangedSubview(card)
    }

    private func buildKeySection() {
        keyField.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        keyField.textColor = DebugTheme.accentColor
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.spellCheckingType = .no
        keyField.keyboardAppearance = .dark
        keyField.returnKeyType = .next
        keyField.clearButtonMode = .whileEditing
        keyField.delegate = self
        keyField.attributedPlaceholder = NSAttributedString(
            string: "my_feature_flag",
            attributes: [.foregroundColor: UIColor(white: 0.30, alpha: 1)])

        let card = makeCard()
        let stack = UIStackView(arrangedSubviews: [makeCaption("KEY"), keyField])
        stack.axis = .vertical
        stack.spacing = 6
        embed(stack, in: card)
        contentStack.addArrangedSubview(card)
    }

    private func buildValueSection() {
        valueTextView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        valueTextView.textColor = UIColor(white: 0.88, alpha: 1)
        valueTextView.backgroundColor = .clear
        valueTextView.autocapitalizationType = .none
        valueTextView.autocorrectionType = .no
        valueTextView.spellCheckingType = .no
        valueTextView.keyboardAppearance = .dark
        valueTextView.textContainerInset = .zero
        valueTextView.textContainer.lineFragmentPadding = 0
        // Multi-line on purpose: long tokens/JSON blobs are exactly what a
        // system alert would truncate.
        valueTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        boolSwitch.onTintColor = DebugTheme.accentColor
        boolSwitch.addTarget(self, action: #selector(boolChanged), for: .valueChanged)
        boolLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        boolLabel.textColor = UIColor(white: 0.88, alpha: 1)
        boolLabel.text = "false"

        boolSwitch.translatesAutoresizingMaskIntoConstraints = false
        boolLabel.translatesAutoresizingMaskIntoConstraints = false
        boolRow.addSubview(boolSwitch)
        boolRow.addSubview(boolLabel)
        NSLayoutConstraint.activate([
            boolSwitch.leadingAnchor.constraint(equalTo: boolRow.leadingAnchor),
            boolSwitch.topAnchor.constraint(equalTo: boolRow.topAnchor),
            boolSwitch.bottomAnchor.constraint(equalTo: boolRow.bottomAnchor),
            boolLabel.leadingAnchor.constraint(equalTo: boolSwitch.trailingAnchor, constant: 12),
            boolLabel.centerYAnchor.constraint(equalTo: boolSwitch.centerYAnchor),
            boolLabel.trailingAnchor.constraint(lessThanOrEqualTo: boolRow.trailingAnchor),
        ])

        hintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        hintLabel.textColor = UIColor(white: 0.45, alpha: 1)
        hintLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [makeCaption("VALUE"), valueTextView, boolRow, hintLabel])
        stack.axis = .vertical
        stack.spacing = 8
        embed(stack, in: valueCard)
        contentStack.addArrangedSubview(valueCard)
    }

    private func buildFooter() {
        errorLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        contentStack.addArrangedSubview(errorLabel)

        let save = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Save to UserDefaults"
        config.baseBackgroundColor = DebugTheme.accentColor
        config.baseForegroundColor = .black
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 15, weight: .bold)
            return attrs
        }
        save.configuration = config
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(save)
    }

    // MARK: State

    @objc private func typeChanged() {
        errorLabel.isHidden = true
        updateForType()
    }

    @objc private func boolChanged() {
        boolLabel.text = boolSwitch.isOn ? "true" : "false"
    }

    private func updateForType() {
        let isBool = entryType == .bool
        valueTextView.isHidden = isBool
        boolRow.isHidden = !isBool

        switch entryType {
        case .string:
            valueTextView.keyboardType = .default
            hintLabel.text = "Written with set(_:forKey:) as a String, exactly as typed — newlines included."
        case .int:
            valueTextView.keyboardType = .numbersAndPunctuation
            hintLabel.text = "Whole numbers only, e.g. 42 or -7. Written as an Int."
        case .double:
            valueTextView.keyboardType = .decimalPad
            hintLabel.text = "Decimal numbers, e.g. 1.5 or -0.25. Written as a Double."
        case .bool:
            hintLabel.text = "Written as a real Bool, so bool(forKey:) reads it back correctly."
        }
        if valueTextView.isFirstResponder { valueTextView.reloadInputViews() }
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    // MARK: Actions

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        view.endEditing(true)
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            showError("Enter a key name.")
            return
        }
        guard !existingKeys.contains(key) else {
            showError("“\(key)” already exists. Close this and edit it in the list instead.")
            return
        }

        let raw = valueTextView.text ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any

        switch entryType {
        case .string:
            value = raw
        case .int:
            guard let intValue = Int(trimmed) else {
                showError("“\(trimmed)” isn’t a whole number. Try 42, 0 or -7.")
                return
            }
            value = intValue
        case .double:
            guard let doubleValue = Double(trimmed) else {
                showError("“\(trimmed)” isn’t a number. Try 1.5 or -0.25.")
                return
            }
            value = doubleValue
        case .bool:
            value = boolSwitch.isOn
        }

        onSave?(key, value)
        dismiss(animated: true)
    }

    // MARK: Keyboard

    private func registerKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }

    @objc private func keyboardWillHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }
}

extension UserDefaultsAddEntryViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if entryType == .bool {
            textField.resignFirstResponder()
        } else {
            valueTextView.becomeFirstResponder()
        }
        return true
    }
}

// MARK: - Helpers

private extension UIView {
    /// Walks up to the `KeyValueCardCell` that owns this view, if any.
    func enclosingKeyValueCard() -> KeyValueCardCell? {
        var candidate: UIView? = self
        while let current = candidate {
            if let card = current as? KeyValueCardCell { return card }
            candidate = current.superview
        }
        return nil
    }
}
