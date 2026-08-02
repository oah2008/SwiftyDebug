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
///   NAME       — what to call this rule; blank keeps the auto-derived name
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
        /// First, because it is the one thing that makes a rule identifiable in
        /// every list that shows it. Mocks, breakpoints and rewrites had no name
        /// at all, so a list of them read as a list of "Empty rule".
        case name = 0
        case endpoint = 1
        case action = 2
        /// Sits with the other "what to do with a matching request" choices —
        /// a rewrite is the same kind of decision as mock/breakpoint/redirect.
        case responseRewrites = 3
        case headers = 4
        case availableHeaders = 5
        case queryParams = 6
        case availableParams = 7
    }

    /// The rows of the ENDPOINT section, as a list rather than as row numbers.
    /// The host row is only offered when there is a real host to pin to, so the
    /// row indices move — naming them keeps `cellForRowAt` and `didSelectRowAt`
    /// from disagreeing about what row 2 is.
    private enum EndpointRow {
        /// Pattern / Exact.
        case mode
        /// The path this rule matches, shown in full.
        case path
        /// This host only, or any host.
        case hostScope
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

    /// The literal path an `.exact` rule matches — the FULL path, never a
    /// pattern. Empty means "no concrete path is known here" (editing a pattern
    /// rule with no captured request behind it), and Exact is then not offered
    /// rather than silently saving `/product/{id}` as an exact path that no
    /// request can ever equal.
    private var requestPath = ""
    /// The pattern a `.normalized` rule matches (`/product/{id}/{id}`).
    private var normalizedPath = ""
    /// Host of the request that opened this screen, lowercased. The candidate
    /// for the host pin.
    private var requestHost = ""
    /// The host an endpoint rule is pinned to. Empty = ANY host.
    private var matchHost = ""
    /// What the user typed in NAME. Empty on purpose when they did not type
    /// anything: the rule then keeps deriving its name from what it does, so
    /// arming a mock later renames it instead of leaving a stale label behind.
    private var ruleName = ""
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
        tableView.register(RuleNameCell.self, forCellReuseIdentifier: "Name")
        tableView.register(EndpointPathCell.self, forCellReuseIdentifier: "Path")
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

    // NO `viewDidAppear` OVERRIDE, DELIBERATELY.
    //
    // A previous round popped the "this host / any host" sheet automatically the
    // first time a NEW endpoint rule appeared. The maintainer asked for it gone:
    // the answer it offered as its default (THIS HOST) is the answer the editor
    // already applies in `populateFromModel()`, so the sheet asked a question
    // whose answer never changed anything and stood between the user and the
    // screen they asked for.
    //
    // The scope did not go away with it — it is stated on the ENDPOINT rows
    // (`endpointHostScopeCell`, `endpointScopeExplanation`) and changed by
    // tapping the host row, which still opens `presentHostScopePicker()`.

    // MARK: - Populate

    private func populateFromModel() {
        if let model = httpModel {
            requestPath = model.url?.path ?? ""
            normalizedPath = EndpointNormalizer.normalize(requestPath)
            requestHost = InterceptRule.canonicalHost(model.url?.host ?? "")
        }
        // A rule handed in directly wins over an id to look up, and — unlike
        // before — is honoured even when a captured request came along with it.
        // The two are not alternatives: the request supplies the concrete path
        // and host, the rule supplies what it currently matches.
        if let rule = ruleToEdit {
            existingRule = rule
            existingRuleId = rule.id
        } else if let ruleId = existingRuleId {
            // The URL lookup is the fast path; `allRules()` is the safety net.
            // Failing to find the rule being edited used to mean Save quietly
            // created a SECOND rule and left the original behind, still armed.
            let byURL = (httpModel?.url as URL?).map { InterceptRuleStore.shared.matchingRules(forURL: $0) } ?? []
            existingRule = byURL.first { $0.id == ruleId }
                ?? InterceptRuleStore.shared.allRules().first { $0.id == ruleId }
        }

        if let rule = existingRule {
            matchMode = rule.matchMode
            selectedHosts = rule.matchHosts
            matchHost = InterceptRule.canonicalHost(rule.matchHost)
            ruleName = rule.name
            // The RULE's own scope wins over whichever request happened to open
            // this screen. Seeding the path from `httpModel` instead showed a
            // path the rule does not match, and Save then re-keyed the rule onto
            // it — silently changing what it intercepts.
            seedEndpointFields(from: rule)
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
                // Pinned to the request's host by default — nothing asks, because
                // the host row on screen both STATES this and is the way to change
                // it. Any-host is the surprising answer (a rule for `/api/users`
                // firing on staging, production and every third party using the
                // same path), so it is the one you opt into. Existing rules on disk
                // keep their empty pin and their any-host behaviour.
                matchHost = requestHost
                prefillFromEndpoint()
            }
        }
    }

    /// Fills the Pattern and Exact fields from a rule, keeping them DISTINCT.
    ///
    /// They used to both be set to `rule.matchEndpoint`, so a pattern rule showed
    /// `/product/{id}/{id}` under *Exact* as well; tapping Exact then saved that
    /// pattern as an exact path, which no `url.path` can ever equal. Every such
    /// rule was inert and — because the endpoint was the whole storage key —
    /// they all landed in the same bucket and overwrote each other. That is the
    /// "exact rules override each other" the report opens with.
    ///
    /// Pure and `static` so both halves are covered by tests: an exact rule keeps
    /// its full literal path, a pattern rule only offers Exact when a captured
    /// request is a real instance of that pattern.
    static func endpointSeed(for rule: InterceptRule,
                             capturedPath: String) -> (exact: String, pattern: String) {
        switch rule.matchMode {
        case .global, .host:
            return (capturedPath, EndpointNormalizer.normalize(capturedPath))
        case .exact:
            // The full path, verbatim. Nothing here shortens it.
            return (rule.matchEndpoint, EndpointNormalizer.normalize(rule.matchEndpoint))
        case .normalized:
            let pattern = rule.matchEndpoint
            let concrete = EndpointNormalizer.normalize(capturedPath) == pattern ? capturedPath : ""
            return (concrete, pattern)
        }
    }

    private func seedEndpointFields(from rule: InterceptRule) {
        guard rule.matchMode == .exact || rule.matchMode == .normalized else { return }
        let seed = Self.endpointSeed(for: rule, capturedPath: requestPath)
        requestPath = seed.exact
        normalizedPath = seed.pattern
        if requestHost.isEmpty { requestHost = InterceptRule.canonicalHost(rule.matchHost) }
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

    /// What Save decided. `internal` with a case per refusal so the whole
    /// build-and-validate step is testable without a store, a window or disk.
    enum SaveOutcome {
        case ok(InterceptRule)
        /// `.host` mode with nothing selected.
        case noHosts
        /// An endpoint rule with no path to match — the Exact field is empty.
        case noEndpoint
        /// Nothing armed: the rule would be saved and do nothing.
        case noEffect
    }

    /// Builds the rule Save would write, or says why it will not.
    ///
    /// The scope is applied to `existingRule` itself rather than only to a
    /// freshly-made one. It used to read
    /// `rule = existingRule ?? InterceptRule(matchEndpoint: endpoint, ...)`, and
    /// on the `existingRule` branch `matchEndpoint` was NEVER assigned — so
    /// editing a rule and switching Pattern → Exact changed `matchMode` and left
    /// the pattern in place, and the "did the endpoint change?" guard compared
    /// the rule with itself and could never fire. Re-keying is now unconditional:
    /// mode, path and host pin are written every time, and the store re-files the
    /// rule under its new key.
    func validatedRule() -> SaveOutcome {
        var rule: InterceptRule
        switch matchMode {
        case .global:
            rule = existingRule ?? InterceptRule.globalRule()
        case .host:
            guard !canonicalSelectedHosts.isEmpty else { return .noHosts }
            rule = existingRule ?? InterceptRule.hostRule(hosts: canonicalSelectedHosts)
        case .exact, .normalized:
            guard !currentEndpoint.isEmpty else { return .noEndpoint }
            rule = existingRule ?? InterceptRule.endpointRule(path: currentEndpoint,
                                                              mode: matchMode,
                                                              host: matchHost)
        }

        applyScope(to: &rule)
        applyEditorState(to: &rule)

        let hasEffect = rule.isBlocked
            || rule.mock.isEnabled
            || rule.breakpointMode != .off
            || rule.redirectMode != .none && !rule.redirectTarget.isEmpty
            || !rule.headerOverrides.isEmpty || !rule.removedHeaderKeys.isEmpty
            || !rule.queryParamOverrides.isEmpty || !rule.removedQueryParamKeys.isEmpty
            || !rule.responseRewrites.isEmpty
        guard hasEffect else { return .noEffect }
        return .ok(rule)
    }

    /// The endpoint the current mode matches on: the FULL literal path for
    /// Exact, the pattern for Pattern. Never one standing in for the other.
    private var currentEndpoint: String {
        matchMode == .exact ? requestPath : normalizedPath
    }

    private var canonicalSelectedHosts: [String] {
        InterceptRule.canonicalHosts(selectedHosts)
    }

    /// Writes mode + endpoint + host pin onto `rule`, unconditionally.
    private func applyScope(to rule: inout InterceptRule) {
        rule.matchMode = matchMode
        switch matchMode {
        case .global:
            rule.matchEndpoint = "global"
            rule.matchHosts = []
            rule.matchHost = ""
        case .host:
            let hosts = canonicalSelectedHosts
            rule.matchHosts = hosts
            rule.matchEndpoint = InterceptRule.hostKey(for: hosts)
            rule.matchHost = ""
        case .exact, .normalized:
            rule.matchEndpoint = currentEndpoint
            rule.matchHost = InterceptRule.canonicalHost(matchHost)
            rule.matchHosts = []
        }
    }

    /// Whether the saved rule is armed. Pure and `internal` so the rule can be
    /// unit-tested: this screen has no enable control, so an existing rule must
    /// keep whatever the list's switch said, and only a brand-new rule arms
    /// itself. Forcing `true` here silently re-armed a rule the user had switched
    /// off — and a blocking rule then broke the host app's traffic again.
    static func applyEnablement(to rule: inout InterceptRule, existing: InterceptRule?) {
        rule.isEnabled = existing?.isEnabled ?? true
    }

    /// Writes everything the editor arms onto `rule`. Pure state transfer — no
    /// store, no disk — so `derivedNamePreview` can run it on a throwaway rule.
    private func applyEditorState(to rule: inout InterceptRule) {
        // Empty when the user did not type a name, which is what keeps the rule
        // tracking its own configuration: freezing today's derived text into
        // `name` would leave "3 headers" on a rule that now mocks a 404.
        rule.name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.isBlocked = isBlocked
        // Do NOT force this on. A rule switched off in the list and then merely
        // opened and saved used to re-arm itself — and if it blocks requests, the
        // host app starts failing again with nothing on screen suggesting the user
        // asked for it. There is no enable control on this screen, so the only
        // honest behaviour is to leave the flag exactly as it was. A brand-new
        // rule (no existing one) still arms itself, which is what the user means
        // by creating it.
        Self.applyEnablement(to: &rule, existing: existingRule)
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
    }

    /// The name this rule would carry with the NAME field left blank. Shown as
    /// the field's placeholder and refreshed whenever anything is armed, so the
    /// auto-name is never a mystery.
    ///
    /// Pure: builds a throwaway rule and reads `derivedName`, which does no I/O.
    var derivedNamePreview: String {
        var rule = existingRule ?? InterceptRule(matchEndpoint: currentEndpoint, matchMode: matchMode)
        applyScope(to: &rule)
        applyEditorState(to: &rule)
        rule.name = ""
        return rule.derivedName
    }

    @objc private func saveTapped() {
        switch validatedRule() {
        case .noHosts:
            showAlert(title: "No URLs", message: "Select at least one URL to intercept.")
        case .noEndpoint:
            showAlert(title: "No Endpoint",
                      message: "This rule has no path to match. Pick Pattern, or open it from a captured request "
                        + "so there is a real path to match exactly.")
        case .noEffect:
            showAlert(title: "Empty Rule",
                      message: "Add a header/parameter change, a response rewrite, a redirect, or enable blocking.")
        case .ok(let rule):
            // No remove-then-add: `addOrUpdate` drops every copy of this id from
            // every bucket before re-filing it, so a re-scoped rule cannot leave
            // a stale twin behind still matching what it used to.
            InterceptRuleStore.shared.addOrUpdate(rule)
            if isPresentedModally {
                dismiss(animated: true)
            } else {
                navigationController?.popViewController(animated: true)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    @objc private func blockToggleChanged(_ sender: UISwitch) {
        setBlocked(sender.isOn)
    }

    /// Arms or disarms blocking. `internal` so a test drives the same code the
    /// switch does.
    func setBlocked(_ blocked: Bool) {
        isBlocked = blocked
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

    /// Save this rule, then open a switched-off copy of it.
    ///
    /// The maintainer's reason for wanting duplication is "easier to edit", so
    /// the copy carries what is on SCREEN, not what was last written to disk —
    /// which means this rule has to be saved first, or the edits you can see
    /// would exist only on the copy and silently vanish from the original.
    /// Validation is the same one Save uses, and refuses for the same reasons.
    ///
    /// The copy is created disabled (see `InterceptRuleDuplicator.duplicate`),
    /// and the editor that opens on it says so in the ACTION footer.
    @objc private func duplicateRuleTapped() {
        // Nothing to duplicate until the rule exists; the row is not offered
        // then either.
        guard existingRule != nil else { return }
        switch validatedRule() {
        case .noHosts:
            showAlert(title: "No URLs", message: "Select at least one URL to intercept.")
        case .noEndpoint:
            showAlert(title: "No Endpoint",
                      message: "This rule has no path to match, so there is nothing to copy.")
        case .noEffect:
            showAlert(title: "Empty Rule",
                      message: "This rule does nothing yet, so a copy of it would do nothing either.")
        case .ok(let rule):
            InterceptRuleStore.shared.addOrUpdate(rule)
            guard let copy = InterceptRuleDuplicator.duplicateAndStore(id: rule.id) else { return }
            openEditor(for: copy)
        }
    }

    /// Pushes a second editor onto the copy, leaving this one behind it so Back
    /// returns to the original.
    private func openEditor(for rule: InterceptRule) {
        let editor = InterceptRuleEditorViewController()
        editor.httpModel = httpModel
        editor.ruleToEdit = rule
        // Both, so the title reads "Edit Rule" — `viewDidLoad` chooses it before
        // `populateFromModel()` derives the id from `ruleToEdit`.
        editor.existingRuleId = rule.id
        if let nav = navigationController {
            nav.pushViewController(editor, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
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
        // Exact is disabled without a concrete path, so this can only pick a mode
        // that has something to match on.
        setMatchMode(sender.selectedSegmentIndex == 0 ? .normalized : .exact)
    }

    /// Switches between Pattern and Exact. `internal` so a test drives the same
    /// code the segmented control does.
    func setMatchMode(_ mode: EndpointMatchMode) {
        matchMode = mode
        reloadAll()
    }

    // MARK: - Host scope (this host / any host)

    /// The host this rule could be pinned to: the one it is already pinned to,
    /// or the one the request in context came from. Empty means there is no host
    /// to offer — a curl import with no captured request, for instance.
    private var hostScopeCandidate: String {
        matchHost.isEmpty ? requestHost : matchHost
    }

    /// "This endpoint on api.example.com" vs "This endpoint on any host".
    ///
    /// A sheet, not an alert: hosts and paths are long and an alert row cuts them
    /// off, which is the whole reason `OptionPickerSheetViewController` exists.
    private func presentHostScopePicker() {
        let host = hostScopeCandidate
        guard !host.isEmpty else { return }
        let endpoint = currentEndpoint.isEmpty ? "this endpoint" : currentEndpoint

        let pinned = OptionPickerSheetViewController.Option(
            title: "This endpoint on \(host)",
            subtitle: "Matches \(endpoint) only when the request goes to \(host). "
                + "Requests to any other host are left alone.",
            symbol: "lock.circle", tint: .systemPurple
        ) { [weak self] in
            self?.setHostScope(pinned: true)
        }
        let anyHost = OptionPickerSheetViewController.Option(
            title: "This endpoint on any host",
            subtitle: "Matches \(endpoint) wherever it is requested — staging, production and "
                + "anything else that uses the same path.",
            symbol: "globe", tint: .systemOrange
        ) { [weak self] in
            self?.setHostScope(pinned: false)
        }

        OptionPickerSheetViewController.present(
            from: self,
            title: "Which Requests?",
            message: "An endpoint rule can match one host or every host. Matching every host is how "
                + "a rule for one app ends up firing on someone else's.",
            options: [pinned, anyHost],
            selectedIndex: matchHost.isEmpty ? 1 : 0)
    }

    /// The two answers to "which requests?", as one seam the picker and the
    /// tests both go through. `internal` for that reason.
    func setHostScope(pinned: Bool) {
        matchHost = pinned ? hostScopeCandidate : ""
        reloadAll()
    }

    // MARK: - Name

    @objc private func nameFieldChanged(_ sender: UITextField) {
        // Held in `ruleName`, not read back off the cell: the cell is rebuilt by
        // every reload and a value living only in a text field would vanish with
        // it. Blank stays blank — see `applyEditorState`.
        ruleName = sender.text ?? ""
    }

    @objc private func nameFieldDone(_ sender: UITextField) {
        sender.resignFirstResponder()
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
        // Two rules can now share scope and host pin (duplication), so name the
        // one this editor owns rather than letting the store guess.
        editor.attachRuleId = existingRule?.id
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
            guard hostPinAllows(url) else { return false }
            return !requestPath.isEmpty && url.path == requestPath
        case .normalized:
            guard hostPinAllows(url) else { return false }
            return !normalizedPath.isEmpty && EndpointNormalizer.normalize(url.path) == normalizedPath
        }
    }

    /// Mirrors `InterceptRule.hostPinAllows(_:)` for the scope currently being
    /// edited — so the rewrite preview samples a response this rule could
    /// actually have seen, not one from a host it is pinned away from.
    private func hostPinAllows(_ url: URL) -> Bool {
        let pin = InterceptRule.canonicalHost(matchHost)
        return pin.isEmpty || InterceptRule.canonicalHost(url.host ?? "") == pin
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

    /// The ENDPOINT section's rows for the current mode. The host row only
    /// appears when there is a host it could be pinned to.
    private var endpointRows: [EndpointRow] {
        guard matchMode == .exact || matchMode == .normalized else { return [] }
        var rows: [EndpointRow] = [.mode, .path]
        if !hostScopeCandidate.isEmpty { rows.append(.hostScope) }
        return rows
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .name:
            return 1
        case .endpoint:
            if matchMode == .global { return 1 }
            if matchMode == .host { return 1 + selectedHosts.count }
            return endpointRows.count
        case .action:
            // block, redirect, mock, breakpoint (+ duplicate, delete once the
            // rule exists — there is nothing to copy or remove before that).
            return existingRule != nil ? 6 : 4
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
        case .name:       return nameCell(indexPath)
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
        guard endpointRows.indices.contains(ip.row) else { return plainCell("endpointEmpty") }
        switch endpointRows[ip.row] {
        case .mode:      return endpointModeCell()
        case .path:      return endpointPathCell(ip)
        case .hostScope: return endpointHostScopeCell()
        }
    }

    private func endpointModeCell() -> UITableViewCell {
        let c = plainCell("mode")
        c.selectionStyle = .none
        let seg = UISegmentedControl(items: ["Pattern", "Exact"])
        seg.selectedSegmentIndex = matchMode == .normalized ? 0 : 1
        // Exact needs a real path. Editing a pattern rule with no captured
        // request behind it has none, and the old screen offered the pattern
        // itself — saving `/product/{id}` as an "exact" path that nothing can
        // ever equal.
        seg.setEnabled(!requestPath.isEmpty, forSegmentAt: 1)
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

    /// The path this rule matches — **in full**, however long it is.
    ///
    /// This used to be a stock `.subtitle` cell whose `textLabel` was given
    /// `numberOfLines = 3`. The stock labels do not self-size with
    /// `automaticDimension` (the same defect `OptionPickerSheetViewController`
    /// was built to avoid), so the row kept its stock height and the path was
    /// clipped: `/product/10289032912/20920220` showed as `/product/10289032912`
    /// and it was impossible to tell which of two long paths a rule was on.
    /// `EndpointPathCell` wraps instead, with real constraints top AND bottom.
    private func endpointPathCell(_ ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Path", for: ip) as! EndpointPathCell
        let exact = matchMode == .exact
        cell.configure(path: currentEndpoint,
                       detail: endpointScopeExplanation,
                       tint: exact ? .systemOrange : DebugTheme.accentColor)
        return cell
    }

    /// Says, in one line, exactly which requests this scope catches — including
    /// the host, so "any host" is never the silent default it used to be.
    private var endpointScopeExplanation: String {
        let pin = InterceptRule.canonicalHost(matchHost)
        let what = matchMode == .exact
            ? "Matches only this exact path"
            : "Matches every path with this pattern (IDs replaced)"
        return pin.isEmpty ? what + ", on ANY host" : what + ", on " + pin + " only"
    }

    private func endpointHostScopeCell() -> UITableViewCell {
        let c = plainCell("hostScope", style: .subtitle)
        let pin = InterceptRule.canonicalHost(matchHost)
        c.textLabel?.text = pin.isEmpty ? "Any host" : pin
        c.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        c.textLabel?.textColor = pin.isEmpty ? .systemOrange : .systemPurple
        c.detailTextLabel?.text = pin.isEmpty
            ? "Fires wherever this path is requested — tap to limit it to one host"
            : "Only requests to this host — tap to change"
        c.detailTextLabel?.font = .systemFont(ofSize: 11)
        c.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        c.accessoryType = .disclosureIndicator
        return c
    }

    /// NAME. The field is pre-filled with the user's own name and *placeholdered*
    /// with the derived one — deliberately not pre-filled with the derived text,
    /// because a name frozen at creation stops describing the rule the moment
    /// anything is armed.
    private func nameCell(_ ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Name", for: ip) as! RuleNameCell
        cell.configure(name: ruleName, placeholder: derivedNamePreview)
        cell.field.removeTarget(self, action: nil, for: .allEvents)
        cell.field.addTarget(self, action: #selector(nameFieldChanged(_:)), for: .editingChanged)
        cell.field.addTarget(self, action: #selector(nameFieldDone(_:)), for: .editingDidEndOnExit)
        return cell
    }

    private func actionCell(_ ip: IndexPath) -> UITableViewCell {
        switch ip.row {
        case 0:
            let c = plainCell("block", style: .subtitle)
            c.selectionStyle = .none
            c.textLabel?.text = "Block Request"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = .white
            let pin = InterceptRule.canonicalHost(matchHost)
            let target: String
            switch matchMode {
            case .global:     target = "all URLs"
            case .host:       target = "selected hosts"
            case .exact, .normalized:
                target = pin.isEmpty ? "this endpoint on any host" : "this endpoint on \(pin)"
            }
            c.detailTextLabel?.text = "Cancel all future requests to \(target)"
            c.detailTextLabel?.numberOfLines = 2
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
        case 4:
            let c = plainCell("duplicate", style: .subtitle)
            c.textLabel?.text = "Duplicate Rule"
            c.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            c.textLabel?.textColor = DebugTheme.accentColor
            c.detailTextLabel?.text = "Saves this rule, then opens a switched-off copy of it"
            c.detailTextLabel?.font = .systemFont(ofSize: 11)
            c.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
            c.detailTextLabel?.numberOfLines = 2
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
        case .name:
            break
        case .endpoint:
            if matchMode == .host {
                if ip.row == 0 { selectHostsTapped() }
                return
            }
            guard endpointRows.indices.contains(ip.row) else { return }
            if endpointRows[ip.row] == .hostScope { presentHostScopePicker() }
        case .action:
            if ip.row == 1 { presentRedirectEditor() }
            else if ip.row == 2 { presentMockEditor() }
            else if ip.row == 3 { presentBreakpointPicker() }
            else if ip.row == 4 { duplicateRuleTapped() }
            else if ip.row == 5 { removeRuleTapped() }
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
        case .name:     return "NAME"
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
        case .name: hint.text = "blank = auto"
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
        if s == .name {
            // Says out loud that leaving it blank is a live default, not an
            // absence: the rule keeps re-describing itself as it changes.
            return ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Left blank, this rule is listed as \u{201C}\(derivedNamePreview)\u{201D} and keeps up with whatever you arm."
                : nil
        }
        if s == .action {
            // ORDER MATTERS. "Switched off" subsumes everything else — if the rule
            // does not run, no conflict between its actions is worth mentioning
            // yet. This screen has NO enable control (see `applyEnablement`), so a
            // disabled rule otherwise reads exactly like an armed one, which bites
            // hardest on a fresh duplicate (created switched off on purpose):
            // without this you would edit a copy, save it, and watch nothing happen.
            if let existing = existingRule, !existing.isEnabled {
                return "This rule is switched OFF, so none of the above happens yet. "
                    + "Turn it on with the switch on its row in the rules list."
            }
            // A mock answers from `startLoading` and never touches the network, so
            // the breakpoint parked further down that path never fires. Say so
            // HERE, while both are being armed — the paused inbox reports it
            // afterwards, but by then you are already waiting for a pause that is
            // never coming.
            if mock.isEnabled, breakpointMode != .off {
                return "This rule returns a mock, so the breakpoint never pauses — "
                    + "a mock answers before the request is sent. Edit the mock body instead."
            }
            return nil
        }
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

// MARK: - Endpoint path cell

/// Shows a URL path **in full**, wrapping over as many lines as it takes.
///
/// Built with real constraints from `contentView.top` to `contentView.bottom` so
/// the row self-sizes. The stock `UITableViewCell` labels do not — they keep the
/// stock row height and clip, which is how `/product/10289032912/20920220` came
/// out as `/product/10289032912` on the screen where you choose what a rule
/// matches. Paths have no spaces, so wrapping is `.byCharWrapping`: word
/// wrapping has nowhere to break and falls back to cutting the tail.
final class EndpointPathCell: UITableViewCell {

    private let pathLabel = UILabel()
    private let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        selectionStyle = .none

        pathLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        pathLabel.numberOfLines = 0
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = UIColor(white: 0.45, alpha: 1)
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(pathLabel)
        contentView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            pathLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 4),
            // Pinned to the BOTTOM as well — without this the cell has no height
            // to compute and self-sizing silently falls back to the estimate.
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(path: String, detail: String, tint: UIColor) {
        pathLabel.text = path.isEmpty ? "(no path)" : path
        pathLabel.textColor = path.isEmpty ? UIColor(white: 0.45, alpha: 1) : tint
        detailLabel.text = detail
    }
}

// MARK: - Rule name cell

/// The NAME field. A rule with no name of its own is listed under a description
/// of what it does, which is what the placeholder shows.
final class RuleNameCell: UITableViewCell {

    let field = UITextField()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        selectionStyle = .none

        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.textColor = .white
        field.tintColor = DebugTheme.accentColor
        field.autocorrectionType = .no
        field.autocapitalizationType = .sentences
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, placeholder: String) {
        // Only assign when it differs: assigning `text` to a focused field moves
        // the caret to the end mid-typing.
        if field.text != name { field.text = name }
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.42, alpha: 1)])
    }
}
