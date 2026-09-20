//
//  FileContentViewerViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Renders a single file from the app container in the most useful form for its
/// type: pretty-printed JSON, plain monospace text (capped), a scaled image, or
/// a hex/byte preview for SQLite & other binaries. Copy / Share live in the nav
/// bar. (See FILE-BROWSER.)
final class FileContentViewerViewController: UIViewController {

    // MARK: Palette

    private static let cardBG = UIColor(white: 0.13, alpha: 1)
    private static let cardBorder = UIColor(white: 0.24, alpha: 1)
    private static let captionColor = UIColor(white: 0.48, alpha: 1)
    private static let valueColor = UIColor(white: 0.88, alpha: 1)

    /// Text files are only rendered up to this many bytes.
    private static let maxTextBytes = 200 * 1024
    /// Binary files show this many bytes as hex.
    private static let maxHexBytes = 2 * 1024

    // MARK: Content

    private enum Content {
        /// `label` is what the bytes turned out to be once decoded, which is not
        /// what the extension guessed: a `.plist` in Library/Preferences is a
        /// binary plist rendered as XML, so the header must say PLIST, not TEXT.
        case text(String, truncated: Bool, isJSON: Bool, label: String)
        case image(UIImage)
        case hex(String)
        case unreadable(String)

        /// Header label for what is actually on screen. A payload only a hex
        /// dump can show must never claim to be TEXT. (See FILE-BROWSER.)
        var label: String {
            switch self {
            case .text(_, _, _, let label): return label
            case .image:                    return "IMAGE"
            case .hex:                      return "HEX"
            case .unreadable:               return "UNREADABLE"
            }
        }
    }

    private let fileURL: URL
    private let kind: AppContainerFileKind
    private var content: Content?
    /// Text that COPY puts on the pasteboard / SHARE writes to a temp file.
    private var shareableText: String?

    // MARK: Subviews

    private let headerCard = UIView()
    private let headerStack = UIStackView()
    private let textView = UITextView()
    private let imageScrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let toast = UILabel()
    /// The INFO row's value label. The header card is built in `viewDidLoad`,
    /// long before the background read finishes, so `apply` re-sets this label
    /// with the kind the decoder settled on.
    private var infoValueLabel: UILabel?
    /// Everything in the INFO row after the kind — size and modification date.
    private var metaTail: [String] = []

    private lazy var byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: Init

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.kind = AppContainerFileKind.kind(for: fileURL, isDirectory: false)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = fileURL.lastPathComponent
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = DebugTheme.accentColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        navigationItem.titleView = titleLabel

        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
                                    style: .plain, target: self, action: #selector(shareTapped(_:)))
        let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"),
                                   style: .plain, target: self, action: #selector(copyTapped(_:)))
        share.tintColor = DebugTheme.accentColor
        copy.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItems = [share, copy]

        buildHeaderCard()
        buildContentViews()
        buildToast()

        spinner.color = DebugTheme.accentColor
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        loadContent()
        view.forceLTR()
    }

    // MARK: Layout

    private func buildHeaderCard() {
        headerCard.backgroundColor = Self.cardBG
        headerCard.layer.cornerRadius = 14
        headerCard.layer.cornerCurve = .continuous
        headerCard.layer.borderWidth = 1
        headerCard.layer.borderColor = Self.cardBorder.cgColor
        headerCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerCard)

        headerStack.axis = .vertical
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(headerStack)

        NSLayoutConstraint.activate([
            headerCard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            headerCard.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            headerCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),

            headerStack.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -14),
            headerStack.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 12),
            headerStack.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -12),
        ])

        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        metaTail = [byteFormatter.string(fromByteCount: size)]
        if let modified = values?.contentModificationDate {
            metaTail.append(dateFormatter.string(from: modified))
        }

        headerStack.addArrangedSubview(makeRow(caption: "PATH", value: AppContainerPaths.shortPath(fileURL), lines: 3).row)
        // The extension's guess stands only until the read finishes.
        let info = makeRow(caption: "INFO", value: infoText(label: kind.label), lines: 2)
        infoValueLabel = info.value
        headerStack.addArrangedSubview(info.row)
    }

    private func infoText(label: String) -> String {
        ([label] + metaTail).joined(separator: "  ·  ")
    }

    private func makeRow(caption: String, value: String, lines: Int) -> (row: UIView, value: UILabel) {
        let captionLabel = UILabel()
        captionLabel.text = caption
        captionLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        captionLabel.textColor = Self.captionColor

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = Self.valueColor
        valueLabel.numberOfLines = lines
        valueLabel.lineBreakMode = .byCharWrapping

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 2
        return (stack, valueLabel)
    }

    private func buildContentViews() {
        // Text / JSON / hex
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = Self.valueColor
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.isHidden = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        // Image, zoomable & scaled to fit
        imageScrollView.backgroundColor = .clear
        imageScrollView.minimumZoomScale = 1
        imageScrollView.maximumZoomScale = 6
        imageScrollView.delegate = self
        imageScrollView.showsHorizontalScrollIndicator = false
        imageScrollView.isHidden = true
        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageScrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageScrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageScrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            imageScrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            imageScrollView.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 12),
            imageScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            imageView.leadingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: imageScrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: imageScrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    private func buildToast() {
        toast.text = "Copied"
        toast.font = .systemFont(ofSize: 12, weight: .semibold)
        toast.textColor = .black
        toast.textAlignment = .center
        toast.backgroundColor = DebugTheme.accentColor
        toast.layer.cornerRadius = 10
        toast.layer.cornerCurve = .continuous
        toast.clipsToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            toast.widthAnchor.constraint(equalToConstant: 120),
            toast.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    // MARK: Loading

    private func loadContent() {
        let url = fileURL
        let kind = self.kind
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Self.readContent(at: url, kind: kind)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                self.apply(loaded)
            }
        }
    }

    private func apply(_ content: Content) {
        self.content = content
        // The header card was built from the extension before a single byte was
        // read; the INFO row now says what was actually decoded.
        infoValueLabel?.text = infoText(label: content.label)
        switch content {
        case .text(let string, let truncated, _, _):
            var display = string
            if truncated {
                display += "\n\n— truncated at \(Self.maxTextBytes / 1024) KB —"
            }
            shareableText = string
            textView.text = display
            textView.isHidden = false

        case .hex(let dump):
            shareableText = dump
            textView.text = dump
            textView.isHidden = false

        case .unreadable(let message):
            shareableText = nil
            textView.text = message
            textView.textColor = UIColor(white: 0.55, alpha: 1)
            textView.isHidden = false

        case .image:
            shareableText = nil
            imageScrollView.isHidden = false
            loadImage()
        }
    }

    /// Images go through the bundled `ImageLoader` (downsamples + caches). Its
    /// session can't serve `file://` URLs, so we fall back to a local decode of
    /// the same bytes when it returns nothing.
    private func loadImage() {
        let maxPixel = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
        let key = fileURL.absoluteString
        if let cached = ImageLoader.shared.cachedImage(for: key, maxPixel: maxPixel) {
            imageView.image = cached
            return
        }
        ImageLoader.shared.loadImage(urlString: key, maxPixel: maxPixel) { [weak self] image in
            guard let self = self else { return }
            if let image = image {
                self.imageView.image = image
                return
            }
            if case .image(let local)? = self.content {
                self.imageView.image = local
            }
        }
    }

    // MARK: File reading

    private static func readContent(at url: URL, kind: AppContainerFileKind) -> Content {
        switch kind {
        case .image:
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = UIImage(data: data) else {
                return .unreadable("Can’t decode this image.")
            }
            return .image(image)

        case .json, .text:
            guard let chunk = readPrefix(of: url, maxBytes: maxTextBytes) else {
                return .unreadable("Can’t read this file.\nIt may have been deleted or is not readable by the app.")
            }
            let (data, truncated) = chunk
            guard let string = decodeText(data) else {
                // Not plain text — but "not UTF-8" is not the same as "opaque".
                // Every `.plist` in Library/Preferences is a *binary* plist, and
                // hex-dumping it here is what made the app’s own preferences
                // unreadable. The progressive decoder takes it from here.
                return decoded(data, truncated: truncated)
            }
            // Pretty-print only when the whole file was read (a truncated JSON
            // document would not parse).
            if kind == .json, !truncated, let pretty = JSONExporter.prettyJSONString(from: string) {
                return .text(pretty, truncated: false, isJSON: true, label: "JSON")
            }
            return .text(string, truncated: truncated, isJSON: false, label: kind.label)

        case .binary:
            // No extension means `.binary`, which is exactly how URLCache and
            // most hand-rolled disk caches name their entries — their contents
            // are routinely plain JSON or text. Read a text-sized prefix, not a
            // 2 KB one, or a multi-KB cache entry would never parse.
            guard let chunk = readPrefix(of: url, maxBytes: maxTextBytes) else {
                return .unreadable("Can’t read this file.\nIt may have been deleted or is not readable by the app.")
            }
            return decoded(chunk.data, truncated: chunk.truncated)

        case .database, .archive, .directory:
            // The head of a SQLite file or a zip is genuinely opaque; decoding
            // it would only ever produce the same hex dump.
            guard let chunk = readPrefix(of: url, maxBytes: maxHexBytes) else {
                return .unreadable("Can’t read this file.\nIt may have been deleted or is not readable by the app.")
            }
            return .hex(hexDump(chunk.data))
        }
    }

    /// Hands bytes the extension could not classify to the same progressive
    /// decoder the UserDefaults and Keychain inspectors use (JSON → property
    /// list → keyed archive → UTF-8 → hex), so the rendering comes from what
    /// the bytes *are* rather than from what the filename claimed.
    private static func decoded(_ data: Data, truncated: Bool) -> Content {
        let value = DataValueDecoder.decode(data)
        switch value.representation {
        case .json, .plist, .archive, .text:
            return .text(value.text, truncated: truncated,
                         isJSON: value.representation == .json,
                         label: value.representation.rawValue)
        case .binary:
            return .hex(hexDump(data.prefix(maxHexBytes)))
        }
    }

    /// Reads at most `maxBytes` from a file without mapping the whole thing.
    private static func readPrefix(of url: URL, maxBytes: Int) -> (data: Data, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let read = try? handle.read(upToCount: maxBytes + 1) else { return nil }
        if read.count > maxBytes {
            return (read.prefix(maxBytes), true)
        }
        return (read, false)
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // Binary plists and other non-UTF8 payloads should not masquerade as text.
        let sample = data.prefix(512)
        if sample.contains(0) { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Classic `offset  hex bytes  ascii` dump of the first bytes of a file.
    private static func hexDump(_ data: Data) -> String {
        guard !data.isEmpty else { return "(empty file)" }
        let bytes = [UInt8](data)
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 2)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            let hex = chunk.map { String(format: "%02X", $0) }
                .joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", offset) + hex + "  " + ascii)
            offset = end
        }
        lines.append("")
        lines.append("— first \(bytes.count) bytes —")
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    @objc private func copyTapped(_ sender: UIBarButtonItem) {
        switch content {
        case .image?:
            if let image = imageView.image {
                UIPasteboard.general.image = image
                showToast("Copied")
            }
        case .text(let string, let truncated, _, _)?:
            // Both arms go through the one formatter. The branch used to be
            // inverted — JSON was copied raw (so a `.json` file saved with a BOM
            // or a leading blank line copied them intact) while only non-JSON was
            // handed to the JSON producer. `ClipboardFormatter` already does the
            // right thing for either kind. (See COPY.)
            // The toast belongs in the completion handler, not after the call:
            // above the formatter's threshold the write happens on a background
            // queue behind a blocking overlay, and "Copied" announced underneath
            // that overlay was a lie for as long as the formatting took. The
            // synchronous arm invokes `completion` inline, so a small file keeps
            // its instant toast.
            ClipboardFormatter.copy(string, from: self) { [weak self] in
                // What is on the pasteboard is what was read, and a capped read
                // is a fragment — saying just “Copied” would hide that.
                self?.showToast(truncated ? "Copied \(Self.maxTextBytes / 1024) KB" : "Copied")
            }
        case .hex(let dump)?:
            ClipboardFormatter.copyVerbatim(dump)
            showToast("Copied")
        default:
            UIPasteboard.general.string = fileURL.path
            showToast("Copied path")
        }
    }

    @objc private func shareTapped(_ sender: UIBarButtonItem) {
        var shareURL: URL?

        switch content {
        case .text(let string, let truncated, _, _)?:
            if truncated {
                // The view holds only the first `maxTextBytes`; rewriting those
                // into a temp file under the original name exports a fragment
                // that looks complete (and, for JSON, parses nowhere). The
                // rewrite only earns its keep for a whole-file read, which is
                // also the only case `readContent` pretty-prints.
                shareURL = fileURL
            } else {
                let ext = fileURL.pathExtension.isEmpty ? "txt" : fileURL.pathExtension
                shareURL = JSONExporter.writeTemporaryFile(
                    contents: string,
                    suggestedName: fileURL.deletingPathExtension().lastPathComponent,
                    fileExtension: ext
                )
            }
        default:
            // Binary / image / unreadable: share the real file on disk.
            shareURL = fileURL
        }

        guard let url = shareURL else {
            let alert = UIAlertController(title: "Nothing to Share", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            presentPopover(alert, from: sender)
            return
        }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires an anchor or this crashes.
        presentPopover(activity, from: sender)
    }

    private func presentPopover(_ controller: UIViewController, from item: UIBarButtonItem) {
        if let popover = controller.popoverPresentationController {
            popover.barButtonItem = item
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(controller, animated: true)
    }

    private func showToast(_ message: String) {
        toast.text = message
        view.bringSubviewToFront(toast)
        UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.9) { self.toast.alpha = 0 }
        }
    }
}

// MARK: - UIScrollViewDelegate (image zoom)

extension FileContentViewerViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return scrollView === imageScrollView ? imageView : nil
    }
}
