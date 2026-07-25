//
//  MediaDetailViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Details page for a single media item — the media-tab counterpart of the
/// network detail screen.
///
/// For a **captured media request** it shows everything the transaction knows:
/// URL, method, status, MIME type, transfer sizes, timing, and both header sets.
/// For an **image URL parsed out of a JSON body** there is no transaction, so it
/// shows what can be discovered from the asset itself (pixel dimensions, byte
/// size, sniffed MIME type) and omits the request-specific rows.
///
/// Tapping the preview opens the shared full-screen zoomable pager, positioned
/// on this item and able to swipe through the whole set. (See MEDIA-DETAIL.)
final class MediaDetailViewController: UIViewController {

    // MARK: - Palette

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let teal = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
    private static let caption = UIColor(white: 0.45, alpha: 1)
    private static let valueText = UIColor(white: 0.88, alpha: 1)

    // MARK: - State

    private let items: [MediaItem]
    private let index: Int
    private var item: MediaItem { items[index] }

    private var probe: MediaAssetProbe.Result?
    private var previewToken: ImageLoader.Token?

    // MARK: - Subviews

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let previewImageView = UIImageView()
    private let previewPlaceholder = UIImageView()
    private let previewSpinner = UIActivityIndicatorView(style: .medium)
    private var infoCard: MediaInfoCard!

    // MARK: - Init

    init(items: [MediaItem], startIndex: Int) {
        precondition(!items.isEmpty, "MediaDetailViewController requires at least one item")
        self.items = items
        self.index = max(0, min(startIndex, items.count - 1))
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(item: MediaItem) {
        self.init(items: [item], startIndex: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { previewToken?.cancel() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let navTitle = UILabel()
        navTitle.text = "Media"
        navTitle.font = .boldSystemFont(ofSize: 18)
        navTitle.textColor = DebugTheme.accentColor
        navTitle.sizeToFit()
        navigationItem.titleView = navTitle

        let copyItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain, target: self, action: #selector(copyURL)
        )
        copyItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = copyItem

        setupScaffold()
        buildCards()
        loadPreview()
        loadProbe()

        view.forceLTR()
    }

    // MARK: - Layout scaffold

    private func setupScaffold() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .black
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor),
        ])
    }

    // MARK: - Cards

    private func buildCards() {
        stack.addArrangedSubview(makePreviewCard())

        infoCard = MediaInfoCard(title: "OVERVIEW")
        infoCard.setRows(makeInfoRows())
        stack.addArrangedSubview(infoCard)

        if let headers = item.transaction?.requestHeaderFields as? [String: Any], !headers.isEmpty {
            let card = MediaInfoCard(title: "REQUEST HEADERS")
            card.setRows(headerRows(from: headers))
            stack.addArrangedSubview(card)
        }
        if let headers = item.transaction?.responseHeaderFields as? [String: Any], !headers.isEmpty {
            let card = MediaInfoCard(title: "RESPONSE HEADERS")
            card.setRows(headerRows(from: headers))
            stack.addArrangedSubview(card)
        }
    }

    private func makePreviewCard() -> UIView {
        let card = UIView()
        card.backgroundColor = Self.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = UIView()
        wrapper.backgroundColor = UIColor(white: 0.07, alpha: 1)
        wrapper.layer.cornerRadius = 10
        wrapper.layer.cornerCurve = .continuous
        wrapper.clipsToBounds = true
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.isUserInteractionEnabled = true
        wrapper.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openFullscreen)))
        card.addSubview(wrapper)

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(previewImageView)

        previewPlaceholder.image = UIImage(systemName: item.fallbackSymbolName)
        previewPlaceholder.tintColor = UIColor(white: 0.30, alpha: 1)
        previewPlaceholder.contentMode = .scaleAspectFit
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(previewPlaceholder)

        previewSpinner.color = UIColor(white: 0.5, alpha: 1)
        previewSpinner.hidesWhenStopped = true
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(previewSpinner)

        let hint = UILabel()
        hint.text = items.count > 1
            ? "Tap image to view fullscreen · swipe between \(items.count) items"
            : "Tap image to view fullscreen"
        hint.font = .systemFont(ofSize: 10, weight: .semibold)
        hint.textColor = Self.caption
        hint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(hint)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            wrapper.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            wrapper.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            wrapper.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            wrapper.heightAnchor.constraint(equalToConstant: 240),

            previewImageView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

            previewPlaceholder.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            previewPlaceholder.widthAnchor.constraint(equalToConstant: 48),
            previewPlaceholder.heightAnchor.constraint(equalToConstant: 48),

            previewSpinner.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),

            hint.topAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        // Card is inset 12 from the screen edges like every other detail card.
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        return container
    }

    // MARK: - Rows

    private func makeInfoRows() -> [MediaInfoCard.Row] {
        var rows: [MediaInfoCard.Row] = []
        let tx = item.transaction

        rows.append(.init(caption: "URL", value: item.urlString, color: Self.teal))
        if let host = URL(string: item.urlString)?.host, !host.isEmpty {
            rows.append(.init(caption: "HOST", value: host))
        }
        rows.append(.init(caption: "FILE", value: item.displayName))

        if let tx = tx {
            rows.append(.init(caption: "SOURCE",
                              value: tx.isWebViewRequest ? "Captured request · WebView" : "Captured request · App"))
            rows.append(.init(caption: "METHOD", value: (tx.method ?? "GET").uppercased()))

            let code = tx.statusCode ?? "0"
            rows.append(.init(caption: "STATUS",
                              value: code == "0" ? "failed" : code,
                              color: Self.statusColor(code)))

            if let mime = tx.mineType, !mime.isEmpty {
                rows.append(.init(caption: "MIME TYPE", value: mime))
            } else if let sniffed = probe?.mimeType {
                rows.append(.init(caption: "MIME TYPE", value: "\(sniffed) (sniffed)"))
            }

            let responseBytes = Int(tx.responseDataSize)
            if responseBytes > 0 {
                rows.append(.init(caption: "RESPONSE SIZE", value: Self.formatBytes(responseBytes)))
            } else if let size = tx.size, !size.isEmpty, size != "0" {
                rows.append(.init(caption: "RESPONSE SIZE", value: size))
            } else if let bytes = probe?.byteCount {
                rows.append(.init(caption: "DOWNLOADED SIZE", value: Self.formatBytes(bytes)))
            }
            if tx.requestDataSize > 0 {
                rows.append(.init(caption: "REQUEST SIZE", value: Self.formatBytes(Int(tx.requestDataSize))))
            }
            if tx.isResponseTruncated {
                rows.append(.init(caption: "NOTE", value: "Response body was truncated at capture time",
                                  color: UIColor.systemOrange))
            }

            if let start = tx.startTime, !start.isEmpty {
                rows.append(.init(caption: "START", value: start))
            }
            if let end = tx.endTime, !end.isEmpty {
                rows.append(.init(caption: "FINISH", value: end))
            }
            if let duration = tx.totalDuration, !duration.isEmpty {
                rows.append(.init(caption: "DURATION", value: duration))
            }
            if let error = tx.errorLocalizedDescription ?? tx.errorDescription, !error.isEmpty {
                rows.append(.init(caption: "ERROR", value: error, color: .systemRed))
            }
        } else {
            rows.append(.init(caption: "SOURCE", value: "Parsed from a JSON response body"))
            if let sniffed = probe?.mimeType {
                rows.append(.init(caption: "MIME TYPE", value: sniffed))
            }
            if let bytes = probe?.byteCount {
                rows.append(.init(caption: "SIZE", value: Self.formatBytes(bytes)))
            }
        }

        if let size = probe?.pixelSize {
            rows.append(.init(caption: "DIMENSIONS",
                              value: "\(Int(size.width)) × \(Int(size.height)) px"))
        }
        return rows
    }

    private func headerRows(from headers: [String: Any]) -> [MediaInfoCard.Row] {
        return headers
            .map { (key: $0.key, value: String(describing: $0.value)) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { MediaInfoCard.Row(caption: $0.key.uppercased(), value: $0.value) }
    }

    // MARK: - Loading

    private func loadPreview() {
        guard item.isLikelyImage else {
            previewPlaceholder.isHidden = false
            return
        }
        previewPlaceholder.isHidden = true
        previewSpinner.startAnimating()

        let maxPixel = max(600, UIScreen.main.bounds.width * UIScreen.main.scale)
        previewToken = ImageLoader.shared.loadImage(urlString: item.urlString, maxPixel: maxPixel) { [weak self] image in
            guard let self = self else { return }
            self.previewSpinner.stopAnimating()
            self.previewImageView.image = image
            self.previewPlaceholder.isHidden = image != nil
        }
    }

    private func loadProbe() {
        MediaAssetProbe.probe(urlString: item.urlString, transaction: item.transaction) { [weak self] result in
            guard let self = self, self.isViewLoaded else { return }
            self.probe = result
            self.infoCard.setRows(self.makeInfoRows())
        }
    }

    // MARK: - Actions

    @objc private func openFullscreen() {
        let pager = MediaPagerViewController(imageURLs: items.map { $0.urlString }, startIndex: index)
        pager.modalPresentationStyle = .fullScreen
        present(pager, animated: true)
    }

    @objc private func copyURL() {
        UIPasteboard.general.string = item.urlString
        let toast = UILabel()
        toast.text = "  URL copied  "
        toast.font = .systemFont(ofSize: 12, weight: .semibold)
        toast.textColor = .black
        toast.backgroundColor = Self.teal
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.textAlignment = .center
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            toast.heightAnchor.constraint(equalToConstant: 24),
        ])
        UIView.animate(withDuration: 0.25, delay: 1.0, options: []) {
            toast.alpha = 0
        } completion: { _ in
            toast.removeFromSuperview()
        }
    }

    // MARK: - Formatting

    private static func statusColor(_ code: String) -> UIColor {
        guard let value = Int(code), value > 0 else { return .systemRed }
        switch value {
        case 200..<300: return teal
        case 300..<400: return .systemYellow
        case 400..<500: return .systemOrange
        default: return .systemRed
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let formatted = unitIndex == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(formatted) \(units[unitIndex]) (\(bytes) bytes)"
    }
}

// MARK: - Info card

/// A titled card of caption/value rows, styled to match `KeyValueCardCell`
/// (key on its own line, value on its own line).
private final class MediaInfoCard: UIView {

    struct Row {
        let caption: String
        let value: String
        var color: UIColor?

        init(caption: String, value: String, color: UIColor? = nil) {
            self.caption = caption
            self.value = value
            self.color = color
        }
    }

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let teal = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
    private static let captionColor = UIColor(white: 0.45, alpha: 1)
    private static let valueColor = UIColor(white: 0.88, alpha: 1)

    private let card = UIView()
    private let titleLabel = UILabel()
    private let rowsStack = UIStackView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        card.backgroundColor = Self.cardBG
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        titleLabel.textColor = Self.teal
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        rowsStack.axis = .vertical
        rowsStack.spacing = 12
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            rowsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRows(_ rows: [Row]) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            rowsStack.addArrangedSubview(makeRowView(row))
        }
        forceLTR()
    }

    private func makeRowView(_ row: Row) -> UIView {
        let caption = UILabel()
        caption.text = row.caption
        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textColor = Self.captionColor

        let value = UILabel()
        value.text = row.value
        value.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        value.textColor = row.color ?? Self.valueColor
        value.numberOfLines = 0
        value.lineBreakMode = .byCharWrapping

        let stack = UIStackView(arrangedSubviews: [caption, value])
        stack.axis = .vertical
        stack.spacing = 3
        return stack
    }
}

// MARK: - Asset probe

/// Discovers real, on-the-wire facts about a media asset that the transaction
/// may not carry: byte size, pixel dimensions and the sniffed MIME type.
///
/// Order of preference: an inline `data:` URI, then the captured response body
/// on disk, then a plain fetch through a session that deliberately excludes
/// `CustomHTTPProtocol` (so probing never shows up as a captured request).
enum MediaAssetProbe {

    struct Result {
        let byteCount: Int?
        let pixelSize: CGSize?
        let mimeType: String?
    }

    private static var cache: [String: Result] = [:]
    private static let lock = NSLock()
    private static let maxCacheEntries = 200

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.protocolClasses = []
        return URLSession(configuration: config)
    }()

    /// Probes the asset and calls back on the main thread. Results are memoized.
    static func probe(urlString: String,
                      transaction: NetworkTransaction?,
                      completion: @escaping (Result) -> Void) {
        lock.lock()
        let cached = cache[urlString]
        lock.unlock()
        if let cached {
            completion(cached)
            return
        }

        func finish(_ data: Data?) {
            let result = analyze(data)
            lock.lock()
            if cache.count >= maxCacheEntries { cache.removeAll() }
            cache[urlString] = result
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }

        DispatchQueue.global(qos: .utility).async {
            if let local = localData(urlString: urlString, transaction: transaction) {
                finish(local)
                return
            }
            guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
                finish(nil)
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            session.dataTask(with: request) { data, _, _ in finish(data) }.resume()
        }
    }

    // MARK: - Sources

    private static func localData(urlString: String, transaction: NetworkTransaction?) -> Data? {
        if urlString.lowercased().hasPrefix("data:") {
            guard let commaIndex = urlString.firstIndex(of: ",") else { return nil }
            let meta = urlString[..<commaIndex]
            let payload = String(urlString[urlString.index(after: commaIndex)...])
            guard meta.contains("base64") else { return nil }
            return Data(base64Encoded: payload)
        }
        // The captured body already lives on disk — one read, no network hop.
        if let transaction, transaction.responseDataSize > 0, !transaction.isResponseTruncated {
            return transaction.responseData
        }
        return nil
    }

    // MARK: - Analysis

    /// Reads image metadata via ImageIO **without decoding the bitmap**.
    private static func analyze(_ data: Data?) -> Result {
        guard let data, !data.isEmpty else {
            return Result(byteCount: nil, pixelSize: nil, mimeType: nil)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return Result(byteCount: data.count, pixelSize: nil, mimeType: nil)
        }

        var pixelSize: CGSize?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = props[kCGImagePropertyPixelHeight] as? NSNumber {
            pixelSize = CGSize(width: width.doubleValue, height: height.doubleValue)
        }

        var mimeType: String?
        if let uti = CGImageSourceGetType(source) as String?,
           let type = UTType(uti) {
            mimeType = type.preferredMIMEType
        }

        return Result(byteCount: data.count, pixelSize: pixelSize, mimeType: mimeType)
    }
}
