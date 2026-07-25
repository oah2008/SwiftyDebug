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

    /// Provides autocomplete suggestions for the key field given the current
    /// text. Set by the editor. Return canonical names to show as chips.
    /// (See INTERCEPT-UX.)
    var keySuggestionsProvider: ((String) -> [String])?
    /// Called when a suggestion chip is tapped, so the editor can prefill a value.
    var onKeySuggestionPicked: ((String) -> Void)?

    /// Provides smart value suggestions given (currentKey, currentValueText).
    /// e.g. for key "Authorization" -> ["Bearer ", "Basic ", <real tokens>].
    /// (See INTERCEPT-UX Phase 2.)
    var valueSuggestionsProvider: ((_ key: String, _ currentValue: String) -> [String])?
    /// The current key text, so value suggestions can be header-aware.
    var currentKeyText: (() -> String)?

    // Autocomplete accessory bar (shared; shows suggestions for the focused field)
    private var suggestionBar: UIScrollView?
    private var suggestionStack: UIStackView?
    /// Which field the accessory bar is currently serving.
    private enum ActiveField { case key, value }
    private var activeField: ActiveField = .key

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
        keyField.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        keyField.textColor = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1) // teal for keys
        keyField.attributedPlaceholder = NSAttributedString(
            string: "key",
            attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
        )
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.returnKeyType = .next
        keyField.addTarget(self, action: #selector(keyDidChange), for: .editingChanged)
        keyField.addTarget(self, action: #selector(keyEditingBegan), for: .editingDidBegin)
        contentView.addSubview(keyField)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 0.25, alpha: 1)
        contentView.addSubview(separator)

        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        valueField.textColor = UIColor(white: 0.85, alpha: 1)
        valueField.attributedPlaceholder = NSAttributedString(
            string: "value",
            attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
        )
        valueField.autocapitalizationType = .none
        valueField.autocorrectionType = .no
        valueField.returnKeyType = .done
        valueField.addTarget(self, action: #selector(valueDidChange), for: .editingChanged)
        valueField.addTarget(self, action: #selector(valueEditingBegan), for: .editingDidBegin)
        contentView.addSubview(valueField)

        NSLayoutConstraint.activate([
            dropButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            dropButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dropButton.widthAnchor.constraint(equalToConstant: 28),
            dropButton.heightAnchor.constraint(equalToConstant: 28),

            keyField.leadingAnchor.constraint(equalTo: dropButton.trailingAnchor, constant: 4),
            keyField.leadingAnchor.constraint(equalTo: dropButton.trailingAnchor, constant: 4),
            keyField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            keyField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            keyField.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.30),

            separator.leadingAnchor.constraint(equalTo: keyField.trailingAnchor, constant: 6),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            valueField.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 6),
            valueField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            valueField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            valueField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
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
        // The drop button is the single, unambiguous add/override-vs-remove
        // control: a teal check = "set this header/param to the value", a red
        // minus = "remove this header/param from the request". Tapping toggles.
        // (See INTERCEPT-UX.)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        if isDropped {
            let icon = UIImage(systemName: "minus.circle.fill", withConfiguration: iconConfig)?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            dropButton.setImage(icon, for: .normal)
            dropButton.accessibilityLabel = "Removing this header. Tap to set a value instead."
            keyField.alpha = 0.5
            separator.alpha = 0.35
            valueField.isUserInteractionEnabled = false
            valueField.text = nil
            valueField.attributedPlaceholder = NSAttributedString(
                string: "— removed —",
                attributes: [.foregroundColor: UIColor.systemRed.withAlphaComponent(0.7)]
            )
        } else {
            let icon = UIImage(systemName: "checkmark.circle.fill", withConfiguration: iconConfig)?
                .withTintColor(UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1), renderingMode: .alwaysOriginal)
            dropButton.setImage(icon, for: .normal)
            dropButton.accessibilityLabel = "Setting this header to a value. Tap to remove it instead."
            keyField.alpha = 1
            valueField.alpha = 1
            separator.alpha = 1
            valueField.isUserInteractionEnabled = true
            valueField.attributedPlaceholder = NSAttributedString(
                string: "value",
                attributes: [.foregroundColor: UIColor(white: 0.3, alpha: 1)]
            )
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        keyField.text = nil
        valueField.text = nil
        onKeyChanged = nil
        onValueChanged = nil
        onDropToggled = nil
        keySuggestionsProvider = nil
        onKeySuggestionPicked = nil
        valueSuggestionsProvider = nil
        currentKeyText = nil
        isDropped = false
        isKeyEditable = true
    }

    @objc private func keyDidChange() {
        onKeyChanged?(keyField.text ?? "")
        if activeField == .key { refreshSuggestions() }
    }

    @objc private func keyEditingBegan() {
        activeField = .key
        installSuggestionBar(for: keyField)
        refreshSuggestions()
    }

    @objc private func valueDidChange() {
        onValueChanged?(valueField.text ?? "")
        if activeField == .value { refreshSuggestions() }
    }

    @objc private func valueEditingBegan() {
        activeField = .value
        installSuggestionBar(for: valueField)
        refreshSuggestions()
    }

    @objc private func dropTapped() {
        onDropToggled?()
    }

    // MARK: - Autocomplete accessory bar (INTERCEPT-UX)

    /// Lazily builds one shared accessory bar and attaches it to the given field.
    private func installSuggestionBar(for field: UITextField) {
        // Only install if at least one provider exists.
        guard keySuggestionsProvider != nil || valueSuggestionsProvider != nil else { return }

        if suggestionBar == nil {
            let bar = UIScrollView()
            bar.backgroundColor = UIColor(white: 0.14, alpha: 1)
            bar.showsHorizontalScrollIndicator = false
            bar.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
            bar.autoresizingMask = [.flexibleWidth]

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
                stack.heightAnchor.constraint(equalToConstant: 32),
            ])
            bar.semanticContentAttribute = .forceLeftToRight
            stack.semanticContentAttribute = .forceLeftToRight
            suggestionBar = bar
            suggestionStack = stack
        }
        field.inputAccessoryView = suggestionBar
    }

    private func refreshSuggestions() {
        guard let stack = suggestionStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let suggestions: [String]
        switch activeField {
        case .key:
            suggestions = keySuggestionsProvider?(keyField.text ?? "") ?? []
        case .value:
            let key = currentKeyText?() ?? keyField.text ?? ""
            suggestions = valueSuggestionsProvider?(key, valueField.text ?? "") ?? []
        }

        for s in suggestions {
            stack.addArrangedSubview(makeChip(title: s))
        }
        suggestionBar?.isHidden = suggestions.isEmpty
    }

    private func makeChip(title: String) -> UIButton {
        let chip = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .medium)
            return attr
        }
        chip.configuration = config
        chip.backgroundColor = UIColor(white: 0.22, alpha: 1)
        chip.layer.cornerRadius = 8
        chip.clipsToBounds = true
        chip.addAction(UIAction { [weak self] _ in
            self?.applySuggestion(title)
        }, for: .touchUpInside)
        return chip
    }

    private func applySuggestion(_ suggestion: String) {
        switch activeField {
        case .key:
            keyField.text = suggestion
            onKeyChanged?(suggestion)
            onKeySuggestionPicked?(suggestion)
            refreshSuggestions()
            // Move focus to the value field for a fast add flow.
            valueField.becomeFirstResponder()
        case .value:
            // Prefix templates like "Bearer " should append rather than replace
            // when the user has already typed a value; otherwise set directly.
            let s = suggestion == HTTPHeaderCatalog.UUIDPlaceholder ? UUID().uuidString : suggestion
            if s.hasSuffix(" "), let existing = valueField.text, !existing.isEmpty, !existing.hasSuffix(" ") {
                // User typed something first — don't clobber; just set the prefix + keep.
                valueField.text = s + existing
            } else {
                valueField.text = s
            }
            onValueChanged?(valueField.text ?? "")
            refreshSuggestions()
            // Keep focus in the value field so the user can finish typing (e.g.
            // paste the token after "Bearer ").
        }
    }
}
