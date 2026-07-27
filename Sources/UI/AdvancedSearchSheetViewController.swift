//
//  AdvancedSearchSheetViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Everything the network search can do beyond matching a URL.
///
/// One value object rather than loose flags on the view controller, because each
/// field maps onto `ResponseBodySearch.Options` — whose `cacheKey(for:)` includes
/// all of them, so changing any one correctly invalidates cached hits instead of
/// serving results produced under different rules.
struct AdvancedSearchOptions: Equatable {

    /// Look inside what the server sent back.
    var searchResponseBodies = false
    /// Look inside what the app sent.
    var searchRequestBodies = false
    /// Match capitalisation exactly.
    var caseSensitive = false
    /// Include image/video/audio responses, which are normally skipped.
    var includeMedia = false
    /// Read whole bodies instead of only the first `ResponseBodySearch.defaultByteCap`.
    var scanWholeBodies = false

    /// True when at least one body scope is on — i.e. when a scan is worth running.
    var searchesAnyBody: Bool { searchResponseBodies || searchRequestBodies }

    /// Engine options for scanning **one** side. The caller drives one scan per
    /// side so each chip gets its own count.
    func engineOptions(for side: BodySearchSide) -> ResponseBodySearch.Options {
        var options = ResponseBodySearch.Options()
        options.searchResponseBodies = (side == .response)
        options.searchRequestBodies = (side == .request)
        options.caseSensitive = caseSensitive
        if scanWholeBodies { options.byteCap = .max }
        if !includeMedia {
            // Reuse the list's own media rule so the two can never disagree.
            options.skipTransaction = { NetworkViewController.isMediaTransaction($0) }
        }
        return options
    }
}

/// The "Advanced" sheet: every search option as a labelled toggle with a sentence
/// explaining what it does and what it costs.
///
/// Toggles rather than chips because these are settings that persist across
/// queries, and each one needs room for its description — the whole reason the
/// old unlabelled icons were replaced.
final class AdvancedSearchSheetViewController: UITableViewController {

    /// Fired on every change so the caller can rescan immediately — a search
    /// sheet that only applies on dismiss feels broken.
    var onChange: ((AdvancedSearchOptions) -> Void)?

    private var options: AdvancedSearchOptions

    private struct Toggle {
        let title: String
        let detail: String
        let symbol: String
        let get: (AdvancedSearchOptions) -> Bool
        let set: (inout AdvancedSearchOptions, Bool) -> Void
    }

    private struct Group {
        let header: String
        let footer: String?
        let toggles: [Toggle]
    }

    private let groups: [Group]

    init(options: AdvancedSearchOptions) {
        self.options = options
        self.groups = [
            Group(
                header: "SEARCH INSIDE PAYLOADS",
                footer: "Bodies are stored on disk, so these are read only when you ask. "
                      + "Matches appear in the same list with the matching snippet underneath.",
                toggles: [
                    Toggle(title: "Response body",
                           detail: "Find the term in what the server sent back — the JSON, HTML or text of the response.",
                           symbol: "arrow.down.doc",
                           get: { $0.searchResponseBodies },
                           set: { $0.searchResponseBodies = $1 }),
                    Toggle(title: "Request body",
                           detail: "Find the term in what the app sent — POST and PUT payloads, form fields, GraphQL queries.",
                           symbol: "arrow.up.doc",
                           get: { $0.searchRequestBodies },
                           set: { $0.searchRequestBodies = $1 }),
                ]
            ),
            Group(
                header: "HOW TO MATCH",
                footer: nil,
                toggles: [
                    Toggle(title: "Case sensitive",
                           detail: "Match capitalisation exactly. Off, \u{201C}Token\u{201D} also finds \u{201C}token\u{201D} and \u{201C}TOKEN\u{201D}.",
                           symbol: "textformat",
                           get: { $0.caseSensitive },
                           set: { $0.caseSensitive = $1 }),
                ]
            ),
            Group(
                header: "REACH",
                footer: "Both cost time on a long list. Turn them on when you suspect the hit is "
                      + "in a large payload or in something the list normally hides.",
                toggles: [
                    Toggle(title: "Scan whole bodies",
                           detail: "By default only the first \(ResponseBodySearch.byteCapDescription) of each body is read. "
                                 + "Turn this on to search all of it, however large.",
                           symbol: "arrow.down.left.and.arrow.up.right",
                           get: { $0.scanWholeBodies },
                           set: { $0.scanWholeBodies = $1 }),
                    Toggle(title: "Include media",
                           detail: "Images, video and audio are skipped because their bodies are binary. "
                                 + "Turn this on to scan them anyway.",
                           symbol: "photo",
                           get: { $0.includeMedia },
                           set: { $0.includeMedia = $1 }),
                ]
            ),
        ]
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Advanced Search"
        view.backgroundColor = .black
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Reset", style: .plain, target: self, action: #selector(resetTapped))
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.65, alpha: 1)

        view.forceLTR()
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    @objc private func resetTapped() {
        options = AdvancedSearchOptions()
        tableView.reloadData()
        onChange?(options)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard groups.indices.contains(section) else { return 0 }
        return groups[section].toggles.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cell.selectionStyle = .none
        cell.forceLTR()

        guard groups.indices.contains(ip.section),
              groups[ip.section].toggles.indices.contains(ip.row) else { return cell }
        let toggle = groups[ip.section].toggles[ip.row]
        let isOn = toggle.get(options)

        let icon = UIImageView(image: UIImage(
            systemName: toggle.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))?
            .withTintColor(isOn ? DebugTheme.accentColor : UIColor(white: 0.45, alpha: 1),
                           renderingMode: .alwaysOriginal))
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = toggle.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white

        let detailLabel = UILabel()
        detailLabel.text = toggle.detail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = UIColor(white: 0.55, alpha: 1)
        detailLabel.numberOfLines = 0

        let switchView = UISwitch()
        switchView.isOn = isOn
        switchView.onTintColor = DebugTheme.accentColor
        switchView.setContentHuggingPriority(.required, for: .horizontal)
        // Identity, not index: the row is rebuilt on every change, and an
        // index-keyed action would fire against the wrong toggle after a reload.
        switchView.addAction(UIAction { [weak self] action in
            guard let self, let sender = action.sender as? UISwitch else { return }
            toggle.set(&self.options, sender.isOn)
            self.tableView.reloadData()
            self.onChange?(self.options)
        }, for: .valueChanged)

        let titleRow = UIStackView(arrangedSubviews: [icon, titleLabel, UIView(), switchView])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            // Pinned top AND bottom so the multi-line description sizes the row.
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard groups.indices.contains(section) else { return nil }
        return groups[section].header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard groups.indices.contains(section) else { return nil }
        return groups[section].footer
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = DebugTheme.accentColor
        (view as? UITableViewHeaderFooterView)?.textLabel?.font = .systemFont(ofSize: 12, weight: .heavy)
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = UIColor(white: 0.42, alpha: 1)
        (view as? UITableViewHeaderFooterView)?.textLabel?.font = .systemFont(ofSize: 11)
    }
}
