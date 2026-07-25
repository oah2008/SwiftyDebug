//
//  OptionPickerSheetViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A custom option picker used instead of `UIAlertController` action sheets.
///
/// System alerts truncate long titles (endpoints, hosts, redirect targets), which
/// made the intercept/redirect choices unreadable. This sheet gives every option
/// a full-width, multi-line title **and** a subtitle, so nothing is cut off.
final class OptionPickerSheetViewController: UITableViewController {

    struct Option {
        let title: String
        let subtitle: String?
        /// Optional SF Symbol shown at the leading edge.
        let symbol: String?
        /// Tint for the symbol + title (defaults to white/accent).
        let tint: UIColor?
        let handler: () -> Void

        init(title: String, subtitle: String? = nil, symbol: String? = nil,
             tint: UIColor? = nil, handler: @escaping () -> Void) {
            self.title = title
            self.subtitle = subtitle
            self.symbol = symbol
            self.tint = tint
            self.handler = handler
        }
    }

    private let sheetTitle: String
    private let sheetMessage: String?
    private let options: [Option]
    /// Index of the currently-selected option, if any (gets a checkmark).
    private let selectedIndex: Int?

    init(title: String, message: String? = nil, options: [Option], selectedIndex: Int? = nil) {
        self.sheetTitle = title
        self.sheetMessage = message
        self.options = options
        self.selectedIndex = selectedIndex
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Presents the picker as a bottom sheet from `presenter`.
    static func present(from presenter: UIViewController, title: String, message: String? = nil,
                        options: [Option], selectedIndex: Int? = nil) {
        let picker = OptionPickerSheetViewController(
            title: title, message: message, options: options, selectedIndex: selectedIndex)
        let nav = SwiftyDebugNavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        presenter.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel()
        label.text = sheetTitle
        label.font = .boldSystemFont(ofSize: 17)
        label.textColor = DebugTheme.accentColor
        label.sizeToFit()
        navigationItem.titleView = label
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.contentInset.bottom = 24
        tableView.register(OptionCardCell.self, forCellReuseIdentifier: "OptionCard")

        if let msg = sheetMessage, !msg.isEmpty {
            let header = UIView()
            let l = UILabel()
            l.text = msg
            l.numberOfLines = 0
            l.font = .systemFont(ofSize: 12)
            l.textColor = UIColor(white: 0.55, alpha: 1)
            l.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
                l.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
                l.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
                l.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            ])
            header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 60)
            header.setNeedsLayout(); header.layoutIfNeeded()
            let h = header.systemLayoutSizeFitting(
                CGSize(width: view.bounds.width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            header.frame.size.height = h
            tableView.tableHeaderView = header
        }
        view.forceLTR()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OptionCard", for: indexPath) as! OptionCardCell
        cell.configure(option: options[indexPath.row], isSelected: indexPath.row == selectedIndex)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let handler = options[indexPath.row].handler
        dismiss(animated: true) { handler() }
    }
}

// MARK: - Option card cell

/// Custom cell for the picker.
///
/// The stock `UITableViewCell` labels do **not** self-size reliably with
/// `numberOfLines = 0` + `automaticDimension` — rows collapsed or clipped, which
/// is what broke the picker. Everything here is laid out with real constraints
/// from contentView top to bottom, so multi-line titles/subtitles always size
/// correctly and nothing is truncated.
private final class OptionCardCell: UITableViewCell {

    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkView = UIImageView()
    private let textStack = UIStackView()
    private var iconWidth: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = UIColor(white: 0.5, alpha: 1)
        subtitleLabel.numberOfLines = 0

        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textStack)

        checkView.contentMode = .scaleAspectFit
        checkView.setContentHuggingPriority(.required, for: .horizontal)
        checkView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(checkView)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 22)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            iconWidth,
            iconView.heightAnchor.constraint(equalToConstant: 22),

            // Text drives the cell height — top and bottom both pinned.
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            textStack.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -10),

            checkView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            checkView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 18),
            checkView.heightAnchor.constraint(equalToConstant: 18),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(option: OptionPickerSheetViewController.Option, isSelected: Bool) {
        let tint = option.tint ?? .white
        titleLabel.text = option.title
        titleLabel.textColor = tint
        subtitleLabel.text = option.subtitle
        subtitleLabel.isHidden = (option.subtitle?.isEmpty ?? true)

        if let symbol = option.symbol {
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            iconView.isHidden = false
            iconWidth.constant = 22
        } else {
            iconView.image = nil
            iconView.isHidden = true
            iconWidth.constant = 0
        }

        if isSelected {
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            checkView.image = UIImage(systemName: "checkmark", withConfiguration: cfg)?
                .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        } else {
            checkView.image = nil
        }
        card.layer.borderColor = (isSelected
            ? DebugTheme.accentColor.withAlphaComponent(0.7)
            : UIColor(white: 0.24, alpha: 1)).cgColor
    }

    /// Press feedback (selectionStyle is .none so the card can highlight itself).
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.12) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1)
                : UIColor(white: 0.13, alpha: 1)
        }
    }
}
