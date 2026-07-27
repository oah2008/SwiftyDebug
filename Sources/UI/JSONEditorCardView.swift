//
//  JSONEditorCardView.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 26/07/2026.
//

import UIKit

/// The single affordance for "this text is JSON — open the real editor".
///
/// Every screen in the SDK that lets you edit a payload (replay body, mock body,
/// a paused response, a stored value) shows *this* card above its raw text, so
/// the gesture is learned once and works everywhere. Tapping it is expected to
/// push `JSONEditorViewController` and write `doc.prettyText()` back — the call
/// site owns that push because only it knows what to do with the result.
///
/// The card is deliberately quiet: it hides itself entirely when the text isn't
/// JSON, so screens that also accept form bodies, plain text or XML don't grow a
/// dead control. Screens where the card is the *only* way in (a mock body that
/// starts empty) set `alwaysVisible`.
final class JSONEditorCardView: UIControl {

    // MARK: - Shared JSON detection

    /// True when the text is worth opening the tree editor for.
    ///
    /// Deliberately stricter than `JSONDocument.validate`, which accepts
    /// fragments: a bare `42`, `true` or a quoted string is technically valid
    /// JSON, and offering a tree editor for it is noise. Only objects and arrays
    /// qualify.
    static func isEditableJSON(_ text: String?) -> Bool {
        return summary(for: text) != nil
    }

    /// The live one-liner: `"Valid JSON · 12 keys"`, `"Valid JSON · 4 items"`.
    /// `nil` when the text isn't editable JSON, which is also the hide signal.
    ///
    /// Exactly ONE parse. This runs on every keystroke in the replay body field,
    /// where a validate-then-parse-then-validate-again shape meant three full
    /// `JSONSerialization` passes per character on the main thread.
    static func summary(for text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let doc = JSONDocument(text: trimmed) else { return nil }
        if let array = doc.root as? [Any] {
            return "Valid JSON · \(array.count) item\(array.count == 1 ? "" : "s")"
        }
        if let object = doc.root as? [String: Any] {
            return "Valid JSON · \(object.count) key\(object.count == 1 ? "" : "s")"
        }
        return "Valid JSON · \(JSONValueKind.of(doc.root).badge)"
    }

    /// What to say when the card is pinned visible but the text isn't JSON.
    private static func fallbackSummary(for text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty · start a new JSON body" }
        if JSONDocument.validate(trimmed).isValid { return "JSON fragment · \(trimmed.count) chars" }
        return "Not JSON yet · \(trimmed.count) chars"
    }

    /// One-line, whitespace-collapsed excerpt for the rows that have no raw text
    /// view of their own. String work only — safe to call from `cellForRowAt`.
    static func preview(for text: String?, limit: Int = 140) -> String? {
        let collapsed = (text ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Configuration

    /// Called when the card is tapped. Cleared by `JSONEditorCardCell` on reuse.
    var onTap: (() -> Void)?

    /// Keeps the card on screen even when the text isn't JSON — for rows where
    /// it is the only entry point to the editor.
    var alwaysVisible = false

    /// Appends a truncated excerpt of the text, for call sites that don't show
    /// the raw payload anywhere else.
    var showsPreview = false

    var cardTitle: String = "Edit as JSON" {
        didSet { titleLabel.text = cardTitle }
    }

    var detailText: String = "Open the tree editor to add, rename, retype or reorder fields." {
        didSet { detailLabel.text = detailText }
    }

    // MARK: - Views

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let detailLabel = UILabel()
    private let previewLabel = UILabel()
    private let chevron = UIImageView()
    private let content = UIStackView()

    /// Collapses the card to nothing when hidden. `isHidden` alone is enough
    /// inside a `UIStackView`, but not when the card is pinned inside a cell's
    /// contentView — there the constraints would keep reserving the height.
    private lazy var collapseConstraint = heightAnchor.constraint(equalToConstant: 0)

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = DebugTheme.accentColor.withAlphaComponent(0.12)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DebugTheme.accentColor.withAlphaComponent(0.38).cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.image = UIImage(systemName: "curlybraces", withConfiguration: cfg)
        iconView.tintColor = DebugTheme.accentColor
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.text = cardTitle
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryLabel.font = .systemFont(ofSize: 11, weight: .bold)
        summaryLabel.textColor = DebugTheme.accentColor
        summaryLabel.textAlignment = .right
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.8
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        detailLabel.text = detailText
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = UIColor(white: 0.55, alpha: 1)
        detailLabel.numberOfLines = 0

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = UIColor(white: 0.72, alpha: 1)
        previewLabel.numberOfLines = 2
        previewLabel.isHidden = true

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        chevron.tintColor = DebugTheme.accentColor.withAlphaComponent(0.8)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, summaryLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let textColumn = UIStackView(arrangedSubviews: [titleRow, detailLabel, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 3

        content.axis = .horizontal
        content.spacing = 10
        content.alignment = .center
        content.addArrangedSubview(iconView)
        content.addArrangedSubview(textColumn)
        content.addArrangedSubview(chevron)
        content.isUserInteractionEnabled = false          // taps belong to the card
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // Pinned top AND bottom so the card self-sizes inside a cell. Dropped to
        // 999 so the required collapse constraint can win when hidden without
        // Auto Layout reporting an unsatisfiable set.
        let top = content.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        let bottom = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        top.priority = .init(999)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            top, bottom,
            iconView.widthAnchor.constraint(equalToConstant: 22),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        forceLTR()
    }

    // MARK: - Refresh

    /// Re-reads the text and shows, hides or relabels the card accordingly.
    /// Returns whether the card ended up visible, so table-driven call sites can
    /// keep their row counts in step.
    @discardableResult
    func configure(text: String?) -> Bool {
        let summary = Self.summary(for: text)
        let isJSON = summary != nil
        summaryLabel.text = summary ?? Self.fallbackSummary(for: text)
        summaryLabel.textColor = isJSON ? DebugTheme.accentColor : UIColor(white: 0.5, alpha: 1)

        if showsPreview, let preview = Self.preview(for: text) {
            previewLabel.text = preview
            previewLabel.isHidden = false
        } else {
            previewLabel.text = nil
            previewLabel.isHidden = true
        }

        setVisible(isJSON || alwaysVisible)
        return !isHidden
    }

    private func setVisible(_ visible: Bool) {
        isHidden = !visible
        collapseConstraint.isActive = !visible
    }

    // MARK: - Interaction

    @objc private func handleTap() { onTap?() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

// MARK: - Cell wrapper

/// Hosts a `JSONEditorCardView` as a table row, for the screens whose editors are
/// row-based (mock response, paused breakpoint) rather than free-form.
final class JSONEditorCardCell: UITableViewCell {

    static let reuseIdentifier = "JSONEditorCard"

    let cardView = JSONEditorCardView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A stale closure here would edit whichever payload the cell used to show.
        cardView.onTap = nil
        cardView.alwaysVisible = false
        cardView.showsPreview = false
        cardView.cardTitle = "Edit as JSON"
        cardView.detailText = "Open the tree editor to add, rename, retype or reorder fields."
        cardView.configure(text: nil)
    }
}
