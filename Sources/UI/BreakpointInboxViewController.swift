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

/// Inspect one paused request and release it.
///
/// The two stages hold DIFFERENT things, and this screen has to offer what the
/// breakpoint picker promised for each:
///
///  * `.beforeSend` — "Pause before the request leaves the app so you can edit
///    it." Nothing has gone out yet, so the method, the URL, the headers and the
///    body are all editable here and what you leave is what goes on the wire.
///    This screen used to be read-only for a before-send pause, which made the
///    picker's promise false and the stage useless: the only two things you
///    could do were send the request unchanged or abort it.
///  * `.afterResponse` — the exchange is over, so the RESPONSE body opens in the
///    full JSON editor and you reshape the payload — including arrays of
///    objects — before the app ever sees it.
final class BreakpointDetailViewController: UITableViewController {

    private let paused: BreakpointCenter.PausedRequest
    private var editedBody: String
    /// Only overwrite the response body when the developer actually changed it.
    /// Otherwise the original bytes are delivered untouched — which matters for
    /// binary payloads and for anything the pretty-printer can't round-trip.
    private var bodyWasEdited = false

    // MARK: Editable request state (`.beforeSend` only)

    private var editedMethod: String
    private var editedURLString: String
    /// Ordered so a rename or a delete does not reshuffle the rows under the
    /// developer's finger. Seeded from the parked request, sorted by name.
    private var headers: [(name: String, value: String)]
    private var editedRequestBody: String
    private var requestBodyWasEdited = false

    /// The parked request's body as text, decided ONCE in `init` — parsing a
    /// 512 KB payload from `cellForRowAt` would re-parse it on every scroll.
    private let requestBodyText: String
    /// True when the body isn't text at all (an image upload, protobuf…). Such a
    /// body is shown read-only and delivered byte-for-byte, exactly as the
    /// response side treats a binary payload.
    private let isRequestBodyBinary: Bool
    /// True when the body is something the JSON editor can round-trip: empty, or
    /// valid JSON. Form-encoded and other text bodies are read-only rather than
    /// silently rewritten into `{}` by the editor.
    private let isRequestBodyJSONEditable: Bool

    private enum Row {
        /// Method + status + URL, read-only (`.afterResponse`).
        case summary
        case method
        case url
        case header(Int)
        case addHeader
        /// The read-only header dump shown for an `.afterResponse` pause.
        case requestHeaders
        case body
        case resume
        case abort
    }

    private struct SectionModel {
        let title: String?
        let rows: [Row]
    }

    private var sections: [SectionModel] = []

    /// A response body can only be edited after the response arrived, and only
    /// when it's text — binary payloads are passed through byte-for-byte.
    private var isBodyEditable: Bool {
        paused.stage == .afterResponse && !paused.isResponseBodyBinary
    }

    /// GET and HEAD carry no body, so the section is hidden for them — unless
    /// the parked request actually has one, in which case hiding it would hide
    /// bytes that are still going to be sent.
    private var showsRequestBodySection: Bool {
        let methodCarriesBody = !["GET", "HEAD"].contains(editedMethod.uppercased())
        return methodCarriesBody || !requestBodyText.isEmpty || isRequestBodyBinary
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
        self.editedMethod = paused.method
        self.editedURLString = paused.request.url?.absoluteString ?? ""
        self.headers = (paused.request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (name: $0.key, value: $0.value) }

        // Decoded and parsed ONCE — `cellForRowAt` only reads the results.
        let bodyData = paused.request.httpBody ?? Data()
        let decoded = bodyData.isEmpty ? "" : (String(data: bodyData, encoding: .utf8) ?? "")
        let document = decoded.isEmpty ? nil : JSONDocument(text: decoded)
        self.isRequestBodyBinary = !bodyData.isEmpty && decoded.isEmpty
        self.isRequestBodyJSONEditable = bodyData.isEmpty || document != nil
        // Pretty-print JSON so it is legible — and editable — on a phone.
        // Same trap as the mock editor: `prettyText()` returns "" — not nil — for
        // a body JSON cannot represent, so a held request with a real body showed
        // an empty one. Fall back whenever the render is empty.
        let renderedRequestBody = document?.prettyText()
        self.requestBodyText = (renderedRequestBody?.isEmpty == false) ? renderedRequestBody! : decoded
        self.editedRequestBody = self.requestBodyText
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
        rebuildSections()
        view.forceLTR()
    }

    /// The row layout for this stage. Rebuilt after every edit, because adding a
    /// header — or switching to a method that carries no body — changes it.
    private func rebuildSections() {
        var models: [SectionModel] = []
        if paused.stage == .beforeSend {
            models.append(SectionModel(title: "REQUEST", rows: [.method, .url]))
            var headerRows: [Row] = headers.indices.map { Row.header($0) }
            headerRows.append(.addHeader)
            models.append(SectionModel(title: "HEADERS (\(headers.count))", rows: headerRows))
            if showsRequestBodySection {
                models.append(SectionModel(title: "BODY", rows: [.body]))
            }
            models.append(SectionModel(title: nil, rows: [.resume, .abort]))
        } else {
            models.append(SectionModel(
                title: nil, rows: [.summary, .requestHeaders, .body, .resume, .abort]))
        }
        sections = models
    }

    /// Rebuild + redraw. Every edit path ends here.
    private func reloadAfterEdit() {
        rebuildSections()
        tableView.reloadData()
    }

    private func row(at ip: IndexPath) -> Row? {
        guard sections.indices.contains(ip.section),
              sections[ip.section].rows.indices.contains(ip.row) else { return nil }
        return sections[ip.section].rows[ip.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].rows.count : 0
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections.indices.contains(section) ? sections[section].title : nil
    }

    /// The editable body uses the shared JSON card — the same control, wording
    /// and gesture as the replay editor and the mock editor.
    private func bodyCardCell(_ ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: JSONEditorCardCell.reuseIdentifier, for: ip) as! JSONEditorCardCell
        // The only way into the editor on this screen, so it stays put even while
        // the held payload isn't (yet) valid JSON.
        cell.cardView.alwaysVisible = true
        cell.cardView.showsPreview = true
        if paused.stage == .beforeSend {
            cell.cardView.cardTitle = "Edit request body"
            cell.cardView.detailText = "Change the payload before the request leaves the app — add, rename, retype or reorder fields."
            cell.cardView.configure(text: editedRequestBody)
        } else {
            cell.cardView.cardTitle = "Edit response body"
            cell.cardView.detailText = "Reshape the payload before the app ever sees it — add, rename, retype or reorder fields."
            cell.cardView.configure(text: editedBody)
        }
        cell.cardView.onTap = { [weak self] in self?.editBody() }
        return cell
    }

    private func plainCell() -> UITableViewCell {
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        c.backgroundColor = UIColor(white: 0.11, alpha: 1)
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        c.textLabel?.textColor = .white
        c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        c.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        c.detailTextLabel?.numberOfLines = 0
        c.forceLTR()
        return c
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        guard let row = row(at: ip) else { return plainCell() }
        if case .body = row, isBodyEditable || (paused.stage == .beforeSend && isRequestBodyJSONEditable) {
            return bodyCardCell(ip)
        }

        let c = plainCell()
        switch row {
        case .summary:
            c.selectionStyle = .none
            c.textLabel?.text = "\(paused.method)  \(paused.statusCode.map(String.init) ?? "—")"
            c.detailTextLabel?.text = paused.displayURL
        case .method:
            c.textLabel?.text = "Method"
            c.detailTextLabel?.text = editedMethod
            c.detailTextLabel?.textColor = DebugTheme.accentColor
            c.accessoryType = .disclosureIndicator
        case .url:
            c.textLabel?.text = "URL"
            c.detailTextLabel?.text = editedURLString.isEmpty ? "(none)" : editedURLString
            c.accessoryType = .disclosureIndicator
        case .header(let index):
            guard headers.indices.contains(index) else { return c }
            c.textLabel?.text = headers[index].name
            c.textLabel?.textColor = DebugTheme.accentColor
            c.detailTextLabel?.text = headers[index].value.isEmpty ? "(empty)" : headers[index].value
            c.accessoryType = .disclosureIndicator
        case .addHeader:
            c.textLabel?.text = "Add header"
            c.textLabel?.textColor = DebugTheme.accentColor
            c.detailTextLabel?.text = "Swipe a header to delete it."
        case .requestHeaders:
            c.selectionStyle = .none
            let fields = paused.request.allHTTPHeaderFields ?? [:]
            c.textLabel?.text = "Request headers (\(fields.count))"
            c.detailTextLabel?.text = fields.keys.sorted()
                .map { "\($0): \(fields[$0] ?? "")" }.joined(separator: "\n")
        case .body:
            // Editable bodies are handled above by the shared JSON card; this is
            // the read-only case — a binary payload, or text the JSON editor
            // cannot round-trip.
            c.selectionStyle = .none
            if paused.stage == .beforeSend {
                c.textLabel?.text = "Request body"
                let bytes = paused.request.httpBody?.count ?? 0
                if isRequestBodyBinary {
                    c.detailTextLabel?.text = "Binary payload — \(bytes) bytes, sent unchanged"
                } else {
                    c.detailTextLabel?.text = "Not JSON — \(bytes) bytes, sent unchanged\n"
                        + String(requestBodyText.prefix(300))
                }
            } else {
                c.textLabel?.text = "Response body"
                if paused.isResponseBodyBinary {
                    let bytes = paused.responseBody?.count ?? 0
                    c.detailTextLabel?.text = "Binary payload — \(bytes) bytes, delivered unchanged"
                } else {
                    let preview = editedBody.trimmingCharacters(in: .whitespacesAndNewlines)
                    c.detailTextLabel?.text = preview.isEmpty ? "(empty)" : String(preview.prefix(300))
                }
            }
        case .resume:
            c.textLabel?.text = paused.stage == .afterResponse ? "Deliver to app" : "Send request"
            c.textLabel?.textColor = DebugTheme.accentColor
            c.textLabel?.textAlignment = .center
            // Says out loud that the edits above are what goes out — the whole
            // point of the stage, and the thing the read-only screen denied.
            c.detailTextLabel?.text = paused.stage == .beforeSend
                ? "Sends the request exactly as edited above." : nil
            c.detailTextLabel?.textAlignment = .center
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
        guard let row = row(at: ip) else { return }
        switch row {
        case .method:
            pickMethod()
        case .url:
            editURL()
        case .header(let index):
            editHeader(at: index)
        case .addHeader:
            editHeader(at: nil)
        case .body:
            editBody()
        case .resume:
            releaseTapped()
        case .abort:
            guard BreakpointCenter.shared.abort(paused) else { showGaveUpAlert(); return }
            navigationController?.popViewController(animated: true)
        case .summary, .requestHeaders:
            break
        }
    }

    // MARK: - Deleting a header

    override func tableView(_ tableView: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        if case .header = row(at: ip) { return true }
        return false
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt ip: IndexPath)
        -> UISwipeActionsConfiguration? {
        guard case .header(let index) = row(at: ip) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.removeHeader(at: index)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Editing the outgoing request (`.beforeSend`)

    /// The request as edited on this screen.
    ///
    /// Built by mutating the PARKED request rather than a fresh one, so
    /// everything this screen does not show survives: the recursion flag
    /// `URLProtocol` stamped on it (without which the re-issued request would be
    /// captured again, forever), the cache policy, the timeout, the cookie and
    /// cellular flags.
    func editedRequest() -> URLRequest {
        var request = paused.request
        request.httpMethod = editedMethod
        if let url = URL(string: editedURLString) { request.url = url }

        var fields: [String: String] = [:]
        for pair in headers {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            fields[name] = pair.value
        }
        if requestBodyWasEdited {
            let data = editedRequestBody.data(using: .utf8) ?? Data()
            request.httpBody = data.isEmpty ? nil : data
            // A stale Content-Length makes the server read the wrong number of
            // bytes — the request-side twin of the response bug that
            // `headersForEditedBody` exists to prevent.
            if let existing = fields.keys.first(where: { $0.lowercased() == "content-length" }) {
                fields[existing] = "\(data.count)"
            }
        }

        // ASSIGNING `allHTTPHeaderFields` DOES NOT REPLACE THE SET — Foundation
        // merges the dictionary in, so a header the developer deleted on this
        // screen survives and still goes out. Measured: assigning `[:]` to a
        // request with two headers leaves both in place. Each existing name has
        // to be cleared explicitly first.
        for name in (request.allHTTPHeaderFields ?? [:]).keys {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        for (name, value) in fields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sets the method. `internal` so a test can drive the same entry point the
    /// picker does, rather than a parallel one that could pass while the UI is
    /// broken.
    func applyMethod(_ method: String) {
        editedMethod = method.uppercased()
        reloadAfterEdit()
    }

    /// Returns false — and changes nothing — for something that isn't a usable
    /// http(s) URL. Silently keeping the old URL would send the request
    /// somewhere the screen no longer shows.
    @discardableResult
    func applyURLString(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        editedURLString = url.absoluteString
        reloadAfterEdit()
        return true
    }

    /// Adds a header (`index == nil`) or replaces one. An empty name is refused
    /// rather than stored as a header that can never be sent.
    @discardableResult
    func applyHeader(name: String, value: String, at index: Int?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let index, headers.indices.contains(index) {
            headers[index] = (name: trimmed, value: value)
        } else if let existing = headers.firstIndex(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            // HTTP header names are case-insensitive, so a second "accept" would
            // be dropped when the dictionary is rebuilt. Overwrite in place
            // instead of listing a row that silently does nothing.
            headers[existing] = (name: trimmed, value: value)
        } else {
            headers.append((name: trimmed, value: value))
        }
        reloadAfterEdit()
        return true
    }

    func removeHeader(at index: Int) {
        guard headers.indices.contains(index) else { return }
        headers.remove(at: index)
        reloadAfterEdit()
    }

    func applyRequestBody(_ text: String) {
        editedRequestBody = text
        requestBodyWasEdited = true
        reloadAfterEdit()
    }

    private func pickMethod() {
        var methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
        // An app using an unusual verb must not lose it just by opening the picker.
        if !methods.contains(editedMethod.uppercased()) { methods.insert(editedMethod.uppercased(), at: 0) }
        let options = methods.map { verb in
            OptionPickerSheetViewController.Option(title: verb) { [weak self] in
                self?.applyMethod(verb)
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Method",
            message: "The verb this request goes out with.",
            options: options, selectedIndex: methods.firstIndex(of: editedMethod.uppercased()))
    }

    private func editURL() {
        let alert = UIAlertController(title: "URL",
                                      message: "Where this request is about to be sent.",
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.editedURLString
            field.placeholder = "https://example.com/path?a=1"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            guard self?.applyURLString(text) == true else {
                self?.showInvalidURLAlert()
                return
            }
        })
        present(alert, animated: true)
    }

    private func showInvalidURLAlert() {
        let a = UIAlertController(
            title: "Not a Usable URL",
            message: "The request still goes to the URL shown on the screen. A breakpoint URL needs a scheme and a host, e.g. https://example.com/path.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    private func editHeader(at index: Int?) {
        let existing = index.flatMap { headers.indices.contains($0) ? headers[$0] : nil }
        let alert = UIAlertController(title: existing == nil ? "Add Header" : "Header",
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = existing?.name
            field.placeholder = "Name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.text = existing?.value
            field.placeholder = "Value"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let fields = alert?.textFields ?? []
            self?.applyHeader(name: fields.first?.text ?? "",
                              value: fields.count > 1 ? (fields[1].text ?? "") : "",
                              at: index)
        })
        present(alert, animated: true)
    }

    // MARK: - Releasing

    private func releaseTapped() {
        if paused.stage == .beforeSend {
            // `PausedRequest.request` is what the protocol's resume handler
            // sends, so this is the hand-off: everything edited above rides on it.
            paused.request = editedRequest()
        } else if bodyWasEdited, let data = editedBody.data(using: .utf8) {
            paused.responseBody = data
        }
        guard BreakpointCenter.shared.resume(paused) else { showGaveUpAlert(); return }
        navigationController?.popViewController(animated: true)
    }

    private func editBody() {
        if paused.stage == .beforeSend {
            guard isRequestBodyJSONEditable else { return }
            let editor = JSONEditorViewController(text: editedRequestBody, title: "Request Body")
            editor.saveButtonTitle = "Use Body"
            editor.onSave = { [weak self] doc in
                self?.applyRequestBody(doc.prettyText())
            }
            navigationController?.pushViewController(editor, animated: true)
            return
        }
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
