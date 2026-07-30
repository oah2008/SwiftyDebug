//
//  WebViewStoragePickerViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import WebKit

// MARK: - WebView picker

/// Lists all live WKWebViews so the user can pick which one to inspect storage
/// for. (Storage is per-web-view.)
///
/// Read-only: this screen creates a `WebViewStorageService` for nothing and runs
/// no JavaScript. It reads `title` / `url` / `isLoading` off the web view, which
/// cannot mutate page state.
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
    private let forcedPill = PaddedPill()
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

        // Top row: index pill + state pill + force-overwrite marker
        let pills = UIStackView(arrangedSubviews: [indexPill, statePill, forcedPill, UIView()])
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

    /// Clears every piece of per-row state. `setHighlighted` mutates the card's
    /// colour outside `configure`, so it has to be reset here or a recycled cell
    /// can arrive already looking pressed.
    override func prepareForReuse() {
        super.prepareForReuse()
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        titleLabel.text = nil
        urlLabel.text = nil
        hostLabel.text = nil
        hostLabel.isHidden = false
        forcedPill.isHidden = true
    }

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

        // Force-overwrite is a state that silently rewrites storage behind the
        // developer's back, so it is advertised from the very first screen.
        // In-memory dictionary lookups only — no disk, no JS.
        let pins = WebViewStoragePinStore.shared
        let forcing = WebViewStorageService.Scope.allCases.filter { pins.isForcing(webView, scope: $0) }
        if forcing.isEmpty {
            forcedPill.isHidden = true
        } else {
            forcedPill.isHidden = false
            forcedPill.set(text: "FORCING \(forcing.count)", color: .black, background: .systemYellow)
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

/// Shared by the web-view picker and the storage list. Internal (not private)
/// because both files draw the same pill and two copies would drift.
final class PaddedPill: UILabel {
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
