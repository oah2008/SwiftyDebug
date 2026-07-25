//
//  WebViewStorageViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import WebKit

// MARK: - WebView picker

/// Lists all live WKWebViews so the user can pick which one to inspect storage
/// for. (Storage is per-web-view.)
final class WebViewStoragePickerViewController: UITableViewController {

    private var webViews: [WKWebView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        let titleLabel = UILabel()
        titleLabel.text = "Web Views"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"), style: .plain,
            target: self, action: #selector(refreshTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        tableView.register(WebViewCardCell.self, forCellReuseIdentifier: "WVCard")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        tableView.contentInset.bottom = 24
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTapped()
    }

    @objc private func refreshTapped() {
        webViews = WKWebViewSwizzling.liveWebViews()
        if let label = navigationItem.titleView as? UILabel {
            label.text = webViews.isEmpty ? "Web Views" : "Web Views · \(webViews.count)"
            label.sizeToFit()
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(webViews.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Bounds guard rather than `isEmpty` — the live web-view list can shrink
        // between the row count and this call (web views are weakly held and can
        // deallocate at any time).
        if indexPath.row >= webViews.count {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "empty")
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.textLabel?.text = "No live web views"
            cell.textLabel?.textColor = UIColor(white: 0.5, alpha: 1)
            cell.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            cell.textLabel?.textAlignment = .center
            cell.detailTextLabel?.text = "Open a screen with a WKWebView, then pull refresh."
            cell.detailTextLabel?.textColor = UIColor(white: 0.35, alpha: 1)
            cell.detailTextLabel?.font = .systemFont(ofSize: 12)
            cell.detailTextLabel?.textAlignment = .center
            cell.forceLTR()
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "WVCard", for: indexPath) as! WebViewCardCell
        cell.configure(webView: webViews[indexPath.row], index: indexPath.row)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !webViews.isEmpty, indexPath.row < webViews.count else { return }
        navigationController?.pushViewController(
            WebViewStorageViewController(webView: webViews[indexPath.row]), animated: true
        )
    }
}

// MARK: - WebView card cell

/// Identifies one live WKWebView at a glance: page title, full URL, host, and
/// load state.
///
/// Built from real constraints rather than the stock `UITableViewCell` labels —
/// those don't self-size with `numberOfLines = 0` + `automaticDimension`, which
/// is what broke this list's layout.
private final class WebViewCardCell: UITableViewCell {

    private let card = UIView()
    private let indexPill = PaddedPill()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let hostLabel = UILabel()
    private let statePill = PaddedPill()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = UIColor(white: 0.62, alpha: 1)
        urlLabel.numberOfLines = 3

        hostLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hostLabel.textColor = DebugTheme.accentColor

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(UIColor(white: 0.4, alpha: 1), renderingMode: .alwaysOriginal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        // Top row: index pill + state pill
        let pills = UIStackView(arrangedSubviews: [indexPill, statePill, UIView()])
        pills.axis = .horizontal
        pills.spacing = 6
        pills.alignment = .center

        let stack = UIStackView(arrangedSubviews: [pills, titleLabel, hostLabel, urlLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(7, after: pills)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            // Text drives the height: pinned top AND bottom.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.12) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        }
    }

    func configure(webView: WKWebView, index: Int) {
        indexPill.set(text: "#\(index + 1)",
                      color: UIColor(white: 0.6, alpha: 1),
                      background: UIColor(white: 0.22, alpha: 1))

        let url = webView.url
        let hasPage = (url != nil)

        if webView.isLoading {
            statePill.set(text: "LOADING", color: .black, background: .systemOrange)
        } else if hasPage {
            statePill.set(text: "LOADED", color: .black, background: DebugTheme.accentColor)
        } else {
            statePill.set(text: "NO PAGE", color: .white, background: UIColor(white: 0.3, alpha: 1))
        }

        let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleLabel.text = pageTitle.isEmpty ? (url?.host ?? "Untitled web view") : pageTitle

        hostLabel.text = url?.host
        hostLabel.isHidden = (url?.host?.isEmpty ?? true)

        urlLabel.text = url?.absoluteString ?? "No page loaded yet"
        urlLabel.textColor = hasPage ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.4, alpha: 1)
    }
}

// MARK: - Small pill label

private final class PaddedPill: UILabel {
    private let inset = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 9, weight: .heavy)
        layer.cornerRadius = 5
        clipsToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color: UIColor, background: UIColor) {
        self.text = text
        self.textColor = color
        self.backgroundColor = background
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}

// MARK: - Storage editor

/// Editable storage viewer for one WKWebView: Local / Session / Cookies.
/// Each entry is a card with the **key on its own line and the value on its own
/// line**, edited inline (no modal alerts) and saved as you type.
final class WebViewStorageViewController: UITableViewController {

    private let service: WebViewStorageService
    private var scope: WebViewStorageService.Scope = .local
    private var items: [WebViewStorageService.Item] = []
    /// Keys added in this session that haven't been written yet (blank cards).
    private var draftKeys = Set<Int>()

    private let segment = UISegmentedControl(items: WebViewStorageService.Scope.allCases.map { $0.title })

    init(webView: WKWebView) {
        self.service = WebViewStorageService(webView: webView)
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Storage"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped)),
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain,
                            target: self, action: #selector(reloadTapped)),
        ]
        navigationItem.rightBarButtonItems?.forEach { $0.tintColor = DebugTheme.accentColor }

        segment.selectedSegmentIndex = 0
        segment.selectedSegmentTintColor = DebugTheme.accentColor
        segment.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1)], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        segment.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)

        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 54))
        header.backgroundColor = .black
        segment.frame = CGRect(x: 12, y: 11, width: view.bounds.width - 24, height: 32)
        segment.autoresizingMask = [.flexibleWidth]
        header.addSubview(segment)
        tableView.tableHeaderView = header

        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive

        reload()
        view.forceLTR()
    }

    private func reload() {
        service.loadItems(scope: scope) { [weak self] items in
            guard let self else { return }
            self.items = items
            self.draftKeys.removeAll()
            self.tableView.reloadData()
        }
    }

    @objc private func reloadTapped() { reload() }

    @objc private func scopeChanged() {
        view.endEditing(true)
        scope = WebViewStorageService.Scope(rawValue: segment.selectedSegmentIndex) ?? .local
        reload()
    }

    @objc private func addTapped() {
        items.append(WebViewStorageService.Item(key: "", value: "", cookie: nil))
        draftKeys.insert(items.count - 1)
        tableView.insertRows(at: [IndexPath(row: items.count - 1, section: 0)], with: .automatic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let ip = IndexPath(row: self.items.count - 1, section: 0)
            (self.tableView.cellForRow(at: ip) as? KeyValueCardCell)?.keyField.becomeFirstResponder()
        }
    }

    /// Writes an entry back to the web view.
    private func commit(row: Int) {
        guard row < items.count else { return }
        let item = items[row]
        guard !item.key.isEmpty else { return }
        if scope == .cookies, let cookie = item.cookie {
            service.updateCookie(cookie, newValue: item.value) { _ in }
        } else {
            service.setItem(scope: scope, key: item.key, value: item.value) { _ in }
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(items.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Bounds guard, NOT `items.isEmpty`: `numberOfRowsInSection` returns
        // max(count, 1) for the empty state, so UIKit can legitimately ask for
        // row 0 when the array is empty — and an async storage reload can shrink
        // `items` between the row count and this call. Indexing without this
        // guard crashed while scrolling.
        guard indexPath.row < items.count else {
            let c = UITableViewCell(style: .subtitle, reuseIdentifier: "empty")
            c.backgroundColor = .clear
            c.selectionStyle = .none
            c.textLabel?.text = "Nothing stored"
            c.textLabel?.textColor = UIColor(white: 0.5, alpha: 1)
            c.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            c.textLabel?.textAlignment = .center
            c.detailTextLabel?.text = "Tap + to add an entry"
            c.detailTextLabel?.textColor = UIColor(white: 0.35, alpha: 1)
            c.detailTextLabel?.font = .systemFont(ofSize: 12)
            c.detailTextLabel?.textAlignment = .center
            c.forceLTR()
            return c
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: indexPath) as! KeyValueCardCell
        let item = items[indexPath.row]
        // Storage entries are always "set" — no SET/REMOVE mode control.
        cell.showsModeControl = false
        // Cookie names identify the cookie, so they're locked once created.
        let keyEditable = (scope != .cookies) || item.cookie == nil
        cell.configure(key: item.key, value: item.value, removing: false, keyEditable: keyEditable)

        cell.onKeyChanged = { [weak self] k in
            guard let self, indexPath.row < self.items.count else { return }
            self.items[indexPath.row].key = k
        }
        cell.onValueChanged = { [weak self] v in
            guard let self, indexPath.row < self.items.count else { return }
            self.items[indexPath.row].value = v
            self.commit(row: indexPath.row)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !items.isEmpty && indexPath.row < items.count
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard style == .delete, indexPath.row < items.count else { return }
        let item = items[indexPath.row]
        // A never-saved draft row just disappears.
        if item.key.isEmpty {
            items.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            return
        }
        service.deleteItem(scope: scope, item: item) { [weak self] _ in self?.reload() }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch scope {
        case .local:   return "localStorage for the page this web view is showing. Edits apply immediately."
        case .session: return "sessionStorage is cleared when the page's tab/session ends."
        case .cookies: return "Cookies from this web view's data store. Editing keeps the original domain & path."
        }
    }
}
