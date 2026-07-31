//
//  CanonicalRequest.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

// MARK: - URL canonicalization steps

/// A step in the canonicalization process.
///
/// The canonicalization process is made up of a sequence of steps, each of which is
/// implemented by a function that matches this type. The function gets a URL
/// and a mutable buffer holding that URL as bytes. The function can mutate the buffer as it
/// sees fit. It typically does this by calling CFURLGetByteRangeForComponent to find the range
/// of interest in the buffer. In that case bytesInserted is the amount to adjust that range,
/// and the function should modify that to account for any bytes it inserts or deletes. If
/// the function modifies the buffer too much, it can return kCFNotFound to force the system
/// to re-create the URL from the buffer.
///
/// - Parameters:
///   - url: The original URL to work on.
///   - urlData: The URL as a mutable buffer; the routine modifies this.
///   - bytesInserted: The number of bytes that have been inserted so far in the mutable buffer.
/// - Returns: An updated value of bytesInserted or kCFNotFound if the URL must be reparsed.
private typealias CanonicalRequestStepFunction = (_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex

/// The post-scheme separator should be "://"; if that's not the case, fix it.
private func FixPostSchemeSeparator(_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex {
    var bytesInserted = bytesInserted

    let range = CFURLGetByteRangeForComponent(url as CFURL, .scheme, nil)
    if range.location != kCFNotFound {
        let urlDataBytes = urlData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let urlDataLength = urlData.length

        var separatorLength = 0
        var cursor = Int(range.location) + Int(bytesInserted) + Int(range.length)
        if cursor < urlDataLength && urlDataBytes[cursor] == UInt8(ascii: ":") {
            cursor += 1
            separatorLength += 1
            if cursor < urlDataLength && urlDataBytes[cursor] == UInt8(ascii: "/") {
                cursor += 1
                separatorLength += 1
                if cursor < urlDataLength && urlDataBytes[cursor] == UInt8(ascii: "/") {
                    cursor += 1
                    separatorLength += 1
                }
            }
        }
        _ = cursor // quiets unused variable warning

        let expectedSeparatorLength = 3 // strlen("://")
        if separatorLength != expectedSeparatorLength {
            let replaceRange = NSRange(
                location: Int(range.location) + Int(bytesInserted) + Int(range.length),
                length: separatorLength
            )
            "://".withCString { cStr in
                urlData.replaceBytes(in: replaceRange, withBytes: cStr, length: expectedSeparatorLength)
            }
            bytesInserted = kCFNotFound // have to rebuild everything now
        }
    }

    return bytesInserted
}

/// The scheme should be lower case; if it's not, make it so.
private func LowercaseScheme(_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex {
    let range = CFURLGetByteRangeForComponent(url as CFURL, .scheme, nil)
    if range.location != kCFNotFound {
        let urlDataBytes = urlData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let start = Int(range.location + bytesInserted)
        let end = Int(range.location + bytesInserted + range.length)
        for i in start..<end {
            urlDataBytes[i] = UInt8(bitPattern: Int8(tolower(Int32(urlDataBytes[i]))))
        }
    }
    return bytesInserted
}

/// The host should be lower case; if it's not, make it so.
private func LowercaseHost(_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex {
    let range = CFURLGetByteRangeForComponent(url as CFURL, .host, nil)
    if range.location != kCFNotFound {
        let urlDataBytes = urlData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let start = Int(range.location + bytesInserted)
        let end = Int(range.location + bytesInserted + range.length)
        for i in start..<end {
            urlDataBytes[i] = UInt8(bitPattern: Int8(tolower(Int32(urlDataBytes[i]))))
        }
    }
    return bytesInserted
}

/// An empty host should be treated as "localhost"; if it's not, make it so.
private func FixEmptyHost(_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex {
    var bytesInserted = bytesInserted
    var rangeWithSeparator = CFRange(location: 0, length: 0)

    let range = CFURLGetByteRangeForComponent(url as CFURL, .host, &rangeWithSeparator)
    if range.length == 0 {
        let localhostLength = 9 // strlen("localhost")
        if range.location != kCFNotFound {
            let replaceRange = NSRange(location: Int(range.location) + Int(bytesInserted), length: 0)
            "localhost".withCString { cStr in
                urlData.replaceBytes(in: replaceRange, withBytes: cStr, length: localhostLength)
            }
            bytesInserted += CFIndex(localhostLength)
        } else if rangeWithSeparator.location != kCFNotFound && rangeWithSeparator.length == 0 {
            let replaceRange = NSRange(location: Int(rangeWithSeparator.location) + Int(bytesInserted), length: 0)
            "localhost".withCString { cStr in
                urlData.replaceBytes(in: replaceRange, withBytes: cStr, length: localhostLength)
            }
            bytesInserted += CFIndex(localhostLength)
        }
    }
    return bytesInserted
}

/// Transform an empty URL path to "/".
/// For example, "http://www.apple.com" becomes "http://www.apple.com/".
private func FixEmptyPath(_ url: URL, _ urlData: NSMutableData, _ bytesInserted: CFIndex) -> CFIndex {
    var bytesInserted = bytesInserted
    var rangeWithSeparator = CFRange(location: 0, length: 0)

    let range = CFURLGetByteRangeForComponent(url as CFURL, .path, &rangeWithSeparator)
    // The following is not a typo. We use rangeWithSeparator to find where to insert the
    // "/" and the range length to decide whether we /need/ to insert the "/".
    if rangeWithSeparator.location != kCFNotFound && range.length == 0 {
        let replaceRange = NSRange(location: Int(rangeWithSeparator.location) + Int(bytesInserted), length: 0)
        "/".withCString { cStr in
            urlData.replaceBytes(in: replaceRange, withBytes: cStr, length: 1)
        }
        bytesInserted += 1
    }
    return bytesInserted
}

// MARK: - Other request canonicalization

/// Canonicalize the request headers.
///
/// Historically this force-added default `Content-Type`, `Accept`,
/// `Accept-Encoding` and `Accept-Language` headers. `Accept-Language` is no
/// longer among them at all — see the note at the bottom of this function; the
/// hardwired `en-us` overrode the device language for the whole host app.
///
/// Force-adding the rest defeats intercept
/// rules that try to *remove* one of those headers: canonicalization runs first
/// and re-adds the default, so the removal has nothing to remove and the header
/// still goes out. To make header removal reliable (see WEBVIEW-HEADERS), we
/// skip adding a default for any header that a matching, enabled intercept rule
/// explicitly removes (and don't touch headers a rule overrides — the override
/// is applied later in `startLoading`).
private func CanonicaliseHeaders(_ request: NSMutableURLRequest) {
    // Determine which default headers a matching rule wants gone, so we don't
    // re-inject them here. Case-insensitive.
    var removedByRule = Set<String>()
    if let url = request.url, let rule = InterceptRuleStore.shared.resolvedRule(forURL: url) {
        removedByRule = Set(rule.removedHeaderKeys.map { $0.lowercased() })
    }

    func shouldAddDefault(_ header: String) -> Bool {
        return !removedByRule.contains(header.lowercased())
    }

    // If there's no content type and the request is a POST with a body, add a default
    // content type of "application/x-www-form-urlencoded".

    if request.value(forHTTPHeaderField: "Content-Type") == nil
        && request.httpMethod.caseInsensitiveCompare("POST") == .orderedSame
        && (request.httpBody != nil || request.httpBodyStream != nil)
        && shouldAddDefault("Content-Type")
    {
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }

    // If there's no "Accept" header, add a default.

    if request.value(forHTTPHeaderField: "Accept") == nil && shouldAddDefault("Accept") {
        request.setValue("*/*", forHTTPHeaderField: "Accept")
    }

    // If there's no "Accept-Encoding" header, add a default.

    if request.value(forHTTPHeaderField: "Accept-Encoding") == nil && shouldAddDefault("Accept-Encoding") {
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    }

    // NO DEFAULT "Accept-Language" IS ADDED HERE, DELIBERATELY.
    //
    // This used to hardwire `en-us` onto every request that did not already
    // carry the header — sample code whose own comment conceded it was "quite
    // bogus" and that deriving the real value was "difficult to get right".
    // Inside an SDK embedded in someone else's app it is worse than bogus: a
    // Japanese or Arabic device asks the server for US English, the server
    // answers in US English, and the host app's localisation looks broken to
    // everyone who installed the build. The header is not something the app
    // ever set, so nothing in the app can be adjusted to fix it.
    //
    // Getting it right is not our job either. CFNetwork fills in
    // `Accept-Language` from the device's preferred languages on any request
    // that reaches the wire without one, which is exactly the value the app
    // would have sent with SwiftyDebug absent. Leaving the header off is what
    // makes the two identical.
}

// MARK: - API

/// Returns a canonical form of the supplied request.
///
/// The Foundation URL loading system needs to be able to canonicalize URL
/// requests for various reasons (for example, to look for cache hits). The default
/// HTTP/HTTPS protocol has a complex chunk of code to perform this function. Unfortunately
/// there's no way for third party code to access this. Instead, we have to reimplement
/// it all ourselves. This is split off into a separate file to emphasise that this
/// is standard boilerplate that you probably don't need to look at.
///
/// IMPORTANT: this must produce the request the host app WOULD have sent. Any
/// header added here is added to someone else's app, so `CanonicaliseHeaders`
/// adds only the ones CFNetwork cannot supply for itself.
///
/// - Parameter request: The request to canonicalize; must not be nil.
/// - Returns: The canonical request; should never be nil.
func CanonicalRequestForRequest(_ request: URLRequest) -> NSMutableURLRequest {

    // Make a mutable copy of the request.

    let result = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest

    // First up check that we're dealing with HTTP or HTTPS. If not, do nothing (why were we
    // even called?).

    guard let scheme = request.url?.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return result
    }

    let kStepFunctions: [CanonicalRequestStepFunction] = [
        FixPostSchemeSeparator,
        LowercaseScheme,
        LowercaseHost,
        FixEmptyHost,
        // DeleteDefaultPort -- The built-in canonicalizer has stopped doing this, so we don't do it either.
        FixEmptyPath
    ]

    // Canonicalize the URL by executing each of our step functions.

    var bytesInserted: CFIndex = kCFNotFound
    var urlData: NSMutableData? = nil
    var requestURL: URL = request.url!
    let stepCount = kStepFunctions.count

    for stepIndex in 0..<stepCount {

        // If we don't have valid URL data, create it from the URL.

        if bytesInserted == kCFNotFound {
            let urlDataImmutable = CFURLCreateData(nil, requestURL as CFURL, CFStringBuiltInEncodings.UTF8.rawValue, true) as Data
            urlData = NSMutableData(data: urlDataImmutable)
            bytesInserted = 0
        }

        // Run the step.

        bytesInserted = kStepFunctions[stepIndex](requestURL, urlData!, bytesInserted)

        // If the step invalidated our URL (or we're on the last step, whereupon we'll need
        // the URL outside of the loop), recreate the URL from the URL data.

        if bytesInserted == kCFNotFound || (stepIndex + 1) == stepCount {
            requestURL = CFURLCreateWithBytes(nil, urlData!.bytes.assumingMemoryBound(to: UInt8.self), CFIndex(urlData!.length), CFStringBuiltInEncodings.UTF8.rawValue, nil) as URL
            urlData = nil
        }
    }

    result.url = requestURL

    // Canonicalize the headers.

    CanonicaliseHeaders(result)

    return result
}
