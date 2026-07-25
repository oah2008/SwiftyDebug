//
//  RequestDiffViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 25/07/2026.
//

import UIKit

/// Side-by-side comparison of two captured requests, rendered top-to-bottom
/// (old line above new line) because side-by-side columns are unreadable on a phone.
class RequestDiffViewController: UIViewController {

    // MARK: - Colors

    enum DiffColor {
        static let added = "#42d459".hexColor
        static let removed = "#ff6b6b".hexColor
        static let changed = "#ff9800".hexColor
        static let same = UIColor(white: 0.62, alpha: 1)
        static let note = UIColor(white: 0.45, alpha: 1)

        static func forChange(_ change: RequestDiffChange, isNote: Bool) -> UIColor {
            if isNote { return note }
            switch change {
            case .same:    return same
            case .added:   return added
            case .removed: return removed
            case .changed: return changed
            }
        }
    }

    // MARK: - Input

    private let leftSnapshot: RequestSnapshot
    private let rightSnapshot: RequestSnapshot
    private let result: RequestDiffResult

    /// A diff of two similar requests is mostly noise, so the filter starts on.
    private var changesOnly = true

    private var visibleSections: [RequestDiffSection] = []

    // MARK: - Views

    private var tableView: UITableView!
    private let headerBar = UIView()
    private let summaryLabel = UILabel()
    private let filterButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    // MARK: - Init

    /// Reads each disk-backed body exactly once, up front.
    convenience init(left: NetworkTransaction, right: NetworkTransaction) {
        self.init(left: RequestSnapshot(transaction: left), right: RequestSnapshot(transaction: right))
    }

    init(left: RequestSnapshot, right: RequestSnapshot) {
        leftSnapshot = left
        rightSnapshot = right
        result = RequestDiff.compare(left, right)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Diff"
        view.backgroundColor = .black

        let copyIcon = UIImage(systemName: "doc.on.doc",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        let copyItem = UIBarButtonItem(image: copyIcon, style: .plain, target: self, action: #selector(copyDiff))
        copyItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = copyItem

        setupHeaderBar()
        setupTableView()
        reloadDiff()

        view.forceLTR()
    }

    // MARK: - Setup

    private func setupHeaderBar() {
        headerBar.backgroundColor = UIColor(white: 0.11, alpha: 1)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(stack)

        stack.addArrangedSubview(makeSideRow(badge: "A", snapshot: leftSnapshot, color: DiffColor.removed))
        stack.addArrangedSubview(makeSideRow(badge: "B", snapshot: rightSnapshot, color: DiffColor.added))

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 8

        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLabel.textColor = result.hasChanges ? DiffColor.changed : DiffColor.added
        bottomRow.addArrangedSubview(summaryLabel)
        bottomRow.addArrangedSubview(UIView())

        filterButton.layer.cornerRadius = 11
        filterButton.layer.borderWidth = 1
        filterButton.addTarget(self, action: #selector(toggleChangesOnly), for: .touchUpInside)
        bottomRow.addArrangedSubview(filterButton)

        stack.addArrangedSubview(bottomRow)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -10),
        ])
    }

    private func makeSideRow(badge: String, snapshot: RequestSnapshot, color: UIColor) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let badgeLabel = UILabel()
        badgeLabel.text = badge
        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textAlignment = .center
        badgeLabel.textColor = .black
        badgeLabel.backgroundColor = color
        badgeLabel.layer.cornerRadius = 4
        badgeLabel.clipsToBounds = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        badgeLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(badgeLabel)

        let titleLabel = UILabel()
        titleLabel.font = UIFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = UIColor(white: 0.8, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.text = snapshot.displayTitle
        row.addArrangedSubview(titleLabel)

        let statusLabel = UILabel()
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        statusLabel.text = snapshot.statusCode.isEmpty ? "--" : snapshot.statusCode
        statusLabel.textColor = NetworkCell.colorForStatusCode(snapshot.statusCode)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(statusLabel)

        return row
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .grouped)
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
        tableView.sectionHeaderHeight = 34
        tableView.sectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(RequestDiffCell.self, forCellReuseIdentifier: RequestDiffCell.reuseId)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = UIColor(white: 0.45, alpha: 1)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "No differences.\nThese two requests are identical."
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - State

    private func reloadDiff() {
        visibleSections = result.sections(changesOnly: changesOnly)

        let count = result.changeCount
        summaryLabel.text = count == 0 ? "IDENTICAL" : "\(count) CHANGE\(count == 1 ? "" : "S")"

        let tint = changesOnly ? DebugTheme.accentColor : UIColor(white: 0.45, alpha: 1)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.attributedTitle = AttributedString(NSAttributedString(
            string: changesOnly ? "CHANGES ONLY  ✓" : "CHANGES ONLY",
            attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: tint]
        ))
        filterButton.configuration = config
        filterButton.layer.borderColor = tint.withAlphaComponent(0.6).cgColor
        filterButton.backgroundColor = changesOnly ? tint.withAlphaComponent(0.15) : .clear

        emptyLabel.isHidden = !visibleSections.isEmpty
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func toggleChangesOnly() {
        changesOnly.toggle()
        reloadDiff()
    }

    @objc private func copyDiff() {
        var text = "A: \(leftSnapshot.displayTitle)  [\(leftSnapshot.statusCode)]\n"
        text += "B: \(rightSnapshot.displayTitle)  [\(rightSnapshot.statusCode)]\n\n"
        text += RequestDiff.plainText(result, changesOnly: changesOnly)
        UIPasteboard.general.string = text

        let checkIcon = UIImage(systemName: "checkmark",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        navigationItem.rightBarButtonItem?.image = checkIcon
        navigationItem.rightBarButtonItem?.tintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let copyIcon = UIImage(systemName: "doc.on.doc",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
            self?.navigationItem.rightBarButtonItem?.image = copyIcon
            self?.navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        }
    }
}

// MARK: - UITableViewDataSource

extension RequestDiffViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return visibleSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard visibleSections.indices.contains(section) else { return 0 }
        return visibleSections[section].rows(changesOnly: changesOnly).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: RequestDiffCell.reuseId, for: indexPath) as! RequestDiffCell
        guard let row = row(at: indexPath) else { return cell }
        cell.configure(with: row)
        return cell
    }

    private func row(at indexPath: IndexPath) -> RequestDiffRow? {
        guard visibleSections.indices.contains(indexPath.section) else { return nil }
        let rows = visibleSections[indexPath.section].rows(changesOnly: changesOnly)
        guard rows.indices.contains(indexPath.row) else { return nil }
        return rows[indexPath.row]
    }
}

// MARK: - UITableViewDelegate

extension RequestDiffViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard visibleSections.indices.contains(section) else { return nil }
        let model = visibleSections[section]

        let header = UIView()
        header.backgroundColor = .clear

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.text = model.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        let countLabel = UILabel()
        countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = model.changeCount > 0 ? DiffColor.changed : UIColor(white: 0.35, alpha: 1)
        countLabel.text = model.changeCount > 0 ? "\(model.changeCount)" : "—"
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(countLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        header.forceLTR()
        return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = row(at: indexPath) else { return }

        // Copying the value is the reason you found the row in the first place.
        switch row.change {
        case .added, .same:
            UIPasteboard.general.string = row.newValue ?? row.oldValue ?? ""
        case .removed:
            UIPasteboard.general.string = row.oldValue ?? ""
        case .changed:
            UIPasteboard.general.string = "\(row.label)\n- \(row.oldValue ?? "")\n+ \(row.newValue ?? "")"
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Cell

private class RequestDiffCell: UITableViewCell {

    static let reuseId = "RequestDiffCell"

    private let cardView = UIView()
    private let accentBar = UIView()
    private let stack = UIStackView()
    private let labelLabel = UILabel()
    private let oldLabel = UILabel()
    private let newLabel = UILabel()

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
        cardView.layer.cornerRadius = 8
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(accentBar)

        labelLabel.font = UIFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        labelLabel.textColor = UIColor(white: 0.55, alpha: 1)
        labelLabel.numberOfLines = 0

        for label in [oldLabel, newLabel] {
            label.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
        }

        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labelLabel)
        stack.addArrangedSubview(oldLabel)
        stack.addArrangedSubview(newLabel)
        cardView.addSubview(stack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            accentBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: cardView.topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            // Pinned to both top and bottom so the cell self-sizes.
            stack.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -8),
        ])

        forceLTR()
    }

    func configure(with row: RequestDiffRow) {
        let color = RequestDiffViewController.DiffColor.forChange(row.change, isNote: row.isNote)
        accentBar.backgroundColor = row.change == .same ? UIColor(white: 0.2, alpha: 1) : color

        labelLabel.text = row.label
        labelLabel.isHidden = row.label.isEmpty

        // Old on one line, new on the next — never truncated side by side.
        switch row.change {
        case .same:
            oldLabel.isHidden = false
            oldLabel.text = row.newValue ?? row.oldValue ?? ""
            oldLabel.textColor = row.isNote ? RequestDiffViewController.DiffColor.note : UIColor(white: 0.7, alpha: 1)
            newLabel.isHidden = true
        case .added:
            oldLabel.isHidden = true
            newLabel.isHidden = false
            newLabel.text = "+ " + (row.newValue ?? "")
            newLabel.textColor = color
        case .removed:
            oldLabel.isHidden = false
            oldLabel.text = "− " + (row.oldValue ?? "")
            oldLabel.textColor = color
            newLabel.isHidden = true
        case .changed:
            oldLabel.isHidden = false
            newLabel.isHidden = false
            oldLabel.text = "− " + (row.oldValue ?? "")
            newLabel.text = "+ " + (row.newValue ?? "")
            if row.isNote {
                oldLabel.textColor = RequestDiffViewController.DiffColor.note
                newLabel.textColor = RequestDiffViewController.DiffColor.note
            } else {
                oldLabel.textColor = RequestDiffViewController.DiffColor.removed
                newLabel.textColor = RequestDiffViewController.DiffColor.added
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        oldLabel.text = nil
        newLabel.text = nil
        labelLabel.text = nil
    }
}
