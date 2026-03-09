//
//  KeyValueEditCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

/// Reusable table cell with two editable text fields (key | value) for the intercept rule editor.
/// Supports a "dropped" state that visually marks the pair for removal from the request.
class KeyValueEditCell: UITableViewCell {

    let keyField = UITextField()
    let valueField = UITextField()
    private let dropButton = UIButton(type: .system)
    private let separator = UIView()

    var onKeyChanged: ((String) -> Void)?
    var onValueChanged: ((String) -> Void)?
    var onDropToggled: (() -> Void)?

    var isDropped: Bool = false {
        didSet { updateDropAppearance() }
    }

    var isKeyEditable: Bool = true {
        didSet { keyField.isUserInteractionEnabled = isKeyEditable }
    }

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
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        contentView.backgroundColor = UIColor(white: 0.11, alpha: 1)

        // Drop toggle button
        dropButton.translatesAutoresizingMaskIntoConstraints = false
        dropButton.addTarget(self, action: #selector(dropTapped), for: .touchUpInside)
        contentView.addSubview(dropButton)

        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.textColor = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1) // teal for keys
        keyField.attributedPlaceholder = NSAttributedString(
            string: "key",
            attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
        )
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.returnKeyType = .next
        keyField.addTarget(self, action: #selector(keyDidChange), for: .editingChanged)
        contentView.addSubview(keyField)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 0.25, alpha: 1)
        contentView.addSubview(separator)

        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = UIColor(white: 0.85, alpha: 1)
        valueField.attributedPlaceholder = NSAttributedString(
            string: "value",
            attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
        )
        valueField.autocapitalizationType = .none
        valueField.autocorrectionType = .no
        valueField.returnKeyType = .done
        valueField.addTarget(self, action: #selector(valueDidChange), for: .editingChanged)
        contentView.addSubview(valueField)

        NSLayoutConstraint.activate([
            dropButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            dropButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dropButton.widthAnchor.constraint(equalToConstant: 28),
            dropButton.heightAnchor.constraint(equalToConstant: 28),

            keyField.leadingAnchor.constraint(equalTo: dropButton.trailingAnchor, constant: 4),
            keyField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            keyField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            keyField.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.30),

            separator.leadingAnchor.constraint(equalTo: keyField.trailingAnchor, constant: 6),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            valueField.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 6),
            valueField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            valueField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            valueField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        updateDropAppearance()
        forceLTR()
    }

    func configure(key: String, value: String, dropped: Bool = false, keyEditable: Bool = true) {
        keyField.text = key
        valueField.text = value
        isDropped = dropped
        isKeyEditable = keyEditable
    }

    private func updateDropAppearance() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if isDropped {
            let icon = UIImage(systemName: "minus.circle.fill", withConfiguration: iconConfig)?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            dropButton.setImage(icon, for: .normal)
            keyField.alpha = 0.35
            valueField.alpha = 0.35
            separator.alpha = 0.35
            valueField.isUserInteractionEnabled = false
        } else {
            let icon = UIImage(systemName: "checkmark.circle.fill", withConfiguration: iconConfig)?
                .withTintColor(UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1), renderingMode: .alwaysOriginal)
            dropButton.setImage(icon, for: .normal)
            keyField.alpha = 1
            valueField.alpha = 1
            separator.alpha = 1
            valueField.isUserInteractionEnabled = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        keyField.text = nil
        valueField.text = nil
        onKeyChanged = nil
        onValueChanged = nil
        onDropToggled = nil
        isDropped = false
        isKeyEditable = true
    }

    @objc private func keyDidChange() {
        onKeyChanged?(keyField.text ?? "")
    }

    @objc private func valueDidChange() {
        onValueChanged?(valueField.text ?? "")
    }

    @objc private func dropTapped() {
        onDropToggled?()
    }
}
