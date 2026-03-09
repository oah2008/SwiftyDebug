//
//  NetworkGroupCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

// MARK: - PaddedLabel (pill-shaped tag) — shared with NetworkCell

private class PaddedLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: ceil(size.width) + textInsets.left + textInsets.right,
            height: ceil(size.height) + textInsets.top + textInsets.bottom
        )
    }
}


// MARK: - NetworkGroupCell

class NetworkGroupCell: UITableViewCell {

    // MARK: - Card container

    private let cardView = UIView()
    private let statusLine = UIView()

    // MARK: - Row 1: tag pill + count

    private let tagPill = PaddedLabel()
    private let countLabel = UILabel()

    // MARK: - Row 2: full URL + chevron

    private let urlLabel = UILabel()
    private let chevronIcon = UIImageView()

    // MARK: - Layout containers

    private let topRow = UIStackView()
    private let bottomRow = UIStackView()
    private let mainStack = UIStackView()

    // MARK: - Constants

    private static let cardBackgroundColor = UIColor(white: 0.11, alpha: 1)
    private static let cellSpacing: CGFloat = 4

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Card view
        cardView.backgroundColor = Self.cardBackgroundColor
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // Status line (left edge)
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.backgroundColor = DebugTheme.accentColor
        cardView.addSubview(statusLine)

        // --- Row 1: tag pill + count ---

        tagPill.font = .systemFont(ofSize: 10, weight: .bold)
        tagPill.textColor = .white
        tagPill.textAlignment = .center
        tagPill.layer.cornerRadius = 5
        tagPill.clipsToBounds = true
        tagPill.setContentHuggingPriority(.required, for: .horizontal)
        tagPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = UIColor(white: 0.55, alpha: 1)
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8
        topRow.addArrangedSubview(tagPill)
        topRow.addArrangedSubview(topSpacer)
        topRow.addArrangedSubview(countLabel)

        // --- Row 2: full URL + chevron ---

        urlLabel.font = .systemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = UIColor(white: 0.75, alpha: 1)
        urlLabel.numberOfLines = 2
        urlLabel.lineBreakMode = .byTruncatingMiddle

        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevronIcon.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        chevronIcon.contentMode = .scaleAspectFit
        chevronIcon.translatesAutoresizingMaskIntoConstraints = false
        chevronIcon.setContentHuggingPriority(.required, for: .horizontal)
        chevronIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 8
        bottomRow.addArrangedSubview(urlLabel)
        bottomRow.addArrangedSubview(chevronIcon)

        // --- Main stack ---

        mainStack.axis = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(bottomRow)
        cardView.addSubview(mainStack)

        // --- Constraints ---

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cellSpacing / 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Self.cellSpacing / 2)),

            statusLine.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: cardView.topAnchor),
            statusLine.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            statusLine.widthAnchor.constraint(equalToConstant: 3),

            mainStack.leadingAnchor.constraint(equalTo: statusLine.trailingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            mainStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    // MARK: - Configure

    func configure(with group: NetworkGroup) {
        // Tag pill
        if let tag = group.tag {
            tagPill.isHidden = false
            tagPill.text = tag
            let color = NetworkCell.colorForTag(tag)
            tagPill.backgroundColor = color.withAlphaComponent(0.25)
            tagPill.textColor = color
        } else {
            tagPill.isHidden = true
        }

        // Count
        countLabel.text = "\(group.count) request\(group.count == 1 ? "" : "s")"

        // URL
        urlLabel.text = group.fullURL

        // Status line color
        statusLine.backgroundColor = DebugTheme.accentColor
    }
}
