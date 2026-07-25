//
//  JSONValueEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

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
        switch resolved {
        case let s as String: originalText = s
        case let n as NSNumber:
            originalText = CFGetTypeID(n) == CFBooleanGetTypeID()
                ? (n.boolValue ? "true" : "false") : n.stringValue
        case is NSNull: originalText = ""
        default: originalText = ""
        }
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
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
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

            boolRow.topAnchor.constraint(equalTo: card.topAnchor),
            boolRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            boolRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            boolRow.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            boolRow.heightAnchor.constraint(equalToConstant: 56),

            boolLabel.leadingAnchor.constraint(equalTo: boolRow.leadingAnchor, constant: 14),
            boolLabel.centerYAnchor.constraint(equalTo: boolRow.centerYAnchor),
            boolSwitch.trailingAnchor.constraint(equalTo: boolRow.trailingAnchor, constant: -14),
            boolSwitch.centerYAnchor.constraint(equalTo: boolRow.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -12),
        ])

        // The text card grows to fill the space above the keyboard.
        let grow = card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -44)
        grow.priority = .defaultLow
        grow.isActive = true

        applyKind()
        view.forceLTR()
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
            hintLabel.text = "Saved as a JSON number. Non-numeric text saves as 0."
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
    }

    @objc private func saveTapped() {
        let value: Any
        switch kind {
        case .string: value = textView.text ?? ""
        case .number:
            let raw = (textView.text ?? "").trimmingCharacters(in: .whitespaces)
            // Keep integers as integers so they don't render as "1.0".
            if let i = Int(raw) { value = NSNumber(value: i) }
            else { value = NSNumber(value: Double(raw) ?? 0) }
        case .bool:   value = boolSwitch.isOn
        case .null:   value = NSNull()
        default:      value = textView.text ?? ""
        }
        onSave?(value)
        navigationController?.popViewController(animated: true)
    }
}
