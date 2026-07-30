//
//  WebViewStorageViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import WebKit

// MARK: - Storage editor

/// Editable storage viewer for one WKWebView: Local / Session / Cookies.
///
/// Two rules this screen is built around:
///
/// 1. **Reading changes nothing.** Listing a store runs a read-only enumeration
///    (`length` / `key(i)` / `getItem`) or `getAllCookies`. Nothing is written,
///    re-serialised, normalised or deleted in order to display it.
/// 2. **A write is not believed until it is read back.** WebKit will happily
///    report success for a script that never ran, and the page can overwrite a
///    value microseconds after the SDK sets it. Every save and delete therefore
///    re-reads the store and compares, and says so when the value did not stick.
final class WebViewStorageViewController: UITableViewController {

    private let service: WebViewStorageService
    /// Held weakly and separately from the service, which does not expose it.
    /// The pin store is keyed by web view, so it needs the instance.
    private weak var webView: WKWebView?

    private var scope: WebViewStorageService.Scope = .local
    private var items: [WebViewStorageService.Item] = []
    /// Preview text computed ONCE per reload. Stored values can be hundreds of
    /// KB (cached payloads, session blobs); parsing + re-serializing them inside
    /// `cellForRowAt` — and handing the full string to a label, which forces
    /// TextKit to lay out every character just to truncate it — blew up while
    /// scrolling. Everything the cell needs is precomputed and length-capped.
    private var displays: [StorageRowDisplay] = []

    private let segment = UISegmentedControl(items: WebViewStorageService.Scope.allCases.map { $0.title })
    private let forceSwitch = UISwitch()
    private let forceLabel = UILabel()
    private let reapplyButton = UIButton(type: .system)

    private var pins: WebViewStoragePinStore { .shared }

    init(webView: WKWebView) {
        self.service = WebViewStorageService(webView: webView)
        self.webView = webView
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

        buildHeader()

        tableView.register(StorageRowCell.self, forCellReuseIdentifier: "Card")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive

        if let webView { pins.register(webView) }
        reload()
        view.forceLTR()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeTableHeaderToFit()
    }

    /// A `tableHeaderView` never sizes itself from its own constraints — its
    /// height must be measured and assigned by hand, against the table's real
    /// width. Re-measured on rotation and on any width change.
    private func sizeTableHeaderToFit() {
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        header.frame.size.width = width
        let target = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        guard abs(header.frame.height - target) > 0.5 else { return }
        header.frame.size.height = target
        // Reassigning is what makes UITableView pick up the new height.
        tableView.tableHeaderView = header
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The pin switch may have been changed from the value editor.
        syncForceControls()
        reload()
    }

    // MARK: - Header

    private func buildHeader() {
        segment.selectedSegmentIndex = 0
        segment.selectedSegmentTintColor = DebugTheme.accentColor
        segment.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1)], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        segment.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)

        forceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        forceLabel.textColor = .white
        forceLabel.text = "Force overwrite"

        reapplyButton.setTitle("Re-apply now", for: .normal)
        reapplyButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        reapplyButton.setTitleColor(DebugTheme.accentColor, for: .normal)
        reapplyButton.setTitleColor(UIColor(white: 0.3, alpha: 1), for: .disabled)
        reapplyButton.addTarget(self, action: #selector(reapplyTapped), for: .touchUpInside)

        forceSwitch.onTintColor = DebugTheme.accentColor
        forceSwitch.addTarget(self, action: #selector(forceChanged), for: .valueChanged)

        // Auto Layout, NOT frame math. This ran in `viewDidLoad`, where
        // `view.bounds.width` is still the default size, and the stack carried an
        // autoresizing mask on a `tableHeaderView` — UIKit sizes those specially,
        // so the row ended up wider than the screen and clipped at BOTH edges.
        let header = UIView()
        header.backgroundColor = .black

        segment.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(segment)

        forceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        reapplyButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        reapplyButton.titleLabel?.adjustsFontSizeToFitWidth = true
        reapplyButton.titleLabel?.minimumScaleFactor = 0.8
        forceSwitch.setContentHuggingPriority(.required, for: .horizontal)
        forceSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [forceLabel, UIView(), reapplyButton, forceSwitch])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)

        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            segment.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            segment.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            segment.heightAnchor.constraint(equalToConstant: 32),

            row.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            row.heightAnchor.constraint(equalToConstant: 36),
            // Pinned bottom so the header can size itself.
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])
        header.forceLTR()

        tableView.tableHeaderView = header
        syncForceControls()
    }

    /// Mirrors the pin store into the header controls. Force-overwrite is
    /// per-store, so this runs on every scope change.
    private func syncForceControls() {
        guard let webView else {
            forceSwitch.isOn = false
            forceSwitch.isEnabled = false
            reapplyButton.isEnabled = false
            return
        }
        let set = pins.pinSet(for: webView, scope: scope)
        forceSwitch.isOn = set.isForcing
        forceSwitch.isEnabled = true
        reapplyButton.isEnabled = set.isForcing && !set.isEmpty
        forceLabel.text = set.pins.isEmpty
            ? "Force overwrite"
            : "Force overwrite · \(set.pins.count)"
    }

    // MARK: - Loading

    private func reload(then completion: (([WebViewStorageService.Item]) -> Void)? = nil) {
        let requestedScope = scope
        service.loadItems(scope: requestedScope) { [weak self] items in
            guard let self else { return }
            // The user can switch tabs while a load is in flight; a late result
            // for the previous scope must not replace the current one's rows.
            guard requestedScope == self.scope else { return }

            self.items = items
            self.rebuildDisplays()
            self.syncForceControls()
            self.tableView.reloadData()
            completion?(items)
        }
    }

    /// Recomputes the precomputed row models from `items`. Kept separate from
    /// `reload` so pinning a key can refresh the FORCED badges without another
    /// round trip into the web view.
    private func rebuildDisplays() {
        let set = webView.map { pins.pinSet(for: $0, scope: scope) }
        let isCookies = (scope == .cookies)
        displays = items.map { item in
            var detail: String?
            if isCookies, let c = item.cookie { detail = "\(c.domain)\(c.path)" }
            return StorageRowDisplay(
                key: item.key,
                value: item.value,
                detail: detail,
                isPinned: (set?.isForcing ?? false) && (set?.isPinned(item.key) ?? false))
        }
    }

    @objc private func reloadTapped() { reload() }

    @objc private func scopeChanged() {
        view.endEditing(true)
        scope = WebViewStorageService.Scope(rawValue: segment.selectedSegmentIndex) ?? .local
        syncForceControls()
        reload()
    }

    @objc private func addTapped() {
        presentEditor(for: WebViewStorageService.Item(key: "", value: "", cookie: nil), isNew: true)
    }

    // MARK: - Force overwrite

    @objc private func forceChanged() {
        guard let webView else { forceSwitch.isOn = false; return }
        let on = forceSwitch.isOn
        pins.setForcing(on, webView: webView, scope: scope)
        syncForceControls()
        reload()

        guard on else { return }
        let set = pins.pinSet(for: webView, scope: scope)
        if set.isEmpty {
            // Switching this on with nothing pinned is a legitimate thing to do
            // (pin as you go) but it does nothing *right now*, so say so.
            alert(title: "Force overwrite is on",
                  message: "Nothing is pinned yet. Every value you save from now on is "
                         + "re-applied to \(scope.title) after each page load, until you switch this off.")
        } else {
            pins.reapply(webView: webView, scope: scope) { [weak self] outcome in
                self?.reload()
                self?.reportReapply(outcome, silentOnSuccess: true)
            }
        }
    }

    @objc private func reapplyTapped() {
        guard let webView else { return }
        pins.reapply(webView: webView, scope: scope) { [weak self] outcome in
            self?.reload()
            self?.reportReapply(outcome, silentOnSuccess: false)
        }
    }

    private func reportReapply(_ outcome: WebViewStoragePinStore.Outcome, silentOnSuccess: Bool) {
        switch outcome {
        case .applied(let count):
            guard !silentOnSuccess else { return }
            alert(title: "Re-applied", message: "\(count) pinned key\(count == 1 ? "" : "s") written back.")
        case .notForcing:
            alert(title: "Not forcing", message: "Force overwrite is off for \(scope.title).")
        case .noPins:
            alert(title: "Nothing pinned",
                  message: "No key in \(scope.title) has been edited in this session, so there is "
                         + "nothing to re-apply.")
        case .originMismatch(let pinned, let current):
            alert(title: "Different page",
                  message: "These values were pinned on \(pinned ?? "an unknown origin"), and this web "
                         + "view is showing \(current ?? "no web origin"). Nothing was written — the SDK "
                         + "will not push one site's values into another's storage.")
        case .failed(let reason):
            alert(title: "Could not re-apply", message: reason)
        }
    }

    // MARK: - Saving (always confirmed by a read-back)

    private func presentEditor(for item: WebViewStorageService.Item, isNew: Bool) {
        var subtitle: String?
        if scope == .cookies, let c = item.cookie {
            subtitle = "Domain \(c.domain) · Path \(c.path)"
                + (c.isSecure ? " · Secure" : "")
                + (c.isHTTPOnly ? " · HttpOnly" : "")
        }
        // Cookie names identify the cookie, so they're locked once created.
        let keyEditable = isNew || (scope != .cookies) || item.cookie == nil

        let editor = StorageValueEditorViewController(
            key: item.key, value: item.value, subtitle: subtitle, isKeyEditable: keyEditable)

        editor.onSave = { [weak self] newKey, newValue in
            self?.save(original: item, isNew: isNew, newKey: newKey, newValue: newValue)
        }
        if !isNew {
            editor.onDelete = { [weak self] in self?.delete(item) }
        }

        // Un-pin affordance: a value that keeps reverting to what the SDK set is
        // confusing unless the reason is visible and switchable from the same
        // screen that set it.
        if let webView, !isNew, pins.isPinned(item.key, webView: webView, scope: scope) {
            let scope = self.scope
            let pinnedValue = pins.pinSet(for: webView, scope: scope).value(for: item.key) ?? item.value
            let cookie = item.cookie
            editor.pinControl = StorageValueEditorViewController.PinControl(
                isOn: true,
                title: "Force after page loads",
                footnote: "This key is re-applied after every page load because you edited it. "
                        + "Switch off to leave whatever the page sets.",
                // `[weak webView]`: this closure outlives the push and is owned by
                // the editor, so capturing the host app's web view strongly would
                // keep it alive for as long as the screen is open. (See WEBVIEW-LEAK.)
                onChange: { [weak self, weak webView] on in
                    guard let self, let webView else { return }
                    if on {
                        self.pins.record(webView: webView, scope: scope,
                                         key: item.key, value: pinnedValue, cookie: cookie)
                    } else {
                        self.pins.unpin(webView: webView, scope: scope, key: item.key)
                    }
                })
        }

        navigationController?.pushViewController(editor, animated: true)
    }

    private func save(original: WebViewStorageService.Item, isNew: Bool, newKey: String, newValue: String) {
        guard webView != nil else {
            alert(title: "Web view is gone", message: "It was released, so nothing was written.")
            return
        }
        let scope = self.scope

        if scope == .cookies, let cookie = original.cookie {
            service.updateCookie(cookie, newValue: newValue) { [weak self] _ in
                self?.confirmWrite(scope: scope, key: cookie.name, expected: newValue)
            }
            return
        }

        // A renamed web-storage key means remove the old one, then set the new —
        // strictly sequenced so a failure of the first step is visible in the
        // read-back instead of racing the second.
        if !isNew, newKey != original.key, !original.key.isEmpty {
            service.deleteItem(scope: scope, item: original) { [weak self] _ in
                guard let self else { return }
                if let webView = self.webView {
                    self.pins.unpin(webView: webView, scope: scope, key: original.key)
                }
                self.service.setItem(scope: scope, key: newKey, value: newValue) { [weak self] _ in
                    self?.confirmWrite(scope: scope, key: newKey, expected: newValue)
                }
            }
            return
        }

        service.setItem(scope: scope, key: newKey, value: newValue) { [weak self] _ in
            self?.confirmWrite(scope: scope, key: newKey, expected: newValue)
        }
    }

    /// Re-reads the store and checks the value actually landed.
    ///
    /// The write callbacks are deliberately ignored: the service reports success
    /// whenever `evaluateJavaScript` returns anything at all, including when the
    /// script never ran. The read-back is the only honest confirmation, and it
    /// doubles as detection for the case this screen's force-overwrite toggle
    /// exists for — the page immediately clobbering the value.
    private func confirmWrite(scope: WebViewStorageService.Scope, key: String, expected: String) {
        reload { [weak self] items in
            guard let self, self.scope == scope else { return }
            guard let found = items.first(where: { $0.key == key }) else {
                self.alert(title: "Save did not stick",
                           message: "“\(key)” is not in \(scope.title) after writing. The page may "
                                  + "block storage on this origin, or it removed the key immediately.")
                return
            }
            let recorded = self.recordPin(key: key, value: expected, cookie: found.cookie, scope: scope)
            guard found.value == expected else {
                self.reportClobbered(key: key, scope: scope, canForce: recorded)
                return
            }
            if !recorded, let webView = self.webView, self.pins.isForcing(webView, scope: scope) {
                self.reportUnpinnable(scope: scope)
            }
        }
    }

    /// The value came back different from what was written — almost always the
    /// container app re-injecting on load. This is exactly what force-overwrite
    /// is for, so offer it here rather than leaving the developer guessing.
    ///
    /// `canForce` is false when the value could not be pinned at all; offering
    /// the toggle then would be offering something that cannot work.
    private func reportClobbered(key: String, scope: WebViewStorageService.Scope, canForce: Bool) {
        let a = UIAlertController(
            title: "Value was overwritten",
            message: "“\(key)” was written, but reading it back returned something else — something "
                   + "on the page set it again."
                   + (canForce
                      ? " Turn on force overwrite to re-apply your value after every page load."
                      : " It cannot be force-applied on this page (no web origin)."),
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: canForce ? "Leave it" : "OK", style: .cancel))
        if canForce {
            a.addAction(UIAlertAction(title: "Force overwrite", style: .default) { [weak self] _ in
                guard let self, let webView = self.webView else { return }
                self.pins.setForcing(true, webView: webView, scope: scope)
                self.syncForceControls()
                self.pins.reapply(webView: webView, scope: scope) { [weak self] outcome in
                    self?.reload()
                    self?.reportReapply(outcome, silentOnSuccess: true)
                }
            })
        }
        presentAlert(a)
    }

    /// Force is on but this key can never be re-applied. Never let that pass as
    /// if it were working.
    private func reportUnpinnable(scope: WebViewStorageService.Scope) {
        alert(title: "Cannot force this key",
              message: scope == .cookies
                  ? "The cookie could not be captured, so it will not be re-applied."
                  : "This page has no web origin (\(service.pageURL?.absoluteString ?? "no URL")), "
                    + "so the SDK will not re-apply values into it.")
    }

    /// Remembers a successfully written value so force-overwrite can reinstate
    /// it. Returns false when it could not be pinned.
    @discardableResult
    private func recordPin(key: String,
                           value: String,
                           cookie: HTTPCookie?,
                           scope: WebViewStorageService.Scope) -> Bool {
        guard let webView else { return false }
        let recorded = pins.record(webView: webView, scope: scope, key: key, value: value, cookie: cookie)
        // The FORCED badges were computed before this pin existed — recompute
        // them from the rows already in memory rather than re-reading the store.
        rebuildDisplays()
        syncForceControls()
        tableView.reloadData()
        return recorded
    }

    private func delete(_ item: WebViewStorageService.Item) {
        let scope = self.scope
        service.deleteItem(scope: scope, item: item) { [weak self] _ in
            guard let self else { return }
            // A deleted key is no longer an edit to reinstate. Deletions are
            // deliberately NOT forced: re-deleting a key the page re-creates
            // would be the SDK removing data nobody can see it removing.
            if let webView = self.webView {
                self.pins.unpin(webView: webView, scope: scope, key: item.key)
            }
            self.reload { [weak self] items in
                guard let self, self.scope == scope else { return }
                if items.contains(where: { $0.key == item.key && $0.cookie?.path == item.cookie?.path }) {
                    self.alert(title: "Delete did not stick",
                               message: "“\(item.key)” is still in \(scope.title). "
                                      + (scope == .cookies
                                         ? "The cookie may be re-set by the page or owned by a parent domain."
                                         : "Something on the page wrote it again."))
                }
            }
        }
    }

    private func alert(title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(a)
    }

    /// Every confirmation here arrives one or two async hops after the user hit
    /// Save — by which point the value editor may still be mid-pop and `self` may
    /// no longer be the visible controller. Presenting on `self` in that window
    /// drops the alert on the floor, which is exactly how a failed write would go
    /// unreported.
    private func presentAlert(_ alert: UIAlertController) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let host: UIViewController = self.navigationController ?? self
            guard host.view.window != nil else { return }
            var presenter: UIViewController = host
            while let next = presenter.presentedViewController, !next.isBeingDismissed {
                presenter = next
            }
            presenter.present(alert, animated: true)
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
        guard indexPath.row < items.count, indexPath.row < displays.count else {
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

        guard let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: indexPath) as? StorageRowCell else {
            // Never dequeue twice for one index path — build a plain cell.
            let fallback = UITableViewCell(style: .default, reuseIdentifier: nil)
            fallback.backgroundColor = .clear
            fallback.selectionStyle = .none
            return fallback
        }
        cell.apply(displays[indexPath.row])
        return cell
    }

    /// Tapping a row opens the focused, JSON-aware editor. Editing inline inside
    /// a reusable cell was both fragile and painful for JSON values.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < items.count else { return }
        presentEditor(for: items[indexPath.row], isNew: false)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < items.count
    }

    override func tableView(_ tableView: UITableView,
                            commit style: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard style == .delete, indexPath.row < items.count else { return }
        delete(items[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        // A plain-style table truncates its footer to one line, which cut these
        // explanations off mid-sentence ("Edits…").
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.numberOfLines = 0
        footer.textLabel?.font = .systemFont(ofSize: 12)
        footer.textLabel?.textColor = UIColor(white: 0.45, alpha: 1)
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForFooterInSection section: Int) -> CGFloat {
        44
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        var text: String
        switch scope {
        case .local:   text = "localStorage for the page this web view is showing. Edits apply immediately."
        case .session: text = "sessionStorage is cleared when the page's tab/session ends."
        case .cookies: text = "Cookies from this web view's data store. Editing keeps the original "
                            + "domain, path, expiry, Secure and HttpOnly flags."
        }
        text += "\n\nReading this list never writes: values are enumerated and shown as-is."

        guard let webView else { return text }
        let set = pins.pinSet(for: webView, scope: scope)
        guard set.isForcing else {
            if !set.pins.isEmpty {
                text += "\n\n\(set.pins.count) key\(set.pins.count == 1 ? "" : "s") edited this session. "
                     + "Turn on force overwrite to re-apply them after each page load."
            }
            return text
        }

        if set.isEmpty {
            text += "\n\nFORCE OVERWRITE IS ON, but nothing is pinned yet — it starts working from your "
                 + "next save."
            return text
        }

        let current = WebViewStoragePinScript.originKey(for: webView.url)
        text += "\n\nFORCE OVERWRITE IS ON for \(set.pins.count) key\(set.pins.count == 1 ? "" : "s") "
             + "(marked FORCED). They are re-written when the document finishes parsing and again when "
             + "loading completes. A page that writes later than that still wins — use Re-apply now."
        if set.origin != current {
            text += "\n\n⚠ Pinned on \(set.origin ?? "an unknown origin"); this web view is on "
                 + "\(current ?? "no web origin"). Nothing is re-applied until it returns to that origin."
        }
        text += "\n\nDeleted keys are never re-deleted, and no key you did not edit is ever touched."
        return text
    }
}

// MARK: - Storage row display model

/// Everything a storage row needs to draw, precomputed and **length-capped**.
///
/// This exists because stored values are unbounded: a single localStorage entry
/// can hold a multi-megabyte cached payload. Parsing that per cell (and letting a
/// label lay out the whole string) crashed while scrolling, so detection and
/// truncation happen exactly once, here.
struct StorageRowDisplay {

    /// Hard cap on what ever reaches a label. Well beyond 3 visible lines.
    private static let previewLimit = 220
    /// Only try to parse JSON for values below this size — anything larger is
    /// summarised by size instead. Parsing megabytes for a preview is never worth it.
    private static let jsonParseLimit = 64 * 1024

    let key: String
    let preview: String
    let detail: String?
    /// "JSON · 12 keys" when the value is a JSON payload, else nil.
    let jsonBadge: String?
    let isEmptyValue: Bool
    /// True when force-overwrite will re-apply this key after page loads.
    let isPinned: Bool

    init(key: String, value: String, detail: String?, isPinned: Bool = false) {
        self.key = key
        self.detail = detail
        self.isPinned = isPinned

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEmptyValue = trimmed.isEmpty

        var badge: String?
        var text: String

        let looksStructured = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksStructured, trimmed.utf8.count <= Self.jsonParseLimit,
           JSONDocument.validate(trimmed).isValid, let doc = JSONDocument(text: trimmed) {
            if let arr = doc.root as? [Any] { badge = "JSON · \(arr.count)" }
            else if let obj = doc.root as? [String: Any] { badge = "JSON · \(obj.count)" }
            else { badge = "JSON" }
            // Minify only the prefix we will actually show.
            text = String(doc.minifiedText().prefix(Self.previewLimit))
        } else if looksStructured, trimmed.utf8.count > Self.jsonParseLimit {
            // Too big to parse for a preview — say so rather than stalling.
            badge = "JSON?"
            text = String(trimmed.prefix(Self.previewLimit))
        } else {
            text = trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(Self.previewLimit))
        }

        // Collapse newlines so a row can't grow unexpectedly tall.
        text = text.replacingOccurrences(of: "\n", with: " ")
        if value.count > Self.previewLimit {
            let bytes = ByteCountFormatter().string(fromByteCount: Int64(value.utf8.count))
            text += "…  (\(bytes))"
        }
        self.preview = text
        self.jsonBadge = badge
    }
}

// MARK: - Storage row cell

/// A display-only row for one stored entry: key, a capped value preview, and a
/// JSON badge when the value is structured. Editing happens on a dedicated
/// screen (`StorageValueEditorViewController`), never inline in a reusable cell.
final class StorageRowCell: UITableViewCell {

    private let card = UIView()
    private let keyLabel = UILabel()
    private let valueLabel = UILabel()
    private let detailLabel = UILabel()
    private let jsonBadge = PaddedPill()
    private let pinBadge = PaddedPill()
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

        keyLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.numberOfLines = 2
        keyLabel.lineBreakMode = .byTruncatingMiddle

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = UIColor(white: 0.8, alpha: 1)
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = UIColor(white: 0.42, alpha: 1)
        detailLabel.numberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingMiddle

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(UIColor(white: 0.4, alpha: 1), renderingMode: .alwaysOriginal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let keyRow = UIStackView(arrangedSubviews: [keyLabel, jsonBadge, pinBadge, UIView()])
        keyRow.axis = .horizontal
        keyRow.spacing = 6
        keyRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [keyRow, valueLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            // Text drives the row height — pinned top AND bottom.
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            stack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clears every per-row flag. `setHighlighted` changes the card colour
    /// outside `apply`, so without this a recycled cell can arrive pressed.
    override func prepareForReuse() {
        super.prepareForReuse()
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        keyLabel.text = nil
        valueLabel.text = nil
        detailLabel.text = nil
        detailLabel.isHidden = true
        jsonBadge.isHidden = true
        pinBadge.isHidden = true
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        }
    }

    /// Pure assignment — no parsing, no allocation of large strings.
    func apply(_ display: StorageRowDisplay) {
        keyLabel.text = display.key.isEmpty ? "(no key)" : display.key
        valueLabel.text = display.preview
        valueLabel.textColor = display.isEmptyValue
            ? UIColor(white: 0.4, alpha: 1) : UIColor(white: 0.8, alpha: 1)

        if let badge = display.jsonBadge {
            jsonBadge.isHidden = false
            jsonBadge.set(text: badge, color: .black, background: DebugTheme.accentColor)
        } else {
            jsonBadge.isHidden = true
        }

        // A value that keeps reverting needs a visible explanation on the row
        // itself, not only in the footer.
        pinBadge.isHidden = !display.isPinned
        if display.isPinned {
            pinBadge.set(text: "FORCED", color: .black, background: .systemYellow)
        }

        detailLabel.text = display.detail
        detailLabel.isHidden = (display.detail?.isEmpty ?? true)
    }
}
