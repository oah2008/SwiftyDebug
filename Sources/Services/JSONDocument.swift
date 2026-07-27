//
//  JSONDocument.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Addresses one node inside a JSON tree.
enum JSONPathComponent: Equatable {
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

/// An editable JSON document with **path-based mutations** and undo/redo.
///
/// The editor UI is deliberately thin over this: every change goes through one
/// of these methods, so behavior is testable without a screen. The tree is kept
/// as plain Foundation JSON (`[String: Any]` / `[Any]` / scalars) so it
/// round-trips through `JSONSerialization` with no conversion step.
final class JSONDocument {

    private(set) var root: Any

    private var undoStack: [Any] = []
    private var redoStack: [Any] = []
    private static let maxUndo = 50

    /// Fires after any mutation (including undo/redo).
    var onChange: (() -> Void)?

    init(root: Any) {
        self.root = root
    }

    /// Parses text into a document. Accepts objects, arrays and fragments.
    convenience init?(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        self.init(root: obj)
    }

    /// An empty object, for "type my own".
    static func empty() -> JSONDocument { JSONDocument(root: [String: Any]()) }

    // MARK: - Serialization

    /// Pretty-printed JSON text (slashes unescaped, stable key order).
    func prettyText(sortKeys: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
        if sortKeys { options.insert(.sortedKeys) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: options),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    func minifiedText() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    func data() -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes, .fragmentsAllowed])
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
            parent.remove(at: i)
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
        applyToParent(obj, at: path)
        return true
    }

    /// Appends an element to the array at `path`.
    @discardableResult
    func appendElement(_ newValue: Any, toArrayAt path: JSONPath) -> Bool {
        guard var arr = value(at: path) as? [Any] else { return false }
        pushUndo()
        arr.append(newValue)
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
        arr.insert(arr[i], at: i + 1)
        applyToParent(arr, at: parentPath)
        return true
    }

    /// Moves an array element (for drag-to-reorder).
    @discardableResult
    func moveElement(inArrayAt arrayPath: JSONPath, from: Int, to: Int) -> Bool {
        guard var arr = value(at: arrayPath) as? [Any],
              from >= 0, from < arr.count, to >= 0, to < arr.count, from != to else { return false }
        pushUndo()
        let item = arr.remove(at: from)
        arr.insert(item, at: to)
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

    /// A new element shaped like the array's existing elements: for an array of
    /// objects it returns an object with the union of sibling keys, each reset to
    /// an empty value of the same type. This is what makes "Add item" feel smart.
    func templateElement(forArrayAt path: JSONPath) -> Any {
        guard let arr = value(at: path) as? [Any], !arr.isEmpty else { return "" }

        // Union of keys across object elements, preserving first-seen order.
        var order: [String] = []
        var kinds: [String: JSONValueKind] = [:]
        var sawObject = false
        for element in arr {
            guard let dict = element as? [String: Any] else { continue }
            sawObject = true
            for key in dict.keys.sorted() where kinds[key] == nil {
                order.append(key)
                kinds[key] = JSONValueKind.of(dict[key]!)
            }
        }
        if sawObject {
            var template = [String: Any]()
            for key in order { template[key] = (kinds[key] ?? .string).emptyValue }
            return template
        }
        // Homogeneous scalars/arrays — match the first element's type.
        return JSONValueKind.of(arr[0]).emptyValue
    }

    // MARK: - Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(root)
        root = previous
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(root)
        root = next
        onChange?()
    }

    private func pushUndo() {
        undoStack.append(root)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
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
            return NSNumber(value: Double(text) ?? 0)
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
