//
//  StorageValueEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A focused editor for one stored value — used by web-view storage, cookies,
/// UserDefaults and the Keychain.
///
/// Two reasons this exists rather than editing inline in a table row:
///
/// 1. **Stored values are very often JSON** (a serialized user object, a feature
///    flag blob, a cached payload). Editing that in a one-line field inside a
///    reusable cell is miserable, so when the value parses as JSON this screen
///    offers the full tree editor.
/// 2. Inline editing inside recycled cells is fragile — the text field's
///    lifetime is tied to cell reuse, which is a common source of crashes and
///    edits landing on the wrong row.
final class StorageValueEditorViewController: UIViewController, UITextViewDelegate {

    // MARK: - Input

    private let key: String
    private let originalValue: String
    /// Extra context shown under the key (domain/path for a cookie, type for a default).
    private let subtitle: String?
    private let isKeyEditable: Bool

    /// Called with the (possibly edited) key and value when the user saves.
    var onSave: ((_ key: String, _ value: String) -> Void)?
    /// Called when the user asks to delete this entry.
    var onDelete: (() -> Void)?

    private var currentValue: String
    private var currentKey: String

    // MARK: - UI

    private let scroll = UIScrollView()
    private let keyField = UITextField()
    private let valueView = UITextView()
    private let jsonBanner = UIView()
    private let jsonLabel = UILabel()
    private let jsonButton = UIButton(type: .system)
    private let statsLabel = UILabel()

    init(key: String, value: String, subtitle: String? = nil, isKeyEditable: Bool = false) {
        self.key = key
        self.currentKey = key
        self.originalValue = value
        self.currentValue = value
        self.subtitle = subtitle
        self.isKeyEditable = isKeyEditable
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

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
            title: "Save", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor

        buildUI()
        refreshJSONBanner()
        view.forceLTR()
    }

    private func card() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.13, alpha: 1)
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 10, weight: .heavy)
        l.textColor = UIColor(white: 0.45, alpha: 1)
        return l
    }

    private func buildUI() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // KEY
        stack.addArrangedSubview(caption("KEY"))
        let keyCard = card()
        keyField.text = currentKey
        keyField.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        keyField.textColor = DebugTheme.accentColor
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.isUserInteractionEnabled = isKeyEditable
        keyField.alpha = isKeyEditable ? 1 : 0.75
        keyField.addTarget(self, action: #selector(keyChanged), for: .editingChanged)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyCard.addSubview(keyField)
        NSLayoutConstraint.activate([
            keyField.leadingAnchor.constraint(equalTo: keyCard.leadingAnchor, constant: 12),
            keyField.trailingAnchor.constraint(equalTo: keyCard.trailingAnchor, constant: -12),
            keyField.topAnchor.constraint(equalTo: keyCard.topAnchor, constant: 12),
            keyField.bottomAnchor.constraint(equalTo: keyCard.bottomAnchor, constant: -12),
        ])
        stack.addArrangedSubview(keyCard)

        if let subtitle, !subtitle.isEmpty {
            let l = UILabel()
            l.text = subtitle
            l.font = .systemFont(ofSize: 11)
            l.textColor = UIColor(white: 0.45, alpha: 1)
            l.numberOfLines = 0
            stack.addArrangedSubview(l)
        }

        // JSON banner — appears only when the value parses as JSON.
        jsonBanner.backgroundColor = DebugTheme.accentColor.withAlphaComponent(0.14)
        jsonBanner.layer.cornerRadius = 12
        jsonBanner.layer.cornerCurve = .continuous
        jsonBanner.translatesAutoresizingMaskIntoConstraints = false
        jsonLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        jsonLabel.textColor = DebugTheme.accentColor
        jsonLabel.numberOfLines = 2
        jsonLabel.translatesAutoresizingMaskIntoConstraints = false
        jsonButton.setTitle("Open editor", for: .normal)
        jsonButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        jsonButton.setTitleColor(.black, for: .normal)
        jsonButton.backgroundColor = DebugTheme.accentColor
        jsonButton.layer.cornerRadius = 8
        jsonButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        jsonButton.addTarget(self, action: #selector(openJSONEditor), for: .touchUpInside)
        jsonButton.translatesAutoresizingMaskIntoConstraints = false
        jsonBanner.addSubview(jsonLabel)
        jsonBanner.addSubview(jsonButton)
        NSLayoutConstraint.activate([
            jsonLabel.leadingAnchor.constraint(equalTo: jsonBanner.leadingAnchor, constant: 12),
            jsonLabel.centerYAnchor.constraint(equalTo: jsonBanner.centerYAnchor),
            jsonLabel.trailingAnchor.constraint(lessThanOrEqualTo: jsonButton.leadingAnchor, constant: -8),
            jsonButton.trailingAnchor.constraint(equalTo: jsonBanner.trailingAnchor, constant: -12),
            jsonButton.centerYAnchor.constraint(equalTo: jsonBanner.centerYAnchor),
            jsonBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        stack.addArrangedSubview(jsonBanner)

        // VALUE
        let valueCaptionRow = UIStackView(arrangedSubviews: [caption("VALUE"), UIView(), statsLabel])
        valueCaptionRow.axis = .horizontal
        statsLabel.font = .systemFont(ofSize: 10)
        statsLabel.textColor = UIColor(white: 0.4, alpha: 1)
        stack.addArrangedSubview(valueCaptionRow)

        let valueCard = card()
        valueView.text = currentValue
        valueView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        valueView.textColor = UIColor(white: 0.92, alpha: 1)
        valueView.backgroundColor = .clear
        valueView.autocapitalizationType = .none
        valueView.autocorrectionType = .no
        valueView.spellCheckingType = .no
        valueView.isScrollEnabled = false
        valueView.delegate = self
        valueView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueCard.addSubview(valueView)
        NSLayoutConstraint.activate([
            valueView.leadingAnchor.constraint(equalTo: valueCard.leadingAnchor),
            valueView.trailingAnchor.constraint(equalTo: valueCard.trailingAnchor),
            valueView.topAnchor.constraint(equalTo: valueCard.topAnchor),
            valueView.bottomAnchor.constraint(equalTo: valueCard.bottomAnchor),
            valueView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        stack.addArrangedSubview(valueCard)

        // Actions
        if onDelete != nil {
            let del = UIButton(type: .system)
            del.setTitle("Delete entry", for: .normal)
            del.setTitleColor(.systemRed, for: .normal)
            del.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            del.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            stack.addArrangedSubview(del)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -40),
        ])
    }

    // MARK: - JSON awareness

    /// Shows the "this is JSON" banner when the value parses, so the user can
    /// jump into the tree editor instead of wrestling with raw text.
    private func refreshJSONBanner() {
        let text = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSON = !text.isEmpty && JSONDocument.validate(text).isValid
            && (text.hasPrefix("{") || text.hasPrefix("["))
        jsonBanner.isHidden = !isJSON
        if isJSON, let doc = JSONDocument(text: text) {
            let kind = JSONValueKind.of(doc.root)
            var summary = "Valid JSON"
            if let arr = doc.root as? [Any] { summary += " · \(arr.count) items" }
            else if let obj = doc.root as? [String: Any] { summary += " · \(obj.count) keys" }
            else { summary += " · \(kind.badge)" }
            jsonLabel.text = summary
        }
        let bytes = currentValue.utf8.count
        statsLabel.text = "\(currentValue.count) chars · \(bytes) bytes"
    }

    @objc private func openJSONEditor() {
        let editor = JSONEditorViewController(text: currentValue, title: currentKey)
        editor.saveButtonTitle = "Use JSON"
        editor.onSave = { [weak self] doc in
            guard let self else { return }
            self.currentValue = doc.prettyText()
            self.valueView.text = self.currentValue
            self.refreshJSONBanner()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - Editing

    func textViewDidChange(_ textView: UITextView) {
        currentValue = textView.text
        refreshJSONBanner()
    }

    @objc private func keyChanged() {
        currentKey = keyField.text ?? ""
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        let trimmedKey = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let a = UIAlertController(title: "Key required", message: "Enter a key before saving.", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        onSave?(trimmedKey, currentValue)
        navigationController?.popViewController(animated: true)
    }

    @objc private func deleteTapped() {
        let a = UIAlertController(title: "Delete “\(currentKey)”?", message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.onDelete?()
            self?.navigationController?.popViewController(animated: true)
        })
        present(a, animated: true)
    }
}
