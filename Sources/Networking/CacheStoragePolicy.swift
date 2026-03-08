//
//  CacheStoragePolicy.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

/// Determines the cache storage policy for a response.
///
/// When we provide a response up to the client we need to tell the client whether
/// the response is cacheable or not. The default HTTP/HTTPS protocol has a reasonably
/// complex chunk of code to determine this, but we can't get at it. Thus, we have to
/// reimplement it ourselves. This is split off into a separate file to emphasise that
/// this is standard boilerplate that you probably don't need to look at.
///
/// - Parameters:
///   - request: The request that generated the response; must not be nil.
///   - response: The response itself; must not be nil.
/// - Returns: A cache storage policy to use.
func CacheStoragePolicyForRequestAndResponse(_ request: URLRequest, _ response: HTTPURLResponse) -> URLCache.StoragePolicy {
    var cacheable: Bool

    // First determine if the request is cacheable based on its status code.
    switch response.statusCode {
    case 200, 203, 206, 301, 304, 404, 410:
        cacheable = true
    default:
        cacheable = false
    }

    // If the response might be cacheable, look at the "Cache-Control" header in
    // the response.

    // IMPORTANT: We can't rely on -rangeOfString: returning valid results if the target
    // string is nil, so we have to explicitly test for nil in the following two cases.

    if cacheable {
        if let responseHeader = (response.allHeaderFields["Cache-Control"] as? String)?.lowercased() {
            if responseHeader.range(of: "no-store") != nil {
                cacheable = false
            }
        }
    }

    // If we still think it might be cacheable, look at the "Cache-Control" header in
    // the request.

    if cacheable {
        if let requestHeader = request.allHTTPHeaderFields?["Cache-Control"]?.lowercased() {
            if requestHeader.range(of: "no-store") != nil && requestHeader.range(of: "no-cache") != nil {
                cacheable = false
            }
        }
    }

    // Use the cacheable flag to determine the result.

    if cacheable {
        // This code only caches HTTPS data in memory. This is inline with earlier versions of
        // iOS. Modern versions of iOS use file protection to protect the cache, and thus are
        // happy to cache HTTPS on disk. I've not made the corresponding change because
        // it's nice to see all three cache policies in action.

        if request.url?.scheme?.lowercased() == "https" {
            return .allowedInMemoryOnly
        } else {
            return .allowed
        }
    } else {
        return .notAllowed
    }
}
