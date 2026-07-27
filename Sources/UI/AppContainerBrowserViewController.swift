//
//  AppContainerBrowserViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - File kind

/// Coarse classification of a file, used for both the row icon and to decide
/// how the viewer renders the contents. (See FILE-BROWSER.)
enum AppContainerFileKind {
    case directory
    case json
    case text
    case image
    case database
    case archive
    case binary

    /// Extensions rendered as plain monospace text.
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "html", "htm", "xml", "plist",
        "md", "markdown", "yml", "yaml", "strings", "css", "js", "swift",
        "h", "m", "c", "cpp", "sh", "conf", "ini", "srt", "vtt",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif",
    ]
    private static let databaseExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "sqlitedb", "realm", "sqlite-wal", "sqlite-shm",
    ]
    private static let archiveExtensions: Set<String> = ["zip", "gz", "tar", "ipa", "car"]

    static func kind(for url: URL, isDirectory: Bool) -> AppContainerFileKind {
        if isDirectory { return .directory }
        let ext = url.pathExtension.lowercased()
        if ext == "json" || ext == "geojson" { return .json }
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        if databaseExtensions.contains(ext) { return .database }
        if archiveExtensions.contains(ext) { return .archive }
        return .binary
    }

    var symbolName: String {
        switch self {
        case .directory: return "folder.fill"
        case .json:      return "curlybraces"
        case .text:      return "doc.text"
        case .image:     return "photo"
        case .database:  return "cylinder.split.1x2"
        case .archive:   return "doc.zipper"
        case .binary:    return "doc"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .directory: return DebugTheme.accentColor
        case .json:      return UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
        case .text:      return UIColor(white: 0.78, alpha: 1)
        case .image:     return UIColor(red: 0.55, green: 0.72, blue: 1.0, alpha: 1)
        case .database:  return UIColor(red: 0.78, green: 0.60, blue: 1.0, alpha: 1)
        case .archive:   return UIColor(red: 0.95, green: 0.60, blue: 0.45, alpha: 1)
        case .binary:    return UIColor(white: 0.55, alpha: 1)
        }
    }

    var label: String {
        switch self {
        case .directory: return "FOLDER"
        case .json:      return "JSON"
        case .text:      return "TEXT"
        case .image:     return "IMAGE"
        case .database:  return "DATABASE"
        case .archive:   return "ARCHIVE"
        case .binary:    return "BINARY"
        }
    }
}

// MARK: - Entry model

/// One row in the browser: a file or a directory inside the app container.
struct AppContainerEntry {
    let url: URL
    let displayName: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    /// Number of items directly inside, for directories.
    let childCount: Int?
    /// Replaces the computed caption (used by the root screen to show the path).
    let subtitleOverride: String?

    var kind: AppContainerFileKind { AppContainerFileKind.kind(for: url, isDirectory: isDirectory) }
}

// MARK: - Paths helper

/// Resolves the app-container roots and answers "may this file be deleted?".
enum AppContainerPaths {

    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    static var library: URL? { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first }
    static var caches: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first }
    static var preferences: URL? { library?.appendingPathComponent("Preferences", isDirectory: true) }
    static var temporary: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    static var bundle: URL { Bundle.main.bundleURL }

    // MARK: Virtual roots (not real files)

    /// Sentinel URLs for the two stores that live in the app container but are
    /// not browsable files: UserDefaults and the Keychain. Selecting one of these
    /// rows opens its dedicated inspector instead of a directory listing.
    static let userDefaultsSentinel = URL(string: "swiftydebug-virtual://userdefaults")!
    static let keychainSentinel = URL(string: "swiftydebug-virtual://keychain")!

    static func isVirtual(_ url: URL) -> Bool {
        url.scheme == "swiftydebug-virtual"
    }

    /// Count of defaults the **host app** persisted, excluding SwiftyDebug's own
    /// settings — matches what the UserDefaults inspector lists.
    static var appDefaultsCount: Int {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return 0 }
        return domain.keys.filter { !SettingsKey.isSDKOwned($0) }.count
    }

    /// The two virtual stores, shown above the real folders.
    static func virtualRoots() -> [AppContainerEntry] {
        [
            AppContainerEntry(
                url: userDefaultsSentinel,
                displayName: "User Defaults",
                isDirectory: true, size: 0, modified: nil, childCount: nil,
                subtitleOverride: "\(Self.appDefaultsCount) keys stored by this app"
            ),
            AppContainerEntry(
                url: keychainSentinel,
                displayName: "Keychain",
                isDirectory: true, size: 0, modified: nil, childCount: nil,
                subtitleOverride: "Secure storage for this app"
            ),
        ]
    }

    /// The top-level roots shown on the first screen.
    static func roots() -> [AppContainerEntry] {
        var result: [AppContainerEntry] = virtualRoots()
        func add(_ url: URL?, _ name: String) {
            guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return }
            result.append(AppContainerEntry(
                url: url,
                displayName: name,
                isDirectory: true,
                size: 0,
                modified: nil,
                childCount: childCount(of: url),
                subtitleOverride: shortPath(url)
            ))
        }
        add(documents, "Documents")
        add(library, "Library")
        add(caches, "Library/Caches")
        add(preferences, "Library/Preferences")
        add(temporary, "tmp")
        add(bundle, "Bundle")
        return result
    }

    /// Deletion is only ever offered inside Caches and tmp — never Documents,
    /// Library or the app Bundle.
    static func isDeletableLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let bases = [caches?.standardizedFileURL.path, temporary.standardizedFileURL.path].compactMap { $0 }
        for base in bases where !base.isEmpty {
            if path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") { return true }
        }
        return false
    }

    /// A container-relative path, e.g. `~/Library/Caches/images`.
    static func shortPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func childCount(of url: URL) -> Int? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return contents.count
    }
}

// MARK: - Browser

/// A read-only (delete-in-caches) file explorer over the host app's container.
/// The root screen lists Documents / Library / Caches / Preferences / tmp /
/// Bundle; pushing into a folder shows its contents; tapping a file opens
/// `FileContentViewerViewController`. (See FILE-BROWSER.)
final class AppContainerBrowserViewController: UITableViewController {

    // MARK: Palette

    private static let caption = UIColor(white: 0.48, alpha: 1)

    // MARK: State

    /// nil = root screen (list of container roots).
    private let directory: URL?
    private let screenTitle: String
    /// Presented modally (root) → show a Close button.
    private let showsCloseButton: Bool

    private var entries: [AppContainerEntry] = []
    private var filtered: [AppContainerEntry] = []
    private var searchText: String = ""
    private var loadFailed = false
    private var isLoading = true

    private let searchController = UISearchController(searchResultsController: nil)
    private let emptyLabel = UILabel()

    private lazy var byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: Init

    /// - Parameters:
    ///   - directory: the folder to list; `nil` shows the container roots.
    ///   - title: nav title (folder name).
    init(directory: URL?, title: String, showsCloseButton: Bool = false) {
        self.directory = directory
        self.screenTitle = title
        self.showsCloseButton = showsCloseButton
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = screenTitle
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        navigationItem.titleView = titleLabel

        if showsCloseButton {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Close", style: .plain, target: self, action: #selector(closeTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = DebugTheme.accentColor
        }

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)
        tableView.register(AppContainerFileCell.self, forCellReuseIdentifier: AppContainerFileCell.reuseID)

        // Search
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Filter by name"
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

        // Empty state
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = Self.caption
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        reload()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Contents may have changed while a child screen was open.
        if !isLoading { reload() }
    }

    @objc private func closeTapped() {
        presentingViewController?.dismiss(animated: true)
    }

    // MARK: Loading

    private func reload() {
        guard let directory = directory else {
            entries = AppContainerPaths.roots()
            loadFailed = false
            isLoading = false
            applyFilter()
            return
        }

        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.loadEntries(in: directory)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.entries = result.entries
                self.loadFailed = result.failed
                self.isLoading = false
                self.applyFilter()
            }
        }
    }

    /// Lists a directory. Never throws — an unreadable directory simply reports
    /// `failed = true` so the caller can show an empty state.
    private static func loadEntries(in directory: URL) -> (entries: [AppContainerEntry], failed: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            return ([], true)
        }

        var result: [AppContainerEntry] = []
        result.reserveCapacity(contents.count)
        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            result.append(AppContainerEntry(
                url: url,
                displayName: url.lastPathComponent,
                isDirectory: isDir,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                childCount: isDir ? AppContainerPaths.childCount(of: url) : nil,
                subtitleOverride: nil
            ))
        }

        // Folders first, then alphabetical (case-insensitive).
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return (result, false)
    }

    private func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        updateEmptyState()
        tableView.reloadData()
    }

    private func updateEmptyState() {
        if isLoading {
            emptyLabel.isHidden = true
            return
        }
        if loadFailed {
            emptyLabel.text = "Can’t read this folder.\nThe app doesn’t have permission to list its contents."
        } else if entries.isEmpty {
            emptyLabel.text = "This folder is empty."
        } else if filtered.isEmpty {
            emptyLabel.text = "No items match “\(searchText)”."
        }
        emptyLabel.isHidden = !(loadFailed || filtered.isEmpty)
    }

    // MARK: Captions

    private func caption(for entry: AppContainerEntry) -> String {
        if let override = entry.subtitleOverride { return override }
        if entry.isDirectory {
            guard let count = entry.childCount else { return "unreadable" }
            return count == 1 ? "1 item" : "\(count) items"
        }
        var parts = [byteFormatter.string(fromByteCount: max(entry.size, 0))]
        if let modified = entry.modified {
            parts.append(dateFormatter.string(from: modified))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filtered.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AppContainerFileCell.reuseID, for: indexPath) as! AppContainerFileCell
        let entry = filtered[indexPath.row]
        cell.configure(name: entry.displayName, caption: caption(for: entry), kind: entry.kind)
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < filtered.count else { return }
        let entry = filtered[indexPath.row]

        // Virtual stores open their own inspector rather than a file listing.
        if AppContainerPaths.isVirtual(entry.url) {
            let vc: UIViewController = (entry.url == AppContainerPaths.userDefaultsSentinel)
                ? UserDefaultsBrowserViewController()
                : KeychainBrowserViewController()
            navigationController?.pushViewController(vc, animated: true)
            return
        }

        if entry.isDirectory {
            let child = AppContainerBrowserViewController(directory: entry.url, title: entry.displayName)
            navigationController?.pushViewController(child, animated: true)
        } else {
            let viewer = FileContentViewerViewController(fileURL: entry.url)
            navigationController?.pushViewController(viewer, animated: true)
        }
    }

    // MARK: Swipe to delete (Caches & tmp only)

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard indexPath.row < filtered.count else { return false }
        let entry = filtered[indexPath.row]
        // Never the virtual stores, files only — never folders, and never
        // outside Caches / tmp.
        guard !AppContainerPaths.isVirtual(entry.url) else { return false }
        guard !entry.isDirectory else { return false }
        return AppContainerPaths.isDeletableLocation(entry.url)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard self.tableView(tableView, canEditRowAt: indexPath) else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(at: indexPath, completion: completion)
        }
        action.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func confirmDelete(at indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
        guard indexPath.row < filtered.count else { completion(false); return }
        let entry = filtered[indexPath.row]

        let alert = UIAlertController(
            title: "Delete File",
            message: "Delete “\(entry.displayName)” from disk? This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { completion(false); return }
            do {
                try FileManager.default.removeItem(at: entry.url)
                self.entries.removeAll { $0.url == entry.url }
                self.filtered.remove(at: indexPath.row)
                self.tableView.deleteRows(at: [indexPath], with: .automatic)
                self.updateEmptyState()
                completion(true)
            } catch {
                completion(false)
                let failure = UIAlertController(
                    title: "Delete Failed",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                failure.addAction(UIAlertAction(title: "OK", style: .cancel))
                self.present(failure, animated: true)
            }
        })
        present(alert, animated: true)
    }
}

// MARK: - UISearchResultsUpdating

extension AppContainerBrowserViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        applyFilter()
    }
}

// MARK: - Cell

/// Card row: icon + name, with a caption line (size · date, or item count) and a
/// chevron for folders. Matches `KeyValueCardCell`'s card treatment.
final class AppContainerFileCell: UITableViewCell {

    static let reuseID = "AppContainerFileCell"

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let captionColor = UIColor(white: 0.48, alpha: 1)

    private let card = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let captionLabel = UILabel()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        let selected = UIView()
        selected.backgroundColor = .clear
        selectedBackgroundView = selected

        card.backgroundColor = Self.cardBG
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle

        captionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        captionLabel.textColor = Self.captionColor
        captionLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [nameLabel, captionLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textStack)

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.tintColor = UIColor(white: 0.45, alpha: 1)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])

        forceLTR()
    }

    func configure(name: String, caption: String, kind: AppContainerFileKind) {
        nameLabel.text = name
        captionLabel.text = caption
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        iconView.image = UIImage(systemName: kind.symbolName, withConfiguration: config)
        iconView.tintColor = kind.tintColor
        chevron.isHidden = false
    }
}
