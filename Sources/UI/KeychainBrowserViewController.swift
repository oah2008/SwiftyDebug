//
//  KeychainBrowserViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import Security

// MARK: - Item class

/// The keychain classes the inspector can browse.
enum KeychainItemClass: Int, CaseIterable {
    case genericPassword
    case internetPassword
    case certificate
    case key
    case identity

    var secClass: CFString {
        switch self {
        case .genericPassword:  return kSecClassGenericPassword
        case .internetPassword: return kSecClassInternetPassword
        case .certificate:      return kSecClassCertificate
        case .key:              return kSecClassKey
        case .identity:         return kSecClassIdentity
        }
    }

    /// Short label for the segmented control (space is tight with 5 segments).
    var shortTitle: String {
        switch self {
        case .genericPassword:  return "Generic"
        case .internetPassword: return "Internet"
        case .certificate:      return "Cert"
        case .key:              return "Key"
        case .identity:         return "Identity"
        }
    }

    var title: String {
        switch self {
        case .genericPassword:  return "Generic Passwords"
        case .internetPassword: return "Internet Passwords"
        case .certificate:      return "Certificates"
        case .key:              return "Keys"
        case .identity:         return "Identities"
        }
    }

    /// Only the two password classes carry an editable `kSecValueData` secret.
    var isEditable: Bool { self == .genericPassword || self == .internetPassword }

    /// Data is only requested for the password classes — asking for the data of
    /// a key/identity can trigger a user-presence prompt and returns raw DER.
    var returnsData: Bool { isEditable }

    var explainer: String {
        switch self {
        case .genericPassword:
            return "kSecClassGenericPassword — app secrets stored by service + account. Editing writes the new value with SecItemUpdate immediately."
        case .internetPassword:
            return "kSecClassInternetPassword — credentials scoped to a server, port and protocol. Editing writes the new value with SecItemUpdate immediately."
        case .certificate:
            return "kSecClassCertificate — read-only here. Certificates are stored as DER blobs and are not editable from the inspector."
        case .key:
            return "kSecClassKey — read-only here. Private/public key material is never exported by the inspector, only its attributes."
        case .identity:
            return "kSecClassIdentity — a certificate plus its private key. Read-only; delete removes both halves."
        }
    }
}

// MARK: - Item model

/// One row returned by `SecItemCopyMatching`, plus typed accessors for the
/// attributes worth surfacing.
struct KeychainItem {

    let itemClass: KeychainItemClass
    /// The raw attribute dictionary exactly as the keychain returned it
    /// (short keys such as `acct`, `svce`, `pdmn`, `v_Data`).
    let attributes: [String: Any]

    /// The secret run through the shared progressive decoder: JSON → property
    /// list → keyed archive → UTF-8 text → hex. `nil` when this class doesn't
    /// export its data at all.
    ///
    /// Decoded once, at construction: cells re-read it on every layout pass and
    /// re-parsing a multi-megabyte blob there would stall the table.
    let decodedSecret: DecodedDataValue?

    init(itemClass: KeychainItemClass, attributes: [String: Any]) {
        self.itemClass = itemClass
        self.attributes = attributes
        if let data = attributes[kSecValueData as String] as? Data {
            self.decodedSecret = DataValueDecoder.decode(data)
        } else {
            self.decodedSecret = nil
        }
    }

    // MARK: Typed attributes

    var account: String? { attributes[kSecAttrAccount as String] as? String }
    var service: String? { attributes[kSecAttrService as String] as? String }
    var label: String? { attributes[kSecAttrLabel as String] as? String }
    var accessGroup: String? { attributes[kSecAttrAccessGroup as String] as? String }
    var server: String? { attributes[kSecAttrServer as String] as? String }
    var created: Date? { attributes[kSecAttrCreationDate as String] as? Date }
    var modified: Date? { attributes[kSecAttrModificationDate as String] as? Date }
    var persistentRef: Data? { attributes[kSecValuePersistentRef as String] as? Data }

    /// `kSecAttrApplicationLabel` is a String for some items and a Data hash for keys.
    var applicationLabel: String? {
        if let s = attributes[kSecAttrApplicationLabel as String] as? String { return s }
        if let d = attributes[kSecAttrApplicationLabel as String] as? Data {
            return KeychainInspector.hexString(d, limit: 12)
        }
        return nil
    }

    /// Human-readable protection class, e.g. "WhenUnlocked".
    var accessibleDescription: String? {
        guard let raw = attributes[kSecAttrAccessible as String] as? String else { return nil }
        return KeychainInspector.accessibleName(raw)
    }

    // MARK: Secret

    var secretData: Data? { attributes[kSecValueData as String] as? Data }

    /// The secret decoded as plain UTF-8, when it actually looks like text.
    var secretText: String? {
        guard let decoded = decodedSecret, decoded.representation == .text else { return nil }
        return decoded.text
    }

    /// `true` when the secret can be re-encoded from edited text and written
    /// back with `SecItemUpdate` — archives and opaque blobs cannot.
    var isSecretEditable: Bool {
        guard itemClass.isEditable else { return false }
        guard let decoded = decodedSecret else { return false }
        return decoded.isEditable
    }

    /// The secret as shown when revealed — the decoded text, or a hex preview.
    var revealedSecretDisplay: String {
        guard let decoded = decodedSecret else {
            return itemClass.returnsData ? "(no data)" : "(not exported for this class)"
        }
        return decoded.text.isEmpty ? "(empty)" : decoded.text
    }

    /// The masked stand-in shown until the user taps the eye.
    var maskedSecretDisplay: String {
        guard let data = secretData, !data.isEmpty else {
            return itemClass.returnsData ? "(no data)" : "(not exported for this class)"
        }
        let count = min(max((secretText?.count ?? data.count), 6), 16)
        return String(repeating: "•", count: count)
    }

    /// Best available name for the item.
    var displayName: String {
        for candidate in [account, label, service, applicationLabel, server] {
            if let c = candidate, !c.isEmpty { return c }
        }
        return "(unnamed item)"
    }

    /// Stable identity for per-row UI state (reveal / draft / in-flight save).
    ///
    /// Section indexes shift under the list whenever a reload lands, so nothing
    /// asynchronous may key off them — this string survives a reload of the same
    /// underlying item.
    var identity: String {
        if let ref = persistentRef { return "ref:" + ref.base64EncodedString() }
        let parts = [String(itemClass.rawValue), account, service, server, label,
                     accessGroup, applicationLabel]
            .map { $0 ?? "" }
        return "attr:" + parts.joined(separator: "\u{1}")
    }
}

// MARK: - Scope

/// Which slice of the keychain the browser shows.
///
/// The process can see more than it owns — shared access groups, and the
/// system entries iOS keeps in groups such as `apple` or `com.apple.token`.
/// The inspector defaults to `thisApp` so the list matches what the host app
/// actually wrote.
enum KeychainScope {
    /// Only items that belong to the container app (the default).
    case thisApp
    /// Everything `SecItemCopyMatching` hands back, unfiltered.
    case all

    var buttonTitle: String {
        switch self {
        case .thisApp: return "This app"
        case .all:     return "All"
        }
    }

    var toggled: KeychainScope { self == .thisApp ? .all : .thisApp }

    /// `true` when an item's raw attribute dictionary passes this scope.
    func includes(_ attributes: [String: Any]) -> Bool {
        switch self {
        case .all:     return true
        case .thisApp: return KeychainOwnership.isOwnItem(attributes)
        }
    }
}

// MARK: - Ownership

/// Works out which keychain access group belongs to the container app, and
/// decides whether a given item is the app's own.
///
/// The app's default group is `"<TeamID>.<bundleIdentifier>"`, but the team
/// prefix isn't readable from any public API on iOS. Rather than writing a
/// probe item into the user's keychain, the group is *discovered* from items
/// that are already there: any visible item whose access group ends in
/// `".<bundleIdentifier>"` is, by construction, the app's own group. Until such
/// an item exists the suffix rule alone does the filtering, which produces the
/// same answer — the discovered value only exists so it can be displayed.
enum KeychainOwnership {

    /// The container app's bundle identifier (empty only in odd host setups).
    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""

    /// Double optional: `nil` = not resolved yet, `.some(nil)` = resolved to
    /// "no item carried the app's group".
    private static var cachedGroup: String??

    /// The app's real access group (`"<TeamID>.<bundleIdentifier>"`) once an
    /// existing item has revealed it, otherwise `nil`.
    static var resolvedAccessGroup: String? {
        if let cached = cachedGroup { return cached }
        let discovered = discoverAccessGroup()
        cachedGroup = .some(discovered)
        return discovered
    }

    /// The team prefix of the resolved group, when there is one.
    static var teamIdentifier: String? {
        guard let group = resolvedAccessGroup,
              let dot = group.firstIndex(of: "."),
              dot != group.startIndex else { return nil }
        return String(group[group.startIndex..<dot])
    }

    /// Forgets the discovered group so the next read re-scans (called on reload,
    /// since the app may have written its first item in the meantime).
    static func invalidate() { cachedGroup = nil }

    /// Human-readable description of what is being filtered on, for the footer.
    static var scopeDescription: String {
        if let group = resolvedAccessGroup { return group }
        if bundleIdentifier.isEmpty { return "items with no access group" }
        return "*.\(bundleIdentifier) (team prefix not discovered yet)"
    }

    /// Scans the visible items of every class for one carrying the app's own
    /// default access group. Read-only — nothing is written to the keychain.
    private static func discoverAccessGroup() -> String? {
        guard !bundleIdentifier.isEmpty else { return nil }
        let suffix = "." + bundleIdentifier
        for itemClass in KeychainItemClass.allCases {
            let (dictionaries, status) = KeychainInspector.copyMatching(itemClass,
                                                                        includeData: false,
                                                                        includeRefs: false)
            guard status == errSecSuccess else { continue }
            for attributes in dictionaries {
                guard let group = (attributes[kSecAttrAccessGroup as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty else { continue }
                if group == bundleIdentifier || group.hasSuffix(suffix) { return group }
            }
        }
        return nil
    }

    /// `true` when the item looks like it belongs to the container app.
    ///
    /// An item counts as the app's own when its access group is missing/empty,
    /// matches the discovered group, or ends in `".<bundleIdentifier>"`.
    /// Obvious Apple-owned services are dropped unless the app itself is the
    /// one that stored them under its own group.
    static func isOwnItem(_ attributes: [String: Any]) -> Bool {
        let group = (attributes[kSecAttrAccessGroup as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var groupMatches = false
        if let group, !group.isEmpty {
            if let own = resolvedAccessGroup, group == own {
                groupMatches = true
            } else if !bundleIdentifier.isEmpty,
                      group == bundleIdentifier || group.hasSuffix("." + bundleIdentifier) {
                groupMatches = true
            }
            if !groupMatches { return false }
        }

        // A `com.apple.*` service in the app's own group is the app's business;
        // one in an inherited/unset group is a system entry we should not show.
        if !groupMatches, isSystemService(attributes) { return false }
        return true
    }

    /// `true` for entries that clearly belong to an Apple/system service.
    private static func isSystemService(_ attributes: [String: Any]) -> Bool {
        // If the host app itself lives under `com.apple.`, the prefix says nothing.
        guard !bundleIdentifier.hasPrefix("com.apple.") else { return false }
        for key in [kSecAttrService, kSecAttrLabel, kSecAttrApplicationTag] {
            guard let value = attributes[key as String] as? String else { continue }
            if value.hasPrefix("com.apple.") { return true }
        }
        return false
    }
}

// MARK: - Keychain access

/// Thin wrapper over the `SecItem*` API: query, update, delete and OSStatus
/// translation. Every call is failure-tolerant — `errSecItemNotFound` is an
/// empty result, never an error.
enum KeychainInspector {

    // MARK: Query

    /// One class's worth of results: what the scope kept, the raw status, and
    /// how many rows the scope filtered out (so the UI can say so).
    struct FetchResult {
        var items: [KeychainItem]
        var status: OSStatus
        var hiddenCount: Int
    }

    /// Runs `SecItemCopyMatching` for one class and returns the raw attribute
    /// dictionaries. Kept separate from `fetch` so ownership discovery can read
    /// the keychain without recursing back through the scope filter.
    static func copyMatching(_ itemClass: KeychainItemClass,
                             includeData: Bool,
                             includeRefs: Bool) -> ([[String: Any]], OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: itemClass.secClass,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if includeRefs {
            // Persistent refs give us an unambiguous handle for update/delete.
            query[kSecReturnPersistentRef as String] = true
        }
        if includeData && itemClass.returnsData {
            query[kSecReturnData as String] = true
        }

        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        // Some classes refuse the persistent-ref request; retry without it
        // rather than reporting a failure for items we can still read.
        if includeRefs, status != errSecSuccess, status != errSecItemNotFound {
            query.removeValue(forKey: kSecReturnPersistentRef as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }

        guard status == errSecSuccess else { return ([], status) }

        if let array = result as? [[String: Any]] { return (array, status) }
        if let single = result as? [String: Any] { return ([single], status) }
        return ([], status)
    }

    /// Fetches one class, filtered to `scope`.
    /// - Returns: the parsed items plus the raw status (so the UI can tell
    ///   "nothing stored" apart from "no entitlement").
    static func fetch(_ itemClass: KeychainItemClass, scope: KeychainScope) -> FetchResult {
        let (dictionaries, status) = copyMatching(itemClass, includeData: true, includeRefs: true)
        guard status == errSecSuccess else {
            // "Nothing stored" is a clean empty state, not a failure.
            return FetchResult(items: [], status: status, hiddenCount: 0)
        }

        let kept = dictionaries.filter { scope.includes($0) }
        let items = kept
            .map { KeychainItem(itemClass: itemClass, attributes: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return FetchResult(items: items,
                           status: status,
                           hiddenCount: dictionaries.count - kept.count)
    }

    /// Cheap count used for the segmented-control badges. Applies the same
    /// scope filter as `fetch` so the badge matches the list.
    static func count(_ itemClass: KeychainItemClass, scope: KeychainScope) -> Int {
        let (dictionaries, status) = copyMatching(itemClass, includeData: false, includeRefs: false)
        guard status == errSecSuccess else { return 0 }
        return dictionaries.reduce(into: 0) { $0 += scope.includes($1) ? 1 : 0 }
    }

    // MARK: Mutation

    /// Rewrites the secret of a password item.
    static func update(_ item: KeychainItem, data: Data) -> OSStatus {
        guard item.itemClass.isEditable else { return errSecUnimplemented }
        let attributes: [String: Any] = [kSecValueData as String: data]
        return SecItemUpdate(matchQuery(for: item) as CFDictionary, attributes as CFDictionary)
    }

    static func delete(_ item: KeychainItem) -> OSStatus {
        SecItemDelete(matchQuery(for: item) as CFDictionary)
    }

    /// Builds a query that resolves to exactly one item: a persistent reference
    /// when we have one, otherwise the class's primary keys.
    private static func matchQuery(for item: KeychainItem) -> [String: Any] {
        if let ref = item.persistentRef {
            return [kSecValuePersistentRef as String: ref]
        }

        var query: [String: Any] = [kSecClass as String: item.itemClass.secClass]
        let primaryKeys: [CFString]
        switch item.itemClass {
        case .genericPassword:
            primaryKeys = [kSecAttrAccount, kSecAttrService, kSecAttrAccessGroup, kSecAttrSynchronizable]
        case .internetPassword:
            primaryKeys = [kSecAttrAccount, kSecAttrServer, kSecAttrProtocol, kSecAttrPort,
                           kSecAttrPath, kSecAttrSecurityDomain, kSecAttrAuthenticationType,
                           kSecAttrAccessGroup, kSecAttrSynchronizable]
        case .certificate:
            primaryKeys = [kSecAttrCertificateType, kSecAttrIssuer, kSecAttrSerialNumber,
                           kSecAttrLabel, kSecAttrAccessGroup]
        case .key:
            primaryKeys = [kSecAttrApplicationLabel, kSecAttrApplicationTag, kSecAttrKeyType,
                           kSecAttrKeyClass, kSecAttrKeySizeInBits, kSecAttrAccessGroup]
        case .identity:
            primaryKeys = [kSecAttrLabel, kSecAttrApplicationLabel, kSecAttrAccessGroup]
        }
        for key in primaryKeys {
            if let value = item.attributes[key as String] { query[key as String] = value }
        }
        return query
    }

    // MARK: Translation

    /// Readable name for a `kSecAttrAccessible` constant.
    static func accessibleName(_ raw: String) -> String {
        // The two "Always" classes are deprecated; their raw values are matched
        // literally so the deprecated symbols aren't referenced.
        let names: [String: String] = [
            kSecAttrAccessibleWhenUnlocked as String: "WhenUnlocked",
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String: "WhenUnlocked · ThisDeviceOnly",
            kSecAttrAccessibleAfterFirstUnlock as String: "AfterFirstUnlock",
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String: "AfterFirstUnlock · ThisDeviceOnly",
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String: "WhenPasscodeSet · ThisDeviceOnly",
            "dk": "Always (deprecated)",
            "dku": "Always · ThisDeviceOnly (deprecated)",
        ]
        return names[raw] ?? raw
    }

    /// Readable message for an `OSStatus` returned by the Security framework.
    static func message(for status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "Success"
        case errSecItemNotFound:
            return "The item no longer exists in the keychain (errSecItemNotFound)."
        case errSecAuthFailed:
            return "Authentication failed — the device may be locked or the item requires user presence (errSecAuthFailed)."
        case errSecDuplicateItem:
            return "An item with these primary attributes already exists (errSecDuplicateItem)."
        case errSecMissingEntitlement:
            return "The app is missing the keychain entitlement. Add the Keychain Sharing capability to the host app (errSecMissingEntitlement)."
        case errSecInteractionNotAllowed:
            return "The keychain is not accessible right now — unlock the device and try again (errSecInteractionNotAllowed)."
        case errSecNotAvailable:
            return "No keychain is available (errSecNotAvailable)."
        case errSecDecode:
            return "The item could not be decoded (errSecDecode)."
        case errSecParam:
            return "The keychain rejected the query parameters (errSecParam)."
        case errSecUserCanceled:
            return "Cancelled."
        case errSecUnimplemented:
            return "This class is read-only in the inspector."
        default:
            return "Keychain error \(status)."
        }
    }

    // MARK: Formatting helpers

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Hex dump of at most `limit` bytes, with an ellipsis when truncated.
    static func hexString(_ data: Data, limit: Int) -> String {
        let slice = data.prefix(limit)
        let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? hex + " …" : hex
    }

    /// `true` when a decoded string is safe to show as text (no stray control bytes).
    static func isPrintable(_ string: String) -> Bool {
        DataValueDecoder.isPrintable(string)
    }

    /// Renders any attribute value for the raw-attributes card.
    static func describe(_ value: Any) -> String {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return (value as? Bool) == true ? "true" : "false"
        }
        switch value {
        case let string as String:
            return string
        case let date as Date:
            return dateFormatter.string(from: date)
        case let data as Data:
            // Attribute blobs get the same progressive decoding as secrets, so a
            // JSON / plist / archived attribute reads as itself rather than hex.
            let decoded = DataValueDecoder.decode(data)
            switch decoded.representation {
            case .binary:
                return "[BINARY]  \(hexString(data, limit: 32))  (\(data.count) bytes)"
            case .text:
                return decoded.text.isEmpty
                    ? "(empty)  (0 bytes)"
                    : "\(decoded.text)  (\(data.count) bytes)"
            case .json, .plist, .archive:
                return "[\(decoded.representation.rawValue)]  (\(data.count) bytes)\n\(decoded.text)"
            }
        case let number as NSNumber:
            return number.stringValue
        default:
            return String(describing: value)
        }
    }

    /// Friendly name for a short keychain attribute key (`acct` → `Account`).
    static func attributeName(_ key: String) -> String {
        if let known = knownAttributeNames[key] { return known }
        return key
    }

    private static let knownAttributeNames: [String: String] = [
        kSecAttrAccount as String: "Account",
        kSecAttrService as String: "Service",
        kSecAttrLabel as String: "Label",
        kSecAttrAccessGroup as String: "Access Group",
        kSecAttrAccessible as String: "Accessible",
        kSecAttrCreationDate as String: "Created",
        kSecAttrModificationDate as String: "Modified",
        kSecAttrDescription as String: "Description",
        kSecAttrComment as String: "Comment",
        kSecAttrCreator as String: "Creator",
        kSecAttrType as String: "Type",
        kSecAttrIsInvisible as String: "Invisible",
        kSecAttrIsNegative as String: "Negative",
        kSecAttrGeneric as String: "Generic",
        kSecAttrSynchronizable as String: "Synchronizable",
        kSecAttrServer as String: "Server",
        kSecAttrPort as String: "Port",
        kSecAttrPath as String: "Path",
        kSecAttrProtocol as String: "Protocol",
        kSecAttrAuthenticationType as String: "Authentication Type",
        kSecAttrSecurityDomain as String: "Security Domain",
        kSecAttrCertificateType as String: "Certificate Type",
        kSecAttrCertificateEncoding as String: "Certificate Encoding",
        kSecAttrSubject as String: "Subject",
        kSecAttrIssuer as String: "Issuer",
        kSecAttrSerialNumber as String: "Serial Number",
        kSecAttrSubjectKeyID as String: "Subject Key ID",
        kSecAttrPublicKeyHash as String: "Public Key Hash",
        kSecAttrKeyClass as String: "Key Class",
        kSecAttrKeyType as String: "Key Type",
        kSecAttrKeySizeInBits as String: "Key Size (bits)",
        kSecAttrEffectiveKeySize as String: "Effective Key Size",
        kSecAttrApplicationLabel as String: "Application Label",
        kSecAttrApplicationTag as String: "Application Tag",
        kSecAttrTokenID as String: "Token ID",
        kSecAttrCanEncrypt as String: "Can Encrypt",
        kSecAttrCanDecrypt as String: "Can Decrypt",
        kSecAttrCanDerive as String: "Can Derive",
        kSecAttrCanSign as String: "Can Sign",
        kSecAttrCanVerify as String: "Can Verify",
        kSecAttrCanWrap as String: "Can Wrap",
        kSecAttrCanUnwrap as String: "Can Unwrap",
        kSecAttrIsPermanent as String: "Permanent",
        kSecValueData as String: "Value Data",
        kSecValuePersistentRef as String: "Persistent Ref",
    ]
}

// MARK: - Browser

/// Read/write inspector for the app's keychain, scoped by item class.
///
/// Password items get an inline-editable secret card (masked until you tap the
/// eye); certificates, keys and identities are read-only and labelled as such.
final class KeychainBrowserViewController: UITableViewController {

    // MARK: State

    private var itemClass: KeychainItemClass = .genericPassword
    /// Defaults to the container app's own items — see `KeychainOwnership`.
    private var scope: KeychainScope = .thisApp
    private var items: [KeychainItem] = []
    private var lastStatus: OSStatus = errSecSuccess
    /// How many rows the scope filter removed from the current class.
    private var hiddenCount = 0
    private var counts: [KeychainItemClass: Int] = [:]
    /// Items whose secret is currently shown in the clear, keyed by
    /// `KeychainItem.identity` — **never** by section index, which shifts under
    /// the list on every reload.
    private var revealed = Set<String>()

    private let segment = UISegmentedControl(items: KeychainItemClass.allCases.map { $0.shortTitle })
    private let headerContainer = UIView()
    private let footerLabel = UILabel()
    private let footerContainer = UIView()
    private lazy var scopeButton = UIBarButtonItem(title: scope.buttonTitle, style: .plain,
                                                   target: self, action: #selector(scopeTapped))

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let caption = UIColor(white: 0.45, alpha: 1)

    // MARK: Init

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Keychain"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        let reload = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain,
                                     target: self, action: #selector(reloadTapped))
        reload.tintColor = DebugTheme.accentColor
        scopeButton.tintColor = DebugTheme.accentColor
        scopeButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                           for: .normal)
        scopeButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                           for: .highlighted)
        navigationItem.rightBarButtonItems = [reload, scopeButton]

        segment.selectedSegmentIndex = 0
        segment.selectedSegmentTintColor = DebugTheme.accentColor
        segment.setTitleTextAttributes([
            .foregroundColor: UIColor(white: 0.65, alpha: 1),
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
        ], for: .normal)
        segment.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
        ], for: .selected)
        segment.addTarget(self, action: #selector(classChanged), for: .valueChanged)

        // Sized for real in `viewDidLayoutSubviews` — `view.bounds` is still the
        // placeholder size here, because the presenter force-loads the view
        // before this controller is in a navigation controller or a window.
        headerContainer.backgroundColor = .black
        segment.autoresizingMask = [.flexibleWidth]
        headerContainer.addSubview(segment)
        tableView.tableHeaderView = headerContainer

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = UIColor(white: 0.38, alpha: 1)
        footerLabel.numberOfLines = 0
        footerLabel.autoresizingMask = [.flexibleWidth]
        footerContainer.backgroundColor = .clear
        footerContainer.addSubview(footerLabel)
        tableView.tableFooterView = footerContainer

        tableView.register(KeychainSecretCell.self, forCellReuseIdentifier: KeychainSecretCell.reuseID)
        tableView.register(KeychainMetaCell.self, forCellReuseIdentifier: "Meta")
        tableView.register(KeychainMessageCell.self, forCellReuseIdentifier: "Message")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive

        reloadCounts()
        reloadItems()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
        layoutFooter()
    }

    /// `tableHeaderView` gets no automatic sizing, and re-assigning it is what
    /// makes the table adopt a new height — so only do it when the size actually
    /// changed, otherwise this loops through `viewDidLayoutSubviews`.
    private func layoutHeader() {
        let width = max(tableView.bounds.width, 1)
        guard abs(headerContainer.bounds.width - width) > 0.5
                || headerContainer.bounds.height < 1 else { return }
        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: 54)
        segment.frame = CGRect(x: 12, y: 11, width: max(width - 24, 1), height: 32)
        headerContainer.forceLTR()
        tableView.tableHeaderView = headerContainer
    }

    // MARK: Loading

    private func reloadCounts() {
        for cls in KeychainItemClass.allCases {
            counts[cls] = KeychainInspector.count(cls, scope: scope)
        }
        for (index, cls) in KeychainItemClass.allCases.enumerated() where index < segment.numberOfSegments {
            let count = counts[cls] ?? 0
            segment.setTitle("\(cls.shortTitle) \(count)", forSegmentAt: index)
        }
    }

    private func reloadItems() {
        let result = KeychainInspector.fetch(itemClass, scope: scope)
        items = result.items
        lastStatus = result.status
        hiddenCount = result.hiddenCount
        counts[itemClass] = items.count
        if let index = KeychainItemClass.allCases.firstIndex(of: itemClass),
           index < segment.numberOfSegments {
            segment.setTitle("\(itemClass.shortTitle) \(items.count)", forSegmentAt: index)
        }
        // Reveal state is keyed by item identity, so it survives a reload of the
        // same items; entries for items that vanished are dropped.
        let living = Set(items.map { $0.identity })
        revealed.formIntersection(living)
        tableView.reloadData()
        layoutFooter()
    }

    /// Sizes the explainer footer by hand — `tableFooterView` gets no automatic
    /// sizing. Re-assigning it is what makes the table pick up a new height, so
    /// that only happens when the height actually changed (this runs from
    /// `viewDidLayoutSubviews`, and re-assigning unconditionally would loop).
    /// Explainer for the class, plus what the current scope is filtering on so
    /// the developer can see which access group the list is limited to.
    private var footerText: String {
        var lines = [itemClass.explainer]
        switch scope {
        case .thisApp:
            lines.append("Scope: this app only — access group \(KeychainOwnership.scopeDescription). Items with no access group are included; shared groups and com.apple.* services are not.")
            if hiddenCount > 0 {
                let noun = hiddenCount == 1 ? "item" : "items"
                lines.append("\(hiddenCount) \(noun) hidden in this class. Tap “All” to include shared groups and system entries.")
            }
        case .all:
            lines.append("Scope: everything this process can see, including shared access groups and system entries. Tap “This app” to filter back to \(KeychainOwnership.scopeDescription).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func layoutFooter() {
        let width = max(tableView.bounds.width - 24, 1)
        footerLabel.text = footerText
        let height = ceil(footerLabel.sizeThatFits(CGSize(width: width,
                                                          height: .greatestFiniteMagnitude)).height)
        footerLabel.frame = CGRect(x: 12, y: 16, width: width, height: height)
        let newHeight = height + 32
        guard abs(footerContainer.bounds.height - newHeight) > 0.5 else { return }
        footerContainer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: newHeight)
        footerContainer.forceLTR()
        tableView.tableFooterView = footerContainer
    }

    // MARK: Actions

    @objc private func reloadTapped() {
        view.endEditing(true)
        // The app may have written its first item since the last scan, which is
        // what makes the real access group discoverable.
        KeychainOwnership.invalidate()
        reloadCounts()
        reloadItems()
    }

    /// Toggles between the container app's own items (the default) and every
    /// item the process can see. Scoping itself lives in `KeychainScope.includes`.
    @objc private func scopeTapped() {
        view.endEditing(true)
        scope = scope.toggled
        scopeButton.title = scope.buttonTitle
        // Row identity changes with the scope, so drop per-item UI state.
        revealed.removeAll()
        reloadCounts()
        reloadItems()
    }

    @objc private func classChanged() {
        view.endEditing(true)
        itemClass = KeychainItemClass(rawValue: segment.selectedSegmentIndex) ?? .genericPassword
        revealed.removeAll()
        reloadItems()
    }

    /// Toggles the clear-text reveal for one item. Keyed by identity and
    /// re-resolved to a section here, so a list that shifted between the tap and
    /// the handler can never reload the wrong (or an out-of-range) section.
    private func toggleReveal(identity: String) {
        if revealed.contains(identity) {
            revealed.remove(identity)
            view.endEditing(true)
        } else {
            revealed.insert(identity)
        }
        guard let section = items.firstIndex(where: { $0.identity == identity }) else {
            tableView.reloadData()
            return
        }
        tableView.reloadSections(IndexSet(integer: section), with: .none)
    }

    /// Writes an edited secret back with `SecItemUpdate`, **as Data**: the text
    /// is re-encoded into the representation it was decoded from. A re-encoding
    /// failure is reported inline on the card and nothing is written.
    private func commit(identity: String, text: String, from cell: KeychainSecretCell) {
        guard let item = items.first(where: { $0.identity == identity }) else {
            cell.showError("This item is no longer in the keychain — reload the list.")
            return
        }
        guard item.itemClass.isEditable else {
            cell.showError("\(item.itemClass.title) are read-only in the inspector.")
            return
        }
        guard let decoded = item.decodedSecret else {
            cell.showError("This item's data was not exported, so it can't be rewritten.")
            return
        }
        guard decoded.isEditable else {
            cell.showError(decoded.representation.editHint)
            return
        }
        guard text != decoded.text else {
            cell.clearError()
            return
        }

        let encoded: Data
        do {
            encoded = try DataValueDecoder.encode(text, like: decoded)
        } catch let error as DataValueDecoder.EncodeError {
            cell.showError(error.message)
            return
        } catch {
            cell.showError(error.localizedDescription)
            return
        }

        cell.clearError()
        let status = KeychainInspector.update(item, data: encoded)
        view.endEditing(true)
        // Deferred: the field is still resigning first responder when the row
        // would be rebuilt underneath it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if status != errSecSuccess {
                self.presentStatus(status, title: "Could not update item")
            }
            self.reloadItems()
        }
    }

    private func confirmDelete(identity: String) {
        guard let item = items.first(where: { $0.identity == identity }) else { return }
        let alert = UIAlertController(
            title: "Delete keychain item?",
            message: "\(item.displayName)\n\nThis removes the item from the \(item.itemClass.title.lowercased()) class permanently.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let status = KeychainInspector.delete(item)
            if status != errSecSuccess {
                self.presentStatus(status, title: "Could not delete item")
            }
            self.reloadCounts()
            self.reloadItems()
        })
        alert.view.forceLTR()
        present(alert, animated: true)
    }

    private func presentStatus(_ status: OSStatus, title: String) {
        let alert = UIAlertController(title: title,
                                      message: KeychainInspector.message(for: status),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.view.forceLTR()
        present(alert, animated: true)
    }

    // MARK: Empty state

    private var emptyStateText: (title: String, body: String) {
        let plural = itemClass.title.lowercased()
        switch lastStatus {
        case errSecMissingEntitlement:
            return ("Keychain unavailable",
                    "This app has no keychain entitlement, so the keychain cannot be queried at all.\n\nAdd the Keychain Sharing capability (Signing & Capabilities → + Capability → Keychain Sharing) to the host app target, then run again.")
        case errSecNotAvailable:
            return ("Keychain unavailable",
                    "No keychain is available to this process (errSecNotAvailable), so nothing can be listed.")
        case errSecItemNotFound, errSecSuccess:
            guard scope == .thisApp else {
                return ("Nothing stored",
                        "No \(plural) are visible to this process at all, in any access group.")
            }
            if hiddenCount > 0 {
                let noun = hiddenCount == 1 ? "item" : "items"
                return ("Nothing for this app",
                        "This app has no \(plural) of its own (access group \(KeychainOwnership.scopeDescription)).\n\n\(hiddenCount) \(noun) from shared groups or system services \(hiddenCount == 1 ? "is" : "are") hidden — tap “All” in the nav bar to see everything the process can read.")
            }
            return ("Nothing for this app",
                    "This app has no \(plural) in the keychain (access group \(KeychainOwnership.scopeDescription)). Store something and tap the reload button.")
        case errSecInteractionNotAllowed:
            return ("Keychain unavailable",
                    "The keychain cannot be read while the device is locked (errSecInteractionNotAllowed). Unlock the device and reload.")
        default:
            return ("Keychain query failed", KeychainInspector.message(for: lastStatus))
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        items.isEmpty ? 1 : items.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // The empty state borrows section 0 row 0, so nothing below may assume
        // a section index maps to an item — every accessor range-checks first.
        guard items.indices.contains(section) else { return 1 }
        return items[section].itemClass.isEditable ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let spacer = UIView()
        spacer.backgroundColor = .clear
        return spacer
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 4 : 14
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard items.indices.contains(indexPath.section) else {
            return messageCell(at: indexPath)
        }

        let item = items[indexPath.section]

        // Row 0 — the attribute summary card (tap for all raw attributes).
        if indexPath.row == 0 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "Meta", for: indexPath) as? KeychainMetaCell else {
                return messageCell(at: indexPath)
            }
            cell.configure(item: item, revealed: revealed.contains(item.identity))
            return cell
        }

        // Row 1 — the decoded, editable secret (password classes only).
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: KeychainSecretCell.reuseID, for: indexPath) as? KeychainSecretCell else {
            return messageCell(at: indexPath)
        }
        let identity = item.identity
        let isRevealed = revealed.contains(identity)
        cell.configure(item: item, revealed: isRevealed)
        // Item identity travels in the closures — never a section index, which
        // is stale the moment a reload lands.
        cell.onToggleReveal = { [weak self] in self?.toggleReveal(identity: identity) }
        cell.onCopy = { text in UIPasteboard.general.string = text }
        cell.onSave = { [weak self, weak cell] text in
            guard let self, let cell else { return }
            self.commit(identity: identity, text: text, from: cell)
        }
        return cell
    }

    private func messageCell(at indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "Message", for: indexPath) as? KeychainMessageCell else {
            let fallback = UITableViewCell(style: .default, reuseIdentifier: nil)
            fallback.backgroundColor = .clear
            fallback.contentView.backgroundColor = .clear
            fallback.selectionStyle = .none
            return fallback
        }
        let text = emptyStateText
        cell.configure(title: text.title, body: text.body)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row == 0, items.indices.contains(indexPath.section) else { return }
        let detail = KeychainItemDetailViewController(item: items[indexPath.section])
        navigationController?.pushViewController(detail, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        items.indices.contains(indexPath.section)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard items.indices.contains(indexPath.section) else { return nil }
        let identity = items[indexPath.section].identity
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(identity: identity)
            completion(true)
        }
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }
}

// MARK: - Summary card

/// Read-only card listing the translated attributes of one keychain item, with a
/// READ-ONLY badge for the classes that cannot be edited.
final class KeychainMetaCell: UITableViewCell {

    private let card = UIView()
    private let titleLabel = UILabel()
    private let classPill = PaddedPillLabel()
    private let readOnlyPill = PaddedPillLabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let rowsStack = UIStackView()

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

        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.numberOfLines = 2

        classPill.configureAsPill(background: UIColor(white: 0.22, alpha: 1),
                                  textColor: UIColor(white: 0.72, alpha: 1))
        readOnlyPill.configureAsPill(background: UIColor(red: 0.95, green: 0.60, blue: 0.35, alpha: 0.22),
                                     textColor: UIColor(red: 0.98, green: 0.72, blue: 0.48, alpha: 1))
        readOnlyPill.text = "READ-ONLY"

        chevron.tintColor = UIColor(white: 0.38, alpha: 1)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true

        let pillRow = UIStackView(arrangedSubviews: [classPill, readOnlyPill, UIView(), chevron])
        pillRow.axis = .horizontal
        pillRow.spacing = 6
        pillRow.alignment = .center

        rowsStack.axis = .vertical
        rowsStack.spacing = 8

        let stack = UIStackView(arrangedSubviews: [pillRow, titleLabel, rowsStack])
        stack.axis = .vertical
        stack.spacing = 8
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

    func configure(item: KeychainItem, revealed: Bool) {
        titleLabel.text = item.displayName
        classPill.text = item.itemClass.shortTitle.uppercased()
        readOnlyPill.isHidden = item.itemClass.isEditable

        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var pairs: [(String, String)] = []
        func add(_ caption: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            pairs.append((caption, value))
        }
        add("ACCOUNT", item.account)
        add("SERVICE", item.service)
        add("SERVER", item.server)
        add("LABEL", item.label)
        add("ACCESS GROUP", item.accessGroup)
        add("ACCESSIBLE", item.accessibleDescription)
        add("CREATED", item.created.map { KeychainInspector.dateFormatter.string(from: $0) })
        add("MODIFIED", item.modified.map { KeychainInspector.dateFormatter.string(from: $0) })
        if !item.itemClass.isEditable {
            add("VALUE", revealed ? item.revealedSecretDisplay : item.maskedSecretDisplay)
        }
        if pairs.isEmpty { pairs.append(("ATTRIBUTES", "(none reported)")) }

        for (caption, value) in pairs {
            rowsStack.addArrangedSubview(makeRow(caption: caption, value: value))
        }
        forceLTR()
    }

    private func makeRow(caption: String, value: String) -> UIView {
        let captionLabel = UILabel()
        captionLabel.text = caption
        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = UIColor(white: 0.45, alpha: 1)

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = UIColor(white: 0.88, alpha: 1)
        valueLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }
}

// MARK: - Secret card

/// The secret of a password item: masked until the eye is tapped, then shown as
/// whatever the blob decoded into (JSON / plist / archive / text / hex) with the
/// winning representation on a pill.
///
/// Editing goes through an explicit SAVE rather than `editingDidEnd`, so the
/// write is never triggered by a cell being recycled mid-edit, and the caller
/// re-encodes the text back into the *same* representation before `SecItemUpdate`.
final class KeychainSecretCell: UITableViewCell {

    static let reuseID = "KeychainSecretCell"

    var onToggleReveal: (() -> Void)?
    var onSave: ((String) -> Void)?
    var onCopy: ((String) -> Void)?

    private let card = UIView()
    private let caption = UILabel()
    private let nameLabel = UILabel()
    private let formatPill = PaddedPillLabel()
    private let lockPill = PaddedPillLabel()
    private let byteLabel = UILabel()
    private let separator = UIView()
    private let valueCaption = UILabel()
    private let maskedLabel = UILabel()
    private let textView = UITextView()
    private let errorLabel = UILabel()
    private let note = UILabel()
    private let eyeButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let revertButton = UIButton(type: .system)
    private let buttonRow = UIStackView()

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

        for label in [caption, valueCaption] {
            label.font = .systemFont(ofSize: 10, weight: .heavy)
            label.textColor = UIColor(white: 0.45, alpha: 1)
        }
        caption.text = "ITEM"
        valueCaption.text = "SECRET"

        nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = DebugTheme.accentColor
        nameLabel.numberOfLines = 2

        byteLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        byteLabel.textColor = UIColor(white: 0.45, alpha: 1)

        formatPill.configureAsPill(background: UIColor(white: 0.22, alpha: 1),
                                   textColor: UIColor(white: 0.85, alpha: 1))
        lockPill.configureAsPill(background: UIColor(red: 0.95, green: 0.60, blue: 0.35, alpha: 0.22),
                                 textColor: UIColor(red: 0.98, green: 0.72, blue: 0.48, alpha: 1))
        lockPill.text = "READ-ONLY"

        maskedLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        maskedLabel.textColor = UIColor(white: 0.70, alpha: 1)
        maskedLabel.numberOfLines = 1

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
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
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

        eyeButton.tintColor = DebugTheme.accentColor
        eyeButton.setImage(UIImage(systemName: "eye.fill"), for: .normal)
        eyeButton.setContentHuggingPriority(.required, for: .horizontal)
        eyeButton.addTarget(self, action: #selector(eyeTapped), for: .touchUpInside)

        style(copyButton, title: "COPY", filled: false)
        style(revertButton, title: "REVERT", filled: false)
        style(saveButton, title: "SAVE AS DATA", filled: true)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        revertButton.addTarget(self, action: #selector(revertTapped), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [caption, UIView(), lockPill, formatPill, eyeButton])
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

        let stack = UIStackView(arrangedSubviews: [topRow, nameLabel, separator, valueRow,
                                                   maskedLabel, textView, errorLabel, buttonRow, note])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: nameLabel)
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
    @objc private func eyeTapped() { onToggleReveal?() }
    @objc private func copyTapped() { onCopy?(textView.isHidden ? "" : (textView.text ?? "")) }
    @objc private func saveTapped() { onSave?(textView.text ?? "") }
    @objc private func revertTapped() {
        textView.text = originalText
        clearError()
    }

    // MARK: Configure

    override func prepareForReuse() {
        super.prepareForReuse()
        // The editor can still be first responder when this row is recycled.
        if textView.isFirstResponder { textView.resignFirstResponder() }
        onToggleReveal = nil
        onSave = nil
        onCopy = nil
        originalText = ""
        clearError()
    }

    func configure(item: KeychainItem, revealed: Bool) {
        nameLabel.text = item.displayName
        eyeButton.isHidden = item.secretData == nil
        eyeButton.setImage(UIImage(systemName: revealed ? "eye.slash.fill" : "eye.fill"), for: .normal)

        let decoded = item.decodedSecret
        if let decoded {
            formatPill.text = decoded.representation.rawValue
            formatPill.isHidden = false
            byteLabel.text = "·  \(decoded.byteCountText)"
        } else {
            formatPill.isHidden = true
            byteLabel.text = nil
        }

        let full = revealed ? (decoded?.text ?? item.revealedSecretDisplay) : ""
        // A truncated body must never be editable — saving it would destroy the
        // part that isn't on screen.
        let capped = full.count > 20_000
        let body = capped ? String(full.prefix(20_000)) + "\n… truncated" : full
        let editable = item.isSecretEditable && revealed && !capped
        lockPill.isHidden = editable

        maskedLabel.isHidden = revealed
        maskedLabel.text = item.maskedSecretDisplay
        textView.isHidden = !revealed
        copyButton.isHidden = !revealed
        buttonRow.isHidden = !editable

        originalText = body
        textView.text = body
        textView.isEditable = editable
        textView.textColor = editable ? UIColor(white: 0.90, alpha: 1) : UIColor(white: 0.70, alpha: 1)

        if !revealed {
            note.text = "Tap the eye to decode and reveal this secret."
        } else if capped {
            note.text = "Too large to edit safely — shown truncated, read-only."
        } else if let decoded {
            note.text = decoded.representation.editHint
                + (item.itemClass.isEditable ? "" : " This class is read-only in the inspector.")
        } else {
            note.text = item.itemClass.returnsData
                ? "This item has no kSecValueData."
                : "Data is not exported for \(item.itemClass.title.lowercased())."
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

/// Centered card used for every empty / error state.
final class KeychainMessageCell: UITableViewCell {

    private let card = UIView()
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

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.62, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = UIColor(white: 0.45, alpha: 1)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
        forceLTR()
    }

    func configure(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
        forceLTR()
    }
}

// MARK: - Attribute card

/// Caption + monospaced value card, used by the raw-attribute detail screen.
final class KeychainAttributeCell: UITableViewCell {

    private let card = UIView()
    private let captionLabel = UILabel()
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

        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = UIColor(white: 0.45, alpha: 1)
        captionLabel.numberOfLines = 0

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = UIColor(white: 0.88, alpha: 1)
        valueLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        forceLTR()
    }

    func configure(caption: String, value: String) {
        captionLabel.text = caption.uppercased()
        valueLabel.text = value
        forceLTR()
    }
}

// MARK: - Pill

/// Small uppercase badge with internal padding.
final class PaddedPillLabel: UILabel {

    private var insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

    func configureAsPill(background: UIColor, textColor: UIColor) {
        font = .systemFont(ofSize: 9, weight: .heavy)
        self.textColor = textColor
        backgroundColor = background
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}

// MARK: - Detail

/// Every raw attribute of one keychain item, one monospace card per attribute.
final class KeychainItemDetailViewController: UITableViewController {

    private let item: KeychainItem
    private var revealed = false
    private var rows: [(caption: String, value: String)] = []

    init(item: KeychainItem) {
        self.item = item
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Keychain Item"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        var buttons: [UIBarButtonItem] = [
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                            target: self, action: #selector(copyTapped)),
        ]
        if item.secretData != nil {
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "eye.fill"), style: .plain,
                                           target: self, action: #selector(revealTapped)))
        }
        buttons.forEach { $0.tintColor = DebugTheme.accentColor }
        navigationItem.rightBarButtonItems = buttons

        tableView.register(KeychainAttributeCell.self, forCellReuseIdentifier: "Attr")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.contentInset.top = 8

        rebuildRows()
        view.forceLTR()
    }

    private func rebuildRows() {
        var result: [(String, String)] = [
            ("Class", item.itemClass.title),
            ("Editable", item.itemClass.isEditable ? "Yes — secret can be rewritten" : "No — read-only class"),
        ]
        if let accessible = item.accessibleDescription {
            result.append(("Accessible (translated)", accessible))
        }

        // Every raw attribute, alphabetical by readable name.
        let attributes = item.attributes.sorted {
            KeychainInspector.attributeName($0.key).localizedCaseInsensitiveCompare(
                KeychainInspector.attributeName($1.key)) == .orderedAscending
        }
        for (key, value) in attributes {
            let caption = "\(KeychainInspector.attributeName(key))  ·  \(key)"
            if key == kSecValueData as String {
                result.append((caption, revealed ? item.revealedSecretDisplay : item.maskedSecretDisplay))
            } else {
                result.append((caption, KeychainInspector.describe(value)))
            }
        }
        rows = result.map { (caption: $0.0, value: $0.1) }
        tableView.reloadData()
    }

    @objc private func revealTapped() {
        revealed.toggle()
        navigationItem.rightBarButtonItems?.last?.image =
            UIImage(systemName: revealed ? "eye.slash.fill" : "eye.fill")
        rebuildRows()
    }

    @objc private func copyTapped() {
        // The secret is only copied when it is currently revealed.
        let dump = rows.map { "\($0.caption)\n\($0.value)" }.joined(separator: "\n\n")
        UIPasteboard.general.string = dump
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "Attr", for: indexPath) as? KeychainAttributeCell,
              rows.indices.contains(indexPath.row) else {
            let fallback = UITableViewCell(style: .default, reuseIdentifier: nil)
            fallback.backgroundColor = .clear
            fallback.contentView.backgroundColor = .clear
            fallback.selectionStyle = .none
            return fallback
        }
        let row = rows[indexPath.row]
        cell.configure(caption: row.caption, value: row.value)
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        item.itemClass.explainer
    }
}
