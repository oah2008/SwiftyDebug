//
//  InterceptRuleEditorViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Editor for creating or editing a single intercept rule.
///
/// Layout (mobile-first):
///   SCOPE      — how the rule matches (pattern / exact / hosts / global)
///   ACTION     — block, redirect, delete
///   REWRITES   — automated edits applied to the response body (see RESPONSE-REWRITE)
///   HEADERS    — the headers this rule SETs or REMOVEs, one card each
///                (key on its own line, value on its own line)
///   AVAILABLE  — every header known for this scope, one tap to pull into the rule
///   PARAMS     — same two sections for query parameters
///
/// "Available" is sourced from `RequestMetadataStore`, which persists every
/// header/param ever seen (per endpoint, per host, and globally) and **survives
/// clearing the captured requests** — so you can still pick real headers after
/// wiping the network list. (See INTERCEPT-UX.)
class InterceptRuleEditorViewController: UITableViewController {

    // MARK: - Input

    var httpModel: NetworkTransaction?
    var existingRuleId: String?
    var initialMatchMode: EndpointMatchMode?
    var ruleToEdit: InterceptRule?

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case endpoint = 0
        case action = 1
        /// Sits with the other "what to do with a matching request" choices —
        /// a rewrite is the same kind of decision as mock/breakpoint/redirect.
        case responseRewrites = 2
        case headers = 3
        case availableHeaders = 4
        case queryParams = 5
        case availableParams = 6
    }

    struct EditItem {
        var key: String
        var value: String
        var isRemoving: Bool
        var isKeyEditable: Bool
        /// Only active items are written into the saved rule. A row you can see
        /// but did not switch on changes nothing about the outgoing request.
        var isActive: Bool = true
    }

    /// Splits editor rows into the two things a rule stores: value overrides and
    /// removals. Pure and `internal` so the "nothing applies unless it is checked"
    /// guarantee is covered by tests rather than by inspection.
    ///
    /// `lowercaseRemovals` matches how the rule stores removed keys: headers are
    /// case-insensitive, query parameters are not.
    static func partition(_ items: [EditItem],
                          lowercaseRemovals: Bool) -> (overrides: [KVPair], removed: Set<String>) {
        let active = items.filter { $0.isActive && !$0.key.isEmpty }
        let overrides = active.filter { !$0.isRemoving }.map { KVPair(key: $0.key, value: $0.value) }
        let removed = Set(active.filter { $0.isRemoving }
            .map { lowercaseRemovals ? $0.key.lowercased() : $0.key })
        return (overrides, removed)
    }

    // MARK: - State

    private var requestPath = ""
    private var normalizedPath = ""
    private var requestHost = ""
    private var matchMode: EndpointMatchMode = .normalized
    private var selectedHosts: [String] = []
    private var isBlocked = false
    private var redirectMode: RedirectMode = .none
    private var redirectTarget = ""
    private var mock = MockResponse()
    private var breakpointMode: BreakpointMode = .off
    private var headerItems: [EditItem] = []
    private var queryParamItems: [EditItem] = []
    /// Automated edits applied to the response body of a matching request.
    /// Saved with the rule through the same path as headers and params.
    private var responseRewrites: [ResponseRewrite] = []
    private var existingRule: InterceptRule?

    /// Everything known for the current scope (persisted + current request).
    private var availableHeaders: [RequestMetadataStore.Entry] = []
    private var availableParams: [RequestMetadataStore.Entry] = []
    /// The inline "available" lists stay short — the full list opens in a sheet.
    private static let availablePreviewCount = 5

    private var isPresentedModally: Bool {
        navigationController?.viewControllers.first === self
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existingRuleId != nil ? "Edit Rule" : "New Rule"
        view.backgroundColor = .black

        let save = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        save.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = save
        if isPresentedModally {
            let cancel = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
            cancel.tintColor = UIColor(white: 0.7, alpha: 1)
            navigationItem.leftBarButtonItem = cancel
        }

        let table = UITableView(frame: .zero, style: .grouped)
        table.dataSource = self
        table.delegate = self
        tableView = table
        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive

        setupKeyboardDismissButton()
        populateFromModel()
        refreshAvailable()
        view.forceLTR()
    }

    // MARK: - Populate

    private func populateFromModel() {
        if let model = httpModel {
            requestPath = model.url?.path ?? ""
            normalizedPath = EndpointNormalizer.normalize(requestPath)
            requestHost = (model.url?.host ?? "").lowercased()
            if let ruleId = existingRuleId, let url = model.url as URL? {
                existingRule = InterceptRuleStore.shared.matchingRules(forURL: url).first { $0.id == ruleId }
            }
        } else if let rule = ruleToEdit {
            existingRule = rule
            existingRuleId = rule.id
            if rule.matchMode == .host {
                selectedHosts = rule.matchHosts
            } else if rule.matchMode != .global {
                requestPath = rule.matchEndpoint
                normalizedPath = rule.matchEndpoint
            }
        }

        if let rule = existingRule {
            matchMode = rule.matchMode
            selectedHosts = rule.matchHosts
            isBlocked = rule.isBlocked
            redirectMode = rule.redirectMode
            redirectTarget = rule.redirectTarget
            mock = rule.mock
            breakpointMode = rule.breakpointMode
            responseRewrites = rule.responseRewrites
            headerItems = rule.headerOverrides.map {
                EditItem(key: $0.key, value: $0.value, isRemoving: false, isKeyEditable: false)
            }
            for k in rule.removedHeaderKeys.sorted() {
                headerItems.append(EditItem(key: k, value: "", isRemoving: true, isKeyEditable: false))
            }
            queryParamItems = rule.queryParamOverrides.map {
                EditItem(key: $0.key, value: $0.value, isRemoving: false, isKeyEditable: false)
            }
            for k in rule.removedQueryParamKeys.sorted() {
                queryParamItems.append(EditItem(key: k, value: "", isRemoving: true, isKeyEditable: false))
            }
        } else {
            matchMode = initialMatchMode ?? .normalized
            if matchMode == .host && !requestHost.isEmpty { selectedHosts = [requestHost] }
            // For a NEW endpoint-scoped rule, pre-load every header and query
            // parameter this endpoint actually sends, already filled in with
            // their real values — so you edit what's there instead of hunting
            // for it. Host/global rules stay empty on purpose: they match many
            // endpoints, so one endpoint's headers would be misleading.
            if matchMode == .exact || matchMode == .normalized {
                prefillFromEndpoint()
            }
        }
    }

    /// Seeds a NEW endpoint-scoped rule with the headers and query parameters
    /// **this request actually sent**, already switched on — the same set the
    /// replay screen shows you.
    ///
    /// Strictly the current request: headers remembered from *other* requests are
    /// left in AVAILABLE HEADERS to be added deliberately. Pulling those in was
    /// how rules ended up setting headers nobody chose.
    private func prefillFromEndpoint() {
        guard let model = httpModel else { return }

        var headers: [(String, String)] = []
        var params: [(String, String)] = []

        if let dict = model.requestHeaderFields as? [String: Any] {
            headers = dict.map { ($0.key, "\($0.value)") }
        }
        if let url = model.url as URL?,
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            params = items.map { ($0.name, $0.value ?? "") }
        }

        headerItems = headers
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { EditItem(key: $0.0, value: $0.1, isRemoving: false, isKeyEditable: false, isActive: true) }
        queryParamItems = params
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { EditItem(key: $0.0, value: $0.1, isRemoving: false, isKeyEditable: false, isActive: true) }
    }

    /// Rebuilds the "available" lists for the current scope, merging the current
    /// request's own headers/params (most relevant) with everything remembered.
    private func refreshAvailable() {
        let endpoint = (matchMode == .exact) ? requestPath : normalizedPath
        let hosts = matchMode == .host ? selectedHosts : (requestHost.isEmpty ? [] : [requestHost])

        var headers = RequestMetadataStore.shared.headers(forMode: matchMode, endpoint: endpoint, hosts: hosts)
        var params = RequestMetadataStore.shared.params(forMode: matchMode, endpoint: endpoint, hosts: hosts)

        // Current request first — it's the most relevant context.
        if let model = httpModel {
            var frontHeaders: [RequestMetadataStore.Entry] = []
            if let dict = model.requestHeaderFields as? [String: Any] {
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    frontHeaders.append(.init(name: k, value: "\(v)"))
                }
            }
            var frontParams: [RequestMetadataStore.Entry] = []
            if let url = model.url as URL?,
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let items = comps.queryItems {
                for i in items { frontParams.append(.init(name: i.name, value: i.value ?? "")) }
            }
            headers = dedupe(frontHeaders + headers)
            params = dedupe(frontParams + params)
        }

        // Hide the ones already in the rule.
        let usedH = Set(headerItems.map { $0.key.lowercased() })
        let usedP = Set(queryParamItems.map { $0.key.lowercased() })
        availableHeaders = headers.filter { !usedH.contains($0.name.lowercased()) }
        availableParams = params.filter { !usedP.contains($0.name.lowercased()) }
    }

    private func dedupe(_ list: [RequestMetadataStore.Entry]) -> [RequestMetadataStore.Entry] {
        var seen = Set<String>(); var out: [RequestMetadataStore.Entry] = []
        for e in list where seen.insert(e.name.lowercased()).inserted { out.append(e) }
        return out
    }

    private func reloadAll() {
        refreshAvailable()
        // The scope may have just changed, so the captured response the rewrite
        // editor previews against has to be looked up again.
        cachedSample = nil
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        var rule: InterceptRule
        if matchMode == .global {
            rule = existingRule ?? InterceptRule.globalRule()
        } else if matchMode == .host {
            guard !selectedHosts.isEmpty else {
                showAlert(title: "No URLs", message: "Select at least one URL to intercept.")
                return
            }
            let sorted = selectedHosts.map { $0.lowercased() }.sorted()
            rule = existingRule ?? InterceptRule(matchEndpoint: "host:" + sorted.joined(separator: ","), matchMode: .host)
            rule.matchHosts = sorted
        } else {
            let endpoint = matchMode == .exact ? requestPath : normalizedPath
            rule = existingRule ?? InterceptRule(matchEndpoint: endpoint, matchMode: matchMode)
        }

        rule.isBlocked = isBlocked
        rule.isEnabled = true
        rule.matchMode = matchMode
        rule.redirectMode = redirectMode
        rule.redirectTarget = redirectTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.mock = mock
        rule.breakpointMode = breakpointMode
        rule.responseRewrites = responseRewrites

        // `isActive` is the guarantee that a rule only ever carries what was
        // explicitly switched on. Everything else is inert editor state.
        let headers = Self.partition(headerItems, lowercaseRemovals: true)
        let params = Self.partition(queryParamItems, lowercaseRemovals: false)
        rule.headerOverrides = headers.overrides
        rule.removedHeaderKeys = headers.removed
        rule.queryParamOverrides = params.overrides
        rule.removedQueryParamKeys = params.removed

        let hasEffect = rule.isBlocked
            || rule.mock.isEnabled
            || rule.breakpointMode != .off
            || rule.redirectMode != .none && !rule.redirectTarget.isEmpty
            || !rule.headerOverrides.isEmpty || !rule.removedHeaderKeys.isEmpty
            || !rule.queryParamOverrides.isEmpty || !rule.removedQueryParamKeys.isEmpty
            || !rule.responseRewrites.isEmpty
        guard hasEffect else {
            showAlert(title: "Empty Rule",
                      message: "Add a header/parameter change, a response rewrite, a redirect, or enable blocking.")
            return
        }

        if let existing = existingRule, existing.matchEndpoint != rule.matchEndpoint {
            InterceptRuleStore.shared.remove(id: existing.id)
        }
        InterceptRuleStore.shared.addOrUpdate(rule)
        if isPresentedModally {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    @objc private func blockToggleChanged(_ sender: UISwitch) {
        isBlocked = sender.isOn
        tableView.reloadData()
    }

    @objc private func removeRuleTapped() {
        if let id = existingRule?.id { InterceptRuleStore.shared.remove(id: id) }
        if isPresentedModally {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func selectHostsTapped() {
        let picker = HostPickerSheetViewController()
        picker.selectedHosts = Set(selectedHosts)
        picker.onApply = { [weak self] applied in
            self?.selectedHosts = applied
            self?.reloadAll()
        }
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(picker, animated: true)
    }

    @objc private func endpointModeChanged(_ sender: UISegmentedControl) {
        matchMode = sender.selectedSegmentIndex == 0 ? .normalized : .exact
        reloadAll()
    }

    private func addHeader(key: String = "", value: String = "") {
        headerItems.append(EditItem(key: key, value: value, isRemoving: false, isKeyEditable: key.isEmpty))
        reloadAll()
    }
    private func addParam(key: String = "", value: String = "") {
        queryParamItems.append(EditItem(key: key, value: value, isRemoving: false, isKeyEditable: key.isEmpty))
        reloadAll()
    }

    // MARK: - Redirect editor

    /// Opens the full redirect editor (mode + destination + live preview).
    /// Replaces the old system alert, whose text was truncated. (See REDIRECT.)
    private func presentRedirectEditor() {
        let editor = RedirectEditorViewController(
            mode: redirectMode,
            target: redirectTarget,
            sampleURL: httpModel?.url as URL?
        )
        editor.onSave = { [weak self] mode, target in
            guard let self else { return }
            self.redirectMode = mode
            self.redirectTarget = target
            self.tableView.reloadData()
        }
        if let nav = navigationController {
            nav.pushViewController(editor, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
        }
    }

    /// Mock editor — scenario presets plus a full JSON body editor. (See MOCK.)
    private func presentMockEditor() {
        // Offer the endpoint's real response as a starting point.
        let currentBody = httpModel?.responseData?.dataToPrettyPrintString()
        let editor = MockResponseEditorViewController(mock: mock, currentResponseText: currentBody)
        // Pre-fills "Add to profile…" so a mock copied into a scenario answers the
        // same requests this rule does.
        editor.endpointMatchMode = matchMode
        editor.endpointPattern = mockPatternForCurrentScope
        editor.onSave = { [weak self] updated in
            self?.mock = updated
            self?.tableView.reloadData()
        }
        if let nav = navigationController {
            nav.pushViewController(editor, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
        }
    }

    /// What a mock copied out of this rule should match on. Mirrors the scope the
    /// rule itself uses, so the profile entry fires on the same requests.
    private var mockPatternForCurrentScope: String {
        switch matchMode {
        case .exact:      return requestPath
        case .normalized: return normalizedPath
        case .host:       return selectedHosts.first ?? requestHost
        case .global:     return ""
        }
    }

    /// Breakpoint stage picker. Exactly one stage can be armed, so a request is
    /// never paused twice. (See BREAKPOINTS.)
    private func presentBreakpointPicker() {
        let modes: [BreakpointMode] = [.off, .beforeSend, .afterResponse]
        let options = modes.map { m in
            OptionPickerSheetViewController.Option(
                title: m.title, subtitle: m.detail,
                symbol: m == .off ? "nosign" : (m == .beforeSend ? "arrow.up.circle" : "arrow.down.circle"),
                tint: m == .off ? .white : .systemOrange
            ) { [weak self] in
                self?.breakpointMode = m
                self?.tableView.reloadData()
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Breakpoint",
            message: "Paused requests appear in the Paused inbox — the app waits until you release them, "
                + "for up to \(Self.holdBudgetText()). After that the request is let go on its own.",
            options: options, selectedIndex: modes.firstIndex(of: breakpointMode))
    }

    // MARK: - Response rewrites

    /// Opens the rewrite authoring screen.
    ///
    /// `destination: .caller` on purpose: this screen already owns the rule and
    /// its scope, so the rewrite comes back through `onSave` and is saved with
    /// the rule. Letting the editor attach it as well would arm the same edit
    /// twice, on two different rules.
    private func presentRewriteEditor(_ existing: ResponseRewrite?) {
        let sample = sampleResponse()
        let editor = ResponseRewriteEditorViewController(rewrite: existing,
                                                         sampleBody: sample.body,
                                                         sampleLabel: sample.label,
                                                         destination: .caller)
        editor.onSave = { [weak self] rewrite in
            guard let self else { return }
            // Match on id, so editing replaces instead of adding a second copy.
            if let index = self.responseRewrites.firstIndex(where: { $0.id == rewrite.id }) {
                self.responseRewrites[index] = rewrite
            } else {
                self.responseRewrites.append(rewrite)
            }
            self.tableView.reloadData()
        }
        if let existing = existing {
            editor.onDelete = { [weak self] in
                guard let self else { return }
                self.responseRewrites.removeAll { $0.id == existing.id }
                self.tableView.reloadData()
            }
        }
        if let nav = navigationController {
            nav.pushViewController(editor, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
        }
    }

    private func setRewrite(id: String, enabled: Bool) {
        guard let index = responseRewrites.firstIndex(where: { $0.id == id }) else { return }
        responseRewrites[index].isEnabled = enabled
        // Whole section: the header counts how many are on, and the footer is
        // what says "all of them are off" out loud.
        tableView.reloadSections([Section.responseRewrites.rawValue], with: .none)
    }

    // MARK: Sample response for the rewrite editor

    /// The captured response the rewrite editor previews and counts matches
    /// against, resolved once per scope. Response bodies are disk-backed, so
    /// this runs when an editor is opened — never from `cellForRowAt`.
    private var cachedSample: (body: Data?, label: String?)?
    /// How many captured responses are opened while looking for a JSON body.
    private static let sampleScanLimit = 8

    private func sampleResponse() -> (body: Data?, label: String?) {
        if let cachedSample = cachedSample { return cachedSample }
        let found = findSampleResponse()
        cachedSample = found
        return found
    }

    /// Newest captured JSON response inside this rule's scope, or `(nil, nil)`
    /// when nothing has been captured yet — the editor handles that case and
    /// says so rather than pretending to preview.
    private func findSampleResponse() -> (body: Data?, label: String?) {
        var candidates: [NetworkTransaction] = []
        if let model = httpModel { candidates.append(model) }
        // Same live store the host picker reads for this screen's suggestions.
        let captured = (NetworkRequestStore.shared.httpModels.copy() as? NSArray as? [NetworkTransaction]) ?? []
        for model in captured.reversed() where model !== httpModel && scopeMatches(model) {
            candidates.append(model)
        }

        var opened = 0
        for model in candidates {
            // Cheap in-memory checks first; only then touch the disk.
            guard model.responseDataSize > 0,
                  model.responseDataSize <= UInt(ResponseRewriteEngine.maxBodyBytes) else { continue }
            guard opened < Self.sampleScanLimit else { break }
            opened += 1
            guard let body = model.responseData, !body.isEmpty,
                  (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil
            else { continue }
            return (body, sampleLabel(for: model))
        }
        return (nil, nil)
    }

    /// Does this captured request fall inside the scope currently on screen?
    private func scopeMatches(_ model: NetworkTransaction) -> Bool {
        guard let url = model.url as URL? else { return false }
        switch matchMode {
        case .global:
            return true
        case .host:
            let hosts = selectedHosts.isEmpty ? (requestHost.isEmpty ? [] : [requestHost]) : selectedHosts
            return hosts.contains { InterceptRuleStore.urlMatchesPattern(url, pattern: $0) }
        case .exact:
            return !requestPath.isEmpty && url.path == requestPath
        case .normalized:
            return !normalizedPath.isEmpty && EndpointNormalizer.normalize(url.path) == normalizedPath
        }
    }

    /// "GET /v1/products · 200" — shown as the editor's prompt so it is never a
    /// mystery which body the preview is running against.
    private func sampleLabel(for model: NetworkTransaction) -> String {
        var parts: [String] = []
        let method = (model.method ?? "").uppercased()
        if !method.isEmpty { parts.append(method) }
        if let path = (model.url as URL?)?.path, !path.isEmpty { parts.append(path) }
        let head = parts.joined(separator: " ")
        let status = model.statusCode ?? ""
        if status.isEmpty { return head.isEmpty ? "Captured response" : head }
        return head.isEmpty ? status : head + " · " + status
    }

    // MARK: - Breakpoint hold budget

    /// How long a paused request is actually held (`Settings.breakpointHoldSeconds`),
    /// written the way a human reads it: "10 min", "45 s", "2 hr".
    static func holdBudgetText(seconds: TimeInterval = Settings.shared.breakpointHoldSeconds) -> String {
        func trim(_ value: Double, _ unit: String) -> String {
            return value == value.rounded()
                ? "\(Int(value)) \(unit)"
                : String(format: "%.1f %@", value, unit)
        }
        if seconds >= 3600 { return trim(seconds / 3600, "hr") }
        if seconds >= 60   { return trim(seconds / 60, "min") }
        return "\(max(1, Int(seconds.rounded()))) s"
    }

    /// The one short line the Breakpoint row appends once a stage is armed.
    /// Says out loud whether the host app's own timeout can cut the hold short.
    static func holdBudgetPhrase() -> String {
        let budget = holdBudgetText()
        return Settings.shared.extendTimeoutsForBreakpoints
            ? "held up to \(budget) while you edit"
            : "held up to \(budget), or until the app's own timeout"
    }

    /// Full list of available headers/params in a searchable sheet.
    private func presentAllAvailable(isHeader: Bool) {
        let entries = isHeader ? availableHeaders : availableParams
        let options = entries.map { entry in
            OptionPickerSheetViewController.Option(
                title: entry.name,
                subtitle: entry.value.isEmpty ? "—" : entry.value,
                symbol: "plus.circle",
                tint: DebugTheme.accentColor
            ) { [weak self] in
                isHeader ? self?.addHeader(key: entry.name, value: entry.value)
                         : self?.addParam(key: entry.name, value: entry.value)
            }
        }
        OptionPickerSheetViewController.present(
            from: self,
            title: isHeader ? "Available Headers" : "Available Parameters",
            message: "Everything seen for this scope — including requests you've already cleared. Tap one to add it to the rule.",
            options: options
        )
    }

    private var redirectSummary: String {
        guard redirectMode != .none, !redirectTarget.isEmpty else { return "Off" }
        return (redirectMode == .host ? "Host → " : "Host+Path → ") + redirectTarget
    }

    // MARK: - Suggestions

    private func headerNameSuggestions(matching q: String) -> [String] {
        let present = Set(headerItems.map { $0.key.lowercased() }.filter { !$0.isEmpty })
        let query = q.lowercased()
        var seen = Set<String>(); var out: [String] = []
        for e in availableHeaders where !present.contains(e.name.lowercased()) {
            if query.isEmpty || e.name.lowercased().contains(query), seen.insert(e.name.lowercased()).inserted {
                out.append(e.name)
            }
        }
        for n in HeaderSuggestionStore.shared.suggestions(matching: q, excluding: present, limit: 30)
        where seen.insert(n.lowercased()).inserted { out.append(n) }
        return Array(out.prefix(12))
    }

    private func headerValueSuggestions(forKey key: String, current: String) -> [String] {
        guard !key.isEmpty else { return [] }
        let q = current.lowercased()
        var seen = Set<String>(); var out: [String] = []
        func add(_ v: String) {
            guard !v.isEmpty || v.hasSuffix(" ") else { return }
            guard q.isEmpty || v.lowercased().hasPrefix(q) || v.hasSuffix(" ") else { return }
            if seen.insert(v.lowercased()).inserted { out.append(v) }
        }
        for t in HTTPHeaderCatalog.valueTemplates(forHeader: key) { add(t) }
        if let e = availableHeaders.first(where: { $0.name.lowercased() == key.lowercased() }) { add(e.value) }
        for v in RequestMetadataStore.shared.values(forHeader: key) { add(v) }
        return Array(out.prefix(12))
    }

    private func paramNameSuggestions(matching q: String) -> [String] {
        let present = Set(queryParamItems.map { $0.key.lowercased() }.filter { !$0.isEmpty })
        let query = q.lowercased()
        var seen = Set<String>(); var out: [String] = []
        for e in availableParams where !present.contains(e.name.lowercased()) {
            if query.isEmpty || e.name.lowercased().contains(query), seen.insert(e.name.lowercased()).inserted {
                out.append(e.name)
            }
        }
        return Array(out.prefix(12))
    }

    private func paramValueSuggestions(forKey key: String, current: String) -> [String] {
        guard !key.isEmpty else { return [] }
        let q = current.lowercased()
        var seen = Set<String>(); var out: [String] = []
        func add(_ v: String) {
            guard !v.isEmpty, q.isEmpty || v.lowercased().hasPrefix(q) else { return }
            if seen.insert(v).inserted { out.append(v) }
        }
        if let e = availableParams.first(where: { $0.name.lowercased() == key.lowercased() }) { add(e.value) }
        for v in RequestMetadataStore.shared.values(forParam: key) { add(v) }
        return Array(out.prefix(12))
    }

    // MARK: - Table data

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    private var visibleAvailableHeaders: [RequestMetadataStore.Entry] {
        Array(availableHeaders.prefix(Self.availablePreviewCount))
    }
    private var visibleAvailableParams: [RequestMetadataStore.Entry] {
        Array(availableParams.prefix(Self.availablePreviewCount))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .endpoint:
            if matchMode == .global { return 1 }
            if matchMode == .host { return 1 + selectedHosts.count }
            return 2
        case .action:
            return existingRule != nil ? 5 : 4      // block, redirect, mock, breakpoint (+ delete)
        case .responseRewrites:
            // A blocked request never gets a response, so there is nothing for a
            // rewrite to act on — the section disappears, exactly like headers.
            return isBlocked ? 0 : responseRewrites.count + 1     // +1 = "Add rewrite"
        case .headers:
            return isBlocked ? 0 : headerItems.count + 1     // +1 = "Add header"
        case .availableHeaders:
            if isBlocked || availableHeaders.isEmpty { return 0 }
            return visibleAvailableHeaders.count + (availableHeaders.count > Self.availablePreviewCount ? 1 : 0)
        case .queryParams:
            return isBlocked ? 0 : queryParamItems.count + 1
        case .availableParams:
            if isBlocked || availableParams.isEmpty { return 0 }
            return visibleAvailableParams.count + (availableParams.count > Self.availablePreviewCount ? 1 : 0)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .endpoint:   return endpointCell(indexPath)
        case .action:     return actionCell(indexPath)
        case .responseRewrites:
            guard responseRewrites.indices.contains(indexPath.row) else {
                return addButtonCell(title: "Add rewrite")
            }
            return rewriteCell(responseRewrites[indexPath.row])
        case .headers:
            if indexPath.row == headerItems.count { return addButtonCell(title: "Add header") }
            return cardCell(indexPath, isHeader: true)
        case .availableHeaders:
            if indexPath.row >= visibleAvailableHeaders.count {
                return moreCell(remaining: availableHeaders.count - visibleAvailableHeaders.count)
            }
            return availableCell(visibleAvailableHeaders[indexPath.row])
        case .queryParams:
            if indexPath.row == queryParamItems.count { return addButtonCell(title: "Add parameter") }
            return cardCell(indexPath, isHeader: false)
        case .availableParams:
            if indexPath.row >= visibleAvailableParams.count {
                return moreCell(remaining: availableParams.count - visibleAvailableParams.count)
            }
            return availableCell(visibleAvailableParams[indexPath.row])
        }
    }

    // MARK: Cell builders

    private func plainCell(_ id: String, style: UITableViewCell.CellStyle = .default) -> UITableViewCell {
        let c = UITableViewCell(style: style, reuseIdentifier: id)
        c.backgroundColor = UIColor(white: 0.11, alpha: 1)
        c.selectionStyle = .default
        c.forceLTR()
        return c
    }

    private func endpointCell(_ ip: IndexPath) -> UITableViewCell {
        if matchMode == .global {
            let c = plainCell("global", style: .subtitle)
            c.selectionStyle = .none
            c.textLabel?.text = "Global Rule"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            c.textLabel?.textColor = .systemPink
            c.detailTextLabel?.text = "Applies to every request in the app and web views"
            c.detailTextLabel?.font = .systemFont(ofSize: 11)
            c.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
            c.detailTextLabel?.numberOfLines = 2
            return c
        }
        if matchMode == .host {
            if ip.row == 0 {
                let c = plainCell("hostSelect")
                c.textLabel?.text = selectedHosts.isEmpty ? "Select URLs…" : "Change URLs…"
                c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                c.textLabel?.textColor = .systemPurple
                c.accessoryType = .disclosureIndicator
                return c
            }
            let c = plainCell("host")
            c.selectionStyle = .none
            c.textLabel?.text = selectedHosts[ip.row - 1]
            c.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            c.textLabel?.textColor = .systemPurple
            c.textLabel?.numberOfLines = 2
            return c
        }
        if ip.row == 0 {
            let c = plainCell("mode")
            c.selectionStyle = .none
            let seg = UISegmentedControl(items: ["Pattern", "Exact"])
            seg.selectedSegmentIndex = matchMode == .normalized ? 0 : 1
            seg.selectedSegmentTintColor = DebugTheme.accentColor
            seg.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
            seg.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1)], for: .normal)
            seg.addTarget(self, action: #selector(endpointModeChanged(_:)), for: .valueChanged)
            seg.translatesAutoresizingMaskIntoConstraints = false
            c.contentView.addSubview(seg)
            NSLayoutConstraint.activate([
                seg.leadingAnchor.constraint(equalTo: c.contentView.leadingAnchor, constant: 12),
                seg.trailingAnchor.constraint(equalTo: c.contentView.trailingAnchor, constant: -12),
                seg.topAnchor.constraint(equalTo: c.contentView.topAnchor, constant: 8),
                seg.bottomAnchor.constraint(equalTo: c.contentView.bottomAnchor, constant: -8),
                seg.heightAnchor.constraint(equalToConstant: 32),
            ])
            return c
        }
        let c = plainCell("endpoint", style: .subtitle)
        c.selectionStyle = .none
        c.textLabel?.text = matchMode == .exact ? requestPath : normalizedPath
        c.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        c.textLabel?.textColor = matchMode == .exact ? .systemOrange : DebugTheme.accentColor
        c.textLabel?.numberOfLines = 3
        c.detailTextLabel?.text = matchMode == .exact
            ? "Matches only this exact path"
            : "Matches every path with this pattern (IDs replaced)"
        c.detailTextLabel?.font = .systemFont(ofSize: 10)
        c.detailTextLabel?.textColor = UIColor(white: 0.45, alpha: 1)
        c.detailTextLabel?.numberOfLines = 2
        return c
    }

    private func actionCell(_ ip: IndexPath) -> UITableViewCell {
        switch ip.row {
        case 0:
            let c = plainCell("block", style: .subtitle)
            c.selectionStyle = .none
            c.textLabel?.text = "Block Request"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .white
            let target = matchMode == .global ? "all URLs" : matchMode == .host ? "selected hosts" : "this endpoint"
            c.detailTextLabel?.text = "Cancel all future requests to \(target)"
            c.detailTextLabel?.font = .systemFont(ofSize: 11)
            c.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
            let sw = UISwitch()
            sw.isOn = isBlocked
            sw.onTintColor = .systemRed
            sw.addTarget(self, action: #selector(blockToggleChanged(_:)), for: .valueChanged)
            c.accessoryView = sw
            return c
        case 1:
            let c = plainCell("redirect", style: .subtitle)
            let on = redirectMode != .none && !redirectTarget.isEmpty
            c.textLabel?.text = "Redirect"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .white
            c.detailTextLabel?.text = redirectSummary
            c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            c.detailTextLabel?.textColor = on ? DebugTheme.accentColor : UIColor(white: 0.45, alpha: 1)
            c.detailTextLabel?.numberOfLines = 2
            c.accessoryType = .disclosureIndicator
            return c
        case 2:
            let c = plainCell("mock", style: .subtitle)
            c.textLabel?.text = "Mock Response"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .white
            c.detailTextLabel?.text = mock.isEnabled
                ? "Returns \(mock.statusCode) without hitting the network"
                : "Off — requests go to the real endpoint"
            c.detailTextLabel?.font = .systemFont(ofSize: 11)
            c.detailTextLabel?.textColor = mock.isEnabled ? DebugTheme.accentColor : UIColor(white: 0.45, alpha: 1)
            c.detailTextLabel?.numberOfLines = 2
            c.accessoryType = .disclosureIndicator
            return c
        case 3:
            let c = plainCell("breakpoint", style: .subtitle)
            c.textLabel?.text = "Breakpoint"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .white
            // An armed breakpoint holds the request for a *budget*, not forever — say so
            // here, because nothing else in the UI mentions it. (See BREAKPOINTS.)
            c.detailTextLabel?.text = breakpointMode == .off
                ? "Off — requests are never paused"
                : breakpointMode.title + " · " + breakpointMode.detail + " · " + Self.holdBudgetPhrase()
            c.detailTextLabel?.font = .systemFont(ofSize: 11)
            c.detailTextLabel?.textColor = breakpointMode == .off ? UIColor(white: 0.45, alpha: 1) : .systemOrange
            c.detailTextLabel?.numberOfLines = 3
            c.accessoryType = .disclosureIndicator
            return c
        default:
            let c = plainCell("delete")
            c.textLabel?.text = "Delete Rule"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .systemRed
            c.textLabel?.textAlignment = .center
            return c
        }
    }

    private func cardCell(_ ip: IndexPath, isHeader: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: ip) as! KeyValueCardCell
        let item = isHeader ? headerItems[ip.row] : queryParamItems[ip.row]
        cell.showsActiveControl = true
        cell.configure(key: item.key, value: item.value, removing: item.isRemoving,
                       keyEditable: item.isKeyEditable, active: item.isActive)

        cell.onActiveToggled = { [weak self] in
            guard let self else { return }
            if isHeader { self.headerItems[ip.row].isActive.toggle() }
            else { self.queryParamItems[ip.row].isActive.toggle() }
            // Whole section, not just the row: the header shows the active count.
            self.tableView.reloadSections([ip.section], with: .none)
        }
        cell.onKeyChanged = { [weak self] k in
            guard let self else { return }
            if isHeader { self.headerItems[ip.row].key = k } else { self.queryParamItems[ip.row].key = k }
        }
        cell.onValueChanged = { [weak self] v in
            guard let self else { return }
            if isHeader { self.headerItems[ip.row].value = v } else { self.queryParamItems[ip.row].value = v }
        }
        cell.onModeToggled = { [weak self] in
            guard let self else { return }
            if isHeader { self.headerItems[ip.row].isRemoving.toggle() }
            else { self.queryParamItems[ip.row].isRemoving.toggle() }
            self.tableView.reloadRows(at: [ip], with: .automatic)
        }
        cell.currentKeyText = { [weak self] in
            guard let self else { return "" }
            return isHeader ? self.headerItems[ip.row].key : self.queryParamItems[ip.row].key
        }
        if item.isKeyEditable {
            cell.keySuggestionsProvider = { [weak self] q in
                isHeader ? (self?.headerNameSuggestions(matching: q) ?? []) : (self?.paramNameSuggestions(matching: q) ?? [])
            }
            cell.onKeySuggestionPicked = { [weak self] name in
                guard let self else { return }
                if isHeader { self.headerItems[ip.row].key = name } else { self.queryParamItems[ip.row].key = name }
            }
        }
        cell.valueSuggestionsProvider = { [weak self] key, cur in
            isHeader ? (self?.headerValueSuggestions(forKey: key, current: cur) ?? [])
                     : (self?.paramValueSuggestions(forKey: key, current: cur) ?? [])
        }
        return cell
    }

    /// One rewrite: what it is called, what it does, and the switch that decides
    /// whether it runs. Tapping the row opens the same editor that made it.
    private func rewriteCell(_ rewrite: ResponseRewrite) -> UITableViewCell {
        let c = plainCell("rewrite", style: .subtitle)
        let on = rewrite.isEnabled
        c.textLabel?.text = rewrite.displayName
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        c.textLabel?.textColor = on ? .white : UIColor(white: 0.5, alpha: 1)
        c.textLabel?.numberOfLines = 2
        c.detailTextLabel?.text = Self.rewriteSubtitle(rewrite)
        c.detailTextLabel?.font = .systemFont(ofSize: 11)
        c.detailTextLabel?.textColor = on ? DebugTheme.accentColor : UIColor(white: 0.4, alpha: 1)
        c.detailTextLabel?.numberOfLines = 2

        // Keyed by the rewrite's id, never by row index — the list is re-sorted
        // by nothing today, but an index captured here would be a live landmine.
        let id = rewrite.id
        let sw = UISwitch()
        sw.isOn = on
        sw.onTintColor = DebugTheme.accentColor
        sw.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            self.setRewrite(id: id, enabled: toggle.isOn)
        }, for: .valueChanged)

        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: cfg)?
            .withTintColor(UIColor(white: 0.45, alpha: 1), renderingMode: .alwaysOriginal))
        chevron.contentMode = .center

        // `accessoryView` is laid out from its frame, so the stack gets one.
        let accessory = UIStackView(arrangedSubviews: [sw, chevron])
        accessory.axis = .horizontal
        accessory.alignment = .center
        accessory.spacing = 8
        let switchSize = sw.intrinsicContentSize
        accessory.frame = CGRect(x: 0, y: 0,
                                 width: switchSize.width + 8 + 14,
                                 height: max(switchSize.height, 31))
        accessory.forceLTR()
        c.accessoryView = accessory
        return c
    }

    /// "data.items[*].url · Replace the host with salla.com" — the pattern plus
    /// what the action does, in the same plain words the rewrite editor uses.
    private static func rewriteSubtitle(_ rewrite: ResponseRewrite) -> String {
        let pattern = rewrite.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return (pattern.isEmpty ? "(no path yet)" : pattern) + " · " + actionSummary(rewrite.action)
    }

    private static func actionSummary(_ action: RewriteAction) -> String {
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        }
        switch action {
        case .replaceHost(let target):
            let t = clean(target)
            return t.isEmpty ? "Replace the host — no host set yet" : "Replace the host with \(t)"
        case .replaceHostAndPath(let target):
            let t = clean(target)
            return t.isEmpty ? "Replace the host and path — nothing set yet" : "Replace the host and path with \(t)"
        case .setValue(let value):
            let v = clean(value)
            return v.isEmpty ? "Set to an empty value" : "Set to \(v)"
        case .findReplace(let find, let replace, let isRegex):
            return "Replace \u{201C}\(clean(find))\u{201D} with \u{201C}\(clean(replace))\u{201D}"
                + (isRegex ? " (regex)" : "")
        case .removeKey:
            return "Remove it from the response"
        }
    }

    private func addButtonCell(title: String) -> UITableViewCell {
        let c = plainCell("add")
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        c.imageView?.image = UIImage(systemName: "plus.circle.fill", withConfiguration: cfg)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        c.textLabel?.text = title
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        c.textLabel?.textColor = DebugTheme.accentColor
        return c
    }

    /// A compact one-tap row from the "available" list.
    private func availableCell(_ entry: RequestMetadataStore.Entry) -> UITableViewCell {
        let c = plainCell("avail", style: .subtitle)
        c.textLabel?.text = entry.name
        c.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        c.textLabel?.textColor = DebugTheme.accentColor
        c.textLabel?.lineBreakMode = .byTruncatingTail
        c.detailTextLabel?.text = entry.value.isEmpty ? "—" : entry.value
        c.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        c.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        c.detailTextLabel?.lineBreakMode = .byTruncatingTail
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let plus = UIImageView(image: UIImage(systemName: "plus.circle", withConfiguration: cfg)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal))
        c.accessoryView = plus
        return c
    }

    private func moreCell(remaining: Int) -> UITableViewCell {
        let c = plainCell("more")
        c.textLabel?.text = "Show all (\(remaining) more)…"
        c.textLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        c.textLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        c.textLabel?.textAlignment = .center
        return c
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch Section(rawValue: ip.section)! {
        case .endpoint:
            if matchMode == .host && ip.row == 0 { selectHostsTapped() }
        case .action:
            if ip.row == 1 { presentRedirectEditor() }
            else if ip.row == 2 { presentMockEditor() }
            else if ip.row == 3 { presentBreakpointPicker() }
            else if ip.row == 4 { removeRuleTapped() }
        case .responseRewrites:
            guard responseRewrites.indices.contains(ip.row) else { presentRewriteEditor(nil); return }
            presentRewriteEditor(responseRewrites[ip.row])
        case .headers:
            if ip.row == headerItems.count { addHeader() }
        case .queryParams:
            if ip.row == queryParamItems.count { addParam() }
        case .availableHeaders:
            if ip.row >= visibleAvailableHeaders.count { presentAllAvailable(isHeader: true); return }
            let e = visibleAvailableHeaders[ip.row]
            addHeader(key: e.name, value: e.value)
        case .availableParams:
            if ip.row >= visibleAvailableParams.count { presentAllAvailable(isHeader: false); return }
            let e = visibleAvailableParams[ip.row]
            addParam(key: e.name, value: e.value)
        }
    }

    // MARK: - Swipe to delete rule rows

    override func tableView(_ tableView: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        switch Section(rawValue: ip.section)! {
        case .headers:          return ip.row < headerItems.count
        case .queryParams:      return ip.row < queryParamItems.count
        case .responseRewrites: return ip.row < responseRewrites.count
        default:                return false
        }
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard style == .delete else { return }
        switch Section(rawValue: ip.section)! {
        case .headers:     headerItems.remove(at: ip.row)
        case .queryParams: queryParamItems.remove(at: ip.row)
        case .responseRewrites:
            guard responseRewrites.indices.contains(ip.row) else { return }
            responseRewrites.remove(at: ip.row)
        default: return
        }
        reloadAll()
    }

    // MARK: - Headers / footers

    private func sectionTitle(_ s: Section) -> String? {
        switch s {
        case .endpoint: return matchMode == .global ? "SCOPE" : matchMode == .host ? "URLS" : "ENDPOINT"
        case .action:   return "ACTION"
        case .responseRewrites:
            guard !isBlocked else { return nil }
            if responseRewrites.isEmpty { return "RESPONSE REWRITES" }
            return "RESPONSE REWRITES (\(responseRewrites.filter { $0.isEnabled }.count) of \(responseRewrites.count) on)"
        case .headers:
            guard !isBlocked else { return nil }
            return headerItems.isEmpty ? "HEADERS"
                : "HEADERS (\(headerItems.filter { $0.isActive }.count) of \(headerItems.count) active)"
        case .availableHeaders:
            guard !isBlocked, !availableHeaders.isEmpty else { return nil }
            return "AVAILABLE HEADERS (\(availableHeaders.count))"
        case .queryParams:
            guard !isBlocked else { return nil }
            return queryParamItems.isEmpty ? "QUERY PARAMETERS"
                : "QUERY PARAMETERS (\(queryParamItems.filter { $0.isActive }.count) of \(queryParamItems.count) active)"
        case .availableParams:
            guard !isBlocked, !availableParams.isEmpty else { return nil }
            return "AVAILABLE PARAMETERS (\(availableParams.count))"
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let s = Section(rawValue: section), let title = sectionTitle(s) else { return nil }
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
        hint.translatesAutoresizingMaskIntoConstraints = false
        switch s {
        case .availableHeaders, .availableParams: hint.text = "tap to add"
        case .headers, .queryParams:
            // Say out loud that the checkbox is what makes a row take effect.
            hint.text = isBlocked ? nil : "only checked rows apply"
        case .responseRewrites:
            hint.text = isBlocked ? nil : "only switched-on ones run"
        default: break
        }
        header.addSubview(hint)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            hint.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        header.forceLTR()
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let s = Section(rawValue: section), sectionTitle(s) != nil else { return 0 }
        return 38
    }
    private static let footerFont = UIFont.systemFont(ofSize: 11)

    /// What the section does, in one plain sentence — and when the honest answer
    /// is "nothing right now", it says that instead.
    private func sectionFooterText(_ s: Section) -> String? {
        guard s == .responseRewrites, !isBlocked else { return nil }
        // A mock replaces the whole response, so rewrites never see it. Better to
        // say so here than to let someone arm a rewrite that can never run.
        if mock.isEnabled, !responseRewrites.isEmpty {
            return "This rule returns a mock, so rewrites never run. Edit the mock body instead."
        }
        if !responseRewrites.isEmpty, !responseRewrites.contains(where: { $0.isEnabled }) {
            return responseRewrites.count == 1
                ? "This rewrite is switched off, so responses arrive unchanged."
                : "All \(responseRewrites.count) rewrites are switched off, so responses arrive unchanged."
        }
        var text = "Change values in the response before the app sees them — no need to pause."
        // Rewrites run in the URLProtocol, which never sees WKWebView traffic.
        // A rule scoped wide enough to imply web views must not overpromise.
        if matchMode == .global || matchMode == .host {
            text += " Web view requests are not rewritten."
        }
        return text
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let s = Section(rawValue: section), let text = sectionFooterText(s) else { return nil }
        let footer = UIView()
        let label = UILabel()
        label.font = Self.footerFont
        label.textColor = UIColor(white: 0.45, alpha: 1)
        label.numberOfLines = 0
        label.text = text
        label.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: footer.topAnchor, constant: 6),
            label.bottomAnchor.constraint(lessThanOrEqualTo: footer.bottomAnchor, constant: -6),
        ])
        footer.forceLTR()
        return footer
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard let s = Section(rawValue: section), let text = sectionFooterText(s) else { return 4 }
        let width = max(tableView.bounds.width - 36, 80)
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.footerFont],
            context: nil)
        return ceil(box.height) + 14
    }

    // MARK: - Keyboard dismiss button

    private var _dismissKeyboardButton: UIButton?
    private var dismissKeyboardButton: UIButton {
        if let b = _dismissKeyboardButton { return b }
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = UIColor(white: 0.22, alpha: 1)
        cfg.baseForegroundColor = UIColor(white: 0.7, alpha: 1)
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        cfg.image = UIImage(systemName: "keyboard.chevron.compact.down",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        b.configuration = cfg
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(dismissKeyboardTapped), for: .touchUpInside)
        b.alpha = 0
        _dismissKeyboardButton = b
        return b
    }

    private func setupKeyboardDismissButton() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ n: Notification) {
        guard dismissKeyboardButton.superview == nil else {
            UIView.animate(withDuration: 0.2) { self.dismissKeyboardButton.alpha = 1 }
            return
        }
        guard let window = view.window else { return }
        window.addSubview(dismissKeyboardButton)
        var bottom = dismissKeyboardButton.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        if let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            bottom = dismissKeyboardButton.bottomAnchor.constraint(equalTo: window.topAnchor, constant: f.origin.y - 12)
        }
        NSLayoutConstraint.activate([
            dismissKeyboardButton.centerXAnchor.constraint(equalTo: window.centerXAnchor), bottom,
        ])
        UIView.animate(withDuration: 0.25) { self.dismissKeyboardButton.alpha = 1 }
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        UIView.animate(withDuration: 0.2) { self.dismissKeyboardButton.alpha = 0 }
    }

    @objc private func dismissKeyboardTapped() { view.endEditing(true) }

    deinit {
        _dismissKeyboardButton?.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
    }
}
