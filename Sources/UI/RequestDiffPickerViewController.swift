//
//  RequestDiffPickerViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import UIKit

/// Selection mode for the network list: pick exactly two requests, then diff them.
/// First pick is A (the "before"), second is B (the "after").
class RequestDiffPickerViewController: UIViewController {

    // MARK: - Input

    private let allTransactions: [NetworkTransaction]

    // MARK: - State

    private var filtered: [NetworkTransaction] = []

    /// Selection is keyed by object identity, never by row index — the list can be
    /// re-filtered by the search bar under the user's fingers.
    private var selectedIds: [ObjectIdentifier] = []
    private var transactionsById: [ObjectIdentifier: NetworkTransaction] = [:]

    // MARK: - Views

    private var tableView: UITableView!
    private var searchBar: UISearchBar!
    private let hintLabel = UILabel()
    private var diffItem: UIBarButtonItem!

    // MARK: - Init

    /// - Parameter preselected: optional request that starts as A, so the picker can
    ///   also be opened from a request that is already on screen.
    init(transactions: [NetworkTransaction], preselected: NetworkTransaction? = nil) {
        allTransactions = transactions
        super.init(nibName: nil, bundle: nil)

        for transaction in transactions {
            transactionsById[ObjectIdentifier(transaction)] = transaction
        }
        if let preselected = preselected, transactionsById[ObjectIdentifier(preselected)] != nil {
            selectedIds = [ObjectIdentifier(preselected)]
        }
        filtered = transactions
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Compare Requests"
        view.backgroundColor = .black

        diffItem = UIBarButtonItem(title: "Diff", style: .done, target: self, action: #selector(showDiff))
        diffItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = diffItem

        setupSearchBar()
        setupHintLabel()
        setupTableView()
        updateChrome()

        view.forceLTR()
    }

    // MARK: - Setup

    private func setupSearchBar() {
        searchBar = UISearchBar()
        searchBar.searchBarStyle = .minimal
        searchBar.barTintColor = .clear
        searchBar.isTranslucent = true
        searchBar.tintColor = DebugTheme.accentColor
        searchBar.backgroundImage = UIImage()
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        let textField = searchBar.searchTextField
        textField.textColor = .white
        textField.font = .systemFont(ofSize: 14, weight: .regular)
        textField.layer.cornerRadius = 10
        textField.layer.masksToBounds = true
        textField.backgroundColor = UIColor(white: 0.11, alpha: 1)
        textField.layer.borderWidth = 1
        textField.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        textField.attributedPlaceholder = NSAttributedString(
            string: "Search URL...",
            attributes: [.foregroundColor: UIColor(white: 0.4, alpha: 1)]
        )
        textField.leftView?.tintColor = UIColor(white: 0.4, alpha: 1)

        view.addSubview(searchBar)
    }

    private func setupHintLabel() {
        hintLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        hintLabel.textColor = UIColor(white: 0.45, alpha: 1)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(RequestDiffPickerCell.self, forCellReuseIdentifier: RequestDiffPickerCell.reuseId)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            hintLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 2),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 6),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - State

    private func updateChrome() {
        switch selectedIds.count {
        case 0:  hintLabel.text = "PICK TWO REQUESTS TO COMPARE"
        case 1:  hintLabel.text = "A SELECTED — PICK ONE MORE"
        default: hintLabel.text = "A → B READY"
        }
        diffItem.isEnabled = selectedIds.count == 2
    }

    private func applySearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filtered = allTransactions
        } else {
            filtered = allTransactions.filter { transaction in
                let url = (transaction.url?.absoluteString ?? "").lowercased()
                let method = (transaction.method ?? "").lowercased()
                return url.contains(query) || method.contains(query)
            }
        }
        tableView.reloadData()
    }

    /// Marker shown on the row: A for the first pick, B for the second.
    private func badge(for transaction: NetworkTransaction) -> String? {
        guard let index = selectedIds.firstIndex(of: ObjectIdentifier(transaction)) else { return nil }
        return index == 0 ? "A" : "B"
    }

    private func toggleSelection(_ transaction: NetworkTransaction) {
        let id = ObjectIdentifier(transaction)
        if let existing = selectedIds.firstIndex(of: id) {
            selectedIds.remove(at: existing)
        } else {
            // Picking a third request rolls the window forward: B becomes A.
            if selectedIds.count == 2 { selectedIds.removeFirst() }
            selectedIds.append(id)
        }
        updateChrome()
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func showDiff() {
        guard selectedIds.count == 2,
              let left = transactionsById[selectedIds[0]],
              let right = transactionsById[selectedIds[1]] else { return }
        searchBar.resignFirstResponder()
        navigationController?.pushViewController(RequestDiffViewController(left: left, right: right), animated: true)
    }
}

// MARK: - UITableViewDataSource

extension RequestDiffPickerViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filtered.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: RequestDiffPickerCell.reuseId, for: indexPath) as! RequestDiffPickerCell
        guard filtered.indices.contains(indexPath.row) else { return cell }
        let transaction = filtered[indexPath.row]
        cell.configure(with: transaction, badge: badge(for: transaction))
        return cell
    }
}

// MARK: - UITableViewDelegate

extension RequestDiffPickerViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard filtered.indices.contains(indexPath.row) else { return }
        toggleSelection(filtered[indexPath.row])
    }
}

// MARK: - UISearchBarDelegate

extension RequestDiffPickerViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applySearch(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Cell

private class RequestDiffPickerCell: UITableViewCell {

    static let reuseId = "RequestDiffPickerCell"

    private let cardView = UIView()
    private let badgeLabel = UILabel()
    private let methodLabel = UILabel()
    private let pathLabel = UILabel()
    private let hostLabel = UILabel()
    private let statusLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = UIColor.clear.cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textAlignment = .center
        badgeLabel.textColor = .black
        badgeLabel.layer.cornerRadius = 9
        badgeLabel.clipsToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(badgeLabel)

        methodLabel.font = .systemFont(ofSize: 11, weight: .bold)
        methodLabel.textColor = UIColor(white: 0.55, alpha: 1)
        methodLabel.translatesAutoresizingMaskIntoConstraints = false
        methodLabel.setContentHuggingPriority(.required, for: .horizontal)
        methodLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cardView.addSubview(methodLabel)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        statusLabel.textAlignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cardView.addSubview(statusLabel)

        pathLabel.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .white
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(pathLabel)

        hostLabel.font = .systemFont(ofSize: 10)
        hostLabel.textColor = UIColor(white: 0.45, alpha: 1)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(hostLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            badgeLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            badgeLabel.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            badgeLabel.widthAnchor.constraint(equalToConstant: 18),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18),

            methodLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 10),
            methodLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),

            statusLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: methodLabel.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: methodLabel.centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -10),

            hostLabel.leadingAnchor.constraint(equalTo: methodLabel.leadingAnchor),
            hostLabel.topAnchor.constraint(equalTo: methodLabel.bottomAnchor, constant: 3),
            hostLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -10),
            hostLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    func configure(with transaction: NetworkTransaction, badge: String?) {
        let method = (transaction.method ?? "").uppercased()
        methodLabel.text = method.isEmpty ? "?" : method

        let path = transaction.url?.path ?? ""
        pathLabel.text = path.isEmpty ? (transaction.url?.absoluteString ?? "--") : path

        let host = transaction.url?.host ?? ""
        let duration = RequestDiff.durationText(start: transaction.startTime, end: transaction.endTime)
        hostLabel.text = host.isEmpty ? duration : "\(host)  ·  \(duration)"

        let code = transaction.statusCode ?? "0"
        statusLabel.text = code == "0" ? "\u{274C}" : code
        statusLabel.textColor = NetworkCell.colorForStatusCode(code)

        if let badge = badge {
            badgeLabel.text = badge
            badgeLabel.backgroundColor = DebugTheme.accentColor
            badgeLabel.isHidden = false
            cardView.layer.borderColor = DebugTheme.accentColor.cgColor
        } else {
            badgeLabel.text = nil
            badgeLabel.backgroundColor = UIColor(white: 0.2, alpha: 1)
            badgeLabel.isHidden = false
            cardView.layer.borderColor = UIColor.clear.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        badgeLabel.text = nil
        cardView.layer.borderColor = UIColor.clear.cgColor
    }
}
