//
//  JSONNodeCell.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - Sizing / routing rules

/// The pure rules behind inline value editing: how tall the field should be for
/// a given amount of text, and whether a value is better edited on its own page.
///
/// Deliberately free of any view state so both decisions are unit-testable
/// without a table view — the height math is what stops a growing row from
/// pushing itself off the screen, so it's worth pinning down in tests.
enum JSONInlineEditMetrics {

    /// Roughly three lines of the editor font plus its text container insets.
    /// Deliberately generous: a one-line box is technically enough to type in
    /// but leaves no room to read what you are editing, which is the complaint
    /// this whole inline mode exists to answer.
    static let minHeight: CGFloat = 92

    /// Past this the field stops growing and scrolls internally, so a long value
    /// can never make the row taller than the gap above the keyboard.
    static let maxHeight: CGFloat = 260

    /// Values longer than this open on their own page instead of inline. Raised
    /// alongside the taller field — what used to overflow a 150pt box now fits.
    static let fullPageCharacterThreshold = 400

    /// Values with at least this many lines open on their own page.
    static let fullPageLineThreshold = 8

    /// The inline field's height for a measured content height, clamped into
    /// `[minHeight, maxHeight]`. Rounded up so a partially-filled line never
    /// clips its descenders.
    static func clampedHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        guard contentHeight.isFinite, contentHeight > 0 else { return minHeight }
        return min(max(contentHeight.rounded(.up), minHeight), maxHeight)
    }

    /// True once the content no longer fits the tallest allowed field — from
    /// here the field scrolls its own text instead of the row growing further.
    static func scrollsInternally(contentHeight: CGFloat) -> Bool {
        contentHeight.isFinite && contentHeight > maxHeight
    }

    /// Number of lines in `text` (a trailing newline opens a new, empty line).
    static func lineCount(of text: String) -> Int {
        text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    /// Only scalars you actually type are edited inline; bool/null/containers
    /// need the type switcher or the tree.
    static func isInlineEditable(_ kind: JSONValueKind) -> Bool {
        kind == .string || kind == .number
    }

    /// Should this value skip the inline field and go straight to the full-page
    /// editor? Long or multi-line text is miserable in a row, however tall.
    static func prefersFullPage(text: String, kind: JSONValueKind) -> Bool {
        guard isInlineEditable(kind) else { return true }
        if text.count > fullPageCharacterThreshold { return true }
        return lineCount(of: text) >= fullPageLineThreshold
    }
}

// MARK: - Cell

/// One node row in the JSON tree editor: indent guide, disclosure chevron for
/// containers, key, type badge, and a value preview.
///
/// Scalar rows can also be edited **in place**: the preview swaps for a
/// multi-line `UITextView` that grows with its content up to
/// `JSONInlineEditMetrics.maxHeight` and then scrolls. The cell only measures
/// and reports its height — the table view owns re-measuring the row, and the
/// controller owns the text, so a recycled cell never carries an edit with it.
///
/// Content is pinned to BOTH the top and bottom of `contentView` so the text
/// drives the row height — stock cell labels don't self-size with
/// `automaticDimension` and silently collapse.
final class JSONNodeCell: UITableViewCell {

    /// What the controller hands over when a row is being edited inline.
    struct EditingState {
        let text: String
        /// The height the field last measured, so a cell that scrolled away and
        /// came back is restored at the same size instead of snapping to one line.
        let height: CGFloat?
        let kind: JSONValueKind
    }

    var onDisclosureTapped: (() -> Void)?
    /// "Edit this value on its own page."
    var onExpandTapped: (() -> Void)?
    /// Live text while editing inline. The document is written on commit, not
    /// per keystroke — a mutation re-flattens the tree and would kill the caret.
    var onTextChanged: ((String) -> Void)?
    /// The field grew or shrank; the table needs to re-measure this row.
    var onHeightChanged: ((CGFloat) -> Void)?
    /// The field resigned first responder — commit the text.
    var onEditingEnded: ((String) -> Void)?

    private let card = UIView()
    private let disclosure = UIButton(type: .system)
    private let keyLabel = UILabel()
    private let badge = JSONTypeBadge()
    private let previewLabel = UILabel()
    private let indentGuide = UIView()
    private let expandButton = UIButton(type: .system)
    private let valueEditor = UITextView()

    private var indentConstraint: NSLayoutConstraint!
    private var disclosureWidth: NSLayoutConstraint!
    private var editorHeightConstraint: NSLayoutConstraint!

    /// True while this cell is showing the inline field.
    private(set) var isEditingValue = false
    /// True while the caret is actually in this cell's field. A cell that was
    /// recycled while editing still shows the field but has lost the keyboard.
    var isValueEditorFocused: Bool { valueEditor.isFirstResponder }
    /// Width the field was last measured at, so layout re-measures only on a
    /// real width change instead of looping.
    private var measuredWidth: CGFloat = 0
    /// Set while the controller resigns the field itself — no commit callback.
    private var suppressEndCallback = false

    private static let indentPerLevel: CGFloat = 14
    private static let maxIndent: CGFloat = 8 * indentPerLevel

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = UIColor(white: 0.125, alpha: 1)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // Vertical hairline showing nesting depth.
        indentGuide.backgroundColor = UIColor(white: 0.26, alpha: 1)
        indentGuide.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(indentGuide)

        disclosure.tintColor = DebugTheme.accentColor
        disclosure.addTarget(self, action: #selector(disclosureTapped), for: .touchUpInside)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(disclosure)

        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = DebugTheme.accentColor
        keyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        previewLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewLabel.textColor = UIColor(white: 0.82, alpha: 1)
        previewLabel.numberOfLines = 2

        // The always-visible way into the full-page editor for a scalar row.
        let expandConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                      withConfiguration: expandConfig), for: .normal)
        expandButton.tintColor = DebugTheme.accentColor
        expandButton.accessibilityLabel = "Edit on its own page"
        expandButton.setContentHuggingPriority(.required, for: .horizontal)
        expandButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)

        setupValueEditor()

        let topRow = UIStackView(arrangedSubviews: [keyLabel, badge, UIView(), expandButton])
        topRow.axis = .horizontal
        topRow.spacing = 6
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, previewLabel, valueEditor])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        indentConstraint = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        disclosureWidth = disclosure.widthAnchor.constraint(equalToConstant: 26)
        editorHeightConstraint = valueEditor.heightAnchor.constraint(
            equalToConstant: JSONInlineEditMetrics.minHeight)

        NSLayoutConstraint.activate([
            indentConstraint,
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            indentGuide.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            indentGuide.topAnchor.constraint(equalTo: card.topAnchor),
            indentGuide.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            indentGuide.widthAnchor.constraint(equalToConstant: 2),

            disclosure.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            // Containers never grow an inline field, so centring stays correct.
            disclosure.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            disclosureWidth,
            disclosure.heightAnchor.constraint(equalToConstant: 30),

            expandButton.widthAnchor.constraint(equalToConstant: 30),
            expandButton.heightAnchor.constraint(equalToConstant: 26),
            editorHeightConstraint,

            // Text drives the height.
            stack.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupValueEditor() {
        valueEditor.isHidden = true
        // Always scrollable: toggling `isScrollEnabled` mid-edit makes the caret
        // jump. The height constraint is what limits growth instead.
        valueEditor.isScrollEnabled = true
        valueEditor.alwaysBounceVertical = false
        valueEditor.showsHorizontalScrollIndicator = false
        valueEditor.backgroundColor = UIColor(white: 0.07, alpha: 1)
        valueEditor.textColor = UIColor(white: 0.95, alpha: 1)
        valueEditor.tintColor = DebugTheme.accentColor
        valueEditor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        valueEditor.layer.cornerRadius = 10
        valueEditor.layer.cornerCurve = .continuous
        valueEditor.layer.borderWidth = 1
        valueEditor.layer.borderColor = DebugTheme.accentColor.withAlphaComponent(0.55).cgColor
        valueEditor.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        valueEditor.textContainer.lineFragmentPadding = 0
        valueEditor.autocapitalizationType = .none
        valueEditor.autocorrectionType = .no
        valueEditor.spellCheckingType = .no
        valueEditor.delegate = self
        valueEditor.inputAccessoryView = makeAccessoryBar()
    }

    /// Keyboard bar: the second, unmissable route to the full-page editor, plus
    /// a Done that commits (Return types a newline — this is a multi-line field).
    private func makeAccessoryBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        bar.autoresizingMask = [.flexibleWidth]
        bar.barStyle = .black
        bar.isTranslucent = false
        bar.barTintColor = UIColor(white: 0.10, alpha: 1)
        bar.tintColor = DebugTheme.accentColor
        let expand = UIBarButtonItem(title: "Full Editor", style: .plain,
                                     target: self, action: #selector(expandTapped))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done,
                                   target: self, action: #selector(doneTapped))
        bar.items = [expand, flex, done]
        bar.semanticContentAttribute = .forceLeftToRight
        return bar
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.125, alpha: 1)
        }
    }

    @objc private func disclosureTapped() { onDisclosureTapped?() }
    @objc private func expandTapped() { onExpandTapped?() }
    @objc private func doneTapped() { valueEditor.resignFirstResponder() }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Clear callbacks BEFORE resigning: a recycled cell must not commit an
        // edit on behalf of the row it used to show.
        onDisclosureTapped = nil
        onExpandTapped = nil
        onTextChanged = nil
        onHeightChanged = nil
        onEditingEnded = nil
        endValueEditingSilently()
        keyLabel.text = nil
        previewLabel.text = nil
        // The badge is the one visual not reset here: an unconfigured dequeue
        // would show blank text beside the previous row's type.
        badge.set(kind: .null)
        expandButton.isHidden = true
    }

    // MARK: - Configuration

    func configure(label: String, preview: String, kind: JSONValueKind, depth: Int,
                   isContainer: Bool, isExpanded: Bool, childCount: Int,
                   editing: EditingState? = nil) {
        indentConstraint.constant = 10 + min(CGFloat(depth) * Self.indentPerLevel, Self.maxIndent)
        indentGuide.isHidden = (depth == 0)

        keyLabel.text = label
        badge.set(kind: kind)
        // Containers are edited in the tree, never on the value page.
        expandButton.isHidden = isContainer

        if isContainer {
            let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            let symbol = isExpanded ? "chevron.down" : "chevron.right"
            disclosure.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            disclosure.isHidden = false
            disclosureWidth.constant = 26
            previewLabel.text = "\(childCount) \(kind == .array ? "item" : "key")\(childCount == 1 ? "" : "s")"
            previewLabel.textColor = UIColor(white: 0.5, alpha: 1)
        } else {
            disclosure.setImage(nil, for: .normal)
            disclosure.isHidden = true
            disclosureWidth.constant = 4
            previewLabel.text = preview
            previewLabel.textColor = (kind == .null)
                ? UIColor(white: 0.45, alpha: 1)
                : UIColor(white: 0.82, alpha: 1)
        }

        if let editing, !isContainer {
            applyEditing(editing)
        } else {
            clearEditingChrome()
        }
    }

    private func applyEditing(_ state: EditingState) {
        isEditingValue = true
        previewLabel.isHidden = true
        valueEditor.isHidden = false
        if valueEditor.text != state.text { valueEditor.text = state.text }
        valueEditor.keyboardType = (state.kind == .number) ? .numbersAndPunctuation : .default
        editorHeightConstraint.constant = state.height ?? JSONInlineEditMetrics.minHeight
        measuredWidth = 0   // force a re-measure at the next layout pass
    }

    private func clearEditingChrome() {
        isEditingValue = false
        previewLabel.isHidden = false
        valueEditor.isHidden = true
        if !valueEditor.text.isEmpty { valueEditor.text = "" }
        editorHeightConstraint.constant = JSONInlineEditMetrics.minHeight
        measuredWidth = 0
    }

    // MARK: - Inline editing

    /// Puts the caret at the end of the inline field and reports its measured
    /// height, so the controller can grow the row before the keyboard lands.
    func focusValueEditor() {
        guard isEditingValue else { return }
        layoutIfNeeded()
        updateEditorHeight(notify: true, force: true)
        valueEditor.becomeFirstResponder()
        let end = (valueEditor.text as NSString).length
        valueEditor.selectedRange = NSRange(location: end, length: 0)
    }

    /// Resigns and returns to preview WITHOUT firing `onEditingEnded` — the
    /// controller calls this when it is already committing, so the commit can't
    /// re-enter itself.
    func endValueEditingSilently() {
        suppressEndCallback = true
        if valueEditor.isFirstResponder { valueEditor.resignFirstResponder() }
        suppressEndCallback = false
        clearEditingChrome()
    }

    /// Keeps the caret visible after the row has been re-measured.
    func scrollCaretToVisible() {
        guard isEditingValue else { return }
        valueEditor.scrollRangeToVisible(valueEditor.selectedRange)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isEditingValue else { return }
        // First real width (or a rotation): size the field silently. Notifying
        // from here would re-enter layout.
        let width = valueEditor.bounds.width
        guard width > 0, abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        updateEditorHeight(notify: false)
    }

    /// `force` reports the measured height even when the constraint didn't move.
    /// `focusValueEditor` needs that: its `layoutIfNeeded()` makes `layoutSubviews`
    /// apply the constant first, so the notifying call would otherwise take the
    /// early return and leave the controller believing the row is still one line —
    /// clipping a multi-line value until the first keystroke corrected it.
    private func updateEditorHeight(notify: Bool, force: Bool = false) {
        let width = valueEditor.bounds.width
        guard width > 0 else { return }
        let content = valueEditor.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let target = JSONInlineEditMetrics.clampedHeight(forContentHeight: content)
        let moved = abs(target - editorHeightConstraint.constant) > 0.5
        guard moved || force else { return }
        editorHeightConstraint.constant = target
        if notify { onHeightChanged?(target) }
    }
}

// MARK: - Inline field delegate

extension JSONNodeCell: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        onTextChanged?(textView.text ?? "")
        updateEditorHeight(notify: true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard !suppressEndCallback else { return }
        onEditingEnded?(textView.text ?? "")
    }
}

// MARK: - Type badge

/// Small colored pill showing a node's JSON type.
final class JSONTypeBadge: UILabel {

    private let inset = UIEdgeInsets(top: 1.5, left: 6, bottom: 1.5, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 8.5, weight: .heavy)
        layer.cornerRadius = 4
        clipsToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        semanticContentAttribute = .forceLeftToRight
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(kind: JSONValueKind) {
        text = kind.badge
        let color: UIColor
        switch kind {
        case .object: color = UIColor(red: 0.55, green: 0.72, blue: 1.0, alpha: 1)
        case .array:  color = UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1)
        case .string: color = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        case .number: color = UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
        case .bool:   color = UIColor(red: 0.95, green: 0.60, blue: 0.45, alpha: 1)
        case .null:   color = UIColor(white: 0.55, alpha: 1)
        }
        textColor = color
        backgroundColor = color.withAlphaComponent(0.18)
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}
