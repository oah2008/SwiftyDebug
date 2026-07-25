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
        case headers = 2
        case availableHeaders = 3
        case queryParams = 4
        case availableParams = 5
    }

    private struct EditItem {
        var key: String
        var value: String
        var isRemoving: Bool
        var isKeyEditable: Bool
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
    private var headerItems: [EditItem] = []
    private var queryParamItems: [EditItem] = []
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
        }
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

        rule.headerOverrides = headerItems.filter { !$0.isRemoving && !$0.key.isEmpty }
            .map { KVPair(key: $0.key, value: $0.value) }
        rule.removedHeaderKeys = Set(headerItems.filter { $0.isRemoving && !$0.key.isEmpty }.map { $0.key.lowercased() })
        rule.queryParamOverrides = queryParamItems.filter { !$0.isRemoving && !$0.key.isEmpty }
            .map { KVPair(key: $0.key, value: $0.value) }
        rule.removedQueryParamKeys = Set(queryParamItems.filter { $0.isRemoving && !$0.key.isEmpty }.map { $0.key })

        let hasEffect = rule.isBlocked
            || rule.redirectMode != .none && !rule.redirectTarget.isEmpty
            || !rule.headerOverrides.isEmpty || !rule.removedHeaderKeys.isEmpty
            || !rule.queryParamOverrides.isEmpty || !rule.removedQueryParamKeys.isEmpty
        guard hasEffect else {
            showAlert(title: "Empty Rule", message: "Add a header/parameter change, a redirect, or enable blocking.")
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
            return existingRule != nil ? 3 : 2      // block, redirect (+ delete)
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
        cell.configure(key: item.key, value: item.value, removing: item.isRemoving, keyEditable: item.isKeyEditable)

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
            else if ip.row == 2 { removeRuleTapped() }
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
        case .headers:     return ip.row < headerItems.count
        case .queryParams: return ip.row < queryParamItems.count
        default:           return false
        }
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard style == .delete else { return }
        switch Section(rawValue: ip.section)! {
        case .headers:     headerItems.remove(at: ip.row)
        case .queryParams: queryParamItems.remove(at: ip.row)
        default: return
        }
        reloadAll()
    }

    // MARK: - Headers / footers

    private func sectionTitle(_ s: Section) -> String? {
        switch s {
        case .endpoint: return matchMode == .global ? "SCOPE" : matchMode == .host ? "URLS" : "ENDPOINT"
        case .action:   return "ACTION"
        case .headers:  return isBlocked ? nil : "HEADERS\(headerItems.isEmpty ? "" : " (\(headerItems.count))")"
        case .availableHeaders:
            guard !isBlocked, !availableHeaders.isEmpty else { return nil }
            return "AVAILABLE HEADERS (\(availableHeaders.count))"
        case .queryParams: return isBlocked ? nil : "QUERY PARAMETERS\(queryParamItems.isEmpty ? "" : " (\(queryParamItems.count))")"
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
        if s == .availableHeaders || s == .availableParams { hint.text = "tap to add" }
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
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 4 }

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
