//
//  JSONEditorViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A mobile-first JSON editor with two modes:
///
/// **Tree** — every node is a tappable row (key, value preview, type badge).
/// Containers collapse. Each row has a full action menu: edit, rename, change
/// type, duplicate, add child, delete, copy. Arrays get first-class treatment:
/// "Add item" builds an element of the same type as the ones already there —
/// all the way down for an object — names that type in the menu so you can see
/// what you are about to get, and offers a different type when the guess isn't
/// what you wanted. Duplicate/reorder are one tap.
///
/// **Raw** — the whole document as text with live validation, format/minify and
/// paste, for when you'd rather type or paste a payload wholesale.
///
/// All edits go through `JSONDocument`, which owns undo/redo and is unit-tested,
/// so the UI can't corrupt the payload.
final class JSONEditorViewController: UIViewController {

    // MARK: - Public

    /// Called with the edited JSON when the user taps Save.
    var onSave: ((_ document: JSONDocument) -> Void)?
    /// Shown as the save button title (e.g. "Save", "Use Response").
    var saveButtonTitle: String = "Save"

    /// Set to turn the tree into a **value picker**: tapping any row returns its
    /// path and pops, instead of opening an editor.
    ///
    /// This is how a response rewrite gets its path without anyone typing
    /// `data.items[*].url` by hand — you tap the value you can already see.
    /// Assigning it also hides Save and the editing affordances, because a
    /// picker that silently let you mutate the sample body would be a trap.
    var onPickPath: ((JSONPath) -> Void)?

    private var isPicking: Bool { onPickPath != nil }

    /// Offered on every scalar row when set, so a rewrite can be authored from
    /// the response you are looking at rather than from the rules screen.
    var onRequestRewrite: ((JSONPath) -> Void)?

    private let document: JSONDocument
    private let editorTitle: String

    /// Set when this editor was opened on text that is **not** JSON — a paused
    /// HTML response, a form body, a stack trace. `JSONDocument` cannot hold it,
    /// so the editor opens in Raw showing these exact bytes.
    ///
    /// The old fallback to `JSONDocument.empty()` meant opening such a body
    /// replaced it with `{}` before a single key was touched, and Save then
    /// handed the host app `{}` in place of the real payload. An empty object is
    /// never a safe stand-in for someone's data.
    private let unparsedText: String?

    private init(document: JSONDocument, unparsedText: String?, title: String) {
        self.document = document
        self.unparsedText = unparsedText
        self.editorTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(document: JSONDocument, title: String = "Edit JSON") {
        self.init(document: document, unparsedText: nil, title: title)
    }

    /// Convenience: start from text. Empty or absent text starts an empty object
    /// ("type my own"); text that is real but isn't JSON is kept verbatim and
    /// opened in Raw.
    convenience init(text: String?, title: String = "Edit JSON") {
        if let text, let parsed = JSONDocument(text: text) {
            self.init(document: parsed, unparsedText: nil, title: title)
            return
        }
        let isBlank = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.init(document: .empty(), unparsedText: isBlank ? nil : text, title: title)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Modes

    private enum Mode: Int { case tree, raw }
    private var mode: Mode = .tree

    // MARK: - UI

    private let modeControl = UISegmentedControl(items: ["Tree", "Raw"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let rawTextView = UITextView()
    private let statusBar = UIView()
    private let statusLabel = UILabel()
    private var toolbar: UIToolbar!

    // MARK: - Tree state

    private struct Row {
        let path: JSONPath
        let label: String          // "name" or "[0]"
        let kind: JSONValueKind
        let depth: Int
        let isContainer: Bool
        let isExpanded: Bool
        let preview: String
        let childCount: Int
    }

    private var rows: [Row] = []
    /// Collapsed container paths (by display string).
    private var collapsed = Set<String>()
    private var filterText = ""

    // MARK: - Inline editing state
    //
    // Keyed by PATH, never by row index: every mutation re-flattens the tree and
    // cells are reused, so an index would point at the wrong node a moment later.

    /// The node currently being edited in place, if any.
    private var editingPath: JSONPath?
    /// Live text for that node. The document is only written on commit — writing
    /// per keystroke would reload the table and kill the caret.
    private var editingDraft = ""
    /// Height the inline field last measured, so a cell that scrolls away and
    /// comes back is restored at the same size.
    private var editingHeight: CGFloat?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = editorTitle
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.sizeToFit()
        navigationItem.titleView = titleLabel

        // No Save in picker mode: the sample body is a reference, not something
        // to edit, and offering Save would imply the edit went somewhere.
        if !isPicking {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: saveButtonTitle, style: .done, target: self, action: #selector(saveTapped))
            navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        }
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        setupModeControl()
        setupTable()
        setupRawEditor()
        setupStatusBar()
        setupToolbar()
        layout()
        showUnparsedTextIfAny()

        document.onChange = { [weak self] in
            self?.documentChanged()
        }
        observeKeyboard()
        rebuildRows()
        updateStatus()
        view.forceLTR()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the screen (Save, back, or pushing the value page) must not
        // drop what's in the inline field.
        commitInlineEdit()
    }

    // MARK: - Setup

    /// A body the tree cannot represent opens in Raw, holding the original text.
    /// Tree stays reachable but `modeChanged` refuses it (with the parse error)
    /// until the text is valid, and `saveTapped` refuses for the same reason —
    /// so the app is never handed a document that isn't what's on screen.
    private func showUnparsedTextIfAny() {
        guard let unparsedText else { return }
        mode = .raw
        modeControl.selectedSegmentIndex = Mode.raw.rawValue
        rawTextView.text = unparsedText
        tableView.isHidden = true
        rawTextView.isHidden = false
    }

    private func setupModeControl() {
        modeControl.selectedSegmentIndex = 0
        modeControl.selectedSegmentTintColor = DebugTheme.accentColor
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.65, alpha: 1),
                                            .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                            .font: UIFont.systemFont(ofSize: 12, weight: .bold)], for: .selected)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)
    }

    private func setupTable() {
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(JSONNodeCell.self, forCellReuseIdentifier: "Node")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.keyboardDismissMode = .interactive
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
    }

    private func setupRawEditor() {
        rawTextView.backgroundColor = .black
        rawTextView.textColor = UIColor(white: 0.9, alpha: 1)
        rawTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        rawTextView.autocapitalizationType = .none
        rawTextView.autocorrectionType = .no
        rawTextView.spellCheckingType = .no
        rawTextView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        rawTextView.delegate = self
        rawTextView.isHidden = true
        rawTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rawTextView)
    }

    private func setupStatusBar() {
        statusBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 6),
            statusLabel.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: -6),
        ])
    }

    private func setupToolbar() {
        toolbar = UIToolbar()
        toolbar.barStyle = .black
        toolbar.isTranslucent = false
        toolbar.barTintColor = UIColor(white: 0.10, alpha: 1)
        toolbar.tintColor = DebugTheme.accentColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        refreshToolbar()
    }

    private func refreshToolbar() {
        func item(_ symbol: String, _ action: Selector, enabled: Bool = true) -> UIBarButtonItem {
            let i = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
            i.isEnabled = enabled
            return i
        }
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbar.items = [
            item("plus.circle", #selector(addRootChildTapped)),
            flex,
            item("doc.on.clipboard", #selector(pasteTapped)),
            flex,
            item("wand.and.stars", #selector(formatTapped)),
            flex,
            item("arrow.uturn.backward", #selector(undoTapped), enabled: document.canUndo),
            flex,
            item("arrow.uturn.forward", #selector(redoTapped), enabled: document.canRedo),
        ]
    }

    private func layout() {
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            modeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            modeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            modeControl.heightAnchor.constraint(equalToConstant: 32),

            statusBar.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            rawTextView.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            rawTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rawTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rawTextView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Mode

    @objc private func modeChanged() {
        // Commit before the raw text is rendered, or the draft is lost.
        commitInlineEdit()
        let newMode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .tree
        // Leaving raw: commit the text if it parses, otherwise refuse to switch.
        if mode == .raw, newMode == .tree {
            let result = JSONDocument.validate(rawTextView.text)
            guard result.isValid, let parsed = JSONDocument(text: rawTextView.text) else {
                modeControl.selectedSegmentIndex = Mode.raw.rawValue
                showAlert("Invalid JSON", result.error ?? "Fix the JSON before switching to Tree.")
                return
            }
            document.setValue(parsed.root, at: [])
        }
        // Going to Raw with a document that cannot be written as text would
        // render an EMPTY text view over a body that is still there — see
        // `renderedText(of:)`.
        var rawRender: String?
        if newMode == .raw {
            guard let text = renderedText(of: document) else {
                modeControl.selectedSegmentIndex = Mode.tree.rawValue
                showAlert("Can't show this as text",
                          unrepresentableReason(of: document)
                            + "\n\nRaw mode would show an empty document. Fix that value in the tree first.")
                return
            }
            rawRender = text
        }
        mode = newMode
        tableView.isHidden = (mode != .tree)
        rawTextView.isHidden = (mode != .raw)
        if let rawRender { rawTextView.text = rawRender }
        if mode == .tree { rebuildRows() }
        updateStatus()
        view.endEditing(true)
    }

    private func documentChanged() {
        if mode == .tree {
            rebuildRows()
        } else if let text = renderedText(of: document) {
            // Only overwrite with text the document can actually produce.
            // `prettyText()` answers "" for one it cannot, which used to wipe
            // the text view and take the body off screen with it.
            rawTextView.text = text
        }
        refreshToolbar()
        updateStatus()
    }

    /// The document as JSON text, or nil when it holds a value JSON cannot
    /// express.
    ///
    /// **Not a theoretical state.** `JSONSerialization` PARSES a negative
    /// literal that overflows a `Double` — `{"balance":-2e308}`, valid JSON that
    /// a backend really can emit — and hands back `-infinity`. JSON has no way
    /// to write that back, so `JSONTextWriter` throws and `prettyText()`
    /// answers `""`.
    ///
    /// Every path that took that `""` at face value did real damage: Raw mode
    /// showed an empty document (and then refused to switch back, because `""`
    /// is not valid JSON), and `onSave` handed `""` to callers that write it
    /// straight into a mock body or a held request/response — so the host app
    /// was served an EMPTY body with nothing on screen saying so.
    ///
    /// Costs exactly one serialisation, the same one the caller needed anyway.
    private func renderedText(of document: JSONDocument) -> String? {
        let text = document.prettyText()
        return text.isEmpty ? nil : text
    }

    /// The sentence to show when `renderedText(of:)` came back nil. Only asked
    /// for on that path, so the extra pass is never on the editing hot path.
    private func unrepresentableReason(of document: JSONDocument) -> String {
        document.serializationProblem() ?? "This document holds a value JSON cannot represent."
    }

    private func updateStatus() {
        if mode == .raw {
            let result = JSONDocument.validate(rawTextView.text)
            statusLabel.text = result.isValid ? "Valid JSON" : "Invalid: \(result.error ?? "")"
            statusLabel.textColor = result.isValid ? DebugTheme.accentColor : .systemRed
        } else {
            let kind = JSONValueKind.of(document.root)
            var summary = "\(kind.badge)"
            if let arr = document.root as? [Any] { summary += " · \(arr.count) items" }
            if let obj = document.root as? [String: Any] { summary += " · \(obj.count) keys" }
            summary += " · \(rows.count) rows"
            statusLabel.text = summary
            statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        }
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = view.convert(end, from: nil)
        applyKeyboardOverlap(max(0, tableView.frame.maxY - keyboard.minY))
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        applyKeyboardOverlap(0)
    }

    /// Insets the scrollers so the edited row can sit above the keyboard rather
    /// than under it.
    private func applyKeyboardOverlap(_ overlap: CGFloat) {
        tableView.contentInset.bottom = overlap
        tableView.verticalScrollIndicatorInsets.bottom = overlap
        rawTextView.contentInset.bottom = overlap
        rawTextView.verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0, editingPath != nil { scrollEditingRowIntoView(animated: true) }
    }

    // MARK: - Inline value editing

    /// Starts editing `path` in place. The cell must be on screen to take first
    /// responder, so the row is scrolled in and laid out first.
    private func beginInlineEdit(at path: JSONPath) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        let indexPath = IndexPath(row: index, section: 0)

        editingPath = path
        editingDraft = JSONInlineValueCoder.text(for: document.value(at: path))
        editingHeight = nil
        // Dragging must not yank the keyboard away mid-edit.
        tableView.keyboardDismissMode = .none

        tableView.scrollToRow(at: indexPath, at: .none, animated: false)
        tableView.layoutIfNeeded()
        guard let cell = tableView.cellForRow(at: indexPath) as? JSONNodeCell else {
            // Couldn't get a live cell — fall back to the full page rather than
            // leaving the row stuck in a half-editing state.
            finishInlineEditing()
            editValue(at: path)
            return
        }
        configure(cell, with: rows[index])
        // Grow the row for the field BEFORE focusing, so the keyboard animates
        // in against a row that's already its final size.
        applyRowHeightChange()
        cell.focusValueEditor()
        scrollEditingRowIntoView(animated: true)
    }

    /// The inline field grew or shrank: re-measure the row without reloading it
    /// (a reload would destroy the cell and with it the first responder).
    private func inlineEditorHeightChanged(_ height: CGFloat) {
        editingHeight = height
        applyRowHeightChange()
        scrollEditingRowIntoView(animated: false)
        editingCell()?.scrollCaretToVisible()
    }

    /// `performBatchUpdates(nil)` re-asks visible cells for their height and
    /// keeps first responder. The offset is pinned around it because rows above
    /// the viewport still carry estimated heights and would otherwise shift.
    private func applyRowHeightChange() {
        let offset = tableView.contentOffset
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil)
        }
        let inset = tableView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, tableView.contentSize.height + inset.bottom - tableView.bounds.height)
        let clamped = min(max(offset.y, minY), maxY)
        if abs(tableView.contentOffset.y - clamped) > 0.5 {
            tableView.setContentOffset(CGPoint(x: offset.x, y: clamped), animated: false)
        }
    }

    /// Keeps the edited row visible above the keyboard. A row taller than the
    /// gap is aligned to its bottom, where the caret is.
    private func scrollEditingRowIntoView(animated: Bool) {
        guard let index = editingRowIndex() else { return }
        let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
        guard !rect.isNull, rect.height > 0 else { return }
        let inset = tableView.adjustedContentInset
        let visibleHeight = tableView.bounds.height - inset.top - inset.bottom
        guard visibleHeight > 0 else { return }

        var target = rect.insetBy(dx: 0, dy: -8)
        if target.height > visibleHeight {
            target = CGRect(x: target.minX, y: target.maxY - visibleHeight,
                            width: target.width, height: visibleHeight)
        }
        tableView.scrollRectToVisible(target, animated: animated)
    }

    private func editingRowIndex() -> Int? {
        guard let path = editingPath else { return nil }
        return rows.firstIndex(where: { $0.path == path })
    }

    private func editingCell() -> JSONNodeCell? {
        guard let index = editingRowIndex() else { return nil }
        return tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? JSONNodeCell
    }

    /// Writes the inline draft back through the path API and ends editing.
    /// Safe to call when nothing is being edited — every mutating action calls it
    /// first so a pending edit is never lost or applied to the wrong node.
    @discardableResult
    private func commitInlineEdit() -> Bool {
        guard let path = editingPath else { return false }
        let draft = editingDraft
        let kind = document.kind(at: path)
        finishInlineEditing()

        guard let kind, JSONInlineEditMetrics.isInlineEditable(kind) else { return false }
        // Inline edits commit on loss of first responder, not on an explicit Save.
        // Coercing an unparsable number to 0 would therefore let "select all,
        // backspace, tap elsewhere" silently destroy a value — discard instead.
        if kind == .number {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same hole as the rewrite engine: Double("inf") succeeds and then
            // coerces to 0. The coder returns nil for every non-finite spelling.
            guard JSONInlineValueCoder.number(from: trimmed) != nil else { return false }
        }
        // A no-op write would still push an undo entry.
        guard !JSONInlineValueCoder.isUnchanged(draft: draft, current: document.value(at: path)) else {
            return false
        }
        return document.setValue(JSONInlineValueCoder.value(from: draft, kind: kind), at: path)
    }

    /// Tears the editing state down without touching the document.
    private func finishInlineEditing() {
        guard editingPath != nil else { return }
        let cell = editingCell()
        editingPath = nil
        editingDraft = ""
        editingHeight = nil
        tableView.keyboardDismissMode = .interactive
        cell?.endValueEditingSilently()
        applyRowHeightChange()
    }

    // MARK: - Tree building

    private func rebuildRows() {
        var out: [Row] = []
        buildRows(value: document.root, path: [], label: "root", depth: 0, into: &out)
        // The synthetic root row is only useful when the root is a container.
        rows = out
        // The edited node may have been deleted, filtered out, or collapsed away.
        if let path = editingPath, !rows.contains(where: { $0.path == path }) {
            editingPath = nil
            editingDraft = ""
            editingHeight = nil
            tableView.keyboardDismissMode = .interactive
        }
        tableView.reloadData()
    }

    private func buildRows(value: Any, path: JSONPath, label: String, depth: Int, into out: inout [Row]) {
        let kind = JSONValueKind.of(value)
        let isContainer = (kind == .object || kind == .array)
        let expanded = !collapsed.contains(path.display)
        var childCount = 0
        if let dict = value as? [String: Any] { childCount = dict.count }
        if let arr = value as? [Any] { childCount = arr.count }

        // Filter: show a row when it or any descendant matches.
        let matches = filterText.isEmpty || Self.subtree(value, label: label, contains: filterText)
        guard matches else { return }

        out.append(Row(path: path, label: label, kind: kind, depth: depth,
                       isContainer: isContainer, isExpanded: expanded,
                       preview: Self.preview(of: value), childCount: childCount))

        guard isContainer, expanded else { return }

        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                buildRows(value: dict[key]!, path: path + [.key(key)], label: key, depth: depth + 1, into: &out)
            }
        } else if let arr = value as? [Any] {
            for (i, element) in arr.enumerated() {
                buildRows(value: element, path: path + [.index(i)], label: "[\(i)]", depth: depth + 1, into: &out)
            }
        }
    }

    /// Does this node (or anything under it) match the filter?
    private static func subtree(_ value: Any, label: String, contains needle: String) -> Bool {
        if label.range(of: needle, options: .caseInsensitive) != nil { return true }
        switch value {
        case let dict as [String: Any]:
            return dict.contains { subtree($0.value, label: $0.key, contains: needle) }
        case let arr as [Any]:
            return arr.contains { subtree($0, label: "", contains: needle) }
        case let s as String:
            return s.range(of: needle, options: .caseInsensitive) != nil
        case let n as NSNumber:
            return n.stringValue.range(of: needle, options: .caseInsensitive) != nil
        default:
            return false
        }
    }

    /// One-line summary shown on a row.
    private static func preview(of value: Any) -> String {
        switch value {
        case let dict as [String: Any]: return "{ \(dict.count) }"
        case let arr as [Any]:          return "[ \(arr.count) ]"
        case is NSNull:                 return "null"
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let s as String:
            let flat = s.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
        default: return "\(value)"
        }
    }

    // MARK: - Raw text ↔ document

    /// What happened when an action tried to fold the Raw text view into the
    /// document.
    private enum RawCommit { case notNeeded, committed, doesNotParse }

    /// In Raw mode the text view is the truth on screen and `document` is one
    /// step behind — nothing writes the text back until you switch mode or Save.
    /// Every toolbar action works on `document` and then re-renders it into the
    /// text view, so without this each of them silently destroyed everything
    /// typed since the last sync.
    @discardableResult
    private func commitRawText() -> RawCommit {
        guard mode == .raw, rawTextView.text != document.prettyText() else { return .notNeeded }
        guard let parsed = JSONDocument(text: rawTextView.text) else { return .doesNotParse }
        // Goes through the document, so it lands on the undo stack: the typing is
        // recoverable rather than replaced.
        document.setValue(parsed.root, at: [])
        return .committed
    }

    /// Refusing is the only alternative to throwing text away that cannot be
    /// folded in. Say which action stopped and why.
    private func refuseRawAction(_ action: String) {
        let reason = JSONDocument.validate(rawTextView.text).error ?? "The text isn't valid JSON."
        showAlert("Invalid JSON",
                  "\(reason)\n\n\(action) works on the document, so running it would replace what you typed. Your text is untouched — fix the JSON first.")
    }

    // MARK: - Toolbar actions

    // Every mutating action commits the inline draft first: each of these
    // reloads or replaces the tree, which would otherwise strand the edit. In
    // Raw mode the text view is committed for the same reason.
    @objc private func undoTapped() {
        commitInlineEdit()
        guard commitRawText() != .doesNotParse else { refuseRawAction("Undo"); return }
        document.undo()
    }

    @objc private func redoTapped() {
        commitInlineEdit()
        // Committing clears the redo stack, exactly as typing does in any editor:
        // the typed text becomes the newest state instead of being discarded.
        guard commitRawText() != .doesNotParse else { refuseRawAction("Redo"); return }
        document.redo()
    }

    @objc private func formatTapped() {
        commitInlineEdit()
        if mode == .raw {
            guard let parsed = JSONDocument(text: rawTextView.text) else {
                showAlert("Invalid JSON", JSONDocument.validate(rawTextView.text).error ?? "")
                return
            }
            // Formatting must never be able to empty the editor: text that
            // parses can still hold a value JSON cannot write back (see
            // `renderedText(of:)`).
            guard let formatted = renderedText(of: parsed) else {
                showAlert("Can't format", unrepresentableReason(of: parsed) + "\n\nYour text is untouched.")
                return
            }
            rawTextView.text = formatted
            updateStatus()
        } else {
            collapsed.removeAll()
            rebuildRows()
        }
    }

    /// Paste a whole payload from the clipboard — the fast path for "edit the
    /// endpoint's real JSON" or "type my own".
    @objc private func pasteTapped() {
        commitInlineEdit()
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert("Clipboard empty", "Copy some JSON first, then tap paste.")
            return
        }
        guard let parsed = JSONDocument(text: text) else {
            showAlert("Clipboard isn't JSON", JSONDocument.validate(text).error ?? "Could not parse the clipboard.")
            return
        }
        // Parses but cannot be written back: replacing the document with it
        // would leave nothing to render and nothing to save.
        guard renderedText(of: parsed) != nil else {
            showAlert("Clipboard can't be edited",
                      unrepresentableReason(of: parsed) + "\n\nNothing was replaced.")
            return
        }
        // Fold the Raw text in first, so "you can undo" is true of what is on
        // screen. Text that doesn't parse can't go on the undo stack — say it
        // will be lost rather than dropping it without a word.
        let losesTypedText = (commitRawText() == .doesNotParse)
        let confirm = UIAlertController(
            title: "Replace with clipboard?",
            message: losesTypedText
                ? "This replaces the whole document with the JSON on your clipboard.\n\nThe text you typed isn't valid JSON, so it can't go on the undo stack — it will be lost."
                : "This replaces the whole document with the JSON on your clipboard. You can undo.",
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Replace", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.document.setValue(parsed.root, at: [])
            if self.mode == .raw { self.rawTextView.text = self.document.prettyText() }
        })
        present(confirm, animated: true)
    }

    /// Adds a child to the root container.
    @objc private func addRootChildTapped() {
        commitInlineEdit()
        // Without this the new key lands in the document you can't see, and the
        // moment the prompt is answered everything typed in Raw is gone.
        guard commitRawText() != .doesNotParse else { refuseRawAction("Add"); return }
        addChild(toContainerAt: [])
    }

    @objc private func cancelTapped() {
        // Cancel discards the in-progress inline edit along with everything else.
        finishInlineEditing()
        if navigationController?.viewControllers.first === self {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func saveTapped() {
        commitInlineEdit()
        // Commit raw text first if that's the active mode.
        if mode == .raw {
            let result = JSONDocument.validate(rawTextView.text)
            guard result.isValid, let parsed = JSONDocument(text: rawTextView.text) else {
                showAlert("Invalid JSON", result.error ?? "Fix the JSON before saving.")
                return
            }
            document.setValue(parsed.root, at: [])
        }
        // EVERY caller of `onSave` writes `document.prettyText()` somewhere the
        // host app will read it — a mock body, a held request, a held response.
        // A document that cannot be written answers "", so saving it delivered
        // an EMPTY body and said nothing. Refuse, and name the value.
        guard renderedText(of: document) != nil else {
            showAlert("Can't save",
                      unrepresentableReason(of: document)
                        + "\n\nSaving would replace the body with nothing. Fix that value first.")
            return
        }
        view.endEditing(true)
        onSave?(document)
        if navigationController?.viewControllers.first === self {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    // MARK: - Node actions

    /// The action menu for a node, using the custom picker (no truncation).
    private func presentActions(for row: Row) {
        commitInlineEdit()
        var options: [OptionPickerSheetViewController.Option] = []
        let path = row.path
        let isRoot = path.isEmpty
        let parentIsArray: Bool = {
            guard case .index? = path.last else { return false }
            return true
        }()

        if !row.isContainer {
            // Leads the menu when available: editing this value changes it once,
            // rewriting it changes it on every future response. That is usually
            // what you actually wanted after editing the same field twice.
            if let requestRewrite = onRequestRewrite {
                options.append(.init(title: "Rewrite this always\u{2026}",
                                     subtitle: "Change it automatically on every response",
                                     symbol: "wand.and.stars",
                                     tint: DebugTheme.accentColor) {
                    requestRewrite(path)
                })
            }
            options.append(.init(title: "Edit on its own page", subtitle: row.preview,
                                 symbol: "arrow.up.left.and.arrow.down.right",
                                 tint: DebugTheme.accentColor) { [weak self] in
                self?.editValue(at: path)
            })
            if JSONInlineEditMetrics.isInlineEditable(row.kind) {
                options.append(.init(title: "Edit in place", subtitle: "Type right in the row",
                                     symbol: "pencil") { [weak self] in
                    self?.beginInlineEdit(at: path)
                })
            }
        }
        if row.isContainer {
            if row.kind == .array {
                appendAddItemOptions(forArrayAt: path, to: &options)
            } else {
                options.append(.init(title: "Add key", subtitle: nil,
                                     symbol: "plus.circle", tint: DebugTheme.accentColor) { [weak self] in
                    self?.addChild(toContainerAt: path)
                })
            }
        }
        if case .key(let k)? = path.last {
            options.append(.init(title: "Rename key", subtitle: k, symbol: "character.cursor.ibeam") { [weak self] in
                self?.renameKey(at: path, current: k)
            })
        }
        options.append(.init(title: "Change type", subtitle: "Currently \(row.kind.badge)",
                             symbol: "arrow.triangle.2.circlepath") { [weak self] in
            self?.changeType(at: path, current: row.kind)
        })
        if parentIsArray {
            options.append(.init(title: "Duplicate item", subtitle: "Insert a copy right after",
                                 symbol: "plus.square.on.square") { [weak self] in
                self?.document.duplicateElement(at: path)
            })
        }
        options.append(.init(title: "Copy value", subtitle: nil, symbol: "doc.on.doc") { [weak self] in
            guard let self else { return }
            let value = self.document.value(at: path) ?? NSNull()
            let node = JSONDocument(root: value)
            // Writing "" to the pasteboard is worse than not writing: the user
            // pastes an empty body somewhere and has no idea why.
            guard let text = self.renderedText(of: node) else {
                self.showAlert("Can't copy this value", self.unrepresentableReason(of: node))
                return
            }
            UIPasteboard.general.string = text
        })
        options.append(.init(title: "Copy path", subtitle: path.display, symbol: "arrow.triangle.branch") {
            UIPasteboard.general.string = path.display
        })
        if !isRoot {
            options.append(.init(title: "Delete", subtitle: nil, symbol: "trash", tint: .systemRed) { [weak self] in
                self?.document.remove(at: path)
            })
        }

        OptionPickerSheetViewController.present(
            from: self, title: row.label, message: path.display, options: options)
    }

    private func editValue(at path: JSONPath) {
        let current = document.value(at: path)
        let editor = JSONValueEditorViewController(value: current, pathDisplay: path.display)
        editor.onSave = { [weak self] newValue in
            self?.document.setValue(newValue, at: path)
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func renameKey(at path: JSONPath, current: String) {
        promptText(title: "Rename key", message: path.display, initial: current) { [weak self] newKey in
            guard let self else { return }
            if !self.document.renameKey(at: path, to: newKey) {
                self.showAlert("Couldn't rename", "That key already exists (or the name is empty).")
            }
        }
    }

    private func changeType(at path: JSONPath, current: JSONValueKind) {
        let options = JSONValueKind.allCases.map { kind in
            OptionPickerSheetViewController.Option(
                title: kind.badge,
                subtitle: kind == current ? "current" : nil,
                symbol: nil,
                tint: kind == current ? DebugTheme.accentColor : .white
            ) { [weak self] in
                self?.document.changeKind(at: path, to: kind)
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Change type",
            message: "Values are converted where it makes sense (\"42\" → 42).",
            options: options,
            selectedIndex: JSONValueKind.allCases.firstIndex(of: current))
    }

    /// "Add item" for an array, with the type it is about to add spelled out in
    /// the subtitle, plus an escape hatch.
    ///
    /// Both halves matter. Naming the inferred type ("object with 5 keys") is
    /// what lets you see what you are getting before you tap; the escape hatch is
    /// there because wanting one object in an array of strings is a normal thing,
    /// and a menu that can only add what is already there sends you to Raw mode
    /// to type it by hand.
    private func appendAddItemOptions(forArrayAt path: JSONPath,
                                      to options: inout [OptionPickerSheetViewController.Option]) {
        let template = document.arrayElementTemplate(forArrayAt: path)
        options.append(.init(title: "Add item", subtitle: template.summary,
                             symbol: "plus.circle",
                             // A fallback is not an inference: don't dress a guess
                             // up in the same accent colour as a real match.
                             tint: template.isInferred ? DebugTheme.accentColor : nil) { [weak self] in
            self?.appendItem(template.value, toArrayAt: path)
        })
        options.append(.init(title: "Add item of another type\u{2026}",
                             subtitle: "Pick the type yourself instead",
                             symbol: "plus.square") { [weak self] in
            self?.chooseItemType(forArrayAt: path, inferred: template)
        })
    }

    private func chooseItemType(forArrayAt path: JSONPath, inferred: JSONArrayElementTemplate) {
        let suggested = inferred.isInferred ? inferred.kind : nil
        let options = JSONValueKind.allCases.map { kind in
            OptionPickerSheetViewController.Option(
                title: kind.badge,
                subtitle: kind == suggested ? inferred.summary : nil,
                symbol: nil,
                tint: kind == suggested ? DebugTheme.accentColor : .white
            ) { [weak self] in
                // The matching type keeps the shape that was read from the
                // siblings; any other type starts empty, which is the point of
                // asking for a different one.
                self?.appendItem(kind == suggested ? inferred.value : kind.emptyValue, toArrayAt: path)
            }
        }
        OptionPickerSheetViewController.present(
            from: self, title: "Add item", message: path.display, options: options,
            selectedIndex: suggested.flatMap { JSONValueKind.allCases.firstIndex(of: $0) })
    }

    /// Appends through the document's path API — the only way in, so the source
    /// key order and number spelling of everything already there survive.
    private func appendItem(_ value: Any, toArrayAt path: JSONPath) {
        // Expand first: appending fires `onChange`, which rebuilds the tree, and
        // a collapsed array would hide the element that was just added.
        collapsed.remove(path.display)
        document.appendElement(value, toArrayAt: path)
    }

    /// Adds a child to an object (asks for a key) or an array (uses a template
    /// shaped like the existing elements).
    private func addChild(toContainerAt path: JSONPath) {
        guard let kind = document.kind(at: path) else { return }
        switch kind {
        case .object:
            promptText(title: "New key", message: path.display, initial: "") { [weak self] key in
                guard let self else { return }
                if !self.document.addKey(key, value: "", toObjectAt: path) {
                    self.showAlert("Couldn't add", "That key already exists (or the name is empty).")
                } else {
                    // Jump straight into editing the new value.
                    self.editValue(at: path + [.key(key)])
                }
            }
        case .array:
            appendItem(document.templateElement(forArrayAt: path), toArrayAt: path)
        default:
            showAlert("Not a container", "Only objects and arrays can hold children. Change the type first.")
        }
    }

    private func promptText(title: String, message: String, initial: String, completion: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addTextField { tf in
            tf.text = initial
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in
            guard let text = a?.textFields?.first?.text, !text.isEmpty else { return }
            completion(text)
        })
        present(a, animated: true)
    }
}

// MARK: - Table

extension JSONEditorViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Node", for: indexPath) as! JSONNodeCell
        guard rows.indices.contains(indexPath.row) else { return cell }
        configure(cell, with: rows[indexPath.row])
        return cell
    }

    /// One place that dresses a cell, used by `cellForRowAt` and when a row is
    /// switched into editing without a reload (a reload would lose the caret).
    private func configure(_ cell: JSONNodeCell, with row: Row) {
        let path = row.path
        var editing: JSONNodeCell.EditingState?
        if editingPath == path {
            editing = JSONNodeCell.EditingState(text: editingDraft, height: editingHeight, kind: row.kind)
        }
        cell.configure(label: row.label, preview: row.preview, kind: row.kind, depth: row.depth,
                       isContainer: row.isContainer, isExpanded: row.isExpanded,
                       childCount: row.childCount, editing: editing)

        cell.onDisclosureTapped = { [weak self] in
            guard let self else { return }
            self.commitInlineEdit()
            let key = path.display
            if self.collapsed.contains(key) { self.collapsed.remove(key) } else { self.collapsed.insert(key) }
            self.rebuildRows()
        }
        // The expand affordance: commit what's typed, then hand the node to the
        // full-page editor, which writes back through the same path.
        cell.onExpandTapped = { [weak self] in
            guard let self else { return }
            self.commitInlineEdit()
            self.editValue(at: path)
        }
        cell.onTextChanged = { [weak self] text in
            guard let self, self.editingPath == path else { return }
            self.editingDraft = text
        }
        cell.onHeightChanged = { [weak self] height in
            guard let self, self.editingPath == path else { return }
            self.inlineEditorHeightChanged(height)
        }
        cell.onEditingEnded = { [weak self] text in
            guard let self, self.editingPath == path else { return }
            self.editingDraft = text
            self.commitInlineEdit()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        let row = rows[indexPath.row]

        // Picker mode: one tap IS the answer. Containers still expand via their
        // chevron, but picking one is legitimate — a rewrite can target an object.
        if let pick = onPickPath {
            pick(row.path)
            navigationController?.popViewController(animated: true)
            return
        }

        // Tapping a container opens actions (its chevron toggles expansion).
        if row.isContainer {
            presentActions(for: row)
            return
        }
        // Already editing this node: leave the caret alone, unless the cell was
        // recycled out of the table mid-edit and lost the keyboard.
        if editingPath == row.path {
            let cell = tableView.cellForRow(at: indexPath) as? JSONNodeCell
            if let cell, !cell.isValueEditorFocused { cell.focusValueEditor() }
            return
        }

        let path = row.path
        commitInlineEdit()   // may rebuild the tree, so re-resolve by path below
        guard rows.contains(where: { $0.path == path }), let kind = document.kind(at: path) else { return }

        // Long or multi-line values are still better on their own page.
        let text = JSONInlineValueCoder.text(for: document.value(at: path))
        if JSONInlineEditMetrics.prefersFullPage(text: text, kind: kind) {
            editValue(at: path)
        } else {
            beginInlineEdit(at: path)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row) else { return nil }
        let path = rows[indexPath.row].path
        guard !path.isEmpty else { return nil }   // never delete the root

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.commitInlineEdit()
            self?.document.remove(at: path)
            done(true)
        }
        var actions = [delete]

        if case .index? = path.last {
            let dup = UIContextualAction(style: .normal, title: "Duplicate") { [weak self] _, _, done in
                self?.commitInlineEdit()
                self?.document.duplicateElement(at: path)
                done(true)
            }
            dup.backgroundColor = UIColor(red: 0.16, green: 0.50, blue: 0.47, alpha: 1)
            actions.append(dup)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row) else { return nil }
        let row = rows[indexPath.row]
        let more = UIContextualAction(style: .normal, title: "More") { [weak self] _, _, done in
            self?.presentActions(for: row)
            done(true)
        }
        more.backgroundColor = UIColor(white: 0.3, alpha: 1)
        return UISwipeActionsConfiguration(actions: [more])
    }
}

// MARK: - Raw text

extension JSONEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateStatus()
    }
}
