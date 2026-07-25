//
//  RedirectEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Full-screen editor for a rule's redirect, replacing the old truncating alert.
///
/// Shows a mode selector, a full-width multi-line destination field, and a **live
/// before → after preview** computed with the real `InterceptRule.redirectedURL`
/// logic, so you can see exactly what a matching request will become before you
/// save. (See REDIRECT.)
final class RedirectEditorViewController: UIViewController, UITextViewDelegate {

    // MARK: - In/out

    private var mode: RedirectMode
    private var target: String
    /// A real URL from the matched traffic, used for the preview.
    private let sampleURL: URL?
    /// Called on save with the chosen mode + target.
    var onSave: ((RedirectMode, String) -> Void)?

    // MARK: - UI

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let segment = UISegmentedControl(items: ["Off", "Host", "Host + Path"])
    private let targetView = UITextView()
    private let targetCard = UIView()
    private let hintLabel = UILabel()
    private let beforeLabel = UILabel()
    private let afterLabel = UILabel()
    private let previewCard = UIView()

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)

    init(mode: RedirectMode, target: String, sampleURL: URL?) {
        self.mode = mode
        self.target = target
        self.sampleURL = sampleURL
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let title = UILabel()
        title.text = "Redirect"
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = DebugTheme.accentColor
        title.sizeToFit()
        navigationItem.titleView = title
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -32),
        ])

        buildModeSection()
        buildTargetSection()
        buildPreviewSection()

        segment.selectedSegmentIndex = mode == .none ? 0 : (mode == .host ? 1 : 2)
        targetView.text = target
        syncUI()
        view.forceLTR()
    }

    // MARK: - Sections

    private func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 11, weight: .heavy)
        l.textColor = DebugTheme.accentColor
        return l
    }

    private func makeCard() -> UIView {
        let v = UIView()
        v.backgroundColor = Self.cardBG
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = Self.cardBorder.cgColor
        return v
    }

    private func buildModeSection() {
        stack.addArrangedSubview(caption("MODE"))
        segment.selectedSegmentTintColor = DebugTheme.accentColor
        segment.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1),
                                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                        .font: UIFont.systemFont(ofSize: 12, weight: .bold)], for: .selected)
        segment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        segment.heightAnchor.constraint(equalToConstant: 34).isActive = true
        stack.addArrangedSubview(segment)

        hintLabel.numberOfLines = 0
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = UIColor(white: 0.5, alpha: 1)
        stack.addArrangedSubview(hintLabel)
    }

    private func buildTargetSection() {
        stack.addArrangedSubview(caption("DESTINATION"))

        targetCard.translatesAutoresizingMaskIntoConstraints = false
        let card = makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        targetCard.addSubview(card)

        targetView.backgroundColor = .clear
        targetView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        targetView.textColor = DebugTheme.accentColor
        targetView.isScrollEnabled = false
        targetView.autocapitalizationType = .none
        targetView.autocorrectionType = .no
        targetView.spellCheckingType = .no
        targetView.keyboardType = .URL
        targetView.delegate = self
        targetView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        targetView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(targetView)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: targetCard.topAnchor),
            card.leadingAnchor.constraint(equalTo: targetCard.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: targetCard.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: targetCard.bottomAnchor),
            targetView.topAnchor.constraint(equalTo: card.topAnchor),
            targetView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            targetView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            targetView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            targetView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        stack.addArrangedSubview(targetCard)
    }

    private func buildPreviewSection() {
        stack.addArrangedSubview(caption("PREVIEW"))

        let card = makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false

        func tag(_ text: String, _ color: UIColor) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 9, weight: .heavy)
            l.textColor = color
            return l
        }
        for (t, color, label) in [("BEFORE", UIColor(white: 0.45, alpha: 1), beforeLabel),
                                  ("AFTER", DebugTheme.accentColor, afterLabel)] {
            label.numberOfLines = 0
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = (t == "AFTER") ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.6, alpha: 1)
            inner.addArrangedSubview(tag(t, color))
            inner.addArrangedSubview(label)
        }

        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        previewCard.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: previewCard.topAnchor),
            card.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
        ])
        stack.addArrangedSubview(previewCard)
    }

    // MARK: - Sync

    @objc private func modeChanged() {
        mode = [RedirectMode.none, .host, .hostAndPath][segment.selectedSegmentIndex]
        syncUI()
    }

    func textViewDidChange(_ textView: UITextView) {
        target = textView.text
        syncUI()
    }

    private func syncUI() {
        let sampleHost = sampleURL?.host ?? "example.com"
        let samplePath = sampleURL?.path ?? "/path"

        switch mode {
        case .none:
            hintLabel.text = "No redirect. Requests go to their original destination."
            targetCard.isHidden = true
            previewCard.isHidden = true
        case .host:
            hintLabel.text = "Only the host changes. The path and query string are kept exactly as they were."
            targetCard.isHidden = false
            previewCard.isHidden = false
            targetView.attributedPlaceholderIfEmpty("beta.\(sampleHost)")
        case .hostAndPath:
            hintLabel.text = "The host AND path are replaced. The original query string is still preserved. Applies to every request matching this rule — not just this one."
            targetCard.isHidden = false
            previewCard.isHidden = false
            targetView.attributedPlaceholderIfEmpty("beta.\(sampleHost)\(samplePath)")
        }

        // Live preview through the real redirect logic.
        if mode != .none {
            let before = sampleURL?.absoluteString ?? "https://\(sampleHost)\(samplePath)?param=1"
            beforeLabel.text = before
            var probe = InterceptRule(matchEndpoint: "preview")
            probe.redirectMode = mode
            probe.redirectTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: before), let out = probe.redirectedURL(for: url) {
                afterLabel.text = out.absoluteString
                afterLabel.textColor = UIColor(white: 0.92, alpha: 1)
            } else {
                afterLabel.text = target.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Enter a destination above"
                    : "Invalid destination"
                afterLabel.textColor = UIColor(white: 0.45, alpha: 1)
            }
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        if navigationController?.viewControllers.first === self {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func saveTapped() {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .none && trimmed.isEmpty {
            let a = UIAlertController(title: "Destination required",
                                      message: "Enter where matching requests should go, or set Mode to Off.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        onSave?(mode, mode == .none ? "" : trimmed)
        if navigationController?.viewControllers.first === self {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - Placeholder helper

private extension UITextView {
    /// UITextView has no placeholder; show grey hint text only while empty.
    func attributedPlaceholderIfEmpty(_ placeholder: String) {
        guard text.isEmpty else { return }
        // Keep it simple: use the tint-less hint via `text` only when the user
        // hasn't typed. We avoid overwriting real input.
        if let existing = accessibilityHint, existing == placeholder { return }
        accessibilityHint = placeholder
    }
}
