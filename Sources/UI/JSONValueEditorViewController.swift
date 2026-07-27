//
//  JSONValueEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Converts between a JSON value and the text an editor shows for it.
///
/// Both editors share this: the inline field in the tree and the full page
/// below. Keeping one implementation means a value can't come back a different
/// type depending on which screen you happened to edit it on, and the rules
/// ("42" stays an Int, "  true " is a bool) are unit-testable on their own.
enum JSONInlineValueCoder {

    /// The editable text for a scalar. Containers and null edit as empty text.
    static func text(for value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // CFBoolean is an NSNumber — check it first or `true` reads as "1".
            return CFGetTypeID(n) == CFBooleanGetTypeID()
                ? (n.boolValue ? "true" : "false")
                : n.stringValue
        default:
            return ""
        }
    }

    /// Turns editor text back into a JSON value of `kind`.
    static func value(from text: String, kind: JSONValueKind) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .string:
            return text
        case .number:
            // Keep integers as integers so they don't render as "1.0".
            if let i = Int(trimmed) { return NSNumber(value: i) }
            return NSNumber(value: Double(trimmed) ?? 0)
        case .bool:
            return ["true", "1", "yes", "on"].contains(trimmed.lowercased())
        case .null:
            return NSNull()
        case .object, .array:
            // Containers aren't typed by hand in the field, but if the text does
            // parse as the right shape, honour it rather than wiping the node.
            if let parsed = JSONDocument(text: text)?.root, JSONValueKind.of(parsed) == kind {
                return parsed
            }
            return kind.emptyValue
        }
    }

    /// True when a draft would write back exactly what's already there — the
    /// guard that keeps a no-op edit out of the undo stack.
    static func isUnchanged(draft: String, current: Any?) -> Bool {
        text(for: current) == draft
    }
}

/// Focused editor for a single scalar JSON value.
///
/// Editing long strings (tokens, HTML, base64) inside a table row is miserable
/// on a phone, so leaf values get their own screen: a type switcher, a
/// full-height multi-line field, and the node's path as a breadcrumb.
final class JSONValueEditorViewController: UIViewController, UITextViewDelegate {

    /// Called with the new value when the user saves.
    var onSave: ((Any) -> Void)?

    private var kind: JSONValueKind
    private let pathDisplay: String
    private var originalText: String

    private let breadcrumb = UILabel()
    private let typeControl = UISegmentedControl(items: ["String", "Number", "Bool", "Null"])
    private let textView = UITextView()
    /// Owned so the keyboard can shrink the card instead of covering it.
    private var cardBottom: NSLayoutConstraint!
    private var cardMinHeight: NSLayoutConstraint!
    private var boolRowBottom: NSLayoutConstraint!
    private let boolSwitch = UISwitch()
    private let boolRow = UIView()
    private let hintLabel = UILabel()
    private let card = UIView()

    /// Only scalars are editable here — containers are edited in the tree.
    private static let editableKinds: [JSONValueKind] = [.string, .number, .bool, .null]

    init(value: Any?, pathDisplay: String) {
        let resolved = value ?? NSNull()
        self.kind = JSONValueKind.of(resolved)
        self.pathDisplay = pathDisplay
        self.originalText = JSONInlineValueCoder.text(for: resolved)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Edit Value"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        breadcrumb.text = pathDisplay
        breadcrumb.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        breadcrumb.textColor = UIColor(white: 0.45, alpha: 1)
        breadcrumb.numberOfLines = 2
        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(breadcrumb)

        typeControl.selectedSegmentIndex = Self.editableKinds.firstIndex(of: kind) ?? 0
        typeControl.selectedSegmentTintColor = DebugTheme.accentColor
        typeControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1),
                                            .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        typeControl.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                            .font: UIFont.systemFont(ofSize: 12, weight: .bold)], for: .selected)
        typeControl.addTarget(self, action: #selector(typeChanged), for: .valueChanged)
        typeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(typeControl)

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        textView.backgroundColor = .clear
        textView.textColor = UIColor(white: 0.92, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.text = originalText
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textView)

        // Bool editing uses a switch rather than typing "true".
        boolRow.translatesAutoresizingMaskIntoConstraints = false
        let boolLabel = UILabel()
        boolLabel.text = "Value"
        boolLabel.font = .systemFont(ofSize: 15, weight: .medium)
        boolLabel.textColor = .white
        boolLabel.translatesAutoresizingMaskIntoConstraints = false
        boolSwitch.onTintColor = DebugTheme.accentColor
        boolSwitch.isOn = (originalText == "true")
        boolSwitch.translatesAutoresizingMaskIntoConstraints = false
        boolRow.addSubview(boolLabel)
        boolRow.addSubview(boolSwitch)
        card.addSubview(boolRow)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = UIColor(white: 0.45, alpha: 1)
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            breadcrumb.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            breadcrumb.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            breadcrumb.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            typeControl.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor, constant: 10),
            typeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            typeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            typeControl.heightAnchor.constraint(equalToConstant: 32),

            card.topAnchor.constraint(equalTo: typeControl.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            textView.topAnchor.constraint(equalTo: card.topAnchor),
            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            // NOT pinned to card.bottom: with a fixed 56pt height that would force
            // the card to 56pt, contradicting the fill-to-bottom constraint below.
            // Auto Layout resolved that by breaking the top of the chain, which
            // left the breadcrumb floating in the middle of an empty screen.
            // `boolRowBottom` supplies the bottom only when a bool is being edited.
            boolRow.topAnchor.constraint(equalTo: card.topAnchor),
            boolRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            boolRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            boolRow.heightAnchor.constraint(equalToConstant: 56),

            boolLabel.leadingAnchor.constraint(equalTo: boolRow.leadingAnchor, constant: 14),
            boolLabel.centerYAnchor.constraint(equalTo: boolRow.centerYAnchor),
            boolSwitch.trailingAnchor.constraint(equalTo: boolRow.trailingAnchor, constant: -14),
            boolSwitch.centerYAnchor.constraint(equalTo: boolRow.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -6),
        ])

        // The card fills every remaining point above the keyboard. This is the
        // whole reason a value opens on its own page, so the constraint is
        // required — at .defaultLow it lost to the text view's content hugging
        // and the card sat at the height of one line on a full screen.
        cardBottom = card.bottomAnchor.constraint(equalTo: guide.bottomAnchor,
                                                  constant: -Self.hintReserve)
        cardMinHeight = card.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        // Bool and null need a 56pt row, not a full page — `applyKind` swaps
        // between this and the pair above so the two can never both be required.
        boolRowBottom = boolRow.bottomAnchor.constraint(equalTo: card.bottomAnchor)

        // The text view must stretch, not size itself to its content.
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        observeKeyboard()
        applyKind()
        view.forceLTR()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Space kept under the card for the hint line.
    private static let hintReserve: CGFloat = 30

    /// Nothing tracked the keyboard before, so the bottom of a full-height card
    /// sat underneath it — you could not see the end of what you were typing.
    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let overlap = max(0, view.convert(view.bounds, to: window).maxY - frame.minY)
        setCardBottomInset(overlap + Self.hintReserve, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        setCardBottomInset(Self.hintReserve, note: note)
    }

    private func setCardBottomInset(_ inset: CGFloat, note: Notification) {
        guard abs(cardBottom.constant + inset) > 0.5 else { return }
        cardBottom.constant = -inset
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if kind == .string || kind == .number { textView.becomeFirstResponder() }
    }

    @objc private func typeChanged() {
        kind = Self.editableKinds[typeControl.selectedSegmentIndex]
        applyKind()
    }

    private func applyKind() {
        switch kind {
        case .string:
            textView.isHidden = false; boolRow.isHidden = true
            textView.keyboardType = .default
            hintLabel.text = "Saved as a JSON string."
        case .number:
            textView.isHidden = false; boolRow.isHidden = true
            textView.keyboardType = .numbersAndPunctuation
            hintLabel.text = "Saved as a JSON number. Non-numeric text is discarded."
        case .bool:
            textView.isHidden = true; boolRow.isHidden = false
            view.endEditing(true)
            hintLabel.text = "Saved as true / false."
        case .null:
            textView.isHidden = true; boolRow.isHidden = true
            view.endEditing(true)
            hintLabel.text = "Saved as null."
        default:
            break
        }
        applyCardSizing()
    }

    /// A text value gets the whole page; a bool or null needs one short row.
    /// Exactly one of the two sizings is ever active, so they cannot conflict.
    private func applyCardSizing() {
        let wantsFullHeight = (kind == .string || kind == .number)
        boolRowBottom.isActive = !wantsFullHeight
        cardBottom.isActive = wantsFullHeight
        cardMinHeight.isActive = wantsFullHeight
        view.layoutIfNeeded()
    }

    @objc private func saveTapped() {
        let value: Any
        switch kind {
        case .bool: value = boolSwitch.isOn
        case .null: value = NSNull()
        default:    value = JSONInlineValueCoder.value(from: textView.text ?? "", kind: kind)
        }
        onSave?(value)
        navigationController?.popViewController(animated: true)
    }
}
