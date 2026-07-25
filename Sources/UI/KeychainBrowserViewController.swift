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

    /// The secret decoded as UTF-8, when it actually looks like text.
    var secretText: String? {
        guard let data = secretData, let s = String(data: data, encoding: .utf8) else { return nil }
        return KeychainInspector.isPrintable(s) ? s : nil
    }

    /// `true` when the secret can be edited as text (binary blobs are shown as hex).
    var isSecretEditable: Bool { itemClass.isEditable && (secretData == nil || secretText != nil) }

    /// The secret as shown when revealed — text, or a hex preview + byte count.
    var revealedSecretDisplay: String {
        guard let data = secretData else {
            return itemClass.returnsData ? "(no data)" : "(not exported for this class)"
        }
        if let text = secretText { return text.isEmpty ? "(empty)" : text }
        return "\(KeychainInspector.hexString(data, limit: 24)) · \(data.count) bytes"
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
        for scalar in string.unicodeScalars {
            if scalar.value == 9 || scalar.value == 10 || scalar.value == 13 { continue }
            if scalar.value < 32 || scalar.value == 127 { return false }
        }
        return true
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
            if let text = String(data: data, encoding: .utf8), isPrintable(text), !text.isEmpty {
                return "\(text)  (\(data.count) bytes)"
            }
            return "\(hexString(data, limit: 32))  (\(data.count) bytes)"
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
    /// Sections whose secret is currently shown in the clear.
    private var revealed = Set<Int>()
    /// Edited-but-not-yet-written secrets, keyed by section.
    private var drafts: [Int: String] = [:]

    private let segment = UISegmentedControl(items: KeychainItemClass.allCases.map { $0.shortTitle })
    private let footerLabel = UILabel()
    private let footerContainer = UIView()
    private lazy var scopeButton = UIBarButtonItem(title: scope.buttonTitle, style: .plain,
                                                   target: self, action: #selector(scopeTapped))

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let caption = UIColor(white: 0.45, alpha: 1)

    /// Identifies the reveal button inside a reused cell's content view ("KC").
    private static let revealButtonTag = 0x4B43
    private static let revealActionID = UIAction.Identifier("swiftydebug.keychain.reveal")

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

        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 54))
        header.backgroundColor = .black
        segment.frame = CGRect(x: 12, y: 11, width: view.bounds.width - 24, height: 32)
        segment.autoresizingMask = [.flexibleWidth]
        header.addSubview(segment)
        tableView.tableHeaderView = header

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = UIColor(white: 0.38, alpha: 1)
        footerLabel.numberOfLines = 0
        footerLabel.autoresizingMask = [.flexibleWidth]
        footerContainer.backgroundColor = .clear
        footerContainer.addSubview(footerLabel)
        tableView.tableFooterView = footerContainer

        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFooter()
    }

    // MARK: Loading

    private func reloadCounts() {
        for cls in KeychainItemClass.allCases {
            counts[cls] = KeychainInspector.count(cls, scope: scope)
        }
        for (index, cls) in KeychainItemClass.allCases.enumerated() {
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
        if let index = KeychainItemClass.allCases.firstIndex(of: itemClass) {
            segment.setTitle("\(itemClass.shortTitle) \(items.count)", forSegmentAt: index)
        }
        revealed.removeAll()
        drafts.removeAll()
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
        // Row identity changes with the scope, so drop per-section UI state.
        revealed.removeAll()
        drafts.removeAll()
        reloadCounts()
        reloadItems()
    }

    @objc private func classChanged() {
        view.endEditing(true)
        itemClass = KeychainItemClass(rawValue: segment.selectedSegmentIndex) ?? .genericPassword
        reloadItems()
    }

    private func toggleReveal(section: Int) {
        guard section < items.count else { return }
        if revealed.contains(section) {
            revealed.remove(section)
            view.endEditing(true)
        } else {
            revealed.insert(section)
        }
        tableView.reloadSections(IndexSet(integer: section), with: .none)
    }

    @objc private func secretEditingEnded(_ sender: UITextField) {
        commit(section: sender.tag)
    }

    /// Writes a pending edit back with `SecItemUpdate`.
    private func commit(section: Int) {
        guard section < items.count, let text = drafts[section] else { return }
        let item = items[section]
        guard item.itemClass.isEditable else { return }
        drafts[section] = nil
        guard text != (item.secretText ?? "") else { return }

        let status = KeychainInspector.update(item, data: Data(text.utf8))
        // Deferred: this runs from `editingDidEnd`, so the field is still
        // resigning first responder when the row would be rebuilt.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if status != errSecSuccess {
                self.presentStatus(status, title: "Could not update item")
            }
            self.reloadItems()
        }
    }

    private func confirmDelete(section: Int) {
        guard section < items.count else { return }
        let item = items[section]
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
        if items.isEmpty { return 1 }
        return itemClass.isEditable ? 2 : 1
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
        if items.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Message", for: indexPath) as! KeychainMessageCell
            let text = emptyStateText
            cell.configure(title: text.title, body: text.body)
            return cell
        }

        let item = items[indexPath.section]

        // Row 0 — the attribute summary card (tap for all raw attributes).
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Meta", for: indexPath) as! KeychainMetaCell
            cell.configure(item: item, revealed: revealed.contains(indexPath.section))
            return cell
        }

        // Row 1 — the editable secret (password classes only).
        let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: indexPath) as! KeyValueCardCell
        let isRevealed = revealed.contains(indexPath.section)
        let editable = item.isSecretEditable && isRevealed

        cell.showsModeControl = false
        cell.configure(key: item.displayName,
                       value: isRevealed ? item.revealedSecretDisplay : item.maskedSecretDisplay,
                       removing: false,
                       keyEditable: false)
        cell.valueField.isEnabled = editable
        cell.valueField.isSecureTextEntry = false
        cell.valueField.tag = indexPath.section
        cell.valueField.removeTarget(self, action: nil, for: .editingDidEnd)
        cell.valueField.addTarget(self, action: #selector(secretEditingEnded(_:)), for: .editingDidEnd)
        cell.onValueChanged = { [weak self] newValue in
            guard let self, editable else { return }
            self.drafts[indexPath.section] = newValue
        }
        cell.onKeyChanged = nil

        // Per-item reveal toggle, overlaid on the card's free top-right corner.
        // The section travels in the action closure, never in `tag` — `tag` is the
        // handle `revealButton(in:)` uses to find the button it already added.
        let eye = revealButton(in: cell)
        let section = indexPath.section
        eye.isHidden = item.secretData == nil
        eye.setImage(UIImage(systemName: isRevealed ? "eye.slash.fill" : "eye.fill"), for: .normal)
        // A same-identifier action replaces the previous one, so reuse can't stack handlers.
        eye.addAction(UIAction(identifier: Self.revealActionID) { [weak self] _ in
            self?.toggleReveal(section: section)
        }, for: .touchUpInside)
        return cell
    }

    /// Lazily adds (once) an eye button on top of a `KeyValueCardCell`. The
    /// shared cell has no reveal affordance of its own and must not be modified.
    private func revealButton(in cell: UITableViewCell) -> UIButton {
        if let existing = cell.contentView.viewWithTag(Self.revealButtonTag) as? UIButton { return existing }
        let button = UIButton(type: .system)
        button.tintColor = DebugTheme.accentColor
        button.setImage(UIImage(systemName: "eye.fill"), for: .normal)
        button.tag = Self.revealButtonTag
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -24),
            button.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        button.forceLTR()
        return button
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !items.isEmpty, indexPath.row == 0, indexPath.section < items.count else { return }
        let detail = KeychainItemDetailViewController(item: items[indexPath.section])
        navigationController?.pushViewController(detail, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !items.isEmpty && indexPath.section < items.count
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard !items.isEmpty, indexPath.section < items.count else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(section: indexPath.section)
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "Attr", for: indexPath) as! KeychainAttributeCell
        let row = rows[indexPath.row]
        cell.configure(caption: row.caption, value: row.value)
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        item.itemClass.explainer
    }
}
