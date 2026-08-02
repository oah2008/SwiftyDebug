//
//  ResponseRewriteEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 26/07/2026.
//

import UIKit

/// Authors ONE automated response rewrite — the edit you would otherwise make by
/// hand at an `.afterResponse` breakpoint, armed once and then applied to every
/// matching response with no pause.
///
/// The screen is built so that a path never has to be typed:
///
/// * opened from a value in a real response ("Rewrite this always…"), the path,
///   the action and its target arrive already filled in — changing
///   `google.com` to `salla.com` and tapping Save is the whole interaction;
/// * WHICH VALUES offers plain-language scopes from `JSONPathPattern.scopeOptions`
///   with a **live match count against this very body** ("Every \"url\" anywhere
///   (14 values)") — a bare pattern string is never shown on its own;
/// * PREVIEW runs `ResponseRewriteEngine.preview` on the real captured body on
///   every keystroke, so what you read here is produced by the same code that
///   runs on the wire and cannot disagree with it;
/// * a rewrite that matches nothing, or that matches but changes nothing, says
///   so in words and has to be confirmed before it can be saved. Shipping a
///   silent no-op is the one outcome this screen refuses to allow quietly.
final class ResponseRewriteEditorViewController: UITableViewController {

    // MARK: - Where the finished rewrite goes

    enum Destination {
        /// Handed back through `onSave`; the caller owns the rule.
        case caller
        /// Attached to an intercept rule matching this URL. The APPLIES TO
        /// section picks how wide that rule's scope is.
        case rule(forURL: URL)
    }

    // MARK: - Output

    /// Called with the finished rewrite when `destination` is `.caller`.
    var onSave: ((ResponseRewrite) -> Void)?
    /// Set to show a Delete row (only meaningful when editing an existing one).
    var onDelete: (() -> Void)?

    // MARK: - Input

    /// The rule this editor was opened from, when it was opened from one. Makes
    /// attachment unambiguous now that two rules can share scope and host pin.
    var attachRuleId: String?
    /// True when the rewrite was attached to a rule that is switched OFF, so the
    /// confirmation can say so instead of implying it is live.
    private var attachedToDisabledRule = false

    private let sampleBody: Data?
    private let sampleLabel: String?
    private let destination: Destination
    /// Stable across previews and re-saves, so editing a rewrite replaces it
    /// instead of adding a second copy.
    private let rewriteId: String
    private let isNew: Bool

    /// How many before/after pairs the preview lists.
    private static let previewLimit = 12

    // MARK: - Draft state

    private var pattern: String
    /// The concrete node the user tapped, when there was one. Drives the scope
    /// choices; nil until a value is picked.
    private var seedPath: JSONPath?
    private var actionKind: ActionKind
    private var hostTarget = ""
    /// The host the seeded value has right now, shown as the field's placeholder
    /// so it stays visible for reference without occupying the field.
    private var seededCurrentHost: String?
    /// Set once so the seeded field is focused on first appearance — that focus
    /// tap was a whole step in a flow meant to be three.
    private var didAutoFocus = false
    private var fixedValue = ""
    private var findText = ""
    private var replaceText = ""
    private var isRegex = false
    private var isEnabled = true
    private var name = ""
    private var destinationMode: EndpointMatchMode = .normalized
    /// True once the action came from the user rather than from the value's
    /// shape, so picking another value doesn't overwrite what they typed.
    private var actionWasChosen = false

    /// The response parsed once. Every match count and every preview runs
    /// against this, so the numbers on screen are about the body in hand.
    /// The sample body as text, used as `JSONDocument`'s source so key order and
    /// number spelling match what the server actually sent.
    private lazy var sampleBodyText: String? = sampleBody.flatMap { String(data: $0, encoding: .utf8) }

    private lazy var sampleRoot: Any? = {
        guard let body = sampleBody, !body.isEmpty,
              body.count <= ResponseRewriteEngine.maxBodyBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }()

    private var scopeChoices: [(label: String, pattern: String, count: Int?)] = []
    private var preview = PreviewState()
    private var sections: [SectionModel] = []

    // MARK: - Init

    init(rewrite: ResponseRewrite?,
         sampleBody: Data?,
         sampleLabel: String?,
         seedPath: JSONPath? = nil,
         destination: Destination = .caller) {
        self.sampleBody = sampleBody
        self.sampleLabel = sampleLabel
        self.destination = destination
        self.seedPath = seedPath
        self.rewriteId = rewrite?.id ?? UUID().uuidString
        self.isNew = (rewrite == nil)

        if let rewrite = rewrite {
            pattern = rewrite.pattern
            isEnabled = rewrite.isEnabled
            name = rewrite.name
            switch rewrite.action {
            case .replaceHost(let target):
                actionKind = .changeHost;        hostTarget = target
            case .replaceHostAndPath(let target):
                actionKind = .changeHostAndPath; hostTarget = target
            case .setValue(let value):
                actionKind = .setValue;          fixedValue = value
            case .findReplace(let find, let replace, let regex):
                actionKind = .findReplace; findText = find; replaceText = replace; isRegex = regex
            case .removeKey:
                actionKind = .removeKey
            }
            actionWasChosen = true
        } else {
            pattern = seedPath.map { JSONPathPattern.text(for: $0) } ?? ""
            actionKind = .setValue
        }

        super.init(style: .grouped)

        if rewrite == nil, let path = seedPath, let value = valueInSample(at: path) {
            seedAction(for: value)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = isNew ? "New Rewrite" : "Edit Rewrite"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel
        // Which body every count and preview on this screen is measured against.
        navigationItem.prompt = sampleLabel

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .interactive
        tableView.register(RewriteFieldCell.self, forCellReuseIdentifier: RewriteFieldCell.reuseID)
        tableView.register(RewriteNoteCell.self, forCellReuseIdentifier: RewriteNoteCell.reuseID)
        tableView.register(RewritePreviewCell.self, forCellReuseIdentifier: RewritePreviewCell.reuseID)

        rebuildScopeChoices()
        rebuildSections()
        tableView.reloadData()
        view.forceLTR()
    }

    /// Keeps the value's CURRENT host visible without putting it in the field —
    /// it is the thing being replaced, not a useful starting point.
    private static func hostPlaceholder(currentHost: String?, isHostAndPath: Bool) -> String {
        let example = isHostAndPath ? "salla.com/v2/thing" : "salla.com"
        guard let currentHost, !currentHost.isEmpty else { return example }
        return "\(example)   (now \(currentHost))"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A rewrite seeded from a tapped value needs exactly one thing typed.
        // Landing the caret there removes a whole step from a three-tap flow.
        guard isNew, seedPath != nil, !didAutoFocus else { return }
        didAutoFocus = true
        focusPrimaryField()
    }

    /// The single field a seeded rewrite still needs filled in, if there is one.
    private func focusPrimaryField() {
        let isWanted: (Row) -> Bool
        switch actionKind {
        case .changeHost, .changeHostAndPath:
            isWanted = { if case .hostField = $0 { return true }; return false }
        case .setValue:
            isWanted = { if case .valueField = $0 { return true }; return false }
        case .findReplace, .removeKey:
            return   // nothing single to fill in — leave the keyboard down
        }
        guard let ip = indexPath(ofFirstRowWhere: isWanted) else { return }
        tableView.scrollToRow(at: ip, at: .middle, animated: true)
        (tableView.cellForRow(at: ip) as? RewriteFieldCell)?.focusField()
    }

    /// `Row` carries associated values, so rows are found by predicate rather
    /// than equality.
    private func indexPath(ofFirstRowWhere matches: (Row) -> Bool) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let r = section.rows.firstIndex(where: matches) { return IndexPath(row: r, section: s) }
        }
        return nil
    }

    // MARK: - Actions the picker offers, in plain language

    private enum ActionKind: CaseIterable {
        case changeHost, changeHostAndPath, setValue, findReplace, removeKey

        var title: String {
            switch self {
            case .changeHost:        return "Change host"
            case .changeHostAndPath: return "Change host and path"
            case .setValue:          return "Set a fixed value"
            case .findReplace:       return "Find and replace"
            case .removeKey:         return "Remove the field"
            }
        }

        var detail: String {
            switch self {
            case .changeHost:
                return "Point the URL somewhere else. Scheme, path and query stay exactly as they are."
            case .changeHostAndPath:
                return "Replace the host and the path. The original query string is still kept."
            case .setValue:
                return "Overwrite with a value you type. The JSON type is preserved."
            case .findReplace:
                return "Substitute text inside the value, literally or with a regular expression."
            case .removeKey:
                return "Delete the field (or the array element) from the body entirely."
            }
        }

        var symbol: String {
            switch self {
            case .changeHost:        return "arrow.triangle.swap"
            case .changeHostAndPath: return "arrow.triangle.branch"
            case .setValue:          return "pencil"
            case .findReplace:       return "text.magnifyingglass"
            case .removeKey:         return "trash"
            }
        }
    }

    private var currentAction: RewriteAction {
        switch actionKind {
        case .changeHost:        return .replaceHost(trimmed(hostTarget))
        case .changeHostAndPath: return .replaceHostAndPath(trimmed(hostTarget))
        case .setValue:          return .setValue(fixedValue)
        case .findReplace:       return .findReplace(find: findText, replace: replaceText, isRegex: isRegex)
        case .removeKey:         return .removeKey
        }
    }

    private var currentRewrite: ResponseRewrite {
        ResponseRewrite(pattern: trimmedPattern, action: currentAction,
                        isEnabled: isEnabled, name: trimmed(name), id: rewriteId)
    }

    private var trimmedPattern: String { trimmed(pattern) }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Seeding from the tapped value

    private func valueInSample(at path: JSONPath) -> Any? {
        guard let root = sampleRoot else { return nil }
        return JSONDocument(root: root, sourceText: sampleBodyText).value(at: path)
    }

    /// Leads with the action that fits what the value looks like: a URL becomes
    /// "Change host" pre-filled with the host it has *right now*, so the whole
    /// job is editing one word.
    private func seedAction(for value: Any) {
        if let text = value as? String, Self.isURLLike(text) {
            actionKind = .changeHost
            // Deliberately EMPTY, with the current host shown as the placeholder.
            // Pre-filling the field with "google.com" — the host you are trying to
            // get rid of — means the first thing you do is delete it, and Save
            // without editing arms a rewrite that changes nothing.
            hostTarget = ""
            seededCurrentHost = Self.host(of: text)
        } else {
            actionKind = .setValue
            fixedValue = ResponseRewriteEngine.displayText(for: value, limit: 400)
        }
    }

    /// URL-shaped **by the engine's own definition** — asking the engine means
    /// the suggested action can never disagree with what it will actually do.
    private static func isURLLike(_ text: String) -> Bool {
        ResponseRewriteEngine.rewrittenURLString(text, mode: .host, target: "swiftydebug.probe") != nil
    }

    /// The host (with port) currently inside a URL-ish string, for pre-filling.
    /// Display only — the rewrite itself never goes through this.
    private static func host(of text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in [raw, "http://" + raw] {
            if let comps = URLComponents(string: candidate), let host = comps.host, !host.isEmpty {
                return comps.port.map { "\(host):\($0)" } ?? host
            }
        }
        return nil
    }

    // MARK: - Scope choices, with live counts

    private func rebuildScopeChoices() {
        guard let path = seedPath, !path.isEmpty else { scopeChoices = []; return }
        scopeChoices = JSONPathPattern.scopeOptions(for: path).map { option in
            (option.label, option.pattern, matchCount(for: option.pattern))
        }
    }

    private func matchCount(for text: String) -> Int? {
        guard let root = sampleRoot, let pattern = JSONPathPattern(text) else { return nil }
        return pattern.matches(in: root).count
    }

    /// "Just this one (1 value)" — the count is what makes the choice obvious,
    /// so a scope is never offered as a bare pattern string.
    private func scopeTitle(_ choice: (label: String, pattern: String, count: Int?)) -> String {
        guard let count = choice.count else { return choice.label }
        return "\(choice.label) (\(countPhrase(count)))"
    }

    private func countPhrase(_ count: Int) -> String {
        let capped = count >= JSONPathPattern.maxMatches
        let number = capped ? "\(count)+" : "\(count)"
        return count == 1 ? "1 value" : "\(number) values"
    }

    // MARK: - Preview

    private struct PreviewState {
        var rows: [(path: String, before: String, after: String)] = []
        var totalMatches = 0
        var changedCount = 0
        /// The loud line. Always present when something is wrong.
        var note: String?
        var isProblem = false
    }

    /// Everything the PREVIEW section says, computed from the real body through
    /// the real engine. Nothing here guesses.
    private func computePreview() -> PreviewState {
        var state = PreviewState()
        let text = trimmedPattern

        guard let body = sampleBody, !body.isEmpty else {
            state.note = "No captured response to check this against, so there is nothing to preview. "
                + "Open a request, tap a value in its response and choose \u{201C}Rewrite this always…\u{201D} to see live matches."
            return state
        }
        guard body.count <= ResponseRewriteEngine.maxBodyBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .binary)
            state.note = "This response is \(size) — over the \(ResponseRewriteEngine.maxBodyBytes / 1024 / 1024) MB limit, "
                + "so rewrites are skipped for bodies this big."
            state.isProblem = true
            return state
        }
        guard let root = sampleRoot else {
            state.note = "This response body is not JSON, so nothing in it can be rewritten."
            state.isProblem = true
            return state
        }
        guard !text.isEmpty else {
            state.note = "Choose which value to change."
            state.isProblem = true
            return state
        }
        guard let jsonPattern = JSONPathPattern(text) else {
            state.note = "\u{201C}\(text)\u{201D} is not a path this can match. "
                + "Use names for keys, [0] for one item, [*] for every item, ** for any depth."
            state.isProblem = true
            return state
        }

        let matches = jsonPattern.matches(in: root)
        state.totalMatches = matches.count
        guard !matches.isEmpty else {
            state.note = "This matches nothing in this response. " + missReason(for: text)
            state.isProblem = true
            return state
        }

        state.rows = ResponseRewriteEngine.preview(currentRewrite, on: body, limit: Self.previewLimit)
        state.changedCount = state.rows.filter { $0.before != $0.after }.count

        if state.changedCount == 0 {
            state.note = "Matches \(countPhrase(matches.count)), but nothing changes. " + unchangedReason(state.rows)
            state.isProblem = true
        } else if matches.count > state.rows.count {
            state.note = "Showing the first \(state.rows.count) of \(countPhrase(matches.count))."
        }
        return state
    }

    /// Why a pattern found nothing — and what to do about it. "Matched zero" is
    /// useless on its own; the fix is almost always a wider scope.
    private func missReason(for text: String) -> String {
        guard let root = sampleRoot, let key = Self.lastKey(in: text) else { return "" }
        if let anywhere = JSONPathPattern("**." + key) {
            let count = anywhere.matches(in: root).count
            if count > 0 {
                let subject = count == 1 ? "is 1 value" : "are \(count) values"
                return "There \(subject) named \"\(key)\" elsewhere in it — "
                    + "switch the scope to \u{201C}Every \"\(key)\" anywhere\u{201D}."
            }
        }
        return "This response has no \"\(key)\" field at all."
    }

    /// Why matched values stayed the same. The engine already explains the
    /// per-value failures, so the first one it reported wins.
    private func unchangedReason(_ rows: [(path: String, before: String, after: String)]) -> String {
        let marker = "(unchanged — "
        if let row = rows.first(where: { $0.after.hasPrefix(marker) }) {
            let reason = row.after.dropFirst(marker.count).dropLast()
            return "First problem: \(reason)."
        }
        switch actionKind {
        case .changeHost, .changeHostAndPath:
            let target = trimmed(hostTarget)
            return target.isEmpty
                ? "Type where the URLs should point."
                : "Those values already point at \u{201C}\(target)\u{201D}."
        case .setValue:
            return "They already hold that value."
        case .findReplace:
            return "\u{201C}\(findText)\u{201D} does not appear in them."
        case .removeKey:
            return ""
        }
    }

    /// The last plain key of a pattern, used only to phrase the miss reason.
    /// Anything bracketed or wildcarded returns nil rather than a guess.
    private static func lastKey(in pattern: String) -> String? {
        guard let last = pattern.split(separator: ".").last else { return nil }
        let key = String(last)
        guard !key.isEmpty, !key.contains("["), !key.contains("]"),
              !key.contains("*"), !key.contains("\"") else { return nil }
        return key
    }

    // MARK: - Sections

    private enum SectionID { case scope, action, preview, appliesTo, options, delete }

    private enum Row {
        case scope(Int)
        case pickValue
        case customPattern
        case action
        case hostField
        case valueField
        case findField
        case replaceField
        case regexToggle
        case previewNote
        case previewRow(Int)
        case appliesTo
        case enabledToggle
        case nameField
        case delete
    }

    private struct SectionModel {
        let id: SectionID
        let title: String?
        let hint: String?
        let rows: [Row]
    }

    private func rebuildSections() {
        preview = computePreview()
        var models: [SectionModel] = []

        var scope: [Row] = []
        for index in scopeChoices.indices { scope.append(.scope(index)) }
        if sampleRoot != nil { scope.append(.pickValue) }
        scope.append(.customPattern)
        models.append(SectionModel(id: .scope, title: "WHICH VALUES",
                                   hint: sampleRoot != nil ? "counted in this response" : nil,
                                   rows: scope))

        var action: [Row] = [.action]
        switch actionKind {
        case .changeHost, .changeHostAndPath: action.append(.hostField)
        case .setValue:                       action.append(.valueField)
        case .findReplace:                    action += [.findField, .replaceField, .regexToggle]
        case .removeKey:                      break
        }
        models.append(SectionModel(id: .action, title: "WHAT TO DO", hint: nil, rows: action))

        var previewRows: [Row] = []
        if preview.note != nil { previewRows.append(.previewNote) }
        for index in preview.rows.indices { previewRows.append(.previewRow(index)) }
        models.append(SectionModel(id: .preview, title: "PREVIEW",
                                   hint: previewHint, rows: previewRows))

        if case .rule = destination {
            models.append(SectionModel(id: .appliesTo, title: "APPLIES TO", hint: nil, rows: [.appliesTo]))
        }
        models.append(SectionModel(id: .options, title: "OPTIONS", hint: nil,
                                   rows: [.enabledToggle, .nameField]))
        if onDelete != nil {
            models.append(SectionModel(id: .delete, title: nil, hint: nil, rows: [.delete]))
        }
        sections = models
    }

    private var previewHint: String? {
        guard preview.changedCount > 0 else { return sampleLabel }
        return preview.changedCount == 1 ? "1 value changes" : "\(preview.changedCount) values change"
    }

    /// Recomputes the preview without touching any other section, so the field
    /// being typed into keeps the keyboard and the caret.
    private func refreshPreview() {
        let before = sections.map { $0.rows.count }
        let previewIndex = sections.firstIndex { $0.id == .preview }
        rebuildSections()
        let after = sections.map { $0.rows.count }

        guard let index = previewIndex, before.count == after.count,
              zip(before, after).enumerated().allSatisfy({ $0.offset == index || $0.element.0 == $0.element.1 })
        else {
            tableView.reloadData()
            return
        }
        UIView.performWithoutAnimation {
            tableView.reloadSections(IndexSet(integer: index), with: .none)
        }
    }

    private func reloadEverything() {
        rebuildScopeChoices()
        rebuildSections()
        tableView.reloadData()
    }

    // MARK: - Table data

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        return sections[section].rows.count
    }

    private func row(at ip: IndexPath) -> Row? {
        guard sections.indices.contains(ip.section),
              sections[ip.section].rows.indices.contains(ip.row) else { return nil }
        return sections[ip.section].rows[ip.row]
    }

    private func plainCell(_ style: UITableViewCell.CellStyle = .subtitle) -> UITableViewCell {
        let cell = UITableViewCell(style: style, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cell.selectionStyle = .default
        cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        cell.textLabel?.textColor = .white
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        cell.detailTextLabel?.numberOfLines = 0
        cell.forceLTR()
        return cell
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        guard let row = row(at: ip) else { return plainCell() }

        switch row {
        case .scope(let index):
            guard scopeChoices.indices.contains(index) else { return plainCell() }
            let choice = scopeChoices[index]
            let cell = plainCell()
            let selected = (choice.pattern == trimmedPattern)
            cell.textLabel?.text = scopeTitle(choice)
            cell.textLabel?.textColor = selected ? DebugTheme.accentColor : .white
            cell.detailTextLabel?.text = choice.pattern
            cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.detailTextLabel?.textColor = choice.count == 0
                ? .systemOrange
                : UIColor(white: 0.5, alpha: 1)
            cell.accessoryType = selected ? .checkmark : .none
            cell.tintColor = DebugTheme.accentColor
            return cell

        case .pickValue:
            let cell = plainCell()
            cell.textLabel?.text = seedPath == nil ? "Choose a value from the response…" : "Choose a different value…"
            cell.textLabel?.textColor = DebugTheme.accentColor
            cell.detailTextLabel?.text = "Tap the field you want changed — no path to type."
            let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            cell.imageView?.image = UIImage(systemName: "hand.tap", withConfiguration: cfg)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            cell.accessoryType = .disclosureIndicator
            return cell

        case .customPattern:
            let cell = plainCell()
            cell.textLabel?.text = "Path pattern"
            let isCustom = !scopeChoices.contains { $0.pattern == trimmedPattern }
            cell.detailTextLabel?.text = trimmedPattern.isEmpty ? "Not set" : trimmedPattern
            cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.detailTextLabel?.textColor = trimmedPattern.isEmpty
                ? UIColor(white: 0.4, alpha: 1)
                : (isCustom ? DebugTheme.accentColor : UIColor(white: 0.5, alpha: 1))
            cell.accessoryType = .disclosureIndicator
            return cell

        case .action:
            let cell = plainCell()
            cell.textLabel?.text = actionKind.title
            cell.detailTextLabel?.text = actionKind.detail
            let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            cell.imageView?.image = UIImage(systemName: actionKind.symbol, withConfiguration: cfg)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
            cell.accessoryType = .disclosureIndicator
            return cell

        case .hostField:
            let cell = fieldCell(ip)
            let isHostAndPath = (actionKind == .changeHostAndPath)
            cell.configure(caption: isHostAndPath ? "NEW HOST AND PATH" : "NEW HOST",
                           text: hostTarget,
                           placeholder: Self.hostPlaceholder(currentHost: seededCurrentHost,
                                                             isHostAndPath: isHostAndPath),
                           keyboard: .URL,
                           footer: "Accepts salla.com, https://salla.com and salla.com:8443.")
            cell.onChange = { [weak self] text in
                self?.hostTarget = text
                self?.refreshPreview()
            }
            return cell

        case .valueField:
            let cell = fieldCell(ip)
            cell.configure(caption: "VALUE", text: fixedValue, placeholder: "the value to write",
                           keyboard: .default,
                           footer: "Written with the type the value already has — text stays text, a number stays a number.")
            cell.onChange = { [weak self] text in
                self?.fixedValue = text
                self?.refreshPreview()
            }
            return cell

        case .findField:
            let cell = fieldCell(ip)
            cell.configure(caption: "FIND", text: findText,
                           placeholder: isRegex ? "^https://(.+)$" : "google.com",
                           keyboard: .default, footer: nil)
            cell.onChange = { [weak self] text in
                self?.findText = text
                self?.refreshPreview()
            }
            return cell

        case .replaceField:
            let cell = fieldCell(ip)
            cell.configure(caption: "REPLACE WITH", text: replaceText,
                           placeholder: isRegex ? "https://salla.com/$1" : "salla.com",
                           keyboard: .default,
                           footer: isRegex ? "$1, $2 … insert the capture groups." : nil)
            cell.onChange = { [weak self] text in
                self?.replaceText = text
                self?.refreshPreview()
            }
            return cell

        case .regexToggle:
            let cell = plainCell()
            cell.selectionStyle = .none
            cell.textLabel?.text = "Regular expression"
            cell.detailTextLabel?.text = isRegex
                ? "FIND is a regex. Invalid patterns are reported below."
                : "FIND is matched literally."
            let toggle = UISwitch()
            toggle.isOn = isRegex
            toggle.onTintColor = DebugTheme.accentColor
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                self.isRegex = toggle.isOn
                self.view.endEditing(true)
                self.reloadEverything()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell

        case .previewNote:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: RewriteNoteCell.reuseID, for: ip) as! RewriteNoteCell
            cell.configure(text: preview.note ?? "", isProblem: preview.isProblem)
            return cell

        case .previewRow(let index):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: RewritePreviewCell.reuseID, for: ip) as! RewritePreviewCell
            guard preview.rows.indices.contains(index) else { return cell }
            let entry = preview.rows[index]
            cell.configure(path: entry.path, before: entry.before, after: entry.after)
            return cell

        case .appliesTo:
            let cell = plainCell()
            cell.textLabel?.text = "Every response \(destinationScopeSummary)"
            cell.detailTextLabel?.text = destinationRuleSummary
            let badge = UILabel()
            badge.text = destinationMode.displayName
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.textColor = MockResponseEditorViewController.color(forMatchMode: destinationMode)
            badge.sizeToFit()
            cell.accessoryView = badge
            return cell

        case .enabledToggle:
            let cell = plainCell()
            cell.selectionStyle = .none
            cell.textLabel?.text = "Run this rewrite"
            cell.detailTextLabel?.text = isEnabled
                ? "Applied to every matching response."
                : "Kept, but switched off — it changes nothing."
            let toggle = UISwitch()
            toggle.isOn = isEnabled
            toggle.onTintColor = DebugTheme.accentColor
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                self.isEnabled = toggle.isOn
                if let index = self.sections.firstIndex(where: { $0.id == .options }) {
                    self.rebuildSections()
                    UIView.performWithoutAnimation {
                        self.tableView.reloadSections(IndexSet(integer: index), with: .none)
                    }
                }
            }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell

        case .nameField:
            let cell = fieldCell(ip)
            cell.configure(caption: "NAME (OPTIONAL)", text: name,
                           placeholder: currentRewrite.displayName,
                           keyboard: .default,
                           footer: "Leave it empty and the list shows \u{201C}\(currentRewrite.displayName)\u{201D}.")
            cell.onChange = { [weak self] text in self?.name = text }
            return cell

        case .delete:
            let cell = plainCell(.default)
            cell.textLabel?.text = "Delete Rewrite"
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            return cell
        }
    }

    private func fieldCell(_ ip: IndexPath) -> RewriteFieldCell {
        tableView.dequeueReusableCell(withIdentifier: RewriteFieldCell.reuseID, for: ip) as! RewriteFieldCell
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        guard let row = row(at: ip) else { return }
        switch row {
        case .scope(let index):
            guard scopeChoices.indices.contains(index) else { return }
            pattern = scopeChoices[index].pattern
            view.endEditing(true)
            reloadEverything()
        case .pickValue:      pickValueFromResponse()
        case .customPattern:  promptForPattern()
        case .action:         pickAction()
        case .appliesTo:      pickDestinationScope()
        case .delete:         confirmDelete()
        // Tapping anywhere on a field row focuses it. Requiring the tap to land
        // inside the text field itself cost a whole step in a three-tap flow.
        case .hostField, .valueField, .findField, .replaceField:
            (tableView.cellForRow(at: ip) as? RewriteFieldCell)?.focusField()
        default:              break
        }
    }

    // MARK: - Header / footer

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections.indices.contains(section), let title = sections[section].title else { return nil }
        let header = UIView()

        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .heavy)
        label.textColor = DebugTheme.accentColor
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        let hint = UILabel()
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = UIColor(white: 0.4, alpha: 1)
        hint.text = sections[section].hint
        hint.textAlignment = .right
        hint.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hint)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        header.forceLTR()
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard sections.indices.contains(section), sections[section].title != nil else { return 0 }
        return 38
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 4 }

    // MARK: - Pickers

    private func pickAction() {
        view.endEditing(true)
        let kinds = ActionKind.allCases
        let options = kinds.map { kind in
            OptionPickerSheetViewController.Option(
                title: kind.title, subtitle: kind.detail, symbol: kind.symbol,
                tint: kind == .removeKey ? .systemRed : DebugTheme.accentColor
            ) { [weak self] in
                guard let self else { return }
                self.actionKind = kind
                self.actionWasChosen = true
                self.reloadEverything()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "What to do",
            message: "Applied to every value the scope above matches.",
            options: options, selectedIndex: kinds.firstIndex(of: actionKind))
    }

    /// The no-typing route to a path: the response as a tree, one tap to choose.
    private func pickValueFromResponse() {
        guard let root = sampleRoot else {
            showAlert("No response to pick from",
                      "There is no JSON response captured for this rule yet. Type the path below instead.")
            return
        }
        // Carry the source bytes so the picker shows the server's own key order.
        let document = JSONDocument(root: root, sourceText: sampleBodyText)
        let picker = JSONEditorViewController(document: document, title: "Choose a value")
        picker.onPickPath = { [weak self] path in
            guard let self else { return }
            self.seedPath = path
            self.pattern = JSONPathPattern.text(for: path)
            if !self.actionWasChosen, let value = document.value(at: path) {
                self.seedAction(for: value)
            }
            self.reloadEverything()
        }
        push(picker)
    }

    private func promptForPattern() {
        let alert = UIAlertController(
            title: "Path pattern",
            message: "data.url · data.items[*].url · **.url (a key named url anywhere)",
            preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.trimmedPattern
            field.placeholder = "data.url"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.pattern = alert?.textFields?.first?.text ?? ""
            // A typed path is no longer the node they tapped.
            if !self.scopeChoices.contains(where: { $0.pattern == self.trimmedPattern }) {
                self.seedPath = self.seedPath
            }
            self.reloadEverything()
        })
        present(alert, animated: true)
    }

    private func pickDestinationScope() {
        guard case .rule(let url) = destination else { return }
        let modes: [EndpointMatchMode] = [.normalized, .exact, .host, .global]
        let options = modes.map { mode in
            OptionPickerSheetViewController.Option(
                title: Self.scopeSummary(mode, url).capitalizedFirst,
                subtitle: Self.scopeDetail(mode),
                symbol: nil,
                tint: MockResponseEditorViewController.color(forMatchMode: mode)
            ) { [weak self] in
                self?.destinationMode = mode
                self?.reloadEverything()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Applies to",
            message: "Which responses this rewrite runs on. It is stored on an intercept rule with that scope.",
            options: options, selectedIndex: modes.firstIndex(of: destinationMode))
    }

    // MARK: - Destination wording

    private var destinationScopeSummary: String {
        guard case .rule(let url) = destination else { return "" }
        return Self.scopeSummary(destinationMode, url)
    }

    private var destinationRuleSummary: String {
        guard case .rule(let url) = destination else { return "" }
        let key = Self.ruleKey(for: destinationMode, url: url)
        let existing = InterceptRuleStore.shared.rules(for: key).first { $0.matchMode == destinationMode }
        return existing == nil
            ? "Saved into a new intercept rule."
            : "Added to the intercept rule that already covers this."
    }

    private static func scopeSummary(_ mode: EndpointMatchMode, _ url: URL) -> String {
        switch mode {
        case .exact:      return "from \(url.path.isEmpty ? "/" : url.path)"
        case .normalized: return "from \(EndpointNormalizer.normalize(url.path))"
        case .host:       return "from \(url.host ?? "this host")"
        case .global:     return "the app receives"
        }
    }

    private static func scopeDetail(_ mode: EndpointMatchMode) -> String {
        switch mode {
        case .exact:      return "Only this exact path."
        case .normalized: return "Every path with this shape (IDs replaced)."
        case .host:       return "Every request to this host."
        case .global:     return "Every response in the app and its web views."
        }
    }

    private static func ruleKey(for mode: EndpointMatchMode, url: URL) -> String {
        switch mode {
        case .exact:      return url.path
        case .normalized: return EndpointNormalizer.normalize(url.path)
        case .host:       return "host:" + (url.host ?? "").lowercased()
        case .global:     return "global"
        }
    }

    // MARK: - Save / delete

    @objc private func cancelTapped() { pop() }

    @objc private func saveTapped() {
        view.endEditing(true)
        rebuildSections()

        let text = trimmedPattern
        guard !text.isEmpty else {
            showAlert("Nothing chosen yet", "Pick the value this rewrite should change, or type its path.")
            return
        }
        guard JSONPathPattern(text) != nil else {
            showAlert("That path can't be matched",
                      "\u{201C}\(text)\u{201D} is not a usable pattern. Use names for keys, [0] for one item, "
                      + "[*] for every item and ** for any depth — for example data.items[*].url.")
            return
        }
        if let problem = actionProblem() {
            showAlert("Not finished", problem)
            return
        }
        // A rewrite that matches nothing, or matches but changes nothing, is the
        // failure this feature must never ship silently. Saving one is allowed —
        // the response in hand may simply not be a representative one — but only
        // after being told, in words, exactly what it does to this body.
        if preview.isProblem, let note = preview.note {
            let alert = UIAlertController(title: "This changes nothing here",
                                          message: note + "\n\nSave it anyway?",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep editing", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save anyway", style: .destructive) { [weak self] _ in
                self?.commit()
            })
            present(alert, animated: true)
            return
        }
        commit()
    }

    private func actionProblem() -> String? {
        switch actionKind {
        case .changeHost:
            return trimmed(hostTarget).isEmpty ? "Type the host these URLs should point at, e.g. salla.com." : nil
        case .changeHostAndPath:
            return trimmed(hostTarget).isEmpty ? "Type the host and path these URLs should point at, e.g. salla.com/v2/thing." : nil
        case .findReplace:
            if findText.isEmpty { return "Type the text to find." }
            if isRegex, (try? NSRegularExpression(pattern: findText)) == nil {
                return "\u{201C}\(findText)\u{201D} is not a valid regular expression."
            }
            return nil
        case .setValue, .removeKey:
            return nil
        }
    }

    private func commit() {
        let rewrite = currentRewrite
        switch destination {
        case .caller:
            onSave?(rewrite)
            pop()
        case .rule(let url):
            attach(rewrite, to: url)
            confirmArmed(rewrite, url: url)
        }
    }

    /// Stores the rewrite on an intercept rule with the chosen scope, reusing the
    /// rule that already covers it rather than breeding one rule per rewrite.
    private func attach(_ rewrite: ResponseRewrite, to url: URL) {
        let mode = destinationMode
        let key = Self.ruleKey(for: mode, url: url)
        var rule: InterceptRule
        // `rules(for:)` deliberately returns EVERY host-pinned variant of an
        // endpoint, so `.first` would happily attach this rewrite to a rule
        // pinned to a different host. Prefer this host's rule, then a legacy
        // any-host one, and only then create a new pinned rule.
        let host = InterceptRule.canonicalHost(url.host ?? "")
        let candidates = InterceptRuleStore.shared.rules(for: key).filter { $0.matchMode == mode }
        // Prefer the rule this editor was opened FROM. Once rules can be
        // duplicated, a copy shares scope AND host pin with its original, so
        // matching on those alone is ambiguous — and it resolved to the original
        // by sort order, meaning a rewrite armed while editing the copy silently
        // landed on the rule the user was trying to leave alone.
        if let attachRuleId, let owned = candidates.first(where: { $0.id == attachRuleId }) {
            rule = owned
        } else if let existing = candidates.first(where: { $0.matchHost == host })
            ?? candidates.first(where: { $0.matchHost.isEmpty }) {
            rule = existing
        } else if mode == .host {
            rule = InterceptRule.hostRule(hosts: [(url.host ?? "").lowercased()])
        } else if mode == .global {
            rule = InterceptRule.globalRule()
        } else {
            rule = InterceptRule.endpointRule(path: key, mode: mode, host: url.host)
        }

        if let index = rule.responseRewrites.firstIndex(where: { $0.id == rewrite.id }) {
            rule.responseRewrites[index] = rewrite
        } else {
            rule.responseRewrites.append(rewrite)
        }
        // A brand-new rule arms itself; an EXISTING one keeps whatever the user
        // set. Forcing this on silently re-armed a rule they had deliberately
        // switched off — the same defect already fixed in the rule editor.
        // `wasDisabled` is reported back so the caller can say so rather than
        // leaving the rewrite looking armed when its rule is off.
        if !candidates.contains(where: { $0.id == rule.id }) {
            rule.isEnabled = true
        }
        attachedToDisabledRule = !rule.isEnabled
        InterceptRuleStore.shared.addOrUpdate(rule)
    }

    /// Says exactly what was armed and what it does to the body in hand. An
    /// automated edit that starts silently is indistinguishable from one that
    /// never ran.
    private func confirmArmed(_ rewrite: ResponseRewrite, url: URL) {
        var lines = [rewrite.displayName,
                     "",
                     "Runs on every response \(Self.scopeSummary(destinationMode, url))."]
        if !rewrite.isEnabled {
            lines.append("It is switched OFF, so nothing happens until you turn it on.")
        } else if attachedToDisabledRule {
            // The rewrite is on, but its RULE is not. Saying "armed" here without
            // this would be a lie.
            lines.append("Its rule is switched off, so nothing happens until you turn the rule on.")
        } else if preview.changedCount > 0 {
            let subject = preview.changedCount == 1 ? "1 value" : "\(preview.changedCount) values"
            lines.append("\(subject) in the response you were looking at would change.")
        } else if sampleBody != nil {
            lines.append("It changes nothing in the response you were looking at.")
        }
        // Shown as a banner over the screen we return to, not a modal alert.
        // An alert here costs a tap to dismiss and blocks the pop; the
        // information is worth showing, not worth a step.
        pop()
        RewriteArmedBanner.show(text: lines.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: "Delete this rewrite?",
                                      message: currentRewrite.displayName,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.onDelete?()
            self?.pop()
        })
        present(alert, animated: true)
    }

    // MARK: - Navigation helpers

    private func push(_ controller: UIViewController) {
        if let nav = navigationController {
            nav.pushViewController(controller, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: controller), animated: true)
        }
    }

    private func pop() {
        if navigationController?.viewControllers.first === self || navigationController == nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Field cell

/// Caption + single-line field + optional footer, sized by its own content.
///
/// A stock `UITableViewCell` text field is not enough here: the preview under it
/// updates on every keystroke, so the cell has to own a closure (cleared on
/// reuse) rather than a target keyed by row index.
private final class RewriteFieldCell: UITableViewCell {

    static let reuseID = "RewriteField"

    var onChange: ((String) -> Void)?

    /// Puts the caret in this row's field. Used to auto-focus the one field a
    /// seeded rewrite still needs, and to make tapping the ROW focus it too —
    /// otherwise the tap has to land inside the text field itself.
    func focusField() {
        field.becomeFirstResponder()
        field.selectAll(nil)
    }

    private let captionLabel = UILabel()
    private let field = UITextField()
    private let footerLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        selectionStyle = .none

        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = UIColor(white: 0.45, alpha: 1)

        field.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        field.textColor = DebugTheme.accentColor
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(returnTapped), for: .editingDidEndOnExit)

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = UIColor(white: 0.42, alpha: 1)
        footerLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [captionLabel, field, footerLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        // Pinned top AND bottom — self-sizing depends on it.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        field.text = nil
        field.placeholder = nil
        footerLabel.text = nil
        footerLabel.isHidden = true
    }

    func configure(caption: String, text: String, placeholder: String,
                   keyboard: UIKeyboardType, footer: String?) {
        captionLabel.text = caption
        field.keyboardType = keyboard
        // Never stomp on what is being typed — the preview reload must not move
        // the caret to the end mid-word.
        if !field.isFirstResponder { field.text = text }
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.32, alpha: 1)])
        footerLabel.text = footer
        footerLabel.isHidden = (footer?.isEmpty ?? true)
    }

    @objc private func editingChanged() { onChange?(field.text ?? "") }
    @objc private func returnTapped() { field.resignFirstResponder() }
}

// MARK: - Note cell

/// The loud line: why a rewrite matches nothing, changes nothing, or is capped.
private final class RewriteNoteCell: UITableViewCell {

    static let reuseID = "RewriteNote"

    private let iconView = UIImageView()
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        selectionStyle = .none

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, isProblem: Bool) {
        let tint: UIColor = isProblem ? .systemOrange : UIColor(white: 0.55, alpha: 1)
        label.text = text
        label.textColor = tint
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = UIImage(systemName: isProblem ? "exclamationmark.triangle.fill" : "info.circle",
                                 withConfiguration: cfg)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}

// MARK: - Preview cell

/// One matched value: where it is, what it is now, what it becomes.
private final class RewritePreviewCell: UITableViewCell {

    static let reuseID = "RewritePreview"

    private let pathLabel = UILabel()
    private let beforeLabel = UILabel()
    private let afterLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.13, alpha: 1)
        selectionStyle = .none

        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        pathLabel.textColor = UIColor(white: 0.45, alpha: 1)
        pathLabel.numberOfLines = 0

        beforeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        beforeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        beforeLabel.numberOfLines = 0

        afterLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        afterLabel.textColor = DebugTheme.accentColor
        afterLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [pathLabel, beforeLabel, afterLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        beforeLabel.attributedText = nil
        afterLabel.attributedText = nil
        beforeLabel.text = nil
        afterLabel.text = nil
    }

    func configure(path: String, before: String, after: String) {
        pathLabel.text = path
        let changed = (before != after)
        if changed {
            beforeLabel.attributedText = NSAttributedString(
                string: before,
                attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                             .foregroundColor: UIColor(white: 0.45, alpha: 1)])
        } else {
            beforeLabel.attributedText = nil
            beforeLabel.text = before
        }
        afterLabel.text = after
        afterLabel.textColor = changed ? DebugTheme.accentColor : UIColor(white: 0.4, alpha: 1)
    }
}

// MARK: - Small helpers

private extension String {
    /// "from /api/x" -> "From /api/x", for option titles.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Armed banner

/// A brief, non-blocking confirmation that a rewrite is now live.
///
/// The alert this replaced cost a tap to dismiss and blocked the pop, in a flow
/// whose whole point is being three taps long. The information still matters —
/// an automated edit that starts silently is indistinguishable from one that
/// never ran — so it is shown, just not in the way.
enum RewriteArmedBanner {

    static func show(text: String, duration: TimeInterval = 3.2) {
        guard let host = hostView() else { return }

        let card = UIView()
        card.backgroundColor = UIColor(white: 0.16, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = DebugTheme.accentColor.withAlphaComponent(0.6).cgColor
        card.alpha = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)

        let icon = UIImageView(image: UIImage(
            systemName: "wand.and.stars",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal))
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 3

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let guide = host.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
            card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        card.forceLTR()

        UIView.animate(withDuration: 0.22) { card.alpha = 1 }
        // The banner owns its own dismissal — nothing retains it, so a screen
        // torn down underneath it takes it with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            UIView.animate(withDuration: 0.25, animations: { card.alpha = 0 }) { _ in
                card.removeFromSuperview()
            }
        }
    }

    /// The SDK's own window, so the banner sits above the debug UI rather than
    /// inside whichever view controller happens to be on screen.
    private static func hostView() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return windows.first(where: { $0 is SwiftyDebugWindow && !$0.isHidden })
            ?? windows.first(where: { $0.isKeyWindow })
    }
}
