//
//  RequestSearchIndex.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Precomputed, searchable metadata for one captured request.
///
/// Request/response bodies are disk-backed on `NetworkTransaction`, so searching
/// them per keystroke would hit the disk once per model per character — fatal
/// for a long list. Instead this index is computed **once** at capture time
/// (while the body is already in memory) and holds only the small decomposed,
/// searchable strings we need: URL parts, method/status, header names, query
/// param names/values, response-derived metadata (content-type, detected image
/// URLs, top-level JSON keys). Search then reads this in-memory blob and never
/// touches disk.
///
/// The index also powers:
/// - path-aware tag matching (see TAGS-FILTER),
/// - header-name / query-param autocomplete (see INTERCEPT-UX),
/// - the media grid (`imageURLs`, see JSON-MEDIA / MEDIA-TAB).
struct RequestSearchIndex {

    /// Scheme + host + port, lowercased (e.g. "https://api.example.com").
    let urlBase: String
    /// Host only, lowercased.
    let host: String
    /// Path, original case.
    let path: String
    /// Normalized path with ids/uuids collapsed to `{id}`.
    let normalizedPath: String
    /// Query parameter names, original case.
    let queryParamNames: [String]
    /// Query parameter values, original case.
    let queryParamValues: [String]
    /// HTTP method, uppercased.
    let method: String
    /// Status code string.
    let statusCode: String
    /// MIME / content-type, lowercased.
    let contentType: String
    /// Request header names (original case).
    let requestHeaderNames: [String]
    /// Response header names (original case).
    let responseHeaderNames: [String]
    /// Image URLs discovered in the response body (see JSON-MEDIA detection).
    let imageURLs: [String]
    /// Top-level JSON keys discovered in the response body (searchable).
    let responseJSONKeys: [String]

    /// One lowercased "haystack" blob combining every searchable field, built
    /// once so `search(_:)` is a single `contains` over precomputed text.
    let haystack: String

    // MARK: - Build

    /// Builds the index from a transaction's in-memory fields plus an optional
    /// one-time body scan. Pass the already-loaded response `Data` (do not read
    /// it from disk here) to include body-derived metadata; pass nil to skip it.
    static func build(from model: NetworkTransaction, responseBody: Data?) -> RequestSearchIndex {
        let url = model.url as URL?
        let host = (url?.host ?? "").lowercased()

        var urlBase = ""
        if let scheme = url?.scheme, !host.isEmpty {
            if let port = url?.port {
                urlBase = "\(scheme.lowercased())://\(host):\(port)"
            } else {
                urlBase = "\(scheme.lowercased())://\(host)"
            }
        }

        let path = url?.path ?? ""
        let normalizedPath = EndpointNormalizer.normalize(path)

        var queryNames: [String] = []
        var queryValues: [String] = []
        if let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items {
                queryNames.append(item.name)
                if let v = item.value, !v.isEmpty { queryValues.append(v) }
            }
        }

        let method = (model.method ?? "").uppercased()
        let statusCode = model.statusCode ?? ""
        let contentType = (model.mineType ?? "").lowercased()

        let reqHeaderNames = headerNames(model.requestHeaderFields)
        let resHeaderNames = headerNames(model.responseHeaderFields)

        // One-time body scan for image URLs + top-level JSON keys.
        var imageURLs: [String] = []
        var jsonKeys: [String] = []
        if let body = responseBody, !body.isEmpty {
            let scan = MediaMetadataExtractor.scan(data: body, requestURL: url)
            imageURLs = scan.imageURLs
            jsonKeys = scan.topLevelKeys
        }

        // Build the combined lowercased haystack.
        var parts: [String] = [urlBase, host, path, normalizedPath, method, statusCode, contentType]
        parts.append(contentsOf: queryNames)
        parts.append(contentsOf: queryValues)
        parts.append(contentsOf: reqHeaderNames)
        parts.append(contentsOf: resHeaderNames)
        parts.append(contentsOf: jsonKeys)
        // Full absolute URL too, so existing "search the URL" behavior is a subset.
        if let abs = url?.absoluteString { parts.append(abs) }
        let haystack = parts.joined(separator: "\n").lowercased()

        return RequestSearchIndex(
            urlBase: urlBase,
            host: host,
            path: path,
            normalizedPath: normalizedPath,
            queryParamNames: queryNames,
            queryParamValues: queryValues,
            method: method,
            statusCode: statusCode,
            contentType: contentType,
            requestHeaderNames: reqHeaderNames,
            responseHeaderNames: resHeaderNames,
            imageURLs: imageURLs,
            responseJSONKeys: jsonKeys,
            haystack: haystack
        )
    }

    private static func headerNames(_ dict: NSDictionary?) -> [String] {
        guard let dict = dict as? [String: Any] else { return [] }
        return dict.keys.map { String($0) }
    }

    // MARK: - Search

    /// Returns true if the (already-lowercased or arbitrary) query matches this
    /// index. Supports simple field-scoped queries for power users:
    ///   `header:authorization`, `status:500`, `method:post`, `host:example.com`,
    ///   `param:page`, `path:/users`, `type:json`
    /// Anything else is a plain substring match over the combined haystack.
    func matches(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }

        // Field-scoped query: `field:value`
        if let colon = query.firstIndex(of: ":"),
           let field = SearchField(rawValue: String(query[..<colon])) {
            let value = String(query[query.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return true }
            return matchesField(field, value: value)
        }

        return haystack.contains(query)
    }

    private enum SearchField: String {
        case header, status, method, host, param, path, type
    }

    private func matchesField(_ field: SearchField, value: String) -> Bool {
        switch field {
        case .header:
            return requestHeaderNames.contains { $0.lowercased().contains(value) }
                || responseHeaderNames.contains { $0.lowercased().contains(value) }
        case .status:
            return statusCode.lowercased().contains(value)
        case .method:
            return method.lowercased().contains(value)
        case .host:
            return host.contains(value)
        case .param:
            return queryParamNames.contains { $0.lowercased().contains(value) }
                || queryParamValues.contains { $0.lowercased().contains(value) }
        case .path:
            return path.lowercased().contains(value) || normalizedPath.lowercased().contains(value)
        case .type:
            return contentType.contains(value)
        }
    }
}
