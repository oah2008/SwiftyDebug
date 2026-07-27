//
//  MediaMetadataExtractor.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Walks a JSON response body once and extracts:
/// - image URLs (for the JSON-MEDIA grid + the main Media tab), and
/// - top-level JSON keys (for search).
///
/// Detection (per the confirmed product decision) uses an **extension + key-name
/// heuristic**: a string value is treated as an image if it is an http(s) URL
/// whose path ends in a known image extension, OR its JSON key looks image-ish
/// (image, img, photo, thumbnail, avatar, icon, cover, banner, media, …) and the
/// value is an http(s) URL — this catches extensionless CDN image URLs, which
/// are extremely common.
enum MediaMetadataExtractor {

    struct Result {
        let imageURLs: [String]
        let topLevelKeys: [String]
    }

    /// Known image file extensions.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "svg", "avif", "tiff"
    ]

    /// JSON keys that strongly imply the value is an image URL.
    private static let imageKeyHints: [String] = [
        "image", "img", "photo", "picture", "pic", "thumbnail", "thumb",
        "avatar", "icon", "cover", "banner", "media", "logo", "poster", "artwork"
    ]

    /// Hard cap on how many images we collect to keep memory/CPU bounded even
    /// for pathological payloads.
    private static let maxImages = 300
    /// Hard cap on nesting depth to avoid runaway recursion.
    private static let maxDepth = 12

    /// Bodies larger than this are skipped for media/JSON-key extraction to keep
    /// capture-time cost bounded (search still works over URL/headers/params).
    private static let maxScanBytes = 2 * 1024 * 1024  // 2 MB

    /// Scan a response body. Returns empty results if the data isn't JSON or is
    /// too large to scan cheaply at capture time.
    static func scan(data: Data, requestURL: URL?) -> Result {
        guard data.count <= maxScanBytes else {
            return Result(imageURLs: [], topLevelKeys: [])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return Result(imageURLs: [], topLevelKeys: [])
        }

        var images: [String] = []
        var seen = Set<String>()

        func appendImage(_ raw: String) {
            guard images.count < maxImages else { return }
            guard let absolute = absoluteURLString(raw, base: requestURL) else { return }
            if seen.insert(absolute).inserted {
                images.append(absolute)
            }
        }

        func walk(_ node: Any, keyHint: String?, depth: Int) {
            guard depth <= maxDepth, images.count < maxImages else { return }
            switch node {
            case let dict as [String: Any]:
                for (k, v) in dict { walk(v, keyHint: k, depth: depth + 1) }
            case let arr as [Any]:
                for v in arr { walk(v, keyHint: keyHint, depth: depth + 1) }
            case let str as String:
                if isImageString(str, keyHint: keyHint) { appendImage(str) }
            default:
                break
            }
        }

        walk(root, keyHint: nil, depth: 0)

        // Top-level keys for search.
        var topKeys: [String] = []
        if let dict = root as? [String: Any] {
            topKeys = Array(dict.keys)
        }

        return Result(imageURLs: images, topLevelKeys: topKeys)
    }

    // MARK: - Heuristics

    /// Whether a string value should be treated as an image URL.
    static func isImageString(_ value: String, keyHint: String?) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.count <= 2048 else { return false }

        let lower = trimmed.lowercased()
        let isHTTP = lower.hasPrefix("http://") || lower.hasPrefix("https://")

        // Extension-based: URL path ends in a known image extension.
        if isHTTP, let ext = pathExtension(of: trimmed), imageExtensions.contains(ext) {
            return true
        }
        // Also accept protocol-relative and data image URLs by extension.
        if lower.hasPrefix("data:image/") { return true }
        if lower.hasPrefix("//"), let ext = pathExtension(of: trimmed), imageExtensions.contains(ext) {
            return true
        }

        // Key-name based: image-ish key AND an http(s) URL value (extensionless CDN).
        if isHTTP, let keyHint = keyHint?.lowercased() {
            for hint in imageKeyHints where keyHint.contains(hint) {
                return true
            }
        }
        return false
    }

    /// Lowercased path extension of a URL string (ignoring query/fragment).
    private static func pathExtension(of urlString: String) -> String? {
        var s = urlString
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        guard let lastSlash = s.lastIndex(of: "/") else {
            return (s as NSString).pathExtension.isEmpty ? nil : (s as NSString).pathExtension.lowercased()
        }
        let lastComponent = String(s[s.index(after: lastSlash)...])
        let ext = (lastComponent as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Resolves a possibly-relative image URL string to an absolute URL string.
    static func absoluteURLString(_ raw: String, base: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:image/") {
            return trimmed
        }
        if lower.hasPrefix("//") {
            let scheme = base?.scheme ?? "https"
            return "\(scheme):\(trimmed)"
        }
        // Relative path — resolve against the request URL if we have one.
        if let base, let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return nil
    }
}
