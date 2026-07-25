//
//  JSONNodeCell.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// One node row in the JSON tree editor: indent guide, disclosure chevron for
/// containers, key, type badge, and a value preview.
///
/// Content is pinned to BOTH the top and bottom of `contentView` so the text
/// drives the row height — stock cell labels don't self-size with
/// `automaticDimension` and silently collapse.
final class JSONNodeCell: UITableViewCell {

    var onDisclosureTapped: (() -> Void)?

    private let card = UIView()
    private let disclosure = UIButton(type: .system)
    private let keyLabel = UILabel()
    private let badge = JSONTypeBadge()
    private let previewLabel = UILabel()
    private let indentGuide = UIView()

    private var indentConstraint: NSLayoutConstraint!
    private var disclosureWidth: NSLayoutConstraint!

    private static let indentPerLevel: CGFloat = 14
    private static let maxIndent: CGFloat = 8 * indentPerLevel

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = UIColor(white: 0.125, alpha: 1)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // Vertical hairline showing nesting depth.
        indentGuide.backgroundColor = UIColor(white: 0.26, alpha: 1)
        indentGuide.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(indentGuide)

        disclosure.tintColor = DebugTheme.accentColor
        disclosure.addTarget(self, action: #selector(disclosureTapped), for: .touchUpInside)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(disclosure)

        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        previewLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewLabel.textColor = UIColor(white: 0.82, alpha: 1)
        previewLabel.numberOfLines = 2

        let topRow = UIStackView(arrangedSubviews: [keyLabel, badge, UIView()])
        topRow.axis = .horizontal
        topRow.spacing = 6
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, previewLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        indentConstraint = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        disclosureWidth = disclosure.widthAnchor.constraint(equalToConstant: 26)

        NSLayoutConstraint.activate([
            indentConstraint,
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            indentGuide.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            indentGuide.topAnchor.constraint(equalTo: card.topAnchor),
            indentGuide.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            indentGuide.widthAnchor.constraint(equalToConstant: 2),

            disclosure.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            disclosure.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            disclosureWidth,
            disclosure.heightAnchor.constraint(equalToConstant: 30),

            // Text drives the height.
            stack.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.125, alpha: 1)
        }
    }

    @objc private func disclosureTapped() { onDisclosureTapped?() }

    func configure(label: String, preview: String, kind: JSONValueKind, depth: Int,
                   isContainer: Bool, isExpanded: Bool, childCount: Int) {
        indentConstraint.constant = 10 + min(CGFloat(depth) * Self.indentPerLevel, Self.maxIndent)
        indentGuide.isHidden = (depth == 0)

        keyLabel.text = label
        badge.set(kind: kind)

        if isContainer {
            let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            let symbol = isExpanded ? "chevron.down" : "chevron.right"
            disclosure.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            disclosure.isHidden = false
            disclosureWidth.constant = 26
            previewLabel.text = "\(childCount) \(kind == .array ? "item" : "key")\(childCount == 1 ? "" : "s")"
            previewLabel.textColor = UIColor(white: 0.5, alpha: 1)
        } else {
            disclosure.setImage(nil, for: .normal)
            disclosure.isHidden = true
            disclosureWidth.constant = 4
            previewLabel.text = preview
            previewLabel.textColor = (kind == .null)
                ? UIColor(white: 0.45, alpha: 1)
                : UIColor(white: 0.82, alpha: 1)
        }
    }
}

// MARK: - Type badge

/// Small colored pill showing a node's JSON type.
final class JSONTypeBadge: UILabel {

    private let inset = UIEdgeInsets(top: 1.5, left: 6, bottom: 1.5, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 8.5, weight: .heavy)
        layer.cornerRadius = 4
        clipsToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(kind: JSONValueKind) {
        text = kind.badge
        let color: UIColor
        switch kind {
        case .object: color = UIColor(red: 0.55, green: 0.72, blue: 1.0, alpha: 1)
        case .array:  color = UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1)
        case .string: color = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        case .number: color = UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
        case .bool:   color = UIColor(red: 0.95, green: 0.60, blue: 0.45, alpha: 1)
        case .null:   color = UIColor(white: 0.55, alpha: 1)
        }
        textColor = color
        backgroundColor = color.withAlphaComponent(0.18)
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}
