//
//  JSONDocument.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Addresses one node inside a JSON tree.
enum JSONPathComponent: Hashable {
    case key(String)     // into an object
    case index(Int)      // into an array
}

/// A path from the root to a node. An empty path is the root itself.
typealias JSONPath = [JSONPathComponent]

extension Array where Element == JSONPathComponent {
    /// "root.items[2].name" — used for breadcrumbs.
    var display: String {
        var out = "root"
        for c in self {
            switch c {
            case .key(let k):   out += "." + k
            case .index(let i): out += "[\(i)]"
            }
        }
        return out
    }
}

/// The kind of a JSON value, used for type switching in the editor.
enum JSONValueKind: String, CaseIterable {
    case object, array, string, number, bool, null

    static func of(_ value: Any) -> JSONValueKind {
        switch value {
        case is [String: Any]: return .object
        case is [Any]:         return .array
        case is NSNull:        return .null
        case let n as NSNumber:
            // CFBoolean is an NSNumber — distinguish it or `true` shows as 1.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool : .number
        case is String:        return .string
        default:               return .string
        }
    }

    /// A sensible empty value when switching a node to this type.
    var emptyValue: Any {
        switch self {
        case .object: return [String: Any]()
        case .array:  return [Any]()
        case .string: return ""
        case .number: return 0
        case .bool:   return false
        case .null:   return NSNull()
        }
    }

    var badge: String { rawValue.uppercased() }
}

/// Why a document could not be turned back into JSON text.
///
/// These are **thrown**, not raised: `JSONSerialization` reports both of these
/// conditions with an ObjC `NSInvalidArgumentException`, which `try?` cannot
/// catch and which therefore terminates the *host app*. Nothing in this file
/// hands a value to `JSONSerialization`'s writer any more.
enum JSONWriteError: Error, LocalizedError {
    /// `inf` / `-inf` / `nan` — typeable in the value editor, illegal in JSON.
    case nonFiniteNumber(path: String)
    /// Something that is not a JSON type at all (a `Date`, a `URL`, …).
    case unsupportedValue(type: String, path: String)

    var errorDescription: String? {
        switch self {
        case .nonFiniteNumber(let path):
            return "\(path) is infinity or NaN, which JSON cannot represent."
        case .unsupportedValue(let type, let path):
            return "\(path) holds a \(type), which is not a JSON value."
        }
    }
}

/// An editable JSON document with **path-based mutations** and undo/redo.
///
/// The editor UI is deliberately thin over this: every change goes through one
/// of these methods, so behavior is testable without a screen. The tree is kept
/// as plain Foundation JSON (`[String: Any]` / `[Any]` / scalars) so it
/// round-trips through `JSONSerialization` with no conversion step.
///
/// **Serialization does not use `JSONSerialization`'s writer.** See
/// `JSONTextWriter` — Foundation's writer prints `19.99` as
/// `19.989999999999998`, reorders every object key, and kills the process on a
/// non-finite number. All three of those reach the host app through response
/// rewrites, breakpoint edits and mock seeding.
final class JSONDocument {

    private(set) var root: Any

    /// One point in the document's history.
    ///
    /// The tree alone is NOT the document: key order and number spelling live in
    /// `sourceIndex`, and a mutation can change both (rename, add key, any array
    /// mutation). Undoing a tree without its index restored the values but left
    /// the *shape* of the previous edit behind — renaming a key and changing
    /// your mind shipped the host app a key order no server ever produced.
    private struct Snapshot {
        let root: Any
        let index: JSONSourceIndex
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private static let maxUndo = 50

    /// Fires after any mutation (including undo/redo).
    var onChange: (() -> Void)?

    /// The text this document was parsed from, when there was one. It is the
    /// only record of the author's exact number spelling and key order, both of
    /// which are destroyed by parsing into Foundation containers.
    private let sourceText: String?

    /// Source larger than this is not indexed: the index is keyed by path and
    /// would cost more memory than the body itself. Above the cap serialization
    /// still round-trips numbers losslessly (shortest round-trip formatting) —
    /// only the original key order and exotic literals (`1.0e3`) are lost.
    /// `internal` so the coupling with `Data.maxOrderPreservingBytes` can be
    /// asserted by a test — if the byte ceiling ever exceeds this, the printer
    /// asks for source order on a body that has no source index and silently
    /// falls back to sorted keys.
    static let maxIndexedSourceBytes = 2 * 1024 * 1024

    /// Set by the COPY path only. The index ceiling protects the MAIN THREAD;
    /// copy runs off it behind a blocking overlay, and a clipboard whose key
    /// order depends on how big the body happens to be is the defect, not the
    /// protection.
    var indexesSourceRegardlessOfSize = false

    private lazy var sourceIndex: JSONSourceIndex = {
        guard let sourceText else { return JSONSourceIndex() }
        guard indexesSourceRegardlessOfSize
                || sourceText.utf8.count <= Self.maxIndexedSourceBytes else {
            return JSONSourceIndex()
        }
        return JSONSourceIndex(scanning: sourceText)
    }()

    /// True when this document can reproduce untouched values byte-for-byte.
    /// False for documents built straight from a Foundation tree, which have no
    /// record of the original text — worth surfacing rather than assuming.
    var preservesSourceFormatting: Bool { !sourceIndex.isEmpty }

    init(root: Any, sourceText: String? = nil) {
        self.root = root
        self.sourceText = sourceText
    }

    /// Parses text into a document. Accepts objects, arrays and fragments.
    convenience init?(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        self.init(root: obj, sourceText: text)
    }

    /// Parses UTF-8 bytes, keeping them as the formatting reference.
    ///
    /// Prefer this over `init(root:)` when the bytes are in hand (a response
    /// body, a stored mock): it is what lets an edit to one value leave every
    /// other value in the payload spelled exactly as the server spelled it.
    convenience init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    /// An empty object, for "type my own".
    static func empty() -> JSONDocument { JSONDocument(root: [String: Any]()) }

    // MARK: - Serialization

    /// Pretty-printed JSON text (slashes unescaped, original key order).
    /// Empty when the document cannot be represented — ask
    /// `serializationProblem()` for the reason rather than shipping `""`.
    func prettyText(sortKeys: Bool = false) -> String {
        (try? text(pretty: true, sortKeys: sortKeys)) ?? ""
    }

    func minifiedText() -> String {
        (try? text(pretty: false, sortKeys: false)) ?? ""
    }

    func data() -> Data? {
        guard let text = try? text(pretty: false, sortKeys: false) else { return nil }
        return Data(text.utf8)
    }

    /// Nil when the document serialises. Otherwise a sentence explaining why it
    /// does not, so a caller that has to fall back can say so instead of
    /// silently delivering the original bytes.
    func serializationProblem() -> String? {
        do {
            _ = try text(pretty: false, sortKeys: false)
            return nil
        } catch {
            return (error as? JSONWriteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func text(pretty: Bool, sortKeys: Bool) throws -> String {
        let index = sourceIndex
        var writer = JSONTextWriter(pretty: pretty, sortKeys: sortKeys, index: index)
        return try writer.string(from: root)
    }

    // MARK: - Reading

    /// The value at `path`, or nil if the path doesn't resolve.
    func value(at path: JSONPath) -> Any? {
        var current: Any = root
        for component in path {
            switch component {
            case .key(let k):
                guard let dict = current as? [String: Any], let next = dict[k] else { return nil }
                current = next
            case .index(let i):
                guard let arr = current as? [Any], i >= 0, i < arr.count else { return nil }
                current = arr[i]
            }
        }
        return current
    }

    func kind(at path: JSONPath) -> JSONValueKind? {
        value(at: path).map { JSONValueKind.of($0) }
    }

    // MARK: - Mutations

    /// Replaces the value at `path`. An empty path replaces the whole document.
    @discardableResult
    func setValue(_ newValue: Any, at path: JSONPath) -> Bool {
        pushUndo()
        if path.isEmpty {
            root = newValue
            didChange()
            return true
        }
        guard let updated = Self.setting(newValue, at: path, in: root) else {
            undoStack.removeLast()
            return false
        }
        root = updated
        didChange()
        return true
    }

    /// Renames an object key, preserving its position among siblings.
    @discardableResult
    func renameKey(at path: JSONPath, to newKey: String) -> Bool {
        guard case .key(let oldKey)? = path.last, !newKey.isEmpty, newKey != oldKey else { return false }
        let parentPath = Array(path.dropLast())
        guard var parent = value(at: parentPath) as? [String: Any],
              let existing = parent[oldKey],
              parent[newKey] == nil else { return false }   // refuse to clobber
        pushUndo()
        parent.removeValue(forKey: oldKey)
        parent[newKey] = existing
        // Foundation dictionaries are unordered, so "preserving its position"
        // is only true if the recorded order is renamed alongside the value.
        sourceIndex.renameKey(oldKey, to: newKey, inObjectAt: parentPath)
        applyToParent(parent, at: parentPath)
        return true
    }

    /// Removes the node at `path` (object key or array element).
    @discardableResult
    func remove(at path: JSONPath) -> Bool {
        guard let last = path.last else { return false }
        let parentPath = Array(path.dropLast())
        pushUndo()
        switch last {
        case .key(let k):
            guard var parent = value(at: parentPath) as? [String: Any] else { undoStack.removeLast(); return false }
            parent.removeValue(forKey: k)
            applyToParent(parent, at: parentPath)
        case .index(let i):
            guard var parent = value(at: parentPath) as? [Any], i >= 0, i < parent.count else {
                undoStack.removeLast(); return false
            }
            var sources = Array(0..<parent.count)
            parent.remove(at: i)
            sources.remove(at: i)
            // The survivors slid down one slot; their recorded key order and
            // number spelling have to slide with them.
            sourceIndex.reindexArray(at: parentPath, elementSources: sources)
            applyToParent(parent, at: parentPath)
        }
        return true
    }

    /// Adds a key to the object at `path`. Fails if the key already exists.
    @discardableResult
    func addKey(_ key: String, value newValue: Any, toObjectAt path: JSONPath) -> Bool {
        guard !key.isEmpty, var obj = value(at: path) as? [String: Any], obj[key] == nil else { return false }
        pushUndo()
        obj[key] = newValue
        sourceIndex.appendKey(key, toObjectAt: path)   // a new key belongs at the end
        applyToParent(obj, at: path)
        return true
    }

    /// Appends an element to the array at `path`.
    ///
    /// The appended element gets NO recorded key order of its own, so the writer
    /// spells its keys with `keys.sorted()` while its siblings keep the server's
    /// order. That is deliberate and pinned by
    /// `JSONArrayElementTemplateTests.testAppendingTheTemplateAfterAReorderDoesNotBorrowAnyonesKeyOrder`:
    /// there is no non-arbitrary row to borrow an order from once the array has
    /// been reordered, and a deterministic order for new rows beats a borrowed
    /// one. The visible cost is that an added row reads differently from the
    /// rows above it (`{"created_at":"","email":"","first_name":"","id":0}` next
    /// to `{"id":…,"first_name":…,"email":…,"created_at":…}`), which is worth
    /// revisiting if it ever gets reported — but not by borrowing row 0.
    @discardableResult
    func appendElement(_ newValue: Any, toArrayAt path: JSONPath) -> Bool {
        guard var arr = value(at: path) as? [Any] else { return false }
        pushUndo()
        arr.append(newValue)
        // Nothing shifts, but the new slot must not inherit records left behind
        // by a longer array that used to live here (-1 = no previous element).
        sourceIndex.reindexArray(at: path,
                                 elementSources: Array(0..<(arr.count - 1)) + [JSONSourceIndex.newElement])
        applyToParent(arr, at: path)
        return true
    }

    /// Duplicates the array element at `path`, inserting the copy right after it.
    ///
    /// This is the workhorse for editing arrays of objects — the common case is
    /// "give me another one shaped like this one".
    @discardableResult
    func duplicateElement(at path: JSONPath) -> Bool {
        guard case .index(let i)? = path.last else { return false }
        let parentPath = Array(path.dropLast())
        guard var arr = value(at: parentPath) as? [Any], i >= 0, i < arr.count else { return false }
        pushUndo()
        var sources = Array(0..<arr.count)
        arr.insert(arr[i], at: i + 1)
        sources.insert(i, at: i + 1)   // the copy inherits the original's records
        sourceIndex.reindexArray(at: parentPath, elementSources: sources)
        applyToParent(arr, at: parentPath)
        return true
    }

    /// Moves an array element (for drag-to-reorder).
    @discardableResult
    func moveElement(inArrayAt arrayPath: JSONPath, from: Int, to: Int) -> Bool {
        guard var arr = value(at: arrayPath) as? [Any],
              from >= 0, from < arr.count, to >= 0, to < arr.count, from != to else { return false }
        pushUndo()
        var sources = Array(0..<arr.count)
        let item = arr.remove(at: from)
        arr.insert(item, at: to)
        sources.insert(sources.remove(at: from), at: to)
        sourceIndex.reindexArray(at: arrayPath, elementSources: sources)
        applyToParent(arr, at: arrayPath)
        return true
    }

    /// Changes a node's type, preserving what can sensibly be preserved
    /// (e.g. "42" -> 42, true -> "true").
    @discardableResult
    func changeKind(at path: JSONPath, to kind: JSONValueKind) -> Bool {
        let current = value(at: path)
        let converted = Self.convert(current, to: kind)
        return setValue(converted, at: path)
    }

    /// A new element shaped like the array's existing elements — the value only.
    ///
    /// `arrayElementTemplate(forArrayAt:)` returns the same value *and* the words
    /// for it, which is what a menu needs: "Add item" that guesses silently is
    /// worse than one that says what it is about to add.
    func templateElement(forArrayAt path: JSONPath) -> Any {
        arrayElementTemplate(forArrayAt: path).value
    }

    /// What "Add item" will append to the array at `path`, and how it decided.
    ///
    /// An array that says nothing about itself — an empty one — is read from its
    /// siblings where there are any: an empty `tags` sitting in a list of rows
    /// whose other `tags` hold strings is a list of strings, and matching them
    /// beats defaulting to a type nobody asked for. Failing that it falls back to
    /// an empty string and the summary says so.
    func arrayElementTemplate(forArrayAt path: JSONPath) -> JSONArrayElementTemplate {
        guard let array = value(at: path) as? [Any] else { return .emptyArrayFallback }
        guard array.isEmpty else { return JSONArrayShapeReader.template(forElementsOf: array) }
        guard let siblings = siblingArrayElements(for: path), !siblings.isEmpty else {
            return .emptyArrayFallback
        }
        return JSONArrayShapeReader.template(forElementsOf: siblings)
            .adding(note: "this array is empty — matching the other arrays alongside it")
    }

    /// Elements of the arrays that sit alongside the empty array at `path`: its
    /// neighbours in an array of arrays, or the same key on the sibling rows of
    /// an array of objects. Bounded like every other scan here.
    private func siblingArrayElements(for path: JSONPath) -> [Any]? {
        let limit = JSONArrayShapeReader.sampleLimit
        var out: [Any] = []
        func collect(_ candidate: Any?) {
            guard out.count < limit, let array = candidate as? [Any] else { return }
            out.append(contentsOf: array.prefix(limit - out.count))
        }

        switch path.last {
        case .index(let index):
            guard let parent = value(at: Array(path.dropLast())) as? [Any] else { return nil }
            for (offset, element) in parent.prefix(limit).enumerated() where offset != index {
                collect(element)
            }
        case .key(let key):
            // The object holding this key has to be an array element itself,
            // otherwise it has no siblings to compare against.
            let objectPath = Array(path.dropLast())
            guard case .index(let index)? = objectPath.last,
                  let parent = value(at: Array(objectPath.dropLast())) as? [Any] else { return nil }
            for (offset, element) in parent.prefix(limit).enumerated() where offset != index {
                collect((element as? [String: Any])?[key])
            }
        case nil:
            return nil
        }
        return out
    }

    // MARK: - Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(previous)
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(next)
        onChange?()
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func currentSnapshot() -> Snapshot { Snapshot(root: root, index: sourceIndex) }

    private func restore(_ snapshot: Snapshot) {
        root = snapshot.root
        sourceIndex = snapshot.index
    }

    private func didChange() { onChange?() }

    /// Writes a rebuilt container back to its parent (or the root).
    private func applyToParent(_ container: Any, at path: JSONPath) {
        if path.isEmpty {
            root = container
        } else if let updated = Self.setting(container, at: path, in: root) {
            root = updated
        }
        didChange()
    }

    // MARK: - Pure helpers

    /// Returns a copy of `container` with `newValue` written at `path`.
    /// Recursive and value-semantic — no in-place mutation of shared state.
    private static func setting(_ newValue: Any, at path: JSONPath, in container: Any) -> Any? {
        guard let first = path.first else { return newValue }
        let rest = Array(path.dropFirst())

        switch first {
        case .key(let k):
            guard var dict = container as? [String: Any], let child = dict[k] else { return nil }
            guard let updatedChild = setting(newValue, at: rest, in: child) else { return nil }
            dict[k] = updatedChild
            return dict
        case .index(let i):
            guard var arr = container as? [Any], i >= 0, i < arr.count else { return nil }
            guard let updatedChild = setting(newValue, at: rest, in: arr[i]) else { return nil }
            arr[i] = updatedChild
            return arr
        }
    }

    /// Best-effort type conversion when switching a node's kind.
    static func convert(_ value: Any?, to kind: JSONValueKind) -> Any {
        let text: String
        switch value {
        case let s as String: text = s
        case let n as NSNumber:
            text = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default: text = ""
        }

        switch kind {
        case .string:
            return text
        case .number:
            // `Double(text) ?? 0` used to live here. `Double("inf")` succeeds,
            // and an infinity in the tree took the host app down inside
            // JSONSerialization's writer. `number(from:)` refuses non-finite.
            return JSONInlineValueCoder.number(from: text) ?? NSNumber(value: 0)
        case .bool:
            let lower = text.lowercased()
            return ["true", "1", "yes", "on"].contains(lower)
        case .null:
            return NSNull()
        case .object:
            return (value as? [String: Any]) ?? [String: Any]()
        case .array:
            if let arr = value as? [Any] { return arr }
            if let v = value, !(v is NSNull) { return [v] }   // wrap a scalar
            return [Any]()
        }
    }

    /// Validates arbitrary text as JSON, returning a readable error if not.
    static func validate(_ text: String) -> (isValid: Bool, error: String?) {
        guard let data = text.data(using: .utf8) else { return (false, "Not valid UTF-8 text") }
        if data.isEmpty { return (false, "Empty") }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return (true, nil)
        } catch {
            return (false, (error as NSError).localizedDescription)
        }
    }
}

// MARK: - Array element shape

/// What "Add item" is about to append to an array, and how it decided.
///
/// The value on its own is not enough for a menu. Adding an item that turns out
/// to be the wrong type is only obvious once it is in the payload, so the words
/// travel with the value: `summary` is what the user reads *before* tapping, and
/// `isInferred` says whether it describes a reading of the existing items or a
/// fallback the array left no way to avoid.
struct JSONArrayElementTemplate {
    /// The element to append.
    let value: Any
    /// Its type, so a type picker can preselect it.
    let kind: JSONValueKind
    /// One line for a menu subtitle: "string", "object with 5 keys",
    /// "number (decimal)" — or what it fell back to and why.
    let summary: String
    /// True when the existing items agreed on a type. False when there were none
    /// or they disagreed, in which case the caller should make the escape hatch
    /// obvious rather than presenting a guess as the answer.
    let isInferred: Bool

    /// Nothing to read: an empty string is the least surprising thing to add, and
    /// the summary says that is what happened.
    static let emptyArrayFallback = JSONArrayElementTemplate(
        value: "", kind: .string,
        summary: "empty array · nothing to copy, adding an empty string",
        isInferred: false)

    func adding(note: String) -> JSONArrayElementTemplate {
        JSONArrayElementTemplate(value: value, kind: kind,
                                 summary: summary + " · " + note, isInferred: isInferred)
    }
}

/// Reads the element type of an array so a new element can be given the same
/// shape — the *whole* shape, including nested objects and arrays.
///
/// **Bounded on purpose.** At most `sampleLimit` elements are read and at most
/// `maxDepth` levels are copied, so working out the shape of a 10,000-row
/// response costs the same as a 64-row one, and a deeply nested body cannot
/// recurse the stack away. When the sample is shorter than the array the summary
/// says so, rather than implying the whole thing was read.
enum JSONArrayShapeReader {

    /// Elements read before the reader stops looking. Far more than enough to
    /// union the optional fields of a real collection.
    static let sampleLimit = 64

    /// Levels of nesting copied into the template.
    static let maxDepth = 12

    /// The element to append to an array holding `array`'s items.
    static func template(forElementsOf array: [Any]) -> JSONArrayElementTemplate {
        guard !array.isEmpty else { return .emptyArrayFallback }
        let reading = read(Array(array.prefix(sampleLimit)), depth: 0)
        let template = JSONArrayElementTemplate(
            value: reading.value, kind: reading.kind,
            summary: ([reading.name] + reading.notes).joined(separator: " · "),
            isInferred: reading.isInferred)
        guard array.count > sampleLimit else { return template }
        return template.adding(note: "read the first \(sampleLimit) of \(array.count) items")
    }

    // MARK: Reading

    /// A value plus the words for it. Only the top-level reading's words are
    /// used; nested ones contribute a value (into an object) or a name (into
    /// "array of …").
    private struct Reading {
        let value: Any
        let kind: JSONValueKind
        /// "string", "object with 5 keys", "array of number".
        let name: String
        let notes: [String]
        let isInferred: Bool
    }

    /// `sample` must not be empty.
    private static func read(_ sample: [Any], depth: Int) -> Reading {
        // A null item is an absent value, not a type: a field that is null on
        // the row that happens to come first is an optional string, not a null.
        let present = sample.filter { !($0 is NSNull) }
        guard let first = present.first else {
            return Reading(value: NSNull(), kind: .null, name: "null",
                           notes: ["every item is null"], isInferred: true)
        }
        var kinds: [JSONValueKind] = []
        for item in present {
            let kind = JSONValueKind.of(item)
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        let kind = JSONValueKind.of(first)
        let shaped = shape(kind, from: present, depth: depth)
        let sawNull = present.count < sample.count

        guard kinds.count == 1 else {
            var names = kinds.map(\.rawValue)
            if sawNull { names.append(JSONValueKind.null.rawValue) }
            return Reading(
                value: shaped.value, kind: kind,
                name: "mixed items (\(names.sorted().joined(separator: ", ")))",
                notes: ["adding \(article(for: shaped.name)) \(shaped.name), like the first one"],
                isInferred: false)
        }

        var notes: [String] = []
        // An array slot is added empty on purpose: a seeded element would have to
        // be deleted every time. Say so, since "array of number" implies content.
        if kind == .array { notes.append("adds an empty array") }
        if sawNull { notes.append("some items are null") }
        // Anything the shape itself was unsure about — a field the rows
        // disagree on. Said out loud for the same reason a MIXED array is:
        // a guess presented as a reading is worse than no guess at all.
        notes.append(contentsOf: shaped.notes)
        return Reading(value: shaped.value, kind: kind, name: shaped.name,
                       notes: notes, isInferred: true)
    }

    /// The empty value for a run of items that all share `kind`, the words for
    /// it, and anything it had to guess at. Objects and arrays are shaped from
    /// what the items actually hold.
    private static func shape(_ kind: JSONValueKind, from values: [Any],
                              depth: Int) -> (value: Any, name: String, notes: [String]) {
        guard depth < maxDepth else { return (kind.emptyValue, kind.rawValue, []) }
        switch kind {
        case .string, .bool, .null:
            return (kind.emptyValue, kind.rawValue, [])
        case .number:
            // A column of prices must not hand back an integer 0 and re-type
            // itself; a column of ids must not hand back 0.0.
            return hasFraction(values) ? (NSNumber(value: 0.0), "number (decimal)", [])
                                       : (NSNumber(value: 0), "number", [])
        case .object:
            let shaped = object(from: values, depth: depth)
            let name: String
            switch shaped.value.count {
            case 0:  name = "empty object"
            case 1:  name = "object with 1 key"
            default: name = "object with \(shaped.value.count) keys"
            }
            return (shaped.value, name, disagreementNote(shaped.undecided).map { [$0] } ?? [])
        case .array:
            let inner = values.lazy.compactMap { $0 as? [Any] }.flatMap { $0.prefix(sampleLimit) }
            let sample = Array(inner.prefix(sampleLimit))
            guard !sample.isEmpty else { return ([Any](), "array", []) }
            let element = read(sample, depth: depth + 1)
            guard element.isInferred else { return ([Any](), "array", []) }
            return ([Any](), "array of \(element.name)", [])
        }
    }

    /// The union of the keys these objects hold, each value shaped from every
    /// value observed for that key — not from whichever object came first —
    /// plus the keys whose values did NOT agree on a type.
    ///
    /// Those keys are a guess: the field takes the type of the first row that
    /// has one, exactly as a mixed array does, and the caller says so. Without
    /// this, an array of rows where `"v"` is a number on one row and a string on
    /// the next was described as a confident "object with 1 key" and silently
    /// added `"v": 0`.
    private static func object(from values: [Any],
                               depth: Int) -> (value: [String: Any], undecided: [String]) {
        var observed: [String: [Any]] = [:]
        for value in values {
            guard let dict = value as? [String: Any] else { continue }
            for (key, element) in dict { observed[key, default: []].append(element) }
        }
        var out = [String: Any]()
        var undecided: [String] = []
        for (key, items) in observed where !items.isEmpty {
            let reading = read(items, depth: depth + 1)
            out[key] = reading.value
            if !reading.isInferred { undecided.append(key) }
        }
        return (out, undecided)
    }

    /// One line naming the fields the rows disagree about, or nil when they all
    /// agree. Capped, because a subtitle listing forty field names is not a
    /// subtitle.
    private static func disagreementNote(_ keys: [String]) -> String? {
        guard !keys.isEmpty else { return nil }
        let sorted = keys.sorted()
        let shown = sorted.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        let tail = sorted.count > 3 ? " and \(sorted.count - 3) more" : ""
        return "the rows disagree about \(shown)\(tail) — taking the first value seen"
    }

    /// True when any sampled number has a fractional part.
    private static func hasFraction(_ values: [Any]) -> Bool {
        for value in values {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let double = number.doubleValue
            if double.isFinite, double != double.rounded(.towardZero) { return true }
        }
        return false
    }

    private static func article(for name: String) -> String {
        "aeiou".contains(name.lowercased().first ?? " ") ? "an" : "a"
    }
}

// MARK: - Source index

/// Remembers the parts of the original text that parsing throws away: how each
/// number was spelled, and what order each object's keys were in.
///
/// Both matter because a point edit re-serialises the whole document. Without
/// this, changing one field rewrites every price in the payload
/// (`19.99` -> `19.989999999999998`) and shuffles every key — and that payload
/// is handed to the host app by response rewrites, breakpoint edits and mock
/// seeding.
///
/// A recorded literal is only ever used when it still evaluates to the value
/// currently at that path, so a stale entry (after an insert shifts array
/// indices, say) can never resurrect an old number.
struct JSONSourceIndex {
    private(set) var numberLiterals: [JSONPath: String] = [:]
    private(set) var keyOrder: [JSONPath: [String]] = [:]

    /// For every array the editor has reordered, `elementOrigins[arrayPath][i]`
    /// is the index element `i` had **in the source text** — `newElement` for
    /// one that was not there at all.
    ///
    /// Records above are keyed by the path a value had in the SOURCE, and an
    /// array path contains the element's index. Deleting element 0 therefore
    /// re-points every record at its neighbour. Numbers survived that (a literal
    /// is only used while it still describes the value at that path) but key
    /// order has no such check: the recorded order stopped matching the object
    /// it named and the writer fell back to `keys.sorted()`, alphabetising every
    /// *surviving* object in the array.
    ///
    /// Translating current → source at lookup time, instead of re-keying the
    /// records, is what makes that impossible; it also keeps a rewrite that
    /// deletes a thousand rows from re-hashing the whole index a thousand times
    /// on the networking thread.
    private(set) var elementOrigins: [JSONPath: [Int]] = [:]

    /// An element with no counterpart in the source text. Source indices are
    /// never negative, so it can never collide with one.
    static let newElement = -1

    /// Ids handed to the copy an element duplication makes, so editing the copy
    /// cannot reach back into the records of the element it was copied from.
    private var nextCopiedElement = -2

    var isEmpty: Bool { numberLiterals.isEmpty && keyOrder.isEmpty }

    init() {}

    init(scanning text: String) {
        var scanner = Scanner(bytes: Array(text.utf8))
        // Anything unexpected means the scan and the parse disagree, and a
        // half-built index is worse than none: drop it all.
        guard scanner.run() else { return }
        numberLiterals = scanner.numberLiterals
        keyOrder = scanner.keyOrder
    }

    mutating func renameKey(_ oldKey: String, to newKey: String, inObjectAt path: JSONPath) {
        let source = sourcePath(for: path)
        guard var keys = keyOrder[source], let slot = keys.firstIndex(of: oldKey) else { return }
        keys[slot] = newKey
        keyOrder[source] = keys
    }

    mutating func appendKey(_ key: String, toObjectAt path: JSONPath) {
        let source = sourcePath(for: path)
        guard var keys = keyOrder[source], !keys.contains(key) else { return }
        keys.append(key)
        keyOrder[source] = keys
    }

    /// The path this node had in the source text — the coordinates every record
    /// here is keyed by. Identical to `path` for a document whose arrays have
    /// not been reordered, which is the overwhelming majority of lookups.
    /// The recorded key order for the object now at `path`, following any array
    /// element that has since moved. Looking up the raw current path is what made
    /// a reorder or delete alphabetise every surviving element's keys.
    func keys(at path: JSONPath) -> [String]? {
        keyOrder[sourcePath(for: path)]
    }

    /// The author's original spelling for the number now at `path`, same rule.
    func literal(at path: JSONPath) -> String? {
        numberLiterals[sourcePath(for: path)]
    }

    func sourcePath(for path: JSONPath) -> JSONPath {
        guard !elementOrigins.isEmpty else { return path }
        var out: JSONPath = []
        out.reserveCapacity(path.count)
        for component in path {
            guard case .index(let i) = component else { out.append(component); continue }
            if let origins = elementOrigins[out], i >= 0, i < origins.count {
                out.append(.index(origins[i]))
            } else {
                out.append(component)
            }
        }
        return out
    }

    /// Records that the array at `arrayPath` was reordered:
    /// `elementSources[newIndex]` is the index that element held a moment ago,
    /// or a negative number for an element that has just been created.
    ///
    /// Costs one small array per mutation — never a pass over the records — so
    /// deleting a thousand rows in one rewrite stays a thousand cheap steps.
    mutating func reindexArray(at arrayPath: JSONPath, elementSources: [Int]) {
        guard !isEmpty else { return }
        let source = sourcePath(for: arrayPath)
        let current = elementOrigins[source]
        var origins: [Int] = []
        origins.reserveCapacity(elementSources.count)
        var used = Set<Int>()
        var copies: [(from: Int, to: Int)] = []
        for element in elementSources {
            var origin = Self.newElement
            if element >= 0 {
                if let current {
                    origin = element < current.count ? current[element] : Self.newElement
                } else {
                    origin = element
                }
            }
            // The same source element twice means it was duplicated. The copy
            // gets records of its own, or renaming a key in it would rewrite the
            // key order of the element it was copied from.
            if origin >= Self.newElement + 1, !used.insert(origin).inserted {
                let copy = nextCopiedElement
                nextCopiedElement -= 1
                copies.append((from: origin, to: copy))
                origin = copy
            }
            origins.append(origin)
        }
        elementOrigins[source] = origins
        for copy in copies { copyRecords(under: source, from: copy.from, to: copy.to) }
    }

    /// Copies every record belonging to one array element so a duplicate starts
    /// out with the original's key order and number spelling, and its own copy
    /// of both.
    private mutating func copyRecords(under arrayPath: JSONPath, from: Int, to: Int) {
        let old = arrayPath + [.index(from)]
        let new = arrayPath + [.index(to)]
        for (path, value) in numberLiterals where path.starts(with: old) {
            numberLiterals[new + path[old.count...]] = value
        }
        for (path, value) in keyOrder where path.starts(with: old) {
            keyOrder[new + path[old.count...]] = value
        }
    }

    // MARK: - Scanner

    /// A structural pass over the raw bytes. It does not build a tree — it only
    /// records positions — so it stays a few hundred lines short of a parser.
    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        var depth = 0
        var path: JSONPath = []
        var numberLiterals: [JSONPath: String] = [:]
        var keyOrder: [JSONPath: [String]] = [:]

        /// Deep enough for any real payload, shallow enough that a hostile body
        /// cannot blow the stack.
        private static let maxDepth = 256

        mutating func run() -> Bool {
            skipWhitespace()
            guard scanValue() else { return false }
            skipWhitespace()
            return i == bytes.count
        }

        private mutating func skipWhitespace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        private mutating func scanValue() -> Bool {
            guard i < bytes.count else { return false }
            switch bytes[i] {
            case UInt8(ascii: "{"): return scanObject()
            case UInt8(ascii: "["): return scanArray()
            case UInt8(ascii: "\""): return scanString() != nil
            case UInt8(ascii: "t"): return match("true")
            case UInt8(ascii: "f"): return match("false")
            case UInt8(ascii: "n"): return match("null")
            default: return scanNumber()
            }
        }

        private mutating func match(_ word: String) -> Bool {
            let expected = Array(word.utf8)
            guard i + expected.count <= bytes.count else { return false }
            for (offset, byte) in expected.enumerated() {
                guard bytes[i + offset] == byte else { return false }
            }
            i += expected.count
            return true
        }

        private mutating func scanNumber() -> Bool {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            loop: while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digits += 1; i += 1
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                     UInt8(ascii: "+"), UInt8(ascii: "-"):
                    i += 1
                default:
                    break loop
                }
            }
            guard digits > 0 else { return false }
            numberLiterals[path] = String(decoding: bytes[start..<i], as: UTF8.self)
            return true
        }

        /// Returns the *decoded* string, so a key matches the dictionary key
        /// `JSONSerialization` produced for it.
        private mutating func scanString() -> String? {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
            let open = i
            i += 1
            var hasEscape = false
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\\") {
                    hasEscape = true
                    i += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    let content = bytes[(open + 1)..<i]
                    i += 1
                    guard hasEscape else { return String(decoding: content, as: UTF8.self) }
                    // Escapes are Foundation's business: decoding them here is
                    // how a key would silently stop matching the parsed tree.
                    let quoted = Data(bytes[open..<i])
                    return (try? JSONSerialization.jsonObject(with: quoted,
                                                              options: [.fragmentsAllowed])) as? String
                }
                i += 1
            }
            return nil
        }

        private mutating func scanObject() -> Bool {
            guard depth < Self.maxDepth else { return false }
            depth += 1
            defer { depth -= 1 }
            i += 1                                  // past '{'
            var keys: [String] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                i += 1
                keyOrder[path] = keys
                return true
            }
            while true {
                skipWhitespace()
                guard let key = scanString() else { return false }
                keys.append(key)
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return false }
                i += 1
                skipWhitespace()
                path.append(.key(key))
                let ok = scanValue()
                path.removeLast()
                guard ok else { return false }
                skipWhitespace()
                guard i < bytes.count else { return false }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") {
                    i += 1
                    keyOrder[path] = keys
                    return true
                }
                return false
            }
        }

        private mutating func scanArray() -> Bool {
            guard depth < Self.maxDepth else { return false }
            depth += 1
            defer { depth -= 1 }
            i += 1                                  // past '['
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return true }
            var element = 0
            while true {
                skipWhitespace()
                path.append(.index(element))
                let ok = scanValue()
                path.removeLast()
                guard ok else { return false }
                element += 1
                skipWhitespace()
                guard i < bytes.count else { return false }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return true }
                return false
            }
        }
    }
}

// MARK: - Writer

/// Writes JSON text without `JSONSerialization`.
///
/// Foundation's writer is unusable for an editor that hands its output to the
/// app under test:
///
/// * it formats doubles with 17 significant digits, so re-serialising an
///   untouched document turns `19.99` into `19.989999999999998`;
/// * it emits object keys in hash order, so one edit reshuffles the payload;
/// * it raises `NSInvalidArgumentException` — not a Swift error, so `try?` does
///   not catch it — for a non-finite number, killing the host app.
///
/// This writer preserves the source spelling of untouched numbers and the
/// source key order, formats everything else with shortest round-trip
/// precision, and *throws* on values JSON cannot express.
private struct JSONTextWriter {
    let pretty: Bool
    let sortKeys: Bool
    /// The whole index, not two loose dictionaries: lookups must go through
    /// `sourcePath(for:)` so a moved array element keeps its own key order and
    /// number spelling.
    let index: JSONSourceIndex

    private var path: JSONPath = []

    init(pretty: Bool, sortKeys: Bool, index: JSONSourceIndex) {
        self.pretty = pretty
        self.sortKeys = sortKeys
        self.index = index
    }

    mutating func string(from root: Any) throws -> String {
        var out = ""
        out.reserveCapacity(512)
        try write(root, level: 0, into: &out)
        return out
    }

    private mutating func write(_ value: Any, level: Int, into out: inout String) throws {
        if value is NSNull {
            out += "null"
        } else if let text = value as? String {
            out += Self.quoted(text)
        } else if let dict = value as? [String: Any] {
            try writeObject(dict, level: level, into: &out)
        } else if let array = value as? [Any] {
            try writeArray(array, level: level, into: &out)
        } else if let number = value as? NSNumber {
            out += try numberText(number)
        } else {
            throw JSONWriteError.unsupportedValue(type: String(describing: type(of: value)),
                                                  path: path.display)
        }
    }

    private mutating func writeObject(_ dict: [String: Any], level: Int, into out: inout String) throws {
        guard !dict.isEmpty else { out += "{}"; return }
        let keys = orderedKeys(of: dict)
        out += "{"
        for (offset, key) in keys.enumerated() {
            if offset > 0 { out += "," }
            newline(level + 1, into: &out)
            out += Self.quoted(key)
            out += pretty ? " : " : ":"
            path.append(.key(key))
            try write(dict[key] ?? NSNull(), level: level + 1, into: &out)
            path.removeLast()
        }
        newline(level, into: &out)
        out += "}"
    }

    private mutating func writeArray(_ array: [Any], level: Int, into out: inout String) throws {
        guard !array.isEmpty else { out += "[]"; return }
        out += "["
        for (offset, element) in array.enumerated() {
            if offset > 0 { out += "," }
            newline(level + 1, into: &out)
            path.append(.index(offset))
            try write(element, level: level + 1, into: &out)
            path.removeLast()
        }
        newline(level, into: &out)
        out += "]"
    }

    private func newline(_ level: Int, into out: inout String) {
        guard pretty else { return }
        out += "\n"
        out += String(repeating: "  ", count: level)
    }

    /// Source order first (for the keys still present), then anything new,
    /// sorted so the output is at least deterministic. Foundation's hash order
    /// is neither stable across runs nor recognisable to whoever wrote the JSON.
    private func orderedKeys(of dict: [String: Any]) -> [String] {
        if sortKeys { return dict.keys.sorted() }
        guard let recorded = index.keys(at: path) else { return dict.keys.sorted() }
        var used = Set<String>()
        var out: [String] = []
        out.reserveCapacity(dict.count)
        for key in recorded where dict.keys.contains(key) && used.insert(key).inserted {
            out.append(key)
        }
        if out.count < dict.count {
            for key in dict.keys.sorted() where !used.contains(key) { out.append(key) }
        }
        return out
    }

    // MARK: Scalars

    private func numberText(_ number: NSNumber) throws -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        // The author's own spelling wins — but only while it still describes
        // the value that is actually there, so a stale entry cannot corrupt.
        if let literal = index.literal(at: path), Self.literal(literal, describes: number) {
            return literal
        }
        // NSDecimalNumber carries more digits than a Double; its own
        // description is the only lossless rendering of it.
        if let decimal = number as? NSDecimalNumber {
            let text = decimal.description(withLocale: nil)
            if text != "NaN" { return text }
            throw JSONWriteError.nonFiniteNumber(path: path.display)
        }
        switch UInt8(bitPattern: number.objCType.pointee) {
        case UInt8(ascii: "f"):
            let value = number.floatValue
            guard value.isFinite else { throw JSONWriteError.nonFiniteNumber(path: path.display) }
            return Self.integerText(for: Double(value)) ?? value.description
        case UInt8(ascii: "d"):
            let value = number.doubleValue
            guard value.isFinite else { throw JSONWriteError.nonFiniteNumber(path: path.display) }
            // Swift's description is the shortest text that round-trips to the
            // same Double: 19.99 stays "19.99". Foundation prints 17 digits.
            return Self.integerText(for: value) ?? value.description
        default:
            // Every integer width: stringValue is exact and locale-independent.
            return number.stringValue
        }
    }

    /// The plain integer spelling of a double that is exactly an integer, or nil
    /// when it is not one (or is too large to write out digit by digit).
    ///
    /// `Double.description` is the shortest text that round-trips, which is what
    /// a fraction needs — but for a whole number it spells `1000.0` and
    /// `1e+16`, where Foundation and every server on earth write `1000` and
    /// `10000000000000000`. The difference is visible in mock bodies, in
    /// "copy body", and in any diff a developer runs against the real response.
    /// Past `Int64` the digits stop being writable this way, and Foundation
    /// gives up on them too (`1e+20`), so the round-trip spelling stands.
    private static func integerText(for value: Double) -> String? {
        guard value.isFinite, value == value.rounded(.towardZero) else { return nil }
        // -0.0 is an integer whose sign only survives if it is written down.
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        guard value >= -9_223_372_036_854_775_808.0, value < 9_223_372_036_854_775_808.0 else { return nil }
        return String(Int64(value))
    }

    private static func literal(_ literal: String, describes number: NSNumber) -> Bool {
        let trimmed = literal.trimmingCharacters(in: .whitespaces)
        // Integers first, EXACTLY. Comparing in Double cannot tell
        // 9007199254740993 from 9007199254740992 — both round to the same
        // Double — so editing a 64-bit id above 2^53 to a neighbouring value
        // re-emitted the ORIGINAL spelling and silently discarded the edit.
        if let literalInt = Int(trimmed) {
            guard let numberInt = numberAsExactInt(number) else {
                // Not certainly an Int: a decimal is compared exactly below,
                // and an unsigned value past `Int64.max` is not this literal —
                // falling back to Double here is what let a stale
                // 9223372036854775807 be re-emitted over 9223372036854775808.
                return decimalLiteral(trimmed, describes: number)
            }
            return literalInt == numberInt
        }
        // An NSDecimalNumber holds more digits than a Double, so comparing in
        // Double is exactly as blind here as it is for a big Int: a rewrite that
        // replaces a 21-digit id with its neighbour arrives as a decimal, rounds
        // to the same Double as the recorded literal, and the ORIGINAL id was
        // re-emitted over it.
        if number is NSDecimalNumber { return decimalLiteral(trimmed, describes: number) }
        guard let parsed = Double(literal), parsed.isFinite else { return false }
        let value = number.doubleValue
        guard value.isFinite else { return false }
        return parsed == value
    }

    /// Exact comparison against an `NSDecimalNumber` — the only number here that
    /// carries digits a `Double` cannot. False for anything else, so a caller
    /// that cannot compare exactly refuses the literal instead of guessing.
    private static func decimalLiteral(_ literal: String, describes number: NSNumber) -> Bool {
        guard let decimal = number as? NSDecimalNumber,
              let parsed = Decimal(string: literal, locale: nil), !parsed.isNaN else { return false }
        return parsed == decimal.decimalValue
    }

    /// The number's exact integer value, or nil when it is not certainly an
    /// integer that `Int` can hold.
    ///
    /// Checking `CFNumberGetType` alone is NOT enough, and getting this wrong
    /// corrupts data the host app then trusts:
    ///  • `JSONSerialization` returns an `NSDecimalNumber` for a literal with
    ///    more than 17 significant digits, and its CFNumber type reports
    ///    `.doubleType` on some values and not others;
    ///  • a `UInt64` above `Int64.max` reports an integer type, but `intValue`
    ///    silently wraps to -1.
    /// In both cases a stale source literal was then judged to "describe" the
    /// wrong value and re-emitted over a real one. Round-trip through the
    /// decimal string instead: that is exact by construction, and anything it
    /// cannot represent as an `Int` returns nil and falls back to the safe path.
    private static func numberAsExactInt(_ number: NSNumber) -> Int? {
        switch CFNumberGetType(number as CFNumber) {
        case .float32Type, .float64Type, .cgFloatType:
            return nil
        default:
            break
        }
        if number is NSDecimalNumber { return nil }
        // `stringValue` is exact for every integer width; `Int(_:)` rejects
        // anything that wrapped or does not fit.
        guard let exact = Int(number.stringValue) else { return nil }
        return exact
    }

    private static func quoted(_ text: String) -> String {
        var needsEscape = false
        for scalar in text.unicodeScalars where scalar.value < 0x20 || scalar == "\"" || scalar == "\\" {
            needsEscape = true
            break
        }
        guard needsEscape else { return "\"" + text + "\"" }

        var out = "\""
        out.reserveCapacity(text.unicodeScalars.count + 8)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":     out += "\\\""
            case "\\":     out += "\\\\"
            case "\n":     out += "\\n"
            case "\r":     out += "\\r"
            case "\t":     out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        // Slashes are never escaped: every call site asked Foundation for
        // `.withoutEscapingSlashes`, because an escaped URL is unreadable.
        out += "\""
        return out
    }
}
