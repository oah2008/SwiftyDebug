//
//  BreakpointInboxViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Shows every request currently **paused** at a breakpoint, so you can inspect
/// it, edit the response, and then release it to the app. (See BREAKPOINTS.)
///
/// The app is genuinely waiting while a row sits here — the list makes that
/// obvious with a live "held for Ns" timer, and offers Resume All as an escape
/// hatch.
final class BreakpointInboxViewController: UITableViewController {

    private var items: [BreakpointCenter.PausedRequest] = []
    /// Breakpoints that were armed but never paused, and why. Shown here because
    /// this is the screen a developer stares at when the pause does not come.
    private var notices: [BreakpointCenter.Notice] = []
    private var observer: NSObjectProtocol?
    private var ticker: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Paused"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Resume All", style: .plain, target: self, action: #selector(resumeAllTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        tableView.register(BreakpointRowCell.self, forCellReuseIdentifier: "BP")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110

        observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }

        reload()
        view.forceLTR()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        // Keep the "held for" timers ticking while visible.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tableView.visibleCells
                .compactMap { $0 as? BreakpointRowCell }
                .forEach { $0.refreshHeldFor() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ticker?.invalidate()
        ticker = nil
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        ticker?.invalidate()
    }

    private func reload() {
        items = BreakpointCenter.shared.pausedRequests
        notices = BreakpointCenter.shared.notices
        if let label = navigationItem.titleView as? UILabel {
            label.text = items.isEmpty ? "Paused" : "Paused · \(items.count)"
            label.sizeToFit()
        }
        navigationItem.rightBarButtonItem?.isEnabled = !items.isEmpty
        tableView.reloadData()
    }

    @objc private func resumeAllTapped() {
        BreakpointCenter.shared.resumeAll()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        notices.isEmpty ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "DIDN'T PAUSE" : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 1 ? notices.count : max(items.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if ip.section == 1 {
            let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            c.backgroundColor = UIColor(white: 0.11, alpha: 1)
            c.selectionStyle = .none
            c.textLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            c.textLabel?.textColor = .systemOrange
            c.textLabel?.numberOfLines = 0
            c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            c.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
            c.detailTextLabel?.numberOfLines = 2
            c.forceLTR()
            guard notices.indices.contains(ip.row) else { return c }
            c.textLabel?.text = notices[ip.row].message
            c.detailTextLabel?.text = notices[ip.row].url
            return c
        }
        if items.isEmpty {
            let c = UITableViewCell(style: .subtitle, reuseIdentifier: "empty")
            c.backgroundColor = .clear
            c.selectionStyle = .none
            c.textLabel?.text = "Nothing paused"
            c.textLabel?.textColor = UIColor(white: 0.5, alpha: 1)
            c.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            c.textLabel?.textAlignment = .center
            c.detailTextLabel?.text = "Arm a breakpoint on an intercept rule, then trigger the request."
            c.detailTextLabel?.textColor = UIColor(white: 0.35, alpha: 1)
            c.detailTextLabel?.font = .systemFont(ofSize: 12)
            c.detailTextLabel?.textAlignment = .center
            c.detailTextLabel?.numberOfLines = 0
            c.forceLTR()
            return c
        }
        // `numberOfRows` is max(count, 1) for the empty state, and `items` can
        // shrink between that count and this call when a request is released.
        guard items.indices.contains(ip.row) else { return UITableViewCell() }
        let cell = tableView.dequeueReusableCell(withIdentifier: "BP", for: ip) as! BreakpointRowCell
        cell.configure(items[ip.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        guard ip.section == 0 else { return }   // notices are read-only
        guard ip.row < items.count else { return }
        let detail = BreakpointDetailViewController(paused: items[ip.row])
        navigationController?.pushViewController(detail, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt ip: IndexPath) -> UISwipeActionsConfiguration? {
        guard ip.section == 0, ip.row < items.count else { return nil }
        let item = items[ip.row]
        let resume = UIContextualAction(style: .normal, title: "Resume") { _, _, done in
            BreakpointCenter.shared.resume(item); done(true)
        }
        resume.backgroundColor = UIColor(red: 0.16, green: 0.50, blue: 0.47, alpha: 1)
        let abort = UIContextualAction(style: .destructive, title: "Abort") { _, _, done in
            BreakpointCenter.shared.abort(item); done(true)
        }
        return UISwipeActionsConfiguration(actions: [resume, abort])
    }
}

// MARK: - Row

private final class BreakpointRowCell: UITableViewCell {

    private let card = UIView()
    private let stagePill = JSONTypeBadgeStyle()
    private let methodLabel = UILabel()
    private let statusLabel = UILabel()
    private let urlLabel = UILabel()
    private let heldLabel = UILabel()
    private weak var item: BreakpointCenter.PausedRequest?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.5).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        methodLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        methodLabel.textColor = DebugTheme.accentColor
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        heldLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        heldLabel.textColor = .systemOrange

        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = UIColor(white: 0.7, alpha: 1)
        urlLabel.numberOfLines = 3

        let top = UIStackView(arrangedSubviews: [stagePill, methodLabel, statusLabel, UIView(), heldLabel])
        top.axis = .horizontal
        top.spacing = 6
        top.alignment = .center

        let stack = UIStackView(arrangedSubviews: [top, urlLabel])
        stack.axis = .vertical
        stack.spacing = 6
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
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: BreakpointCenter.PausedRequest) {
        self.item = item
        stagePill.set(text: item.stage == .beforeSend ? "BEFORE" : "AFTER",
                      color: .black, background: .systemOrange)
        methodLabel.text = item.method
        if let code = item.statusCode {
            statusLabel.text = "\(code)"
            statusLabel.textColor = code >= 400 ? .systemOrange : .systemGreen
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }
        urlLabel.text = item.displayURL
        refreshHeldFor()
    }

    /// Shows how long the request has been held **and how long is left** before
    /// the app stops waiting. Without the countdown there is no way to tell a
    /// request you can still edit from one that is about to be abandoned.
    func refreshHeldFor() {
        guard let item else { return }
        let held = Int(item.heldFor)
        if let left = item.remainingHoldTime {
            heldLabel.text = "held \(held)s · \(Int(left))s left"
            heldLabel.textColor = left < 30 ? .systemOrange : UIColor(white: 0.45, alpha: 1)
        } else {
            heldLabel.text = "held \(held)s"
            heldLabel.textColor = UIColor(white: 0.45, alpha: 1)
        }
    }
}

/// Small pill (kept local so it doesn't collide with other badge types).
private final class JSONTypeBadgeStyle: UILabel {
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
        self.text = text; self.textColor = color; self.backgroundColor = background
    }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

// MARK: - Detail

/// Inspect one paused request and release it. For an `.afterResponse` pause the
/// body opens in the full JSON editor, so you can reshape the payload — including
/// arrays of objects — before the app ever sees it.
private final class BreakpointDetailViewController: UITableViewController {

    private let paused: BreakpointCenter.PausedRequest
    private var editedBody: String
    /// Only overwrite the response body when the developer actually changed it.
    /// Otherwise the original bytes are delivered untouched — which matters for
    /// binary payloads and for anything the pretty-printer can't round-trip.
    private var bodyWasEdited = false

    private enum Row: Int, CaseIterable { case summary, requestHeaders, body, resume, abort }

    /// A body can only be edited after the response arrived, and only when it's
    /// text — binary payloads are passed through byte-for-byte.
    private var isBodyEditable: Bool {
        paused.stage == .afterResponse && !paused.isResponseBodyBinary
    }

    /// The app abandoned the request while it was held, so there is nothing left
    /// to deliver to. Say so — this used to be a silent no-op that looked exactly
    /// like a successful delivery producing an empty screen.
    private func showGaveUpAlert() {
        let held = Int(paused.heldFor)
        let a = UIAlertController(
            title: "App Gave Up On This Request",
            message: "It was held for \(held)s and the app stopped waiting, so the edited response has nowhere to go.\n\nRaise \"Breakpoint hold\" in Settings, or re-run the request and release it sooner.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(a, animated: true)
    }

    init(paused: BreakpointCenter.PausedRequest) {
        self.paused = paused
        self.editedBody = paused.responseBodyText
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let titleLabel = UILabel()
        titleLabel.text = paused.stage == .beforeSend ? "Before Send" : "After Response"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = .systemOrange
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.register(JSONEditorCardCell.self, forCellReuseIdentifier: JSONEditorCardCell.reuseIdentifier)
        view.forceLTR()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    /// The editable response body uses the shared JSON card — the same control,
    /// wording and gesture as the replay editor and the mock editor.
    private func bodyCardCell(_ ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: JSONEditorCardCell.reuseIdentifier, for: ip) as! JSONEditorCardCell
        // The only way into the editor on this screen, so it stays put even while
        // the held payload isn't (yet) valid JSON.
        cell.cardView.alwaysVisible = true
        cell.cardView.showsPreview = true
        cell.cardView.cardTitle = "Edit response body"
        cell.cardView.detailText = "Reshape the payload before the app ever sees it — add, rename, retype or reorder fields."
        cell.cardView.configure(text: editedBody)
        cell.cardView.onTap = { [weak self] in self?.editBody() }
        return cell
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if Row(rawValue: ip.row) == .body, isBodyEditable { return bodyCardCell(ip) }

        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        c.backgroundColor = UIColor(white: 0.11, alpha: 1)
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        c.textLabel?.textColor = .white
        c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        c.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        c.detailTextLabel?.numberOfLines = 0
        c.forceLTR()

        switch Row(rawValue: ip.row)! {
        case .summary:
            c.selectionStyle = .none
            c.textLabel?.text = "\(paused.method)  \(paused.statusCode.map(String.init) ?? "—")"
            c.detailTextLabel?.text = paused.displayURL
        case .requestHeaders:
            c.selectionStyle = .none
            let headers = paused.request.allHTTPHeaderFields ?? [:]
            c.textLabel?.text = "Request headers (\(headers.count))"
            c.detailTextLabel?.text = headers.keys.sorted()
                .map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
        case .body:
            // Editable bodies are handled above by the shared JSON card; this is
            // the read-only case (binary payload, or paused before the response).
            c.textLabel?.text = "Response body"
            if paused.isResponseBodyBinary {
                let bytes = paused.responseBody?.count ?? 0
                c.detailTextLabel?.text = "Binary payload — \(bytes) bytes, delivered unchanged"
            } else {
                let preview = editedBody.trimmingCharacters(in: .whitespacesAndNewlines)
                c.detailTextLabel?.text = preview.isEmpty ? "(empty)" : String(preview.prefix(300))
            }
            c.selectionStyle = .none
        case .resume:
            c.textLabel?.text = paused.stage == .afterResponse ? "Deliver to app" : "Send request"
            c.textLabel?.textColor = DebugTheme.accentColor
            c.textLabel?.textAlignment = .center
            c.detailTextLabel?.text = nil
        case .abort:
            c.textLabel?.text = "Abort request"
            c.textLabel?.textColor = .systemRed
            c.textLabel?.textAlignment = .center
            c.detailTextLabel?.text = nil
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch Row(rawValue: ip.row)! {
        case .body:
            editBody()
        case .resume:
            if bodyWasEdited, let data = editedBody.data(using: .utf8) {
                paused.responseBody = data
            }
            guard BreakpointCenter.shared.resume(paused) else { showGaveUpAlert(); return }
            navigationController?.popViewController(animated: true)
        case .abort:
            guard BreakpointCenter.shared.abort(paused) else { showGaveUpAlert(); return }
            navigationController?.popViewController(animated: true)
        default:
            break
        }
    }

    private func editBody() {
        guard isBodyEditable else { return }
        let editor = JSONEditorViewController(text: editedBody, title: "Response Body")
        editor.saveButtonTitle = "Use Body"
        editor.onSave = { [weak self] doc in
            self?.editedBody = doc.prettyText()
            self?.bodyWasEdited = true
            self?.tableView.reloadData()
        }
        navigationController?.pushViewController(editor, animated: true)
    }
}
