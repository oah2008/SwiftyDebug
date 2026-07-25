//
//  UserDefaultsBrowserViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - Data decoding

/// Which decoder won when a raw `Data` blob was parsed. Shown as a pill next to
/// the value so it's obvious *what* is being rendered (and what an edit will be
/// re-encoded back into).
enum DataRepresentation: String {
    case json    = "JSON"
    case plist   = "PLIST"
    case archive = "ARCHIVE"
    case text    = "TEXT"
    case binary  = "BINARY"

    var color: UIColor {
        switch self {
        case .json:    return UIColor(red: 0.42, green: 0.78, blue: 0.98, alpha: 1)
        case .plist:   return UIColor(red: 0.72, green: 0.68, blue: 0.98, alpha: 1)
        case .archive: return UIColor(red: 0.96, green: 0.68, blue: 0.42, alpha: 1)
        case .text:    return UIColor(red: 0.55, green: 0.86, blue: 0.52, alpha: 1)
        case .binary:  return UIColor(white: 0.62, alpha: 1)
        }
    }

    /// Only representations that can be re-encoded from edited text round-trip.
    /// An archive graph and an opaque blob cannot, so they stay read-only.
    var isEditable: Bool {
        switch self {
        case .json, .plist, .text: return true
        case .archive, .binary:    return false
        }
    }

    var editHint: String {
        switch self {
        case .json:    return "Edited text is parsed as JSON and written back as JSON Data."
        case .plist:   return "Edited text is parsed and written back as property-list Data in its original format."
        case .text:    return "Edited text is written back as UTF-8 Data."
        case .archive: return "NSKeyedArchiver payloads are shown decoded but can't be re-encoded from text — read-only."
        case .binary:  return "Opaque bytes — shown as a hex preview, read-only."
        }
    }
}

/// The result of progressively decoding a `Data` value: what it turned out to
/// be, the text to show/edit, and enough context to re-encode an edit into the
/// *same* representation.
struct DecodedDataValue {

    let data: Data
    let representation: DataRepresentation
    /// The text rendered in the inspector (and edited, when editable).
    let text: String
    /// The property-list format the blob was stored in (`.plist` only).
    let plistFormat: PropertyListSerialization.PropertyListFormat
    /// `true` when a `.plist` is rendered as XML plist text rather than JSON —
    /// it held dates/data that JSON cannot carry losslessly.
    let plistRendersAsXML: Bool

    var isEditable: Bool { representation.isEditable }

    var byteCountText: String { "\(data.count) byte\(data.count == 1 ? "" : "s")" }

    /// Compact one-line summary for a collapsed row.
    var previewText: String {
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return byteCountText }
        let clipped = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        return "\(clipped)  ·  \(byteCountText)"
    }
}

/// Progressive `Data` decoding shared by the UserDefaults and Keychain
/// inspectors, plus the matching re-encoder used when an edit is saved.
enum DataValueDecoder {

    // MARK: Decoding

    /// Tries, in order: JSON → property list → keyed archive → UTF-8 text →
    /// hex preview. Stops at the first success.
    static func decode(_ data: Data) -> DecodedDataValue {
        guard !data.isEmpty else {
            return DecodedDataValue(data: data, representation: .text, text: "",
                                    plistFormat: .binary, plistRendersAsXML: false)
        }

        // 1 — JSON. Only containers count: a bare `42` is text, not a document.
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           JSONSerialization.isValidJSONObject(object),
           let pretty = prettyJSON(object) {
            return DecodedDataValue(data: data, representation: .json, text: pretty,
                                    plistFormat: .binary, plistRendersAsXML: false)
        }

        // 2 — property list, binary or XML. A keyed archive is *also* a binary
        // plist, so archive-shaped payloads are handed to step 3 first and only
        // fall back to a plist rendering when unarchiving fails.
        //
        // Only *containers* count. `PropertyListSerialization` still reads the
        // old OpenStep format, in which any bare token — a bearer token, a UUID,
        // "42" — parses as a valid top-level string. Treating those as plists
        // would both mislabel them and, far worse, rewrite a plain secret as an
        // XML plist blob on save. They belong to the UTF-8 step below.
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let plist = parsed.flatMap { isPlistContainer($0) ? $0 : nil }
        if let plist, !isKeyedArchive(plist) {
            return plistValue(data, plist: plist, format: format)
        }

        // 3 — NSKeyedArchiver payload (secure coding off: this is a debug tool
        // and the point is to see whatever the app actually stored).
        if let object = unarchiveTopLevel(data) {
            return DecodedDataValue(data: data, representation: .archive,
                                    text: describeArchived(object),
                                    plistFormat: format, plistRendersAsXML: false)
        }
        if let plist {
            return plistValue(data, plist: plist, format: format)
        }

        // 4 — UTF-8 text.
        if let text = String(data: data, encoding: .utf8), isPrintable(text) {
            return DecodedDataValue(data: data, representation: .text, text: text,
                                    plistFormat: .binary, plistRendersAsXML: false)
        }

        // 5 — opaque bytes.
        return DecodedDataValue(data: data, representation: .binary, text: hexDump(data),
                                plistFormat: .binary, plistRendersAsXML: false)
    }

    private static func plistValue(_ data: Data,
                                   plist: Any,
                                   format: PropertyListSerialization.PropertyListFormat) -> DecodedDataValue {
        // OpenStep is a read-only format — writing it back would throw, so an
        // edit of one is re-encoded as XML.
        let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .openStep) ? .xml : format

        // JSON-shaped plists render (and round-trip) as JSON. Anything carrying
        // dates or nested data renders as XML plist text so nothing is lost.
        if JSONSerialization.isValidJSONObject(plist), let pretty = prettyJSON(plist) {
            return DecodedDataValue(data: data, representation: .plist, text: pretty,
                                    plistFormat: writeFormat, plistRendersAsXML: false)
        }
        if let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return DecodedDataValue(data: data, representation: .plist, text: text,
                                    plistFormat: writeFormat, plistRendersAsXML: true)
        }
        return DecodedDataValue(data: data, representation: .plist, text: String(describing: plist),
                                plistFormat: writeFormat, plistRendersAsXML: true)
    }

    /// `true` for a top-level plist container. Scalars are deliberately excluded
    /// — see the OpenStep note in `decode`.
    private static func isPlistContainer(_ plist: Any) -> Bool {
        plist is NSDictionary || plist is NSArray
    }

    // MARK: Re-encoding

    enum EncodeError: Error {
        case notEditable(DataRepresentation)
        case invalid(String)

        var message: String {
            switch self {
            case .notEditable(let representation):
                return "\(representation.rawValue) values can't be re-encoded from text."
            case .invalid(let reason):
                return reason
            }
        }
    }

    /// Re-encodes `text` into the **same representation** `decoded` came from,
    /// so a `Data` default/secret is never silently rewritten as a String.
    static func encode(_ text: String, like decoded: DecodedDataValue) throws -> Data {
        switch decoded.representation {
        case .json:
            let object = try jsonObject(from: text)
            do {
                return try JSONSerialization.data(withJSONObject: object, options: [])
            } catch {
                throw EncodeError.invalid("Couldn't re-encode as JSON: \(error.localizedDescription)")
            }

        case .plist:
            let object: Any
            if decoded.plistRendersAsXML {
                var format = PropertyListSerialization.PropertyListFormat.xml
                guard let parsed = try? PropertyListSerialization.propertyList(
                    from: Data(text.utf8), options: [], format: &format) else {
                    throw EncodeError.invalid("That isn't a valid property list. Keep the <plist> XML structure intact.")
                }
                object = parsed
            } else {
                object = try jsonObject(from: text)
            }
            do {
                return try PropertyListSerialization.data(fromPropertyList: object,
                                                          format: decoded.plistFormat, options: 0)
            } catch {
                throw EncodeError.invalid("Couldn't re-encode as a property list: \(error.localizedDescription)")
            }

        case .text:
            return Data(text.utf8)

        case .archive, .binary:
            throw EncodeError.notEditable(decoded.representation)
        }
    }

    private static func jsonObject(from text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EncodeError.invalid("The value is empty — enter a JSON object or array.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []),
              JSONSerialization.isValidJSONObject(object) else {
            throw EncodeError.invalid("That isn't valid JSON. Check for a trailing comma, an unquoted key or a missing brace.")
        }
        return object
    }

    // MARK: Helpers

    static func prettyJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `true` when a decoded plist is really an `NSKeyedArchiver` payload.
    private static func isKeyedArchive(_ plist: Any) -> Bool {
        guard let dictionary = plist as? [String: Any] else { return false }
        return dictionary["$archiver"] != nil || dictionary["$objects"] != nil
    }

    /// Top-level unarchive with **secure coding off** — that is the point of a
    /// debug inspector: whatever class graph the app archived should be
    /// readable. `.setErrorAndReturn` keeps a malformed archive from raising an
    /// Objective-C exception (which Swift cannot catch) instead of returning nil.
    private static func unarchiveTopLevel(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        guard let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey),
              unarchiver.error == nil else { return nil }
        return object
    }

    /// Human-readable dump of an unarchived object graph.
    static func describeArchived(_ object: Any) -> String {
        let typeName = String(describing: type(of: object))
        if let plistLike = object as? NSObject,
           JSONSerialization.isValidJSONObject(plistLike),
           let pretty = prettyJSON(plistLike) {
            return "\(typeName)\n\n\(pretty)"
        }
        switch object {
        case let array as [Any]:
            let body = array.enumerated()
                .map { "[\($0.offset)] \(String(describing: $0.element))" }
                .joined(separator: "\n")
            return "\(typeName) · \(array.count) element\(array.count == 1 ? "" : "s")\n\n\(body)"
        case let dictionary as [AnyHashable: Any]:
            let body = dictionary
                .map { "\(String(describing: $0.key)) = \(String(describing: $0.value))" }
                .sorted()
                .joined(separator: "\n")
            return "\(typeName) · \(dictionary.count) key\(dictionary.count == 1 ? "" : "s")\n\n\(body)"
        default:
            return "\(typeName)\n\n\(String(describing: object))"
        }
    }

    /// `true` when a decoded string is safe to show as text (no stray controls).
    static func isPrintable(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            if scalar.value == 9 || scalar.value == 10 || scalar.value == 13 { continue }
            if scalar.value < 32 || scalar.value == 127 { return false }
        }
        return true
    }

    /// Byte count plus a hex preview of the leading bytes.
    static func hexDump(_ data: Data, limit: Int = 512) -> String {
        let hex = data.prefix(limit)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let suffix = data.count > limit ? " …" : ""
        return "\(data.count) byte\(data.count == 1 ? "" : "s")\n\n\(hex)\(suffix)"
    }
}

// MARK: - Model

/// One `UserDefaults.standard` entry, with its detected storage type.
private struct UserDefaultsEntry {
    let key: String
    let value: Any
    let type: UserDefaultsValueType
    /// Non-nil exactly when `type == .data` — what the blob decoded into.
    let decoded: DecodedDataValue?

    init(key: String, value: Any) {
        self.key = key
        self.value = value
        let type = UserDefaultsValueType.detect(value)
        self.type = type
        self.decoded = (type == .data) ? DataValueDecoder.decode((value as? Data) ?? Data()) : nil
    }

    /// Data rows are editable when their decoded form can be re-encoded; the
    /// scalar rows follow the type's own rule.
    var isEditable: Bool {
        if type == .data { return decoded?.isEditable ?? false }
        return type.isEditable
    }
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

    /// Only scalars can be safely re-typed from a single text field. `.data` is
    /// decided per-entry (see `UserDefaultsEntry.isEditable`) because it depends
    /// on what the blob decoded into — always use the entry's flag in the UI.
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
/// back with the original type. A `Data` row expands into `UserDefaultsDataCell`,
/// which shows the blob decoded (JSON → property list → keyed archive → UTF-8 →
/// hex) and writes an edit back **as Data** in the same representation. The
/// remaining containers (Array/Dictionary/Date) expand read-only.
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

    /// `navigationItem.searchController` is installed exactly once, from
    /// `viewWillAppear`. See the comment there.
    private var hasInstalledSearchController = false

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

        // Search bar *appearance* is safe to configure here; attaching it to the
        // navigation item is not — see `installSearchControllerIfNeeded()`.
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

        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
        tableView.register(UserDefaultsRowCell.self, forCellReuseIdentifier: UserDefaultsRowCell.reuseID)
        tableView.register(UserDefaultsReadOnlyCell.self, forCellReuseIdentifier: UserDefaultsReadOnlyCell.reuseID)
        tableView.register(UserDefaultsDataCell.self, forCellReuseIdentifier: UserDefaultsDataCell.reuseID)
        tableView.register(UserDefaultsMessageCell.self, forCellReuseIdentifier: UserDefaultsMessageCell.reuseID)
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
        installSearchControllerIfNeeded()
        reload()
    }

    /// Attaching a `UISearchController` to the navigation item pulls the search
    /// bar into the navigation *bar*, so it is only valid once this controller
    /// actually has one. The presenter force-loads the view (`_ = vc.view`)
    /// before wrapping it in a `UINavigationController`, which means
    /// `viewDidLoad` runs with `navigationController == nil` — doing it there
    /// leaves UIKit installing the search bar into a bar that doesn't exist yet.
    /// `viewWillAppear` is the first point where the hierarchy is guaranteed.
    private func installSearchControllerIfNeeded() {
        guard !hasInstalledSearchController, navigationController != nil else { return }
        hasInstalledSearchController = true
        definesPresentationContext = true
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.searchController = searchController
    }

    // MARK: Loading

    private func reload() {
        // Single source of truth: the app's own persistent domain.
        let domain = Self.appDomain() ?? [:]
        domainCount = domain.count

        var rows = domain.map { UserDefaultsEntry(key: $0.key, value: $0.value) }

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
        case .data:
            // A Data default must stay a Data default: re-encode the edited text
            // into the representation it was decoded from and write *that*.
            guard let decoded = entry.decoded else {
                return .invalid("This value could not be decoded, so it can't be written back.")
            }
            guard decoded.isEditable else {
                return .invalid(decoded.representation.editHint)
            }
            do {
                let encoded = try DataValueDecoder.encode(text, like: decoded)
                defaults.set(encoded, forKey: entry.key)
            } catch let error as DataValueDecoder.EncodeError {
                return .invalid(error.message)
            } catch {
                return .invalid(error.localizedDescription)
            }
        case .array, .dictionary, .date:
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
        case .data:
            return entry.decoded?.text ?? ""
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
            return entry.decoded?.previewText ?? "0 bytes"
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
            return entry.decoded?.text ?? ""
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
        // `numberOfRowsInSection` reports `max(count, 1)` so the empty state has
        // a row to live in — every accessor below must therefore range-check
        // before touching `entries`, not just test for emptiness.
        guard entries.indices.contains(indexPath.row) else {
            return emptyCell(for: indexPath)
        }

        let entry = entries[indexPath.row]
        let isExpanded = entry.key == expandedKey

        // Expanded + Data → the multi-line decoder/editor card.
        if isExpanded, entry.type == .data {
            return dataCell(for: entry, at: indexPath)
        }

        // Expanded + editable scalar → the shared inline editor card.
        if isExpanded && entry.type.isEditable {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "Card", for: indexPath) as? KeyValueCardCell else {
                return emptyCell(for: indexPath)
            }
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
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: UserDefaultsReadOnlyCell.reuseID,
                for: indexPath) as? UserDefaultsReadOnlyCell else {
                return emptyCell(for: indexPath)
            }
            let body = Self.readOnlyBody(for: entry)
            cell.configure(key: entry.key, type: entry.type, body: body)
            cell.onCopy = { [weak self] in
                UIPasteboard.general.string = body
                self?.showToast("Copied value")
            }
            return cell
        }

        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: UserDefaultsRowCell.reuseID, for: indexPath) as? UserDefaultsRowCell else {
            return emptyCell(for: indexPath)
        }
        cell.configure(key: entry.key,
                       type: entry.type,
                       representation: entry.decoded?.representation,
                       editable: entry.isEditable,
                       preview: Self.previewString(for: entry))
        return cell
    }

    /// The expanded Data card: decoded text, the winning representation, and an
    /// editor that re-encodes back into that same representation.
    private func dataCell(for entry: UserDefaultsEntry, at indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: UserDefaultsDataCell.reuseID, for: indexPath) as? UserDefaultsDataCell else {
            return emptyCell(for: indexPath)
        }
        let decoded = entry.decoded ?? DataValueDecoder.decode(Data())
        cell.configure(key: entry.key, decoded: decoded, editable: entry.isEditable)

        // The *key* travels in the closures, never the index path: rows shift
        // whenever the search text or the domain changes, and a captured
        // IndexPath would be stale by the time the button is tapped.
        let key = entry.key
        cell.onCopy = { [weak self] text in
            UIPasteboard.general.string = text
            self?.showToast("Copied value")
        }
        // `cell` is captured weakly: it owns this closure, so a strong capture
        // would be a retain cycle that outlives every reload.
        cell.onSave = { [weak self, weak cell] text in
            guard let self, let cell else { return }
            self.saveData(text: text, forKey: key, from: cell)
        }
        return cell
    }

    /// Writes an edited Data value back, re-encoded as Data. Failure is reported
    /// inline on the card and nothing is written.
    private func saveData(text: String, forKey key: String, from cell: UserDefaultsDataCell) {
        guard let entry = entry(forKey: key) else {
            cell.showError("“\(key)” is no longer in this app's defaults.")
            return
        }
        switch commit(text: text, to: entry) {
        case .unchanged:
            cell.clearError()
            showToast("No change")
        case .written:
            cell.clearError()
            view.endEditing(true)
            reload()
            showToast("Saved “\(key)” as Data")
        case .invalid(let reason):
            cell.showError(reason)
        }
    }

    /// Self-sizing empty/placeholder card. Deliberately **not** a stock
    /// `UITableViewCell` — its `textLabel`/`detailTextLabel` don't self-size
    /// with `numberOfLines = 0`.
    private func emptyCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: UserDefaultsMessageCell.reuseID, for: indexPath) as? UserDefaultsMessageCell else {
            let fallback = UITableViewCell(style: .default, reuseIdentifier: nil)
            fallback.backgroundColor = .clear
            fallback.contentView.backgroundColor = .clear
            fallback.selectionStyle = .none
            return fallback
        }
        cell.configure(
            title: searchText.isEmpty ? "No defaults" : "No key matches “\(searchText)”",
            body: searchText.isEmpty
                ? "This app hasn't persisted any defaults yet. Tap + to add a key."
                : "Clear the search to see every key this app stores.")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        // Flush any in-flight edit before the cell goes away.
        view.endEditing(true)

        let key = entries[indexPath.row].key
        expandedKey = (expandedKey == key) ? nil : key
        tableView.reloadData()

        // Re-derive the row after the reload: `entries` may have been rebuilt.
        guard expandedKey != nil,
              let row = entries.firstIndex(where: { $0.key == key }) else { return }
        let target = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: target, at: .middle, animated: true)
        // Only the single-line scalar editor auto-focuses; the Data editor is a
        // text view the user opens deliberately.
        guard entries[row].type != .data, entries[row].isEditable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.entries.indices.contains(target.row),
                  self.entries[target.row].key == key else { return }
            (self.tableView.cellForRow(at: target) as? KeyValueCardCell)?.valueField.becomeFirstResponder()
        }
    }

    // MARK: Delete

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        entries.indices.contains(indexPath.row)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard entries.indices.contains(indexPath.row) else { return nil }
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
        return "Showing \(entries.count) of \(domainCount) key\(domainCount == 1 ? "" : "s") in this app's own domain (\(domain)). System and global defaults are never listed. Tap a row to edit it inline; edits keep the original type. Data blobs are decoded (JSON → property list → keyed archive → UTF-8 text → hex) and saved back as Data in the same representation. Swipe left to delete."
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
    private let formatPill = PillLabel()
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

        let topRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), lockPill, formatPill, typePill])
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

    fileprivate func configure(key: String,
                               type: UserDefaultsValueType,
                               representation: DataRepresentation?,
                               editable: Bool,
                               preview: String) {
        keyLabel.text = key
        valueLabel.text = preview.isEmpty ? "(empty)" : preview
        valueLabel.textColor = preview.isEmpty
            ? UIColor(white: 0.40, alpha: 1) : UIColor(white: 0.88, alpha: 1)
        typePill.configure(text: type.title, color: type.pillColor)
        if let representation {
            formatPill.configure(text: representation.rawValue, color: representation.color)
        } else {
            formatPill.isHidden = true
        }
        lockPill.isHidden = editable
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

// MARK: - Expanded Data card

/// The expanded card for a `Data` value: shows what the blob decoded into, the
/// decoded text in a multi-line editor, and writes the edit back **as Data** in
/// the same representation. Re-encoding failures are reported inline and never
/// written.
private final class UserDefaultsDataCell: UITableViewCell {

    static let reuseID = "UserDefaultsDataCell"

    /// Called with the edited text when SAVE is tapped.
    var onSave: ((String) -> Void)?
    var onCopy: ((String) -> Void)?

    private let card = UIView()
    private let keyCaption = UILabel()
    private let keyLabel = UILabel()
    private let typePill = PillLabel()
    private let formatPill = PillLabel()
    private let lockPill = PillLabel()
    private let separator = UIView()
    private let valueCaption = UILabel()
    private let byteLabel = UILabel()
    private let textView = UITextView()
    private let errorLabel = UILabel()
    private let note = UILabel()
    private let copyButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let revertButton = UIButton(type: .system)
    private let buttonRow = UIStackView()

    /// The text the cell was configured with, so REVERT can restore it.
    private var originalText = ""

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

        byteLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        byteLabel.textColor = UIColor(white: 0.45, alpha: 1)

        lockPill.configure(text: "READ-ONLY", color: UIColor(white: 0.55, alpha: 1))

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = UIColor(white: 0.90, alpha: 1)
        textView.backgroundColor = UIColor(white: 0.09, alpha: 1)
        textView.layer.cornerRadius = 9
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.keyboardAppearance = .dark
        textView.isScrollEnabled = false          // grow with the content
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        textView.inputAccessoryView = makeKeyboardBar()

        errorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        note.font = .systemFont(ofSize: 10, weight: .medium)
        note.textColor = UIColor(white: 0.45, alpha: 1)
        note.numberOfLines = 0

        separator.backgroundColor = UIColor(white: 0.22, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        style(copyButton, title: "COPY", filled: false)
        style(revertButton, title: "REVERT", filled: false)
        style(saveButton, title: "SAVE AS DATA", filled: true)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        revertButton.addTarget(self, action: #selector(revertTapped), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), lockPill, formatPill, typePill])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        let valueRow = UIStackView(arrangedSubviews: [valueCaption, byteLabel, UIView(), copyButton])
        valueRow.axis = .horizontal
        valueRow.alignment = .center
        valueRow.spacing = 8

        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(saveButton)
        buttonRow.addArrangedSubview(revertButton)
        buttonRow.addArrangedSubview(UIView())

        let stack = UIStackView(arrangedSubviews: [topRow, keyLabel, separator, valueRow,
                                                   textView, errorLabel, buttonRow, note])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: keyLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(10, after: textView)
        stack.setCustomSpacing(10, after: buttonRow)
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

    private func style(_ button: UIButton, title: String, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = filled ? .black : DebugTheme.accentColor
        config.baseBackgroundColor = DebugTheme.accentColor
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 10, weight: .heavy)
            return attrs
        }
        button.configuration = config
        if !filled {
            button.backgroundColor = UIColor(white: 0.23, alpha: 1)
            button.layer.cornerRadius = 9
            button.clipsToBounds = true
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// A Done bar so a multi-line editor can always dismiss the keyboard.
    private func makeKeyboardBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.barStyle = .black
        bar.tintColor = DebugTheme.accentColor
        let done = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneTapped))
        bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
        bar.sizeToFit()
        return bar
    }

    // MARK: Actions

    @objc private func doneTapped() { textView.resignFirstResponder() }
    @objc private func copyTapped() { onCopy?(textView.text ?? "") }
    @objc private func saveTapped() { onSave?(textView.text ?? "") }
    @objc private func revertTapped() {
        textView.text = originalText
        clearError()
    }

    // MARK: Configure

    override func prepareForReuse() {
        super.prepareForReuse()
        // The editor can be first responder when the row is recycled.
        if textView.isFirstResponder { textView.resignFirstResponder() }
        onSave = nil
        onCopy = nil
        originalText = ""
        clearError()
    }

    func configure(key: String, decoded: DecodedDataValue, editable: Bool) {
        keyLabel.text = key
        typePill.configure(text: UserDefaultsValueType.data.title,
                           color: UserDefaultsValueType.data.pillColor)
        formatPill.configure(text: decoded.representation.rawValue, color: decoded.representation.color)
        lockPill.isHidden = editable
        byteLabel.text = "·  \(decoded.byteCountText)"

        // Very long dumps would blow up row height — cap what is rendered. A
        // truncated body must never be editable: saving it would destroy data.
        let capped = decoded.text.count > 20_000
        let body = capped ? String(decoded.text.prefix(20_000)) + "\n… truncated" : decoded.text
        originalText = body
        textView.text = body

        let allowEditing = editable && !capped
        textView.isEditable = allowEditing
        textView.textColor = allowEditing ? UIColor(white: 0.90, alpha: 1) : UIColor(white: 0.70, alpha: 1)
        buttonRow.isHidden = !allowEditing

        if capped {
            note.text = "Value is too large to edit safely (\(decoded.byteCountText)) — shown truncated, read-only."
        } else {
            note.text = decoded.representation.editHint
        }
        clearError()
        forceLTR()
    }

    func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        textView.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.7).cgColor
    }

    func clearError() {
        errorLabel.text = nil
        errorLabel.isHidden = true
        textView.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
    }
}

// MARK: - Message card

/// Self-sizing empty-state card. Replaces the stock `.subtitle` cell, whose
/// `textLabel`/`detailTextLabel` do not self-size with `numberOfLines = 0`.
private final class UserDefaultsMessageCell: UITableViewCell {

    static let reuseID = "UserDefaultsMessageCell"

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = UIColor(white: 0.5, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = UIColor(white: 0.35, alpha: 1)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
        ])
        forceLTR()
    }

    func configure(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
        forceLTR()
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
