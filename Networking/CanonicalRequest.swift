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
private func CanonicaliseHeaders(_ request: NSMutableURLRequest) {
    // If there's no content type and the request is a POST with a body, add a default
    // content type of "application/x-www-form-urlencoded".

    if request.value(forHTTPHeaderField: "Content-Type") == nil
        && request.httpMethod.caseInsensitiveCompare("POST") == .orderedSame
        && (request.httpBody != nil || request.httpBodyStream != nil)
    {
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }

    // If there's no "Accept" header, add a default.

    if request.value(forHTTPHeaderField: "Accept") == nil {
        request.setValue("*/*", forHTTPHeaderField: "Accept")
    }

    // If there's no "Accept-Encoding" header, add a default.

    if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    }

    // If there's no "Accept-Language" header, add a default. This is quite bogus; ideally we
    // should derive the correct "Accept-Language" value from the language that the app is running
    // in. However, that's quite difficult to get right, so rather than show some general purpose
    // code that might fail in some circumstances, I've decided to just hardwire US English.
    // If you use this code in your own app you can customise it as you see fit. One option might be
    // to base this value on -[NSBundle preferredLocalizations], so that the web page comes back in
    // the language that the app is running in.

    if request.value(forHTTPHeaderField: "Accept-Language") == nil {
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
    }
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
/// IMPORTANT: While you can take most of this code as read, you might want to tweak
/// the handling of the "Accept-Language" in the CanonicaliseHeaders routine.
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
