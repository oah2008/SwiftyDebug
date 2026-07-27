//
//  HTTPHeaderCatalog.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// A rich, built-in catalog of known HTTP header names plus smart value
/// suggestions per header. Powers the intercept-editor autocomplete so header
/// keys are comprehensive and values are easy to enter (e.g. typing an
/// `Authorization` value suggests `Bearer `). (See INTERCEPT-UX Phase 2.)
enum HTTPHeaderCatalog {

    /// Comprehensive list of standard (IANA) + widely-used non-standard request
    /// and response header names, canonical-cased.
    static let allHeaderNames: [String] = [
        // Standard request headers
        "A-IM", "Accept", "Accept-Charset", "Accept-Datetime", "Accept-Encoding",
        "Accept-Language", "Access-Control-Request-Method", "Access-Control-Request-Headers",
        "Authorization", "Cache-Control", "Connection", "Content-Encoding", "Content-Length",
        "Content-MD5", "Content-Type", "Cookie", "Date", "Expect", "Forwarded", "From",
        "Host", "HTTP2-Settings", "If-Match", "If-Modified-Since", "If-None-Match",
        "If-Range", "If-Unmodified-Since", "Max-Forwards", "Origin", "Pragma",
        "Prefer", "Proxy-Authorization", "Range", "Referer", "TE", "Trailer",
        "Transfer-Encoding", "Upgrade", "User-Agent", "Via", "Warning",
        // Standard response headers (useful when overriding response-derived flows)
        "Accept-Ranges", "Access-Control-Allow-Origin", "Access-Control-Allow-Credentials",
        "Access-Control-Allow-Headers", "Access-Control-Allow-Methods",
        "Access-Control-Expose-Headers", "Access-Control-Max-Age", "Age", "Allow",
        "Content-Disposition", "Content-Language", "Content-Location", "Content-Range",
        "Content-Security-Policy", "ETag", "Expires", "Last-Modified", "Link", "Location",
        "Retry-After", "Server", "Set-Cookie", "Strict-Transport-Security", "Vary",
        "WWW-Authenticate", "X-Frame-Options",
        // Common non-standard / de-facto headers
        "DNT", "Front-End-Https", "Proxy-Connection", "Save-Data",
        "Sec-Fetch-Dest", "Sec-Fetch-Mode", "Sec-Fetch-Site", "Sec-Fetch-User",
        "Sec-CH-UA", "Sec-CH-UA-Mobile", "Sec-CH-UA-Platform", "Sec-GPC",
        "Upgrade-Insecure-Requests", "X-Requested-With", "X-Forwarded-For",
        "X-Forwarded-Host", "X-Forwarded-Proto", "X-Http-Method-Override",
        "X-Csrf-Token", "X-XSRF-TOKEN", "X-Api-Key", "X-Api-Version", "X-App-Version",
        "X-Auth-Token", "X-Access-Token", "X-Refresh-Token", "X-Client-Id",
        "X-Client-Version", "X-Device-Id", "X-Device-Type", "X-Platform",
        "X-Correlation-Id", "X-Request-Id", "X-Trace-Id", "X-Session-Id",
        "X-Tenant-Id", "X-User-Id", "X-Locale", "X-Timezone", "X-UIDH",
        "X-Wap-Profile", "X-ATT-DeviceId", "X-Powered-By", "X-Content-Type-Options",
        "X-Real-IP", "Idempotency-Key", "Correlation-ID",
    ]

    /// Curated value suggestions for a given header name (case-insensitive).
    /// These are common *prefixes* or complete values a user is likely to want.
    /// Returns an empty array for headers with no meaningful curated values.
    static func valueTemplates(forHeader header: String) -> [String] {
        switch header.lowercased() {
        case "authorization":
            return ["Bearer ", "Basic ", "Token ", "ApiKey "]
        case "proxy-authorization":
            return ["Basic ", "Bearer "]
        case "content-type":
            return [
                "application/json", "application/json; charset=utf-8",
                "application/x-www-form-urlencoded", "multipart/form-data",
                "text/plain", "text/html", "application/xml", "application/octet-stream",
                "application/graphql",
            ]
        case "accept":
            return [
                "*/*", "application/json", "application/json, text/plain, */*",
                "text/html", "application/xml", "application/vnd.api+json",
            ]
        case "accept-encoding":
            return ["gzip, deflate, br", "gzip, deflate", "gzip", "identity", "br"]
        case "accept-language":
            return ["en-US,en;q=0.9", "en", "ar", "ar-SA,ar;q=0.9,en;q=0.8", "fr", "es"]
        case "cache-control":
            return ["no-cache", "no-store", "no-cache, no-store, must-revalidate",
                    "max-age=0", "max-age=3600", "public", "private"]
        case "pragma":
            return ["no-cache"]
        case "connection":
            return ["keep-alive", "close"]
        case "x-requested-with":
            return ["XMLHttpRequest"]
        case "upgrade-insecure-requests":
            return ["1"]
        case "dnt", "sec-gpc":
            return ["1", "0"]
        case "content-encoding", "te":
            return ["gzip", "deflate", "br", "identity", "chunked"]
        case "origin", "referer":
            return ["https://"]
        case "cookie":
            return []
        case "user-agent":
            return [
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            ]
        case "x-api-version", "x-app-version", "x-client-version", "api-version":
            return ["1", "1.0", "v1", "v2", "2024-01-01"]
        case "x-platform":
            return ["ios", "android", "web"]
        case "sec-fetch-mode":
            return ["cors", "navigate", "no-cors", "same-origin"]
        case "sec-fetch-site":
            return ["same-origin", "same-site", "cross-site", "none"]
        case "sec-fetch-dest":
            return ["empty", "document", "image", "script"]
        case "idempotency-key", "x-request-id", "x-correlation-id", "x-trace-id",
             "correlation-id", "x-session-id":
            return [UUIDPlaceholder]
        case "content-length", "age", "max-forwards", "access-control-max-age":
            return ["0"]
        default:
            return []
        }
    }

    /// A sentinel the UI expands into a fresh UUID when picked.
    static let UUIDPlaceholder = "«new-uuid»"
}
