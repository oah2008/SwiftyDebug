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
    ///
    /// `animated` has to match the flag the corresponding `loadImage` uses, or
    /// this reads the other variant's key and always misses.
    func cachedImage(for urlString: String, maxPixel: CGFloat, animated: Bool = false) -> UIImage? {
        return cache.object(forKey: cacheKey(urlString, maxPixel, animated) as NSString)
    }

    /// Loads an image for the given URL string, downsampled so its longest side
    /// is at most `maxPixel` device pixels (0 = full size). Completion is called
    /// on the main thread. Returns a `Token` you can cancel on cell reuse.
    ///
    /// `animated: true` decodes a multi-frame GIF into an animated `UIImage`
    /// instead of its first frame. It is opt-in per call site: a grid full of
    /// animated images holds every frame of every one of them decoded, which is
    /// the full-resolution memory blow-up the pager windowing work closed.
    @discardableResult
    func loadImage(urlString: String, maxPixel: CGFloat, animated: Bool = false, completion: @escaping (UIImage?) -> Void) -> Token {
        let token = Token()
        let key = cacheKey(urlString, maxPixel, animated)

        // Memory cache hit.
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return token
        }

        // data:image/... URLs decode inline.
        if urlString.lowercased().hasPrefix("data:image/") {
            queue.async { [weak self] in
                let image = Self.decodeDataURI(urlString, maxPixel: maxPixel, animated: animated)
                if let image { self?.cache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image)) }
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
            let image = Self.downsample(data: data, maxPixel: maxPixel, animated: animated) ?? UIImage(data: data)
            if let image {
                self.cache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))
            }
            DispatchQueue.main.async { if !token.cancelled { completion(image) } }
        }
        token.task = task
        inFlightLock.lock(); inFlight[key] = task; inFlightLock.unlock()
        task.resume()
        return token
    }

    // MARK: - Cache key

    private func cacheKey(_ urlString: String, _ maxPixel: CGFloat, _ animated: Bool = false) -> String {
        // `animated` is part of the key: the same asset at the same size decodes
        // to a single frame for a grid cell and to every frame for a full-screen
        // page, and one must never be served in place of the other.
        return "\(Int(maxPixel))|\(animated ? "a" : "s")|\(urlString)"
    }

    // MARK: - Cache cost

    /// The memory an entry really occupies: the resident bitmap, not the bytes
    /// downloaded. `totalCostLimit` is enforced against whatever cost insertion
    /// passes, and a downsampled page image is ~17 MB decoded against 1-3 MB of
    /// JPEG — costing the download under-counted by an order of magnitude, so
    /// the 64 MB budget held hundreds of megabytes of real memory and eviction
    /// never fired before the host app was jetsammed.
    ///
    /// Pure, so what the budget is actually counting is testable without a screen.
    static func memoryCost(of image: UIImage) -> Int {
        // EVERY frame. An animated `UIImage` holds one decoded bitmap per frame,
        // but `cgImage` is nil for it and `size` is the first frame's size — so
        // counting either alone reported a 100-frame GIF as 1/100th of what it
        // actually occupies, and the budget that exists to prevent a jetsam
        // happily admitted a hundred times its limit.
        let frameCount = max(1, image.images?.count ?? 1)
        if let cg = image.cgImage { return frameCount * cg.bytesPerRow * cg.height }
        if let first = image.images?.first?.cgImage { return frameCount * first.bytesPerRow * first.height }
        return frameCount * Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    // MARK: - Downsampling (memory-efficient thumbnails)

    /// Downsamples image data to a thumbnail whose max dimension is `maxPixel`
    /// device pixels, using ImageIO so the full-size bitmap is never decoded into
    /// memory. `maxPixel <= 0` returns the full-size image.
    ///
    /// `animated` only matters for multi-frame data (GIF): the thumbnail API
    /// decodes frame 0 and nothing else, so without this a GIF that plays in the
    /// request detail is frozen on every Media surface.
    private static func downsample(data: Data, maxPixel: CGFloat, animated: Bool = false) -> UIImage? {
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

        // An animated image is built from DOWNSAMPLED frames, through the same
        // options as a still. `UIImage.imageWithGIFData` decodes every frame at
        // native resolution, so returning it here ignored `maxPixel` entirely:
        // a 100-frame 800x800 GIF became ~256 MB resident instead of the capped
        // thumbnail the caller asked for — and the pager keeps three pages live.
        let frameCount = CGImageSourceGetCount(source)
        if animated, frameCount > 1 {
            var frames: [UIImage] = []
            frames.reserveCapacity(frameCount)
            var duration: Double = 0
            for index in 0..<frameCount {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    continue
                }
                frames.append(UIImage(cgImage: cg))
                duration += Double(UIImage.ssz_frameDurationAtIndex(index, source: source))
            }
            if let animatedImage = UIImage.animatedImage(with: frames, duration: duration), !frames.isEmpty {
                return animatedImage
            }
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func decodeDataURI(_ uri: String, maxPixel: CGFloat, animated: Bool = false) -> UIImage? {
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let meta = uri[..<commaIndex]
        let payload = String(uri[uri.index(after: commaIndex)...])
        guard meta.contains("base64"), let data = Data(base64Encoded: payload) else { return nil }
        return downsample(data: data, maxPixel: maxPixel, animated: animated) ?? UIImage(data: data)
    }
}
