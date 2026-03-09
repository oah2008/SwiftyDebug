//
//  NetworkSimilarRequestsCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

/// Table cell that renders a horizontal scroll row of mini request cards.
/// Each card shows the HTTP method, status code, and URL path of another request.
/// Tapping a card fires `onTap` with the corresponding `NetworkTransaction`.
final class NetworkSimilarRequestsCell: UITableViewCell {

    // MARK: - Subviews

    private let cardView   = UIView()
    private let titleLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stackView  = UIStackView()

    // MARK: - Callbacks

    var onTap: ((NetworkTransaction) -> Void)?

    // MARK: - Private state

    private var models: [NetworkTransaction] = []

    // MARK: - Shared colors (match NetworkDetailCell palette)

    private static let cardBg   = UIColor(white: 0.11, alpha: 1)       // outer card
    private static let miniCardBg = UIColor(white: 0.17, alpha: 1)     // individual request card
    private static let teal     = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
    private static let dimText  = UIColor(white: 0.65, alpha: 1)

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Layout

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Outer card
        cardView.backgroundColor = Self.cardBg
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // Section title
        titleLabel.text = "SIMILAR REQUESTS"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = Self.teal
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        // Horizontal scroll view
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator   = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(scrollView)

        // Horizontal stack inside scroll view
        stackView.axis         = .horizontal
        stackView.spacing      = 8
        stackView.alignment    = .fill
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            // Outer card inset (matches NetworkDetailCell)
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,   constant:  8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor,           constant:  3),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor,     constant: -3),

            // Title
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor,       constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor,       constant:  8),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor,     constant:  8),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor,   constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor,       constant: -10),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            // Stack inside scroll view
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        forceLTR()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        models = []
        onTap  = nil
    }

    // MARK: - Configure

    func configure(with httpModels: [NetworkTransaction]) {
        models = httpModels
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, model) in models.enumerated() {
            stackView.addArrangedSubview(makeMiniCard(for: model, index: index))
        }
    }

    // MARK: - Mini card builder

    private func makeMiniCard(for model: NetworkTransaction, index: Int) -> UIView {
        let card = UIView()
        card.backgroundColor = Self.miniCardBg
        card.layer.cornerRadius = 8
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 180).isActive = true

        // Method
        let methodLabel = UILabel()
        methodLabel.text = model.method ?? "?"
        methodLabel.font = .systemFont(ofSize: 12, weight: .bold)
        methodLabel.textColor = Self.teal
        methodLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status code
        let statusLabel = UILabel()
        let code = model.statusCode ?? "?"
        statusLabel.text = code == "0" ? "ERR" : code
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let codeInt = Int(code) ?? 0
        statusLabel.textColor = codeInt == 0     ? .systemRed
                              : codeInt < 400    ? .systemGreen
                                                 : .systemOrange
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // URL path
        let urlLabel = UILabel()
        urlLabel.text = model.url?.path ?? model.url?.absoluteString ?? "—"
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = Self.dimText
        urlLabel.numberOfLines = 2
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(methodLabel)
        card.addSubview(statusLabel)
        card.addSubview(urlLabel)

        NSLayoutConstraint.activate([
            methodLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            methodLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),

            statusLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: methodLabel.trailingAnchor, constant: 4),

            urlLabel.topAnchor.constraint(equalTo: methodLabel.bottomAnchor, constant: 6),
            urlLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            urlLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            urlLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
        ])

        // Tap
        card.tag = index
        card.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(cardTapped(_:)))
        card.addGestureRecognizer(tap)
        card.forceLTR()

        return card
    }

    // MARK: - Tap handling

    @objc private func cardTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view, view.tag < models.count else { return }
        onTap?(models[view.tag])
    }
}
