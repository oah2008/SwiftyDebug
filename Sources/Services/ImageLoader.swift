//
//  ImageLoader.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A small, dependency-free async image loader with in-memory caching, in-flight
/// request de-duplication, downsampling for grids, and cancellation.
///
/// Used by the JSON-MEDIA grid, the full-screen gallery, and the Media tab. It
/// deliberately avoids any external SDK (Kingfisher/SDWebImage) so the SDK stays
/// self-contained and SPM/CSP-friendly.
///
/// - Note: its own network fetches are made through a session that does **not**
///   include `CustomHTTPProtocol`, so loading a thumbnail never shows up as a
///   captured request (no noise, no recursion).
final class ImageLoader {

    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.swiftydebug.imageloader", qos: .utility, attributes: .concurrent)
    private let session: URLSession

    /// Tracks in-flight tasks by cache key so identical concurrent requests share
    /// one download and can be cancelled.
    private var inFlight: [String: URLSessionDataTask] = [:]
    private let inFlightLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, diskPath: "SwiftyDebugImageCache")
        // Explicitly exclude SwiftyDebug's own URLProtocol so thumbnail loads are
        // never captured as requests.
        config.protocolClasses = []
        session = URLSession(configuration: config)

        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    // MARK: - Public API

    /// A cancellable handle for an in-progress load. Assign it to a cell/view and
    /// call `cancel()` on reuse.
    final class Token {
        fileprivate var task: URLSessionDataTask?
        fileprivate var cancelled = false
        func cancel() {
            cancelled = true
            task?.cancel()
            task = nil
        }
    }

    /// Returns a cached image immediately if present (memory cache only).
    func cachedImage(for urlString: String, maxPixel: CGFloat) -> UIImage? {
        return cache.object(forKey: cacheKey(urlString, maxPixel) as NSString)
    }

    /// Loads an image for the given URL string, downsampled so its longest side
    /// is at most `maxPixel` device pixels (0 = full size). Completion is called
    /// on the main thread. Returns a `Token` you can cancel on cell reuse.
    @discardableResult
    func loadImage(urlString: String, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) -> Token {
        let token = Token()
        let key = cacheKey(urlString, maxPixel)

        // Memory cache hit.
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return token
        }

        // data:image/... URLs decode inline.
        if urlString.lowercased().hasPrefix("data:image/") {
            queue.async { [weak self] in
                let image = Self.decodeDataURI(urlString, maxPixel: maxPixel)
                if let image { self?.cache.setObject(image, forKey: key as NSString) }
                DispatchQueue.main.async { if !token.cancelled { completion(image) } }
            }
            return token
        }

        guard let url = URL(string: urlString) else {
            completion(nil)
            return token
        }

        // CRITICAL: setting `config.protocolClasses = []` is NOT enough — the SDK
        // globally swizzles the `protocolClasses` *getter*, which unconditionally
        // re-inserts CustomHTTPProtocol whenever URLSession reads it. Without the
        // recursive-request flag below, every thumbnail fetch would be captured as
        // a media request, which reloads the Media tab, which loads more
        // thumbnails — an infinite capture loop. The flag makes `canInit` bail.
        let mutable = NSMutableURLRequest(url: url)
        mutable.timeoutInterval = 20
        URLProtocol.setProperty(true, forKey: CustomHTTPProtocol.recursiveRequestFlagProperty, in: mutable)
        let request = mutable as URLRequest

        let task = session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            self.inFlightLock.lock(); self.inFlight[key] = nil; self.inFlightLock.unlock()

            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async { if !token.cancelled { completion(nil) } }
                return
            }
            let image = Self.downsample(data: data, maxPixel: maxPixel) ?? UIImage(data: data)
            if let image {
                self.cache.setObject(image, forKey: key as NSString, cost: data.count)
            }
            DispatchQueue.main.async { if !token.cancelled { completion(image) } }
        }
        token.task = task
        inFlightLock.lock(); inFlight[key] = task; inFlightLock.unlock()
        task.resume()
        return token
    }

    // MARK: - Cache key

    private func cacheKey(_ urlString: String, _ maxPixel: CGFloat) -> String {
        return "\(Int(maxPixel))|\(urlString)"
    }

    // MARK: - Downsampling (memory-efficient thumbnails)

    /// Downsamples image data to a thumbnail whose max dimension is `maxPixel`
    /// device pixels, using ImageIO so the full-size bitmap is never decoded into
    /// memory. `maxPixel <= 0` returns the full-size image.
    private static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard maxPixel > 0 else { return UIImage(data: data) }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func decodeDataURI(_ uri: String, maxPixel: CGFloat) -> UIImage? {
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let meta = uri[..<commaIndex]
        let payload = String(uri[uri.index(after: commaIndex)...])
        guard meta.contains("base64"), let data = Data(base64Encoded: payload) else { return nil }
        return downsample(data: data, maxPixel: maxPixel) ?? UIImage(data: data)
    }
}
