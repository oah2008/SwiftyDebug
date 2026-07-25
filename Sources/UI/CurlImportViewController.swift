//
//  CurlImportViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Paste a cURL command — from a colleague, from the browser's "Copy as cURL", or
/// from SwiftyDebug's own copy-as-cURL — and either replay it or turn it into an
/// intercept rule.
///
/// Full screen, never a sheet: the editor needs the keyboard plus the whole height
/// to show a real multi-line command.
final class CurlImportViewController: UIViewController {

    // MARK: - Views

    private let summaryCard = UIView()
    private let summaryLabel = UILabel()
    private let editorCard = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let replayButton = UIButton(type: .system)
    private let ruleButton = UIButton(type: .system)
    private var buttonsBottomConstraint: NSLayoutConstraint!

    // MARK: - State

    /// Last successful parse — the source of truth for both actions.
    private var parsed: ParsedCurlRequest?

    private var isPresentedModally: Bool {
        return navigationController?.viewControllers.first === self
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Import cURL"
        view.backgroundColor = .black

        let pasteItem = UIBarButtonItem(title: "Paste", style: .plain, target: self, action: #selector(pasteTapped))
        pasteItem.tintColor = DebugTheme.accentColor
        let clearItem = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(clearTapped))
        clearItem.tintColor = UIColor(white: 0.7, alpha: 1)
        navigationItem.rightBarButtonItems = [pasteItem, clearItem]

        if isPresentedModally {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        setupViews()
        revalidate()

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )

        view.forceLTR()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if (textView.text ?? "").isEmpty {
            textView.becomeFirstResponder()
        }
    }

    // MARK: - Setup

    private func setupViews() {
        summaryCard.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.backgroundColor = UIColor(white: 0.11, alpha: 1)
        summaryCard.layer.cornerRadius = 10
        view.addSubview(summaryCard)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.numberOfLines = 0
        summaryCard.addSubview(summaryLabel)

        editorCard.translatesAutoresizingMaskIntoConstraints = false
        editorCard.backgroundColor = UIColor(white: 0.11, alpha: 1)
        editorCard.layer.cornerRadius = 10
        view.addSubview(editorCard)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.textColor = UIColor(white: 0.9, alpha: 1)
        textView.tintColor = DebugTheme.accentColor
        textView.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        // Smart quotes/dashes silently corrupt a pasted command into something the
        // parser (and the shell it came from) can no longer read.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardAppearance = .dark
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.delegate = self
        textView.inputAccessoryView = makeKeyboardToolbar()
        editorCard.addSubview(textView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.numberOfLines = 0
        placeholderLabel.font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderLabel.textColor = UIColor(white: 0.3, alpha: 1)
        placeholderLabel.text = "curl -X POST 'https://api.example.com/v1/search' \\\n  -H 'Content-Type: application/json' \\\n  --data-raw '{\"query\":\"shoes\"}'"
        editorCard.addSubview(placeholderLabel)

        configure(replayButton, title: "Replay Request", filled: true, action: #selector(replayTapped))
        configure(ruleButton, title: "Create Intercept Rule", filled: false, action: #selector(createRuleTapped))

        let buttons = UIStackView(arrangedSubviews: [replayButton, ruleButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        view.addSubview(buttons)

        buttonsBottomConstraint = buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)

        NSLayoutConstraint.activate([
            summaryCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            summaryCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            summaryCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            summaryLabel.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -12),
            summaryLabel.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: -10),

            editorCard.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 12),
            editorCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            editorCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            editorCard.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: editorCard.topAnchor),
            textView.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -4),
            textView.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -13),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 48),
            buttonsBottomConstraint,
        ])
    }

    private func configure(_ button: UIButton, title: String, filled: Bool, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = 10
        if filled {
            button.backgroundColor = DebugTheme.accentColor
            button.setTitleColor(.black, for: .normal)
        } else {
            button.backgroundColor = UIColor(white: 0.16, alpha: 1)
            button.setTitleColor(DebugTheme.accentColor, for: .normal)
            button.layer.borderWidth = 1
            button.layer.borderColor = DebugTheme.accentColor.withAlphaComponent(0.5).cgColor
        }
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func makeKeyboardToolbar() -> UIToolbar {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        toolbar.barStyle = .black
        toolbar.tintColor = DebugTheme.accentColor
        toolbar.items = [
            UIBarButtonItem(title: "Paste", style: .plain, target: self, action: #selector(pasteTapped)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: self, action: #selector(dismissKeyboard)),
        ]
        toolbar.sizeToFit()
        return toolbar
    }

    // MARK: - Live validation

    private func revalidate() {
        let text = textView.text ?? ""
        placeholderLabel.isHidden = !text.isEmpty

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            summaryLabel.attributedText = message("Paste a cURL command to replay it or turn it into a rule.",
                                                  color: UIColor(white: 0.5, alpha: 1))
            updateButtons()
            return
        }

        do {
            let request = try CurlParser.parse(text)
            parsed = request
            summaryLabel.attributedText = summary(for: request)
        } catch {
            parsed = nil
            let reason = (error as? CurlParseError)?.errorDescription ?? error.localizedDescription
            summaryLabel.attributedText = message(reason, color: .systemRed)
        }
        updateButtons()
    }

    private func updateButtons() {
        let enabled = parsed != nil
        for button in [replayButton, ruleButton] {
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.4
        }
    }

    private func message(_ text: String, color: UIColor) -> NSAttributedString {
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: color,
        ])
    }

    private func summary(for request: ParsedCurlRequest) -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(NSAttributedString(string: request.method, attributes: [
            .font: UIFont(name: "Menlo-Bold", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: Self.color(forMethod: request.method),
        ]))
        result.append(NSAttributedString(string: "  " + request.url.absoluteString, attributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor(white: 0.85, alpha: 1),
        ]))

        var stats = ["\(request.headers.count) header\(request.headers.count == 1 ? "" : "s")"]
        let params = request.queryItems.count
        if params > 0 { stats.append("\(params) query param\(params == 1 ? "" : "s")") }
        if let body = request.body, !body.isEmpty {
            stats.append("body \(ByteCountFormatter().string(fromByteCount: Int64(body.count)))")
        } else {
            stats.append("no body")
        }
        result.append(NSAttributedString(string: "\n" + stats.joined(separator: "  ·  "), attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: DebugTheme.accentColor,
        ]))

        if !request.ignoredFlags.isEmpty {
            result.append(NSAttributedString(string: "\nIgnored: " + request.ignoredFlags.joined(separator: ", "), attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.systemOrange,
            ]))
        }

        return result
    }

    static func color(forMethod method: String) -> UIColor {
        switch method.uppercased() {
        case "GET":    return DebugTheme.accentColor
        case "POST":   return .systemGreen
        case "PUT",
             "PATCH":  return .systemOrange
        case "DELETE": return .systemRed
        default:       return UIColor(white: 0.8, alpha: 1)
        }
    }

    // MARK: - Actions

    @objc private func pasteTapped() {
        guard let clipboard = UIPasteboard.general.string, !clipboard.isEmpty else {
            showAlert(title: "Clipboard is empty", message: "Copy a cURL command first.")
            return
        }
        textView.text = clipboard
        revalidate()
    }

    @objc private func clearTapped() {
        textView.text = ""
        revalidate()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func replayTapped() {
        guard let parsed else { return }
        view.endEditing(true)
        push(CurlReplayViewController(request: parsed))
    }

    @objc private func createRuleTapped() {
        guard let parsed else { return }
        view.endEditing(true)

        let sheet = UIAlertController(
            title: "Match Requests By",
            message: parsed.url.absoluteString,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Exact Path — \(parsed.url.path)", style: .default) { [weak self] _ in
            self?.pushRuleEditor(mode: .exact)
        })
        sheet.addAction(UIAlertAction(title: "Pattern — \(EndpointNormalizer.normalize(parsed.url.path))", style: .default) { [weak self] _ in
            self?.pushRuleEditor(mode: .normalized)
        })
        sheet.addAction(UIAlertAction(title: "Host — \(parsed.url.host ?? "")", style: .default) { [weak self] _ in
            self?.pushRuleEditor(mode: .host)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = ruleButton
        sheet.popoverPresentationController?.sourceRect = ruleButton.bounds
        present(sheet, animated: true)
    }

    private func pushRuleEditor(mode: EndpointMatchMode) {
        guard let parsed else { return }
        // The rule is only prefilled — the editor's Save is what persists it.
        let editor = InterceptRuleEditorViewController()
        editor.ruleToEdit = parsed.makeInterceptRule(matchMode: mode)
        editor.initialMatchMode = mode
        push(editor)
    }

    private func push(_ viewController: UIViewController) {
        if let navigationController {
            navigationController.pushViewController(viewController, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: viewController), animated: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Keyboard

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY - view.safeAreaInsets.bottom)
        buttonsBottomConstraint.constant = -12 - overlap
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        buttonsBottomConstraint.constant = -12
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }
}

// MARK: - UITextViewDelegate

extension CurlImportViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        revalidate()
    }
}
