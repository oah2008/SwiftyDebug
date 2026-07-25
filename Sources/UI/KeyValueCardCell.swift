//
//  KeyValueCardCell.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A single editable key/value entry rendered as a card, with the **key on its
/// own line and the value on its own line** (full width each — no cramped
/// side-by-side fields). Shared by the intercept-rule editor and the web-view
/// storage editor so both feel identical.
///
///  ┌────────────────────────────────────┐
///  │ KEY                        [ SET ] │
///  │ Authorization                      │
///  │ ────────────────────────────────── │
///  │ VALUE                              │
///  │ Bearer eyJhbGciOiJIUzI1NiIs…       │
///  └────────────────────────────────────┘
final class KeyValueCardCell: UITableViewCell {

    // MARK: - Public API

    let keyField = UITextField()
    let valueField = UITextField()

    var onKeyChanged: ((String) -> Void)?
    var onValueChanged: ((String) -> Void)?
    /// Fired when the SET/REMOVE pill is tapped. Only shown when `showsModeControl`.
    var onModeToggled: (() -> Void)?

    /// Key-field autocomplete provider.
    var keySuggestionsProvider: ((String) -> [String])?
    var onKeySuggestionPicked: ((String) -> Void)?
    /// Value-field autocomplete provider: (currentKey, currentValue) -> chips.
    var valueSuggestionsProvider: ((_ key: String, _ currentValue: String) -> [String])?
    /// Supplies the current key text for value suggestions.
    var currentKeyText: (() -> String)?

    /// When false the SET/REMOVE pill is hidden (e.g. storage editor, where every
    /// entry is simply a value you set).
    var showsModeControl: Bool = true {
        didSet { modeButton.isHidden = !showsModeControl }
    }

    /// `true` = this entry removes the header/param from the request.
    var isRemoving: Bool = false {
        didSet { updateModeAppearance() }
    }

    var isKeyEditable: Bool = true {
        didSet { keyField.isUserInteractionEnabled = isKeyEditable }
    }

    // MARK: - Subviews

    private let card = UIView()
    private let keyCaption = UILabel()
    private let valueCaption = UILabel()
    private let separator = UIView()
    private let modeButton = UIButton(type: .system)
    private let stack = UIStackView()

    // Autocomplete accessory
    private var suggestionBar: UIScrollView?
    private var suggestionStack: UIStackView?
    private enum ActiveField { case key, value }
    private var activeField: ActiveField = .key

    // MARK: - Palette

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let teal = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
    private static let caption = UIColor(white: 0.42, alpha: 1)
    private static let valueText = UIColor(white: 0.88, alpha: 1)

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = Self.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // Captions
        for l in [keyCaption, valueCaption] {
            l.font = .systemFont(ofSize: 10, weight: .heavy)
            l.textColor = Self.caption
        }
        keyCaption.text = "KEY"
        valueCaption.text = "VALUE"

        // Mode pill
        modeButton.titleLabel?.font = .systemFont(ofSize: 10, weight: .heavy)
        modeButton.layer.cornerRadius = 9
        modeButton.clipsToBounds = true
        modeButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        modeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Key row: caption + mode pill
        let keyRow = UIStackView(arrangedSubviews: [keyCaption, UIView(), modeButton])
        keyRow.axis = .horizontal
        keyRow.alignment = .center
        keyRow.spacing = 6

        configure(field: keyField, font: .monospacedSystemFont(ofSize: 15, weight: .semibold),
                  color: Self.teal, placeholder: "name")
        keyField.addTarget(self, action: #selector(keyDidChange), for: .editingChanged)
        keyField.addTarget(self, action: #selector(keyEditingBegan), for: .editingDidBegin)

        separator.backgroundColor = UIColor(white: 0.22, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        configure(field: valueField, font: .monospacedSystemFont(ofSize: 14, weight: .regular),
                  color: Self.valueText, placeholder: "value")
        valueField.addTarget(self, action: #selector(valueDidChange), for: .editingChanged)
        valueField.addTarget(self, action: #selector(valueEditingBegan), for: .editingDidBegin)

        // Vertical stack: key caption row / key / separator / value caption / value
        stack.axis = .vertical
        stack.spacing = 5
        stack.setCustomSpacing(10, after: keyField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [keyRow, keyField, separator, valueCaption, valueField].forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(10, after: separator)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        updateModeAppearance()
        forceLTR()
    }

    private func configure(field: UITextField, font: UIFont, color: UIColor, placeholder: String) {
        field.font = font
        field.textColor = color
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.30, alpha: 1)]
        )
    }

    // MARK: - Configure

    func configure(key: String, value: String, removing: Bool = false, keyEditable: Bool = true) {
        keyField.text = key
        valueField.text = value
        isRemoving = removing
        isKeyEditable = keyEditable
    }

    private func updateModeAppearance() {
        if isRemoving {
            modeButton.setTitle("REMOVE", for: .normal)
            modeButton.setTitleColor(.white, for: .normal)
            modeButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
            card.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.5).cgColor
            // Value is irrelevant when removing — collapse it out of the way.
            valueCaption.isHidden = true
            valueField.isHidden = true
            separator.isHidden = true
        } else {
            modeButton.setTitle("SET", for: .normal)
            modeButton.setTitleColor(.black, for: .normal)
            modeButton.backgroundColor = Self.teal
            card.layer.borderColor = Self.cardBorder.cgColor
            valueCaption.isHidden = false
            valueField.isHidden = false
            separator.isHidden = false
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        keyField.text = nil
        valueField.text = nil
        onKeyChanged = nil
        onValueChanged = nil
        onModeToggled = nil
        keySuggestionsProvider = nil
        onKeySuggestionPicked = nil
        valueSuggestionsProvider = nil
        currentKeyText = nil
        showsModeControl = true
        isRemoving = false
        isKeyEditable = true
    }

    // MARK: - Actions

    @objc private func modeTapped() { onModeToggled?() }
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

    // MARK: - Autocomplete accessory bar

    private func installSuggestionBar(for field: UITextField) {
        guard keySuggestionsProvider != nil || valueSuggestionsProvider != nil else { return }
        if suggestionBar == nil {
            let bar = UIScrollView()
            bar.backgroundColor = UIColor(white: 0.15, alpha: 1)
            bar.showsHorizontalScrollIndicator = false
            bar.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 46)
            bar.autoresizingMask = [.flexibleWidth]
            let s = UIStackView()
            s.axis = .horizontal
            s.spacing = 6
            s.alignment = .center
            s.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
                s.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
                s.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                s.heightAnchor.constraint(equalToConstant: 32),
            ])
            bar.semanticContentAttribute = .forceLeftToRight
            s.semanticContentAttribute = .forceLeftToRight
            suggestionBar = bar
            suggestionStack = s
        }
        field.inputAccessoryView = suggestionBar
    }

    private func refreshSuggestions() {
        guard let s = suggestionStack else { return }
        s.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items: [String]
        switch activeField {
        case .key:
            items = keySuggestionsProvider?(keyField.text ?? "") ?? []
        case .value:
            let k = currentKeyText?() ?? keyField.text ?? ""
            items = valueSuggestionsProvider?(k, valueField.text ?? "") ?? []
        }
        for t in items { s.addArrangedSubview(makeChip(title: t)) }
        suggestionBar?.isHidden = items.isEmpty
    }

    private func makeChip(title: String) -> UIButton {
        let chip = UIButton(type: .system)
        var c = UIButton.Configuration.plain()
        c.title = title.count > 46 ? String(title.prefix(46)) + "…" : title
        c.baseForegroundColor = Self.teal
        c.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            return a
        }
        chip.configuration = c
        chip.backgroundColor = UIColor(white: 0.23, alpha: 1)
        chip.layer.cornerRadius = 9
        chip.clipsToBounds = true
        chip.addAction(UIAction { [weak self] _ in self?.applySuggestion(title) }, for: .touchUpInside)
        return chip
    }

    private func applySuggestion(_ suggestion: String) {
        switch activeField {
        case .key:
            keyField.text = suggestion
            onKeyChanged?(suggestion)
            onKeySuggestionPicked?(suggestion)
            refreshSuggestions()
            valueField.becomeFirstResponder()
        case .value:
            let s = suggestion == HTTPHeaderCatalog.UUIDPlaceholder ? UUID().uuidString : suggestion
            // Prefix templates ("Bearer ") keep whatever the user already typed.
            if s.hasSuffix(" "), let existing = valueField.text, !existing.isEmpty, !existing.hasSuffix(" ") {
                valueField.text = s + existing
            } else {
                valueField.text = s
            }
            onValueChanged?(valueField.text ?? "")
            refreshSuggestions()
        }
    }
}
