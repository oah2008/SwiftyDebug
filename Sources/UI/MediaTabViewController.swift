//
//  MediaTabViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// The top-level **Media** tab. It is the single home for everything media in the
/// debugger and aggregates two sources (see MEDIA-TAB):
///
/// 1. **Captured media requests** — image/video/audio/font responses that were
///    intercepted as real transactions. These are deliberately filtered *out* of
///    the Network tab (see `NetworkViewController.isMediaTransaction`) so API
///    traffic stays readable, and surface here instead with their full request
///    details one tap away.
/// 2. **Images parsed out of JSON response bodies** — URLs discovered by
///    `MediaMetadataExtractor` at capture time. We know the URL but never saw a
///    transaction for it.
///
/// Live-updates as new requests arrive. Reuses `MediaGalleryViewController` for
/// rendering so the grid/detail/pager behavior is identical to the per-request
/// JSON-MEDIA "show all".
final class MediaTabViewController: MediaGalleryViewController {

    private var observer: NSObjectProtocol?
    private var clearedObserver: NSObjectProtocol?
    /// Coalesce rapid refreshes into one reload per run-loop tick.
    private var refreshScheduled = false

    init() {
        super.init(items: MediaTabViewController.collectAllItems(), title: "Media")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        observer = NotificationCenter.default.addObserver(
            forName: .networkRequestCompleted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        clearedObserver = NotificationCenter.default.addObserver(
            forName: .allLogsCleared, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh on appear so switching to the tab shows the latest media.
        update(items: MediaTabViewController.collectAllItems())
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshScheduled = false
            // Only reload while visible to avoid needless work in the background.
            if self.viewIfLoaded?.window != nil {
                self.update(items: MediaTabViewController.collectAllItems())
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let clearedObserver { NotificationCenter.default.removeObserver(clearedObserver) }
    }

    // MARK: - Aggregation

    /// Collects, newest-first, every unique media item across all captured
    /// requests: the media requests themselves plus every image URL discovered
    /// inside JSON response bodies.
    ///
    /// Uses only in-memory state (`isImage`/`mineType` and the precomputed
    /// `searchIndex.imageURLs`), so no disk reads or re-parsing happen here.
    /// Deduplicated by URL, with the transaction-backed entry winning so the
    /// details page can show the full request.
    static func collectAllItems() -> [MediaItem] {
        guard SwiftyDebugRuntime.isActive else { return [] }
        let models = (NetworkRequestStore.shared.httpModels as NSArray as? [NetworkTransaction]) ?? []
        // Where each URL already landed in `result`, not just that it was seen:
        // a captured request met later in the walk has to *upgrade* the entry a
        // newer JSON body put there first. A plain seen-set drops the capture
        // whenever any newer response body happens to mention the same image
        // URL, and the details page then has no method/status/headers and no
        // "View source request" for a request sitting in the store.
        var indexByURL: [String: Int] = [:]
        var result: [MediaItem] = []

        // Newest first (the store appends, so iterate in reverse).
        for model in models.reversed() {
            // (a) the media request itself
            if NetworkViewController.isMediaTransaction(model),
               let urlString = model.url?.absoluteString,
               !urlString.isEmpty {
                if let existing = indexByURL[urlString] {
                    // The transaction-backed entry wins, in the placeholder's
                    // position so the newest-first order is untouched.
                    if result[existing].transaction == nil {
                        result[existing] = MediaItem(urlString: urlString, transaction: model)
                    }
                } else {
                    indexByURL[urlString] = result.count
                    result.append(MediaItem(urlString: urlString, transaction: model))
                }
            }
            // (b) images parsed out of this request's JSON response body
            for urlString in model.imageURLs where indexByURL[urlString] == nil {
                indexByURL[urlString] = result.count
                result.append(MediaItem(urlString: urlString))
            }
        }
        return result
    }

    /// Legacy URL-only aggregation (JSON-parsed images plus captured media URLs).
    static func collectAllImageURLs() -> [String] {
        return collectAllItems().map { $0.urlString }
    }
}
