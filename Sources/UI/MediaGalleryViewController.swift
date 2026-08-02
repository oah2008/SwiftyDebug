//
//  MediaGalleryViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - Media item

/// One tile in a media grid.
///
/// A media item is either
/// - a **captured media request** (`transaction != nil`) — an image/video/audio/
///   font response that was intercepted and routed out of the Network tab, or
/// - an **image URL parsed out of a JSON response body** (`transaction == nil`) —
///   we know the URL but never saw a transaction for it.
struct MediaItem {

    /// Absolute URL string of the asset (or a `data:image/...` URI).
    let urlString: String

    /// The captured request backing this item, when there is one.
    let transaction: NetworkTransaction?

    init(urlString: String, transaction: NetworkTransaction? = nil) {
        self.urlString = urlString
        self.transaction = transaction
    }

    /// Last path component without query/fragment — used as a display name.
    var displayName: String {
        if urlString.lowercased().hasPrefix("data:") { return "inline data" }
        var s = urlString
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        let last = s.components(separatedBy: "/").last ?? s
        return last.isEmpty ? s : last
    }

    /// Short uppercase type token ("PNG", "MP4", "WOFF2", …) for fallback tiles.
    var typeToken: String {
        if let mime = transaction?.mineType?.lowercased(),
           let sub = mime.components(separatedBy: ";").first?.components(separatedBy: "/").last,
           !sub.isEmpty {
            return sub.uppercased()
        }
        let ext = (displayName as NSString).pathExtension
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }

    /// Whether this item is expected to decode into a displayable image.
    /// JSON-parsed entries are image URLs by construction; captured requests are
    /// judged by their MIME type / `isImage` flag.
    var isLikelyImage: Bool {
        guard let tx = transaction else { return true }
        if tx.isImage { return true }
        guard let mime = tx.mineType?.lowercased(), !mime.isEmpty else { return true }
        return mime.hasPrefix("image/")
    }

    /// SF Symbol used when there is no renderable thumbnail.
    var fallbackSymbolName: String {
        guard let mime = transaction?.mineType?.lowercased() else { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("font/") { return "textformat" }
        return "photo"
    }
}

// MARK: - Gallery

/// A performant media gallery: 3 columns of downsampled thumbnails backed by the
/// bundled `ImageLoader` (cells cancel loads on reuse; ImageIO downsampling keeps
/// memory bounded). Tapping a tile pushes `MediaDetailViewController`, which in
/// turn opens the full-screen, zoomable, swipeable pager.
///
/// Used by the JSON-MEDIA "Show all" affordance and by the main Media tab.
class MediaGalleryViewController: UIViewController {

    fileprivate var items: [MediaItem]
    fileprivate let galleryTitle: String
    fileprivate var collectionView: UICollectionView!
    private var emptyLabel: UILabel!

    private static let columns: CGFloat = 3
    private static let spacing: CGFloat = 2

    // MARK: - Init

    /// Convenience init for plain URL lists (JSON-parsed media).
    convenience init(imageURLs: [String], title: String = "Media") {
        self.init(items: imageURLs.map { MediaItem(urlString: $0) }, title: title)
    }

    init(items: [MediaItem], title: String = "Media") {
        self.items = items
        self.galleryTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let navTitle = UILabel()
        navTitle.font = .boldSystemFont(ofSize: 18)
        navTitle.textColor = DebugTheme.accentColor
        navigationItem.titleView = navTitle

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(MediaThumbCell.self, forCellWithReuseIdentifier: "MediaThumbCell")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        view.addSubview(collectionView)

        // Empty state (kept around and toggled, so live updates can reveal/hide it).
        emptyLabel = UILabel()
        emptyLabel.text = "No media captured yet"
        emptyLabel.textColor = UIColor(white: 0.5, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        refreshChrome()
        view.forceLTR()
    }

    // MARK: - Updating

    /// Update the set of items (used by the live Media tab).
    func update(items: [MediaItem]) {
        self.items = items
        collectionView?.reloadData()
        refreshChrome()
    }

    /// Update from a plain URL list (JSON-parsed media only).
    func update(imageURLs: [String]) {
        update(items: imageURLs.map { MediaItem(urlString: $0) })
    }

    private func refreshChrome() {
        if let navTitle = navigationItem.titleView as? UILabel {
            navTitle.text = items.isEmpty ? galleryTitle : "\(galleryTitle) · \(items.count)"
            navTitle.sizeToFit()
        }
        emptyLabel?.isHidden = !items.isEmpty
    }
}

// MARK: - Collection view

extension MediaGalleryViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "MediaThumbCell", for: indexPath) as! MediaThumbCell
        cell.configure(item: items[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing = Self.spacing * (Self.columns - 1)
        let side = ((collectionView.bounds.width - totalSpacing) / Self.columns).rounded(.down)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        let detail = MediaDetailViewController(items: items, startIndex: indexPath.item)
        if let nav = navigationController {
            nav.pushViewController(detail, animated: true)
        } else {
            // No nav stack (shouldn't happen inside the debugger) — fall back to
            // the full-screen pager so the tap still does something useful.
            let pager = MediaPagerViewController(imageURLs: items.map { $0.urlString }, startIndex: indexPath.item)
            pager.modalPresentationStyle = .fullScreen
            present(pager, animated: true)
        }
    }
}

// MARK: - Thumbnail cell

private final class MediaThumbCell: UICollectionViewCell {

    private let imageView = UIImageView()
    private let fallbackIcon = UIImageView()
    private let typeLabel = UILabel()
    private var token: ImageLoader.Token?
    private var currentURL: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        fallbackIcon.contentMode = .scaleAspectFit
        fallbackIcon.tintColor = UIColor(white: 0.35, alpha: 1)
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fallbackIcon)

        typeLabel.font = .systemFont(ofSize: 9, weight: .heavy)
        typeLabel.textColor = UIColor(white: 0.55, alpha: 1)
        typeLabel.textAlignment = .center
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(typeLabel)

        NSLayoutConstraint.activate([
            fallbackIcon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -6),
            fallbackIcon.widthAnchor.constraint(equalToConstant: 26),
            fallbackIcon.heightAnchor.constraint(equalToConstant: 26),

            typeLabel.topAnchor.constraint(equalTo: fallbackIcon.bottomAnchor, constant: 4),
            typeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            typeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
        ])

        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        token?.cancel()
        token = nil
        imageView.image = nil
        currentURL = nil
        setFallback(visible: false, item: nil)
    }

    func configure(item: MediaItem) {
        let urlString = item.urlString
        currentURL = urlString

        guard item.isLikelyImage else {
            setFallback(visible: true, item: item)
            return
        }

        let maxPixel = max(160, bounds.width * UIScreen.main.scale)
        if let cached = ImageLoader.shared.cachedImage(for: urlString, maxPixel: maxPixel) {
            imageView.image = cached
            setFallback(visible: false, item: item)
            return
        }
        setFallback(visible: true, item: item)
        token = ImageLoader.shared.loadImage(urlString: urlString, maxPixel: maxPixel) { [weak self] image in
            guard let self = self, self.currentURL == urlString else { return }
            self.imageView.image = image
            self.setFallback(visible: image == nil, item: item)
        }
    }

    private func setFallback(visible: Bool, item: MediaItem?) {
        fallbackIcon.isHidden = !visible
        typeLabel.isHidden = !visible
        guard visible, let item = item else { return }
        fallbackIcon.image = UIImage(systemName: item.fallbackSymbolName)
        typeLabel.text = item.typeToken
    }
}

// MARK: - Full-screen zoomable pager

/// Full-screen, zoomable, horizontally-paged media viewer.
///
/// Dismissal is deliberately over-provisioned (see MEDIA-CLOSE): a large, always
/// front-most circular ✕ button **and** a swipe-down gesture, so the viewer can
/// never trap the user even if a host window swallows a tap.
final class MediaPagerViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    private let imageURLs: [String]
    /// The page the user is on. Also the centre of the live window.
    private var startIndex: Int
    private let pageScroll = UIScrollView()

    /// The pages that currently exist, keyed by index — **not** one per URL.
    ///
    /// Every page used to be built up front and loaded at `maxPixel: 0`, i.e.
    /// decoded at full resolution. A 12 MP asset is ~48 MB decoded, so opening a
    /// gallery of large images asked for hundreds of megabytes at once and got
    /// the host app jetsammed instead. Only the visible page and its two
    /// neighbours are alive now, and they are downsampled to the screen.
    private var pages: [Int: UIScrollView] = [:]
    /// In-flight image loads, so a page leaving the window cancels its download
    /// instead of decoding into a view that is already gone.
    private var tokens: [Int: ImageLoader.Token] = [:]

    private let closeButton = UIButton(type: .system)
    private let counterLabel = UILabel()

    /// 44pt hit target, per HIG minimum.
    private static let closeButtonSize: CGFloat = 44

    /// Tag of the `UIImageView` inside each zoom page.
    private static let imageViewTag = 100

    /// Which pages exist at once: the current one and its immediate neighbours,
    /// so a swipe never lands on an empty page and the count never grows with
    /// the size of the gallery.
    ///
    /// Pure, and clamped to `count`, so the window is testable without a screen.
    static func windowedIndices(around index: Int, count: Int) -> Set<Int> {
        guard count > 0 else { return [] }
        let current = max(0, min(index, count - 1))
        var window: Set<Int> = [current]
        if current - 1 >= 0 { window.insert(current - 1) }
        if current + 1 < count { window.insert(current + 1) }
        return window
    }

    /// Longest side, in device pixels, a full-screen page is decoded to.
    ///
    /// Never 0: `ImageLoader` reads 0 as "decode at full resolution", which is
    /// the defect this replaced. Sharpness past 1x zoom is the price; being
    /// killed by the OS is the alternative.
    static func pageMaxPixel(forScreenSize size: CGSize, scale: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        return max(640, (longest * max(1, scale)).rounded())
    }

    /// Test hook: the pages that are actually built right now.
    var loadedPageIndices: Set<Int> { Set(pages.keys) }

    init(imageURLs: [String], startIndex: Int) {
        self.imageURLs = imageURLs
        self.startIndex = max(0, min(startIndex, max(0, imageURLs.count - 1)))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        pageScroll.isPagingEnabled = true
        pageScroll.showsHorizontalScrollIndicator = false
        pageScroll.delegate = self
        pageScroll.frame = view.bounds
        pageScroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageScroll)

        // Close button — a solid, always-on-top hit target with a background
        // circle and a hairline ring so it stays obvious over any image, and so
        // it can't be swallowed by the paging scroll view's gestures.
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)),
            for: .normal
        )
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0, alpha: 0.6)
        closeButton.layer.cornerRadius = Self.closeButtonSize / 2
        closeButton.layer.borderWidth = 1
        closeButton.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOpacity = 0.5
        closeButton.layer.shadowRadius = 6
        closeButton.layer.shadowOffset = .zero
        closeButton.accessibilityLabel = "Close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // Page counter pill.
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        counterLabel.textColor = UIColor(white: 0.85, alpha: 1)
        counterLabel.textAlignment = .center
        counterLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        counterLabel.layer.cornerRadius = 12
        counterLabel.layer.cornerCurve = .continuous
        counterLabel.clipsToBounds = true
        counterLabel.isHidden = imageURLs.count <= 1
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(counterLabel)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),

            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counterLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            counterLabel.heightAnchor.constraint(equalToConstant: 24),
            counterLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])

        // Swipe-down-to-dismiss — a second, gesture-based escape hatch.
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(closeTapped))
        swipeDown.direction = .down
        swipeDown.delegate = self
        view.addGestureRecognizer(swipeDown)

        updateCounter()
        view.forceLTR()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        // Keep the close button (and counter) above the paging scroll view after
        // every layout pass (layoutPages re-frames the scroll view), so taps
        // always land on the button.
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(counterLabel)
    }

    private var didInitialScroll = false

    private func layoutPages() {
        let pageWidth = view.bounds.width
        pageScroll.frame = view.bounds
        pageScroll.contentSize = CGSize(width: pageWidth * CGFloat(imageURLs.count),
                                        height: view.bounds.height)

        // Before building the window, so the window is centred on the page the
        // caller asked for rather than on page 0.
        if !didInitialScroll, pageWidth > 0 {
            didInitialScroll = true
            pageScroll.setContentOffset(CGPoint(x: pageWidth * CGFloat(startIndex), y: 0), animated: false)
        }

        // A layout pass means the geometry changed (rotation, safe area), so the
        // zoom the user had no longer maps to anything.
        refreshWindow(resettingZoom: true)
    }

    /// Builds the pages inside the window, throws away the ones outside it, and
    /// frames what is left. The single place that decides which bitmaps exist.
    private func refreshWindow(resettingZoom: Bool) {
        let pageWidth = view.bounds.width
        let pageHeight = view.bounds.height
        let wanted = Self.windowedIndices(around: startIndex, count: imageURLs.count)

        for index in Array(pages.keys) where !wanted.contains(index) { discardPage(at: index) }

        for index in wanted {
            let existing = pages[index]
            let page = existing ?? makePage(at: index)
            page.frame = CGRect(x: pageWidth * CGFloat(index), y: 0, width: pageWidth, height: pageHeight)
            if resettingZoom || existing == nil { page.zoomScale = 1 }
            page.viewWithTag(Self.imageViewTag)?.frame = page.bounds
        }
    }

    private func makePage(at index: Int) -> UIScrollView {
        let zoom = UIScrollView()
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = 4
        zoom.delegate = self
        zoom.showsHorizontalScrollIndicator = false
        zoom.showsVerticalScrollIndicator = false

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tag = Self.imageViewTag
        zoom.addSubview(iv)
        pageScroll.addSubview(zoom)
        pages[index] = zoom
        // Pages are built throughout the pager's life now, so each one forces its
        // own direction — `viewDidLoad`'s recursive pass cannot reach them.
        zoom.forceLTR()

        guard imageURLs.indices.contains(index) else { return zoom }
        let maxPixel = Self.pageMaxPixel(forScreenSize: UIScreen.main.bounds.size,
                                         scale: UIScreen.main.scale)
        tokens[index] = ImageLoader.shared.loadImage(urlString: imageURLs[index],
                                                     maxPixel: maxPixel) { [weak iv] image in
            iv?.image = image
        }
        return zoom
    }

    private func discardPage(at index: Int) {
        tokens[index]?.cancel()
        tokens[index] = nil
        if let page = pages[index] {
            (page.viewWithTag(Self.imageViewTag) as? UIImageView)?.image = nil
            page.removeFromSuperview()
        }
        pages[index] = nil
    }

    private func updateCounter() {
        guard imageURLs.count > 1 else { return }
        counterLabel.text = "  \(startIndex + 1) / \(imageURLs.count)  "
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return scrollView.viewWithTag(Self.imageViewTag)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pageScroll, view.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / view.bounds.width).rounded())
        let clamped = max(0, min(page, max(0, imageURLs.count - 1)))
        if clamped != startIndex {
            startIndex = clamped
            updateCounter()
            // The window follows the user: the page they just left is dropped and
            // the one they are heading for is built, one swipe ahead of the swipe.
            refreshWindow(resettingZoom: false)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't hijack a swipe while the user is panning a zoomed-in image.
        guard gestureRecognizer is UISwipeGestureRecognizer else { return true }
        let zoomed = pages.values.contains { $0.zoomScale > 1.01 }
        return !zoomed
    }

    // MARK: - Dismissal

    @objc private func closeTapped() {
        // Works whether the viewer was presented modally or pushed.
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}
