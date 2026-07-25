//
//  RequestReplayViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Re-run a captured request after editing **everything** about it — method,
/// URL, query parameters, headers and body — then see the response inline.
///
/// Mobile-first layout: one card per key/value (key on its own line, value on
/// its own line, see `KeyValueCardCell`), a big method picker, and a single
/// prominent Send button pinned above the keyboard-safe area.
///
/// The replayed request goes out through a normal `URLSession`, so SwiftyDebug's
/// own URLProtocol captures it too — it shows up in the Network list like any
/// other request. (See REPLAY.)
final class RequestReplayViewController: UITableViewController {

    // MARK: - Support check

    /// Replay is only offered for requests we can faithfully rebuild.
    static func canReplay(_ model: NetworkTransaction?) -> Bool {
        guard let model, let url = model.url as URL?,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        // A truncated request body can't be reproduced byte-for-byte.
        if model.isRequestBodyTruncated { return false }
        return true
    }

    // MARK: - Editable state

    private struct KV { var key: String; var value: String }

    private var method: String
    private var baseURLString: String          // scheme://host/path (no query)
    private var params: [KV] = []
    private var headers: [KV] = []
    private var bodyText: String = ""

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    private var methodSupportsBody: Bool { !["GET", "HEAD", "DELETE"].contains(method) }

    private enum Section: Int, CaseIterable {
        case request = 0     // method + URL
        case params = 1
        case headers = 2
        case body = 3
    }

    private var isSending = false

    // MARK: - Init

    init(model: NetworkTransaction) {
        self.method = (model.method ?? "GET").uppercased()

        let url = model.url as URL?
        if let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in comps.queryItems ?? [] {
                params.append(KV(key: item.name, value: item.value ?? ""))
            }
            comps.query = nil
            baseURLString = comps.url?.absoluteString ?? (url.absoluteString)
        } else {
            baseURLString = url?.absoluteString ?? ""
        }

        if let dict = model.requestHeaderFields as? [String: Any] {
            for (k, v) in dict.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
                headers.append(KV(key: k, value: "\(v)"))
            }
        }
        if let data = model.requestData, let s = String(data: data, encoding: .utf8) {
            // Pretty-print JSON bodies so they're editable on a phone.
            bodyText = JSONExporter.prettyJSONString(from: s) ?? s
        }
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Replay Request"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Send", style: .done, target: self, action: #selector(sendTapped)
        )
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        tableView.register(KeyValueCardCell.self, forCellReuseIdentifier: "Card")
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.keyboardDismissMode = .interactive
        tableView.contentInset.bottom = 24
        view.forceLTR()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    // MARK: - Send

    @objc private func sendTapped() {
        view.endEditing(true)
        guard !isSending else { return }

        guard var comps = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespaces)) else {
            showAlert("Invalid URL", "Could not parse the URL.")
            return
        }
        let liveParams = params.filter { !$0.key.isEmpty }
        comps.queryItems = liveParams.isEmpty ? nil : liveParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else {
            showAlert("Invalid URL", "Could not build the URL with those parameters.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for h in headers where !h.key.isEmpty {
            request.setValue(h.value, forHTTPHeaderField: h.key)
        }
        if methodSupportsBody, !bodyText.isEmpty {
            request.httpBody = bodyText.data(using: .utf8)
        }

        isSending = true
        setSendingUI(true)
        let started = Date()

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let finished = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSending = false
                self.setSendingUI(false)

                // Build a real NetworkTransaction from the response and show it in
                // the *actual* details screen, so the replay result page matches
                // the normal detail UI 100% (minus Intercept/Replay). (See REPLAY.)
                let model = Self.makeTransaction(request: request, data: data, response: response,
                                                 error: error, start: started, end: finished)
                let detail = NetworkDetailViewController()
                detail.httpModel = model
                detail.httpModels = [model]
                detail.isReplayResult = true
                self.navigationController?.pushViewController(detail, animated: true)
            }
        }.resume()
    }

    /// Converts a completed replay into a `NetworkTransaction` so it can be
    /// rendered by the standard detail screen (and carries the same fields the
    /// normal capture path produces).
    private static func makeTransaction(request: URLRequest, data: Data?, response: URLResponse?,
                                        error: Error?, start: Date, end: Date) -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = request.url as NSURL?
        model.method = request.httpMethod
        model.requestHeaderFields = request.allHTTPHeaderFields as NSDictionary?
        model.requestData = request.httpBody

        let http = response as? HTTPURLResponse
        model.statusCode = "\(http?.statusCode ?? 0)"
        model.mineType = response?.mimeType
        if let fields = http?.allHeaderFields as? [String: Any] {
            model.responseHeaderFields = fields as NSDictionary
        }
        model.responseData = data
        model.size = ByteCountFormatter().string(fromByteCount: Int64(data?.count ?? 0))
        model.isImage = (response?.mimeType?.hasPrefix("image") ?? false)

        model.startTime = String(format: "%f", start.timeIntervalSince1970)
        model.endTime = String(format: "%f", end.timeIntervalSince1970)
        model.totalDuration = String(format: "%f (s)", end.timeIntervalSince(start))

        if let error = error as NSError? {
            model.errorDescription = error.description
            model.errorLocalizedDescription = error.localizedDescription
        }
        model.buildSearchIndex(responseBody: data)
        return model
    }

    private func setSendingUI(_ sending: Bool) {
        if sending {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = DebugTheme.accentColor
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Send", style: .done, target: self, action: #selector(sendTapped))
            navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .request: return 2                      // method picker + URL
        case .params:  return params.count + 1       // +Add
        case .headers: return headers.count + 1      // +Add
        case .body:    return methodSupportsBody ? 1 : 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        switch Section(rawValue: ip.section)! {
        case .request:
            return ip.row == 0 ? methodCell() : urlCell()
        case .params:
            if ip.row == params.count { return addCell("Add parameter") }
            return kvCell(ip, list: .params)
        case .headers:
            if ip.row == headers.count { return addCell("Add header") }
            return kvCell(ip, list: .headers)
        case .body:
            return bodyCell()
        }
    }

    private enum ListKind { case params, headers }

    private func card(_ id: String) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: id)
        c.backgroundColor = UIColor(white: 0.11, alpha: 1)
        c.selectionStyle = .none
        c.forceLTR()
        return c
    }

    private func methodCell() -> UITableViewCell {
        let c = card("method")
        let seg = UISegmentedControl(items: Self.methods)
        seg.selectedSegmentIndex = Self.methods.firstIndex(of: method) ?? 0
        seg.selectedSegmentTintColor = DebugTheme.accentColor
        seg.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1),
                                    .font: UIFont.systemFont(ofSize: 11, weight: .semibold)], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                    .font: UIFont.systemFont(ofSize: 11, weight: .bold)], for: .selected)
        seg.addAction(UIAction { [weak self, weak seg] _ in
            guard let self, let seg else { return }
            self.method = Self.methods[seg.selectedSegmentIndex]
            self.tableView.reloadSections(IndexSet(integer: Section.body.rawValue), with: .automatic)
        }, for: .valueChanged)
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

    private func urlCell() -> UITableViewCell {
        let c = card("url")
        let tv = UITextView()
        tv.text = baseURLString
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .white
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.keyboardType = .URL
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.tag = 900
        c.contentView.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: c.contentView.leadingAnchor, constant: 4),
            tv.trailingAnchor.constraint(equalTo: c.contentView.trailingAnchor, constant: -4),
            tv.topAnchor.constraint(equalTo: c.contentView.topAnchor, constant: 2),
            tv.bottomAnchor.constraint(equalTo: c.contentView.bottomAnchor, constant: -2),
            tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return c
    }

    private func kvCell(_ ip: IndexPath, list: ListKind) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Card", for: ip) as! KeyValueCardCell
        let item = list == .params ? params[ip.row] : headers[ip.row]
        cell.showsModeControl = false
        cell.configure(key: item.key, value: item.value, removing: false, keyEditable: true)
        cell.onKeyChanged = { [weak self] k in
            guard let self else { return }
            if list == .params { self.params[ip.row].key = k } else { self.headers[ip.row].key = k }
        }
        cell.onValueChanged = { [weak self] v in
            guard let self else { return }
            if list == .params { self.params[ip.row].value = v } else { self.headers[ip.row].value = v }
        }
        cell.currentKeyText = { [weak self] in
            guard let self else { return "" }
            return list == .params ? self.params[ip.row].key : self.headers[ip.row].key
        }
        if list == .headers {
            cell.keySuggestionsProvider = { q in
                HeaderSuggestionStore.shared.suggestions(matching: q, excluding: [], limit: 12)
            }
            cell.valueSuggestionsProvider = { key, cur in
                guard !key.isEmpty else { return [] }
                var out = HTTPHeaderCatalog.valueTemplates(forHeader: key)
                out.append(contentsOf: RequestMetadataStore.shared.values(forHeader: key))
                let q = cur.lowercased()
                var seen = Set<String>()
                return out.filter { v in
                    guard q.isEmpty || v.lowercased().hasPrefix(q) || v.hasSuffix(" ") else { return false }
                    return seen.insert(v.lowercased()).inserted
                }.prefix(12).map { $0 }
            }
        } else {
            cell.valueSuggestionsProvider = { key, cur in
                guard !key.isEmpty else { return [] }
                let q = cur.lowercased()
                var seen = Set<String>()
                return RequestMetadataStore.shared.values(forParam: key).filter { v in
                    guard q.isEmpty || v.lowercased().hasPrefix(q) else { return false }
                    return seen.insert(v).inserted
                }.prefix(12).map { $0 }
            }
        }
        return cell
    }

    private func addCell(_ title: String) -> UITableViewCell {
        let c = card("add")
        c.selectionStyle = .default
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        c.imageView?.image = UIImage(systemName: "plus.circle.fill", withConfiguration: cfg)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        c.textLabel?.text = title
        c.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        c.textLabel?.textColor = DebugTheme.accentColor
        return c
    }

    private func bodyCell() -> UITableViewCell {
        let c = card("body")
        let tv = UITextView()
        tv.text = bodyText
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = UIColor(white: 0.9, alpha: 1)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.tag = 901
        c.contentView.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: c.contentView.leadingAnchor, constant: 4),
            tv.trailingAnchor.constraint(equalTo: c.contentView.trailingAnchor, constant: -4),
            tv.topAnchor.constraint(equalTo: c.contentView.topAnchor, constant: 2),
            tv.bottomAnchor.constraint(equalTo: c.contentView.bottomAnchor, constant: -2),
            tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch Section(rawValue: ip.section)! {
        case .params where ip.row == params.count:
            params.append(KV(key: "", value: ""))
            tableView.reloadSections(IndexSet(integer: ip.section), with: .automatic)
        case .headers where ip.row == headers.count:
            headers.append(KV(key: "", value: ""))
            tableView.reloadSections(IndexSet(integer: ip.section), with: .automatic)
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        switch Section(rawValue: ip.section)! {
        case .params:  return ip.row < params.count
        case .headers: return ip.row < headers.count
        default:       return false
        }
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard style == .delete else { return }
        switch Section(rawValue: ip.section)! {
        case .params:  params.remove(at: ip.row)
        case .headers: headers.remove(at: ip.row)
        default: return
        }
        tableView.reloadSections(IndexSet(integer: ip.section), with: .automatic)
    }

    // MARK: - Section headers

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let s = Section(rawValue: section) else { return nil }
        let text: String
        switch s {
        case .request: text = "REQUEST"
        case .params:  text = "QUERY PARAMETERS\(params.isEmpty ? "" : " (\(params.count))")"
        case .headers: text = "HEADERS\(headers.isEmpty ? "" : " (\(headers.count))")"
        case .body:    guard methodSupportsBody else { return nil }; text = "BODY"
        }
        let v = UIView()
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .heavy)
        l.textColor = DebugTheme.accentColor
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
        ])
        v.forceLTR()
        return v
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if Section(rawValue: section) == .body && !methodSupportsBody { return 0 }
        return 38
    }
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 4 }
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
}

// MARK: - Text view editing (URL + body)

extension RequestReplayViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        if textView.tag == 900 { baseURLString = textView.text }
        else if textView.tag == 901 { bodyText = textView.text }
        // Keep row height in sync without losing first responder.
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }
}

