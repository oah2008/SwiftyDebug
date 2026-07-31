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
    ///
    /// `itemClass` is what disambiguates the keys that **collide**: several
    /// `kSecAttr*` constants share one short string, so the lookup table can
    /// only carry one name for them and the item's class decides which name is
    /// the truthful one (see `collidingAttributeKeys`). Passing `nil` keeps the
    /// password-class wording.
    static func attributeName(_ key: String, itemClass: KeychainItemClass? = nil) -> String {
        // kSecAttrType and kSecAttrKeyType are both the literal string "type".
        // On a key/identity that byte is the key algorithm, not a password's
        // four-character type code.
        if key == kSecAttrKeyType as String, let itemClass,
           itemClass == .key || itemClass == .identity {
            return "Key Type"
        }
        if let known = knownAttributeNames[key] { return known }
        return key
    }

    /// The readable names, as **pairs** rather than a dictionary literal.
    ///
    /// This list is deliberately not `[String: String]([...])` literal syntax:
    /// `kSecAttrType` and `kSecAttrKeyType` are both `"type"`, and a dictionary
    /// literal containing the same key twice traps at runtime — "Fatal error:
    /// Dictionary literal contains duplicate keys" — the first time the lazy
    /// static is touched, which was every single open of the keychain detail
    /// screen. Built through `uniquingKeysWith:` instead, first entry wins, and
    /// `attributeName(_:itemClass:)` recovers the losing name from the class.
    static let knownAttributeNamePairs: [(key: String, name: String)] = [
        (kSecAttrAccount as String, "Account"),
        (kSecAttrService as String, "Service"),
        (kSecAttrLabel as String, "Label"),
        (kSecAttrAccessGroup as String, "Access Group"),
        (kSecAttrAccessible as String, "Accessible"),
        (kSecAttrCreationDate as String, "Created"),
        (kSecAttrModificationDate as String, "Modified"),
        (kSecAttrDescription as String, "Description"),
        (kSecAttrComment as String, "Comment"),
        (kSecAttrCreator as String, "Creator"),
        (kSecAttrType as String, "Type"),
        (kSecAttrIsInvisible as String, "Invisible"),
        (kSecAttrIsNegative as String, "Negative"),
        (kSecAttrGeneric as String, "Generic"),
        (kSecAttrSynchronizable as String, "Synchronizable"),
        (kSecAttrServer as String, "Server"),
        (kSecAttrPort as String, "Port"),
        (kSecAttrPath as String, "Path"),
        (kSecAttrProtocol as String, "Protocol"),
        (kSecAttrAuthenticationType as String, "Authentication Type"),
        (kSecAttrSecurityDomain as String, "Security Domain"),
        (kSecAttrCertificateType as String, "Certificate Type"),
        (kSecAttrCertificateEncoding as String, "Certificate Encoding"),
        (kSecAttrSubject as String, "Subject"),
        (kSecAttrIssuer as String, "Issuer"),
        (kSecAttrSerialNumber as String, "Serial Number"),
        (kSecAttrSubjectKeyID as String, "Subject Key ID"),
        (kSecAttrPublicKeyHash as String, "Public Key Hash"),
        (kSecAttrKeyClass as String, "Key Class"),
        (kSecAttrKeyType as String, "Key Type"),
        (kSecAttrKeySizeInBits as String, "Key Size (bits)"),
        (kSecAttrEffectiveKeySize as String, "Effective Key Size"),
        (kSecAttrApplicationLabel as String, "Application Label"),
        (kSecAttrApplicationTag as String, "Application Tag"),
        (kSecAttrTokenID as String, "Token ID"),
        (kSecAttrCanEncrypt as String, "Can Encrypt"),
        (kSecAttrCanDecrypt as String, "Can Decrypt"),
        (kSecAttrCanDerive as String, "Can Derive"),
        (kSecAttrCanSign as String, "Can Sign"),
        (kSecAttrCanVerify as String, "Can Verify"),
        (kSecAttrCanWrap as String, "Can Wrap"),
        (kSecAttrCanUnwrap as String, "Can Unwrap"),
        (kSecAttrIsPermanent as String, "Permanent"),
        (kSecValueData as String, "Value Data"),
        (kSecValuePersistentRef as String, "Persistent Ref"),
    ]

    /// `knownAttributeNamePairs` collapsed into a lookup. `uniquingKeysWith:`
    /// is load-bearing, not defensive style: with a literal this static traps.
    private static let knownAttributeNames: [String: String] = Dictionary(
        knownAttributeNamePairs.map { ($0.key, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The short keys that more than one `kSecAttr*` constant resolves to.
    /// Non-empty on every SDK shipped so far (`"type"`), and the reason the
    /// table above cannot be a dictionary literal.
    static var collidingAttributeKeys: Set<String> {
        var seen: Set<String> = []
        var collisions: Set<String> = []
        for pair in knownAttributeNamePairs where !seen.insert(pair.key).inserted {
            collisions.insert(pair.key)
        }
        return collisions
    }
}

// MARK: - Browser

/// Read/write inspector for the app's keychain, scoped by item class.
///
/// Rows are **display-only**: one card per item showing its name, the
/// attributes worth scanning, and a masked (or revealed) preview of the secret
/// with the representation it decoded into. Tapping a password row pushes
/// `StorageValueEditorViewController` — the same focused, JSON-aware editor the
/// other storage inspectors use — and the save handler re-encodes the text back
/// into the *same* representation before `SecItemUpdate`. Certificates, keys and
/// identities are never writable, so tapping one opens the read-only attribute
/// dump instead; nothing about those rows offers an editor.
///
/// There is deliberately **no inline editing inside a reusable cell**: a text
/// view whose lifetime is tied to cell reuse, plus a per-row reveal button that
/// reloaded the very section it lived in, was the fragile part of this screen.
final class KeychainBrowserViewController: UITableViewController {

    // MARK: Row model

    /// Everything a row needs, derived **once** per reload. Decoding a secret or
    /// parsing JSON inside `cellForRowAt` would re-run on every layout pass.
    private struct Row {
        let item: KeychainItem
        /// `"JSON · n keys"` when the decoded secret is a JSON container.
        let jsonBadge: String?
        /// `true` when the secret can actually be re-encoded and written back.
        let isEditable: Bool

        init(item: KeychainItem) {
            self.item = item
            let text = item.decodedSecret?.text ?? ""
            self.jsonBadge = StorageJSONBadge.summary(for: text)
            // A body this big can't be rendered into an editor safely, and
            // saving a truncated copy would destroy what never reached screen.
            self.isEditable = item.isSecretEditable && text.count <= 20_000
        }

        var identity: String { item.identity }
    }

    // MARK: State

    private var itemClass: KeychainItemClass = .genericPassword
    /// Defaults to the container app's own items — see `KeychainOwnership`.
    private var scope: KeychainScope = .thisApp
    private var rows: [Row] = []
    private var lastStatus: OSStatus = errSecSuccess
    /// How many rows the scope filter removed from the current class.
    private var hiddenCount = 0
    private var counts: [KeychainItemClass: Int] = [:]
    /// One switch for the whole list rather than a button inside every cell:
    /// a per-row reveal had to reload the section it was tapped in, from inside
    /// that section's own cell.
    private var secretsRevealed = false
    /// Error raised by a save/delete that happened as the editor was popping.
    /// Shown from `viewDidAppear`, never mid-transition.
    private var pendingError: (title: String, message: String)?

    private let segment = UISegmentedControl(items: KeychainItemClass.allCases.map { $0.shortTitle })
    private let headerContainer = UIView()
    private let footerLabel = UILabel()
    private let footerContainer = UIView()
    private lazy var scopeButton = UIBarButtonItem(title: scope.buttonTitle, style: .plain,
                                                   target: self, action: #selector(scopeTapped))
    private lazy var revealButton = UIBarButtonItem(image: UIImage(systemName: "eye.fill"), style: .plain,
                                                    target: self, action: #selector(revealTapped))

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
        for item in [reload, scopeButton, revealButton] { item.tintColor = DebugTheme.accentColor }
        scopeButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                           for: .normal)
        scopeButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                           for: .highlighted)
        navigationItem.rightBarButtonItems = [reload, revealButton, scopeButton]

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

        tableView.register(KeychainRowCell.self, forCellReuseIdentifier: KeychainRowCell.reuseID)
        tableView.register(KeychainMessageCell.self, forCellReuseIdentifier: "Message")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)

        reloadCounts()
        reloadItems()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutHeader()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let error = pendingError else { return }
        pendingError = nil
        presentAlert(title: error.title, message: error.message)
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
        rows = result.items.map { Row(item: $0) }
        lastStatus = result.status
        hiddenCount = result.hiddenCount
        counts[itemClass] = rows.count
        if let index = KeychainItemClass.allCases.firstIndex(of: itemClass),
           index < segment.numberOfSegments {
            segment.setTitle("\(itemClass.shortTitle) \(rows.count)", forSegmentAt: index)
        }
        tableView.reloadData()
        layoutFooter()
    }

    private func row(withIdentity identity: String) -> Row? {
        rows.first { $0.identity == identity }
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
        lines.append(itemClass.isEditable
                     ? "Tap a row to open the value editor — JSON secrets get the full tree editor, and a save is re-encoded into the same representation before SecItemUpdate. Swipe left to delete or inspect the raw attributes."
                     : "Tap a row to inspect its raw attributes. This class is read-only.")
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
        // The app may have written its first item since the last scan, which is
        // what makes the real access group discoverable.
        KeychainOwnership.invalidate()
        reloadCounts()
        reloadItems()
    }

    /// Toggles between the container app's own items (the default) and every
    /// item the process can see. Scoping itself lives in `KeychainScope.includes`.
    @objc private func scopeTapped() {
        scope = scope.toggled
        scopeButton.title = scope.buttonTitle
        reloadCounts()
        reloadItems()
    }

    @objc private func classChanged() {
        itemClass = KeychainItemClass(rawValue: segment.selectedSegmentIndex) ?? .genericPassword
        reloadItems()
    }

    @objc private func revealTapped() {
        secretsRevealed.toggle()
        revealButton.image = UIImage(systemName: secretsRevealed ? "eye.slash.fill" : "eye.fill")
        tableView.reloadData()
    }

    // MARK: Writing

    /// Writes an edited secret back with `SecItemUpdate`, **as Data**: the text
    /// is re-encoded into the representation it was decoded from. A re-encoding
    /// failure writes nothing and parks a message for `viewDidAppear`.
    private func commit(identity: String, text: String) {
        guard let item = row(withIdentity: identity)?.item else {
            pendingError = ("Item is gone", "This item is no longer in the keychain — reload the list.")
            return
        }
        guard item.itemClass.isEditable else {
            pendingError = ("Read-only", "\(item.itemClass.title) are read-only in the inspector.")
            return
        }
        guard let decoded = item.decodedSecret else {
            pendingError = ("Nothing to write", "This item's data was not exported, so it can't be rewritten.")
            return
        }
        guard decoded.isEditable else {
            pendingError = ("Can't re-encode", decoded.representation.editHint)
            return
        }
        guard text != decoded.text else { return }

        let encoded: Data
        do {
            encoded = try DataValueDecoder.encode(text, like: decoded)
        } catch let error as DataValueDecoder.EncodeError {
            pendingError = ("Can't save \(decoded.representation.rawValue)", error.message)
            return
        } catch {
            pendingError = ("Can't save", error.localizedDescription)
            return
        }

        let status = KeychainInspector.update(item, data: encoded)
        if status != errSecSuccess {
            pendingError = ("Could not update item", KeychainInspector.message(for: status))
        }
        reloadItems()
    }

    /// Deletes without a second confirmation — the caller (the editor's Delete
    /// button) already asked.
    private func delete(identity: String) {
        guard let item = row(withIdentity: identity)?.item else { return }
        let status = KeychainInspector.delete(item)
        if status != errSecSuccess {
            pendingError = ("Could not delete item", KeychainInspector.message(for: status))
        }
        reloadCounts()
        reloadItems()
    }

    private func confirmDelete(identity: String) {
        guard let item = row(withIdentity: identity)?.item else { return }
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
                self.presentAlert(title: "Could not delete item",
                                  message: KeychainInspector.message(for: status))
            }
            self.reloadCounts()
            self.reloadItems()
        })
        alert.view.forceLTR()
        present(alert, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
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

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // The empty state borrows row 0, so nothing below may assume a row index
        // maps to an item — every accessor range-checks first.
        max(rows.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Each branch dequeues at most **once**: dequeuing a second cell for the
        // same index path (which the old fallback path did, after a failed cast)
        // is an assertion failure in UIKit.
        guard rows.indices.contains(indexPath.row) else {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "Message", for: indexPath) as? KeychainMessageCell
            let text = emptyStateText
            cell?.configure(title: text.title, body: text.body)
            return cell ?? Self.plainFallbackCell()
        }

        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: KeychainRowCell.reuseID, for: indexPath) as? KeychainRowCell
        cell?.configure(item: row.item,
                        jsonBadge: row.jsonBadge,
                        editable: row.isEditable,
                        revealed: secretsRevealed)
        return cell ?? Self.plainFallbackCell()
    }

    private static func plainFallbackCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    /// Tapping a row opens the editor for a writable secret and the read-only
    /// attribute dump for everything else. Nothing here mutates `rows`, resigns a
    /// first responder or reloads the table, so a tap can never re-enter the
    /// table's own update cycle.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        let row = rows[indexPath.row]
        if row.isEditable {
            pushEditor(for: row)
        } else {
            pushDetail(for: row.item)
        }
    }

    private func pushEditor(for row: Row) {
        let identity = row.identity
        let item = row.item
        let editor = StorageValueEditorViewController(
            key: item.displayName,
            value: item.decodedSecret?.text ?? "",
            subtitle: Self.editorSubtitle(for: item),
            // The "key" here is the item's display name, which is derived from
            // its primary attributes — renaming it would mean deleting and
            // re-adding the item, so it stays locked.
            isKeyEditable: false)
        // Item identity travels in the closures — never a row index, which is
        // stale the moment a reload lands.
        editor.onSave = { [weak self] _, newValue in
            self?.commit(identity: identity, text: newValue)
        }
        editor.onDelete = { [weak self] in
            self?.delete(identity: identity)
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func pushDetail(for item: KeychainItem) {
        navigationController?.pushViewController(KeychainItemDetailViewController(item: item), animated: true)
    }

    private static func editorSubtitle(for item: KeychainItem) -> String {
        var parts: [String] = [item.itemClass.title]
        if let account = item.account, !account.isEmpty { parts.append("account \(account)") }
        if let service = item.service, !service.isEmpty { parts.append("service \(service)") }
        if let server = item.server, !server.isEmpty { parts.append("server \(server)") }
        if let group = item.accessGroup, !group.isEmpty { parts.append("group \(group)") }
        var text = parts.joined(separator: "  ·  ")
        if let decoded = item.decodedSecret {
            text += "\n\(decoded.representation.rawValue) · \(decoded.byteCountText) — \(decoded.representation.editHint)"
        }
        return text
    }

    // MARK: Swipe actions

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        rows.indices.contains(indexPath.row)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row) else { return nil }
        let identity = rows[indexPath.row].identity
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(identity: identity)
            completion(true)
        }
        let attributes = UIContextualAction(style: .normal, title: "Attributes") { [weak self] _, _, completion in
            completion(true)
            guard let self, let item = self.row(withIdentity: identity)?.item else { return }
            self.pushDetail(for: item)
        }
        attributes.backgroundColor = UIColor(white: 0.26, alpha: 1)
        let config = UISwipeActionsConfiguration(actions: [delete, attributes])
        config.performsFirstActionWithFullSwipe = false
        return config
    }
}

// MARK: - Row card

/// **Display-only** card for one keychain item: name, the attributes worth
/// scanning, and the secret masked (or revealed) with the representation it
/// decoded into. Editing happens on `StorageValueEditorViewController`.
final class KeychainRowCell: UITableViewCell {

    static let reuseID = "KeychainRowCell"

    private let card = UIView()
    private let classPill = PaddedPillLabel()
    private let readOnlyPill = PaddedPillLabel()
    private let formatPill = PaddedPillLabel()
    private let jsonPill = PaddedPillLabel()
    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private let attributesStack = UIStackView()
    private let separator = UIView()
    private let secretCaption = UILabel()
    private let byteLabel = UILabel()
    private let secretLabel = UILabel()

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
        formatPill.configureAsPill(background: UIColor(white: 0.22, alpha: 1),
                                   textColor: UIColor(white: 0.85, alpha: 1))
        jsonPill.configureAsPill(background: StorageJSONBadge.color, textColor: .black)

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(UIColor(white: 0.40, alpha: 1), renderingMode: .alwaysOriginal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 11).isActive = true

        attributesStack.axis = .vertical
        attributesStack.spacing = 7

        separator.backgroundColor = UIColor(white: 0.22, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        secretCaption.text = "SECRET"
        secretCaption.font = .systemFont(ofSize: 10, weight: .heavy)
        secretCaption.textColor = UIColor(white: 0.45, alpha: 1)

        byteLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        byteLabel.textColor = UIColor(white: 0.45, alpha: 1)

        secretLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        secretLabel.textColor = UIColor(white: 0.85, alpha: 1)
        secretLabel.numberOfLines = 3
        secretLabel.lineBreakMode = .byTruncatingTail

        let pillRow = UIStackView(arrangedSubviews: [classPill, readOnlyPill, jsonPill, formatPill,
                                                     UIView(), chevron])
        pillRow.axis = .horizontal
        pillRow.spacing = 6
        pillRow.alignment = .center

        let secretRow = UIStackView(arrangedSubviews: [secretCaption, byteLabel, UIView()])
        secretRow.axis = .horizontal
        secretRow.spacing = 8
        secretRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [pillRow, titleLabel, attributesStack,
                                                   separator, secretRow, secretLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(10, after: attributesStack)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(4, after: secretRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            // Text drives the row height: pinned to BOTH top and bottom.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
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

    func configure(item: KeychainItem, jsonBadge: String?, editable: Bool, revealed: Bool) {
        titleLabel.text = item.displayName
        classPill.text = item.itemClass.shortTitle.uppercased()
        readOnlyPill.isHidden = editable

        if let decoded = item.decodedSecret {
            formatPill.text = decoded.representation.rawValue
            formatPill.isHidden = false
            byteLabel.text = "·  \(decoded.byteCountText)"
        } else {
            formatPill.isHidden = true
            byteLabel.text = nil
        }

        if let jsonBadge {
            jsonPill.text = jsonBadge
            jsonPill.isHidden = false
        } else {
            jsonPill.isHidden = true
        }

        // Attributes worth scanning without opening the item.
        attributesStack.arrangedSubviews.forEach {
            attributesStack.removeArrangedSubview($0)
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
        add("MODIFIED", item.modified.map { KeychainInspector.dateFormatter.string(from: $0) })
        if pairs.isEmpty { pairs.append(("ATTRIBUTES", "(none reported)")) }
        for (caption, value) in pairs {
            attributesStack.addArrangedSubview(Self.makeRow(caption: caption, value: value))
        }

        let preview = revealed ? Self.revealedPreview(for: item) : item.maskedSecretDisplay
        secretLabel.text = preview
        secretLabel.textColor = revealed
            ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.62, alpha: 1)

        forceLTR()
    }

    /// A single clipped line — the whole value belongs on the editor screen, not
    /// in a list row.
    private static func revealedPreview(for item: KeychainItem) -> String {
        guard let decoded = item.decodedSecret else {
            return item.itemClass.returnsData ? "(no data)" : "(not exported for this class)"
        }
        return decoded.text.isEmpty ? "(empty)" : decoded.previewText
    }

    private static func makeRow(caption: String, value: String) -> UIView {
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
        stack.semanticContentAttribute = .forceLeftToRight
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
        let itemClass = item.itemClass
        let attributes = item.attributes.sorted {
            KeychainInspector.attributeName($0.key, itemClass: itemClass)
                .localizedCaseInsensitiveCompare(
                    KeychainInspector.attributeName($1.key, itemClass: itemClass)) == .orderedAscending
        }
        for (key, value) in attributes {
            let caption = "\(KeychainInspector.attributeName(key, itemClass: itemClass))  ·  \(key)"
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
