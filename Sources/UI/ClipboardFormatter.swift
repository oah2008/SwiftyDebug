//
//  ClipboardFormatter.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 01/08/2026.
//

import UIKit

/// Puts guaranteed-valid, source-ordered JSON on the clipboard — and, when the
/// body is big enough that formatting it would stall, says so instead of either
/// freezing silently or quietly copying something less than asked for.
///
/// The problem this solves: re-printing a payload in the server's own key order
/// costs real time on a multi-megabyte body. The first answer was to fall back to
/// the minified original above a ceiling — valid JSON, but not what was asked
/// for, and silently different from the smaller bodies next to it. The second
/// answer, freezing the main thread for a second, is worse.
///
/// So: small bodies copy synchronously exactly as before, and big ones format on
/// a background queue behind a blocking overlay that names the size and the work.
/// The clipboard result is identical either way.
enum ClipboardFormatter {

    /// Above this, formatting gets the overlay. Chosen from measurement rather
    /// than taste: the order-preserving writer runs 17-23x Foundation on nested
    /// shapes, so a few hundred KB is already past the point where a tap feels
    /// instant, and anything the user can perceive deserves an explanation.
    static let asyncThresholdBytes = 256 * 1024

    /// True when `text` is large enough that formatting it needs the overlay.
    /// Pure, so the decision is unit-testable without any UI.
    static func needsProgressUI(byteCount: Int) -> Bool {
        byteCount > asyncThresholdBytes
    }

    /// Human-readable size for the overlay's message.
    static func sizeDescription(byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Copies `text` as valid JSON, blocking the screen with an explanation when
    /// the work is big enough to notice.
    ///
    /// - Parameters:
    ///   - text: the ORIGINAL body, not a display transform of it.
    ///   - presenter: the view controller to host the overlay. When nil, the copy
    ///     still happens — it just happens without one.
    ///   - completion: called on the main thread once the clipboard is set.
    static func copy(_ text: String,
                     from presenter: UIViewController?,
                     completion: (() -> Void)? = nil) {
        let byteCount = text.utf8.count
        guard needsProgressUI(byteCount: byteCount), let presenter else {
            UIPasteboard.general.string = JSONExporter.clipboardString(from: text)
            completion?()
            return
        }

        let overlay = FormattingOverlayView(
            message: "Formatting \(sizeDescription(byteCount: byteCount)) of JSON so it copies "
                   + "in the same order the server sent it.")
        overlay.present(over: presenter)

        // The whole point of the overlay: this is the expensive call, and it must
        // not run on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let formatted = JSONExporter.clipboardString(from: text)
            DispatchQueue.main.async {
                UIPasteboard.general.string = formatted
                overlay.dismiss()
                completion?()
            }
        }
    }
}

// MARK: - Overlay

/// A full-screen, touch-blocking overlay with a spinner and one sentence saying
/// what is happening. Blocking is deliberate: the clipboard is about to change,
/// and letting the user navigate away mid-copy would leave them wondering which
/// body they actually got.
private final class FormattingOverlayView: UIView {

    private let spinner = UIActivityIndicatorView(style: .large)

    init(message: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.color = DebugTheme.accentColor
        spinner.startAnimating()

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(over presenter: UIViewController) {
        guard let host = presenter.view else { return }
        alpha = 0
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func dismiss() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            self.spinner.stopAnimating()
            self.removeFromSuperview()
        }
    }
}
