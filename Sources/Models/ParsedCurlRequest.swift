//
//  ParsedCurlRequest.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import Foundation

/// One `-H` header, kept in the order it was written (curl sends duplicates as-is).
struct CurlHeader: Equatable {
    var name: String
    var value: String
}

/// One `-F` field. `filename` is set for `name=@path` fields — the bytes cannot be
/// read from inside the host app, so the part is sent empty.
struct CurlFormField: Equatable {
    var name: String
    var value: String
    var filename: String?
    var contentType: String?
}

/// A cURL command reduced to everything SwiftyDebug needs: replay it, or turn it
/// into an intercept rule.
struct ParsedCurlRequest: Equatable {

    var method: String
    var url: URL
    var headers: [CurlHeader]
    var body: Data?
    /// Flags that were understood well enough to skip, but not acted on
    /// (`-s`, `-o out.json`, `--retry 3`, anything unknown).
    var ignoredFlags: [String]
    var followsRedirects: Bool
    var allowsInsecureTLS: Bool
    var wantsCompressedResponse: Bool

    // MARK: - Derived

    var bodyString: String? {
        guard let body, !body.isEmpty else { return nil }
        return String(data: body, encoding: .utf8)
    }

    /// Duplicate header names collapse with the last one winning — the same rule
    /// `URLRequest.setValue` applies.
    var headerDictionary: [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.name] = header.value
        }
        return result
    }

    var queryItems: [URLQueryItem] {
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func value(forHeader name: String) -> String? {
        return headers.last(where: { $0.name.lowercased() == name.lowercased() })?.value
    }

    // MARK: - Consumers

    /// The request to actually send. Duplicate headers are appended rather than
    /// replaced so `-H 'Set-Cookie: a' -H 'Set-Cookie: b'` still sends both.
    func makeURLRequest(timeout: TimeInterval = 60) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        var seen = Set<String>()
        for header in headers where !header.name.isEmpty {
            let key = header.name.lowercased()
            if seen.insert(key).inserted {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            } else {
                request.addValue(header.value, forHTTPHeaderField: header.name)
            }
        }

        if let body, !body.isEmpty {
            request.httpBody = body
            // curl's default for a body without an explicit type.
            if !seen.contains("content-type") {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }

        return request
    }

    /// Prefills an intercept rule with the command's headers and query params.
    /// The rule is *not* saved — the editor screen owns that decision.
    func makeInterceptRule(matchMode: EndpointMatchMode = .exact) -> InterceptRule {
        var rule: InterceptRule
        switch matchMode {
        case .global:
            rule = InterceptRule.globalRule()
        case .host:
            rule = InterceptRule.hostRule(hosts: [url.host ?? ""])
        case .exact:
            rule = InterceptRule.endpointRule(path: url.path, mode: .exact, host: url.host)
        case .normalized:
            rule = InterceptRule.endpointRule(path: EndpointNormalizer.normalize(url.path), mode: .normalized, host: url.host)
        }

        // A rule holds one value per key: keep the last occurrence, original order.
        var seen = Set<String>()
        var overrides: [KVPair] = []
        for header in headers.reversed() where seen.insert(header.name.lowercased()).inserted {
            overrides.append(KVPair(key: header.name, value: header.value))
        }
        rule.headerOverrides = overrides.reversed()

        var seenParams = Set<String>()
        var paramOverrides: [KVPair] = []
        for item in queryItems.reversed() where seenParams.insert(item.name).inserted {
            paramOverrides.append(KVPair(key: item.name, value: item.value ?? ""))
        }
        rule.queryParamOverrides = paramOverrides.reversed()

        return rule
    }

    /// Bridges an imported command into the model the rest of the SDK speaks, so
    /// screens that consume a captured request (the replay editor, the detail
    /// inspector) can take a pasted cURL without knowing it was pasted.
    func makeNetworkTransaction() -> NetworkTransaction {
        let model = NetworkTransaction()
        model.requestId = UUID().uuidString
        model.url = url as NSURL
        model.method = method
        model.requestHeaderFields = headerDictionary as NSDictionary
        model.requestData = body
        model.startTime = String(format: "%f", Date().timeIntervalSince1970)
        return model
    }
}
