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

// MARK: - JSON badge

/// Shared "is this value JSON?" summary used by the storage inspectors.
///
/// Stored values are very often JSON (a serialized user object, a feature-flag
/// blob, a cached payload), so the row surfaces that up front and the editor
/// screen offers the tree editor for it.
enum StorageJSONBadge {

    /// `"JSON · 4 keys"` / `"JSON · 12 items"` when `text` is a JSON container,
    /// otherwise `nil`.
    ///
    /// Bounded on purpose: this is computed once per entry when the list is
    /// built, never inside `cellForRowAt`, so a multi-megabyte blob can't be
    /// re-parsed on every layout pass.
    static func summary(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 200_000,
              trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              JSONDocument.validate(trimmed).isValid,
              let document = JSONDocument(text: trimmed) else { return nil }
        if let array = document.root as? [Any] {
            return "JSON · \(array.count) item\(array.count == 1 ? "" : "s")"
        }
        if let object = document.root as? [String: Any] {
            return "JSON · \(object.count) key\(object.count == 1 ? "" : "s")"
        }
        return "JSON"
    }

    static let color = UIColor(red: 0.42, green: 0.78, blue: 0.98, alpha: 1)
}

// MARK: - Formatting

private enum UDFormat {

    static let human: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Converts a defaults value into something `JSONSerialization` accepts,
    /// losslessly where JSON allows and descriptively where it doesn't.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            // JSON blobs stored as Data inline as real JSON; anything else is
            // base64 so the export stays valid JSON.
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return object
            }
            return "<data \(data.count) bytes> " + data.base64EncodedString()
        case let date as Date:
            return iso.string(from: date)
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
}

// MARK: - Model

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

    /// Only scalars can be safely re-typed from a text field. `.data` is decided
    /// per-entry (see `UserDefaultsEntry.isEditable`) because it depends on what
    /// the blob decoded into — always use the entry's flag in the UI.
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

/// One `UserDefaults.standard` entry, with its detected storage type and every
/// string the UI needs — all derived **once**, when the list is built.
///
/// Nothing here is recomputed inside `cellForRowAt`: decoding a blob or parsing
/// JSON on every layout pass was what made the list stutter, and stale
/// per-cell state was what made it unsafe.
private struct UserDefaultsEntry {

    let key: String
    let value: Any
    let type: UserDefaultsValueType
    /// Non-nil exactly when `type == .data` — what the blob decoded into.
    let decoded: DecodedDataValue?
    /// The text seeded into the editor; round-trips through `commit`.
    let editText: String
    /// Compact one-line preview for the row.
    let preview: String
    /// `"JSON · n keys"` when `editText` is a JSON container.
    let jsonBadge: String?

    init(key: String, value: Any) {
        self.key = key
        self.value = value
        let type = UserDefaultsValueType.detect(value)
        self.type = type
        let decoded = (type == .data) ? DataValueDecoder.decode((value as? Data) ?? Data()) : nil
        self.decoded = decoded

        // --- editable text -------------------------------------------------
        let text: String
        switch type {
        case .bool:
            text = ((value as? NSNumber)?.boolValue ?? false) ? "true" : "false"
        case .int:
            text = "\((value as? NSNumber)?.int64Value ?? 0)"
        case .double:
            text = "\((value as? NSNumber)?.doubleValue ?? 0)"
        case .string:
            text = value as? String ?? String(describing: value)
        case .url:
            text = (value as? URL)?.absoluteString ?? (value as? String) ?? String(describing: value)
        case .data:
            text = decoded?.text ?? ""
        case .date:
            if let date = value as? Date {
                text = UDFormat.human.string(from: date)
                    + "\n" + UDFormat.iso.string(from: date)
                    + "\nepoch \(date.timeIntervalSince1970)"
            } else {
                text = String(describing: value)
            }
        case .array, .dictionary:
            let safe = UDFormat.jsonSafe(value)
            if JSONSerialization.isValidJSONObject(safe),
               let data = try? JSONSerialization.data(withJSONObject: safe, options: []),
               let json = JSONExporter.prettyJSONString(from: data) {
                text = json
            } else {
                text = String(describing: value)
            }
        }
        self.editText = text

        // --- one-line preview ----------------------------------------------
        switch type {
        case .bool, .int, .double, .string, .url:
            self.preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
        case .date:
            self.preview = (value as? Date).map { UDFormat.human.string(from: $0) }
                ?? String(describing: value)
        case .data:
            self.preview = decoded?.previewText ?? "0 bytes"
        case .array:
            let count = (value as? NSArray)?.count ?? 0
            self.preview = "\(count) item\(count == 1 ? "" : "s")"
        case .dictionary:
            let count = (value as? NSDictionary)?.count ?? 0
            self.preview = "\(count) key\(count == 1 ? "" : "s")"
        }

        self.jsonBadge = StorageJSONBadge.summary(for: text)
    }

    /// A body this big can't be rendered into an editor safely, and saving a
    /// truncated copy would destroy the part that never made it on screen.
    var isTooLargeToEdit: Bool { editText.count > 20_000 }

    /// Data rows are editable when their decoded form can be re-encoded; the
    /// scalar rows follow the type's own rule.
    var isEditable: Bool {
        guard !isTooLargeToEdit else { return false }
        if type == .data { return decoded?.isEditable ?? false }
        return type.isEditable
    }

    /// Why this entry can't be edited, for the read-only screen.
    var readOnlyReason: String {
        if isTooLargeToEdit {
            return "This value is \(editText.count) characters — too large to edit safely from a text field, so it is shown read-only."
        }
        if type == .data {
            return decoded?.representation.editHint
                ?? "This blob could not be decoded, so it can't be written back."
        }
        return "\(type.title) values can't be safely retyped from a text field — inspect only."
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
/// Rows are **display-only**. Tapping one pushes
/// `StorageValueEditorViewController` — the same focused, JSON-aware editor the
/// web-view storage inspector uses — and the save handler writes the value back
/// under its original type (a `Data` default is re-encoded into the same
/// representation it decoded from, an `Int` stays an `Int`). Values that can't
/// round-trip (Array/Dictionary/Date, keyed archives, opaque blobs, anything
/// enormous) open a read-only viewer instead.
///
/// There is deliberately **no inline editing inside a reusable cell**: a text
/// field whose lifetime is tied to cell reuse commits on `editingDidEnd`, which
/// UIKit fires *while* `reloadData()` is tearing the cell down — the commit then
/// re-entered `reloadData()` from inside `reloadData()`.
final class UserDefaultsBrowserViewController: UITableViewController {

    // MARK: State

    private var entries: [UserDefaultsEntry] = []      // app domain, filtered by search
    /// Number of keys in the app domain before the search filter.
    private var domainCount = 0
    private var searchText = ""
    /// Error raised by a save that happened as the editor was popping. Shown
    /// from `viewDidAppear`, never mid-transition.
    private var pendingError: (title: String, message: String)?

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

        tableView.register(UserDefaultsRowCell.self, forCellReuseIdentifier: UserDefaultsRowCell.reuseID)
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A save that failed while the editor was popping can't present an alert
        // mid-transition — it parks the message here instead.
        guard let error = pendingError else { return }
        pendingError = nil
        presentAlert(title: error.title, message: error.message)
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

        titleLabel.text = "User Defaults · \(domainCount)"
        titleLabel.sizeToFit()
        tableView.reloadData()
    }

    private func entry(forKey key: String) -> UserDefaultsEntry? {
        entries.first { $0.key == key }
    }

    // MARK: Actions

    /// The add flow is the *same* editor screen as the edit flow, so there is
    /// one editing experience (and one place where JSON gets the tree editor).
    @objc private func addTapped() {
        view.endEditing(true)
        let editor = StorageValueEditorViewController(
            key: "", value: "",
            subtitle: "New key in \(Bundle.main.bundleIdentifier ?? "this app")'s defaults. "
                + "The type is inferred from what you type: true/false → Bool, 42 → Int, "
                + "1.5 → Double, a JSON object or array → JSON Data, anything else → String.",
            isKeyEditable: true)
        editor.onSave = { [weak self] key, text in
            guard let self else { return }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { return }
            guard !(Self.appDomain() ?? [:]).keys.contains(trimmedKey) else {
                self.pendingError = ("Key already exists",
                                     "“\(trimmedKey)” is already stored. Tap it in the list to edit it — "
                                     + "adding it again here would silently retype the existing value.")
                return
            }
            UserDefaults.standard.set(Self.inferredValue(from: text), forKey: trimmedKey)
            // A new key may be invisible under the current search — clear it so
            // the user actually sees what they just added.
            self.searchText = ""
            self.searchController.searchBar.text = ""
            self.reload()
            if let row = self.entries.firstIndex(where: { $0.key == trimmedKey }) {
                self.tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: true)
            }
            self.showToast("Added “\(trimmedKey)”")
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    /// Picks the narrowest type the typed text round-trips as, so a new Bool is
    /// a real Bool and a JSON payload is stored as JSON `Data` (which is what the
    /// Data editor knows how to re-encode).
    private static func inferredValue(from text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "true":  return true
        case "false": return false
        default:      break
        }
        if let intValue = Int(trimmed) { return intValue }
        if let doubleValue = Double(trimmed) { return doubleValue }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []),
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: []) {
            return data
        }
        return text
    }

    @objc private func copyAllTapped() {
        view.endEditing(true)
        var object: [String: Any] = [:]
        for entry in entries { object[entry.key] = UDFormat.jsonSafe(entry.value) }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let pretty = JSONExporter.prettyJSONString(from: data) else {
            showToast("Nothing to copy")
            return
        }
        UIPasteboard.general.string = pretty
        showToast("Copied \(entries.count) key\(entries.count == 1 ? "" : "s")")
    }

    // MARK: Writing

    private enum CommitResult {
        case unchanged
        case written
        case invalid(String)
    }

    /// Writes `text` back under `entry.key` **using the original type**.
    private func commit(text: String, to entry: UserDefaultsEntry) -> CommitResult {
        guard text != entry.editText else { return .unchanged }
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

    // MARK: Table data

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(entries.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // `numberOfRowsInSection` reports `max(count, 1)` so the empty state has
        // a row to live in — every accessor must therefore range-check before
        // touching `entries`, not just test for emptiness.
        //
        // Note each branch dequeues at most **once**: dequeuing a second cell for
        // the same index path (the old fallback path did, after a failed cast)
        // is an assertion failure in UIKit.
        guard entries.indices.contains(indexPath.row) else {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: UserDefaultsMessageCell.reuseID, for: indexPath) as? UserDefaultsMessageCell
            cell?.configure(
                title: searchText.isEmpty ? "No defaults" : "No key matches “\(searchText)”",
                body: searchText.isEmpty
                    ? "This app hasn't persisted any defaults yet. Tap + to add a key."
                    : "Clear the search to see every key this app stores.")
            return cell ?? Self.plainFallbackCell()
        }

        let entry = entries[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: UserDefaultsRowCell.reuseID, for: indexPath) as? UserDefaultsRowCell
        cell?.configure(key: entry.key,
                        type: entry.type,
                        representation: entry.decoded?.representation,
                        jsonBadge: entry.jsonBadge,
                        editable: entry.isEditable,
                        preview: entry.preview)
        return cell ?? Self.plainFallbackCell()
    }

    /// Non-dequeued placeholder for the (unreachable) case where a registered
    /// cell comes back as the wrong class. Deliberately empty: a stock cell's
    /// `textLabel` doesn't self-size with `automaticDimension`.
    private static func plainFallbackCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    /// Tapping a row opens the focused, JSON-aware editor — nothing here mutates
    /// `entries`, resigns a first responder or reloads the table, so a tap can
    /// never re-enter the table's own update cycle.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        // Only the search field can be first responder here — this screen has no
        // editable cells — so dismissing it can't run a commit or touch `entries`.
        view.endEditing(true)
        let entry = entries[indexPath.row]
        if entry.isEditable {
            pushEditor(for: entry)
        } else {
            pushReadOnlyViewer(for: entry)
        }
    }

    // MARK: Editing

    private func pushEditor(for entry: UserDefaultsEntry) {
        let key = entry.key
        let editor = StorageValueEditorViewController(
            key: key,
            value: entry.editText,
            subtitle: Self.editorSubtitle(for: entry),
            // Renaming a defaults key means delete + recreate; keys stay locked.
            isKeyEditable: false)

        // The *key* travels in the closure, never an index or the struct: rows
        // shift whenever the search text or the domain changes, so the entry is
        // re-resolved by key at save time.
        editor.onSave = { [weak self] _, newValue in
            guard let self else { return }
            guard let fresh = self.entry(forKey: key) ?? Self.liveEntry(forKey: key) else {
                self.pendingError = ("Key is gone", "“\(key)” is no longer in this app's defaults.")
                return
            }
            switch self.commit(text: newValue, to: fresh) {
            case .unchanged:
                self.showToast("No change")
            case .written:
                self.reload()
                self.showToast("Saved “\(key)” as \(fresh.type.title)")
            case .invalid(let reason):
                // Nothing was written — say so once the editor has finished
                // popping, rather than presenting mid-transition.
                self.pendingError = ("Can't save \(fresh.type.title)", reason)
            }
        }
        editor.onDelete = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: key)
            self.reload()
            self.showToast("Deleted “\(key)”")
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    /// Re-reads one key straight from the domain, for the case where the list
    /// was filtered out from under a save.
    private static func liveEntry(forKey key: String) -> UserDefaultsEntry? {
        guard let value = (appDomain() ?? [:])[key] else { return nil }
        return UserDefaultsEntry(key: key, value: value)
    }

    private func pushReadOnlyViewer(for entry: UserDefaultsEntry) {
        var badges = [entry.type.title]
        if let representation = entry.decoded?.representation { badges.append(representation.rawValue) }
        if let json = entry.jsonBadge { badges.append(json) }

        let viewer = StorageValueReadOnlyViewController(
            key: entry.key,
            value: entry.editText,
            subtitle: badges.joined(separator: "  ·  "),
            note: entry.readOnlyReason)
        viewer.onDelete = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: entry.key)
            self.reload()
            self.showToast("Deleted “\(entry.key)”")
        }
        navigationController?.pushViewController(viewer, animated: true)
    }

    private static func editorSubtitle(for entry: UserDefaultsEntry) -> String {
        switch entry.type {
        case .data:
            let decoded = entry.decoded
            let representation = decoded?.representation.rawValue ?? "DATA"
            let bytes = decoded?.byteCountText ?? "0 bytes"
            return "DATA · \(representation) · \(bytes) — "
                + (decoded?.representation.editHint ?? "Saved back as Data.")
        case .url:
            return "URL — stored as a String in UserDefaults and saved back as a String."
        default:
            return "\(entry.type.title) — saved back with `set(_:forKey:)` as a \(entry.type.title.capitalized), "
                + "so the reader still gets the type it expects."
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
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
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
            self.reload()
            self.showToast("Deleted “\(key)”")
        })
        alert.view.forceLTR()
        present(alert, animated: true)
    }

    // MARK: Footer

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let domain = Bundle.main.bundleIdentifier ?? "—"
        return "Showing \(entries.count) of \(domainCount) key\(domainCount == 1 ? "" : "s") in this app's own domain (\(domain)). System and global defaults are never listed. Tap a row to open the value editor — JSON values get the full tree editor, and every save keeps the original type. Data blobs are decoded (JSON → property list → keyed archive → UTF-8 text → hex) and saved back as Data in the same representation. Swipe left to delete."
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = UIColor(white: 0.45, alpha: 1)
        footer.textLabel?.font = .systemFont(ofSize: 11)
        footer.textLabel?.numberOfLines = 0
        footer.contentView.backgroundColor = .black
        footer.forceLTR()
    }

    // MARK: Feedback

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.view.forceLTR()
        present(alert, animated: true)
    }

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

// MARK: - Row card

/// **Display-only** summary card: key on its own line, a compact value preview
/// on its own line, and badges for the detected type / representation / JSON
/// shape. Editing happens on `StorageValueEditorViewController`, never here.
private final class UserDefaultsRowCell: UITableViewCell {

    static let reuseID = "UserDefaultsRowCell"

    private let card = UIView()
    private let keyCaption = UILabel()
    private let keyLabel = UILabel()
    private let typePill = PillLabel()
    private let formatPill = PillLabel()
    private let jsonPill = PillLabel()
    private let lockPill = PillLabel()
    private let separator = UIView()
    private let valueCaption = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView()

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

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(UIColor(white: 0.40, alpha: 1), renderingMode: .alwaysOriginal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let topRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), lockPill, jsonPill, formatPill, typePill])
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
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            // Text drives the row height: pinned to BOTH top and bottom.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
        ])

        forceLTR()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        }
    }

    fileprivate func configure(key: String,
                               type: UserDefaultsValueType,
                               representation: DataRepresentation?,
                               jsonBadge: String?,
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

        // The JSON badge is additive: a Data blob can be both DATA + JSON, and a
        // plain String can hold a JSON payload with no representation pill.
        if let jsonBadge, representation != .json {
            jsonPill.configure(text: jsonBadge, color: StorageJSONBadge.color)
        } else if let jsonBadge, representation == .json {
            // Don't repeat the word JSON — just carry the count over.
            formatPill.configure(text: jsonBadge, color: DataRepresentation.json.color)
            jsonPill.isHidden = true
        } else {
            jsonPill.isHidden = true
        }

        lockPill.isHidden = editable
    }
}

// MARK: - Message card

/// Self-sizing empty-state card. Deliberately **not** a stock `UITableViewCell` —
/// its `textLabel`/`detailTextLabel` don't self-size with `numberOfLines = 0`.
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

/// Tiny rounded badge.
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

// MARK: - Read-only value viewer

/// The counterpart to `StorageValueEditorViewController` for values that cannot
/// round-trip through text — Array/Dictionary/Date defaults, `NSKeyedArchiver`
/// payloads, opaque blobs and anything too large to edit safely.
///
/// It is a separate screen rather than the editor with a disabled field so a
/// read-only value can never *look* editable. The body lives in a scrolling
/// `UITextView` (not a self-sizing label) so a multi-megabyte dump costs one
/// screenful of layout instead of a row height in the tens of thousands of
/// points.
final class StorageValueReadOnlyViewController: UIViewController {

    /// Optional — shows a Delete button when set.
    var onDelete: (() -> Void)?

    private let key: String
    private let value: String
    private let subtitle: String?
    private let note: String?

    private let textView = UITextView()

    init(key: String, value: String, subtitle: String? = nil, note: String? = nil) {
        self.key = key
        self.value = value
        self.subtitle = subtitle
        self.note = note
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Value"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        var items = [UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                                     target: self, action: #selector(copyTapped))]
        if onDelete != nil {
            items.append(UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain,
                                         target: self, action: #selector(deleteTapped)))
        }
        items.forEach { $0.tintColor = DebugTheme.accentColor }
        navigationItem.rightBarButtonItems = items

        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        let keyCaption = UILabel()
        keyCaption.text = "KEY"
        keyCaption.font = .systemFont(ofSize: 10, weight: .heavy)
        keyCaption.textColor = UIColor(white: 0.45, alpha: 1)
        header.addArrangedSubview(keyCaption)

        let keyLabel = UILabel()
        keyLabel.text = key
        keyLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.numberOfLines = 0
        header.addArrangedSubview(keyLabel)

        if let subtitle, !subtitle.isEmpty {
            let label = UILabel()
            label.text = subtitle
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = UIColor(white: 0.55, alpha: 1)
            label.numberOfLines = 0
            header.addArrangedSubview(label)
        }
        if let note, !note.isEmpty {
            let label = UILabel()
            label.text = note
            label.font = .systemFont(ofSize: 11)
            label.textColor = UIColor(white: 0.42, alpha: 1)
            label.numberOfLines = 0
            header.addArrangedSubview(label)
        }
        view.addSubview(header)

        textView.text = value.isEmpty ? "(empty)" : value
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = UIColor(white: 0.88, alpha: 1)
        textView.backgroundColor = UIColor(white: 0.10, alpha: 1)
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
            textView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
        ])

        view.forceLTR()
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = value
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "Delete “\(key)”?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.onDelete?()
            self?.navigationController?.popViewController(animated: true)
        })
        alert.view.forceLTR()
        present(alert, animated: true)
    }
}
