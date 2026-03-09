//
//  NetworkCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

// MARK: - PaddedLabel (pill-shaped tag)

private class PaddedLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        // ceil() prevents sub-pixel rounding from clipping text when clipsToBounds = true
        return CGSize(
            width: ceil(size.width) + textInsets.left + textInsets.right,
            height: ceil(size.height) + textInsets.top + textInsets.bottom
        )
    }
}

// MARK: - NetworkCell

class NetworkCell: UITableViewCell {

    // MARK: - Card container

    private let cardView = UIView()

    /// 3pt-wide vertical bar on the left edge of the card
    private let statusLine = UIView()

    // MARK: - Row 1: method, row#, spacer, status dot, status code

    private let methodLabel = UILabel()
    private let rowNumberLabel = UILabel()
    private let statusDot = UIView()
    private let statusCodeLabel = UILabel()

    // MARK: - Row 2: URL

    private let urlLabel = UILabel()

    // MARK: - Row 1 pill: host tag (after method)

    private let hostTagLabel = PaddedLabel()

    // MARK: - Row 3: tag pills (left), timestamp (right)

    private let contentTypeTagLabel = PaddedLabel()
    private let sizeTagLabel = PaddedLabel()
    private let durationTagLabel = PaddedLabel()
    private let timeLabel = UILabel()
    private let viewedIcon = UIImageView()
    private let pinIcon = UIImageView()

    // MARK: - cURL action row (detail header only)

    private let curlButton = UIButton(type: .system)
    var onCurlTapped: (() -> Void)?

    // MARK: - Layout containers

    private let topRow = UIStackView()
    private let bottomRow = UIStackView()
    private let tagsStack = UIStackView()
    private let mainStack = UIStackView()

    // MARK: - Constants

    private static let cardBackgroundColor = UIColor(white: 0.11, alpha: 1)  // #1C1C1C
    private static let cellSpacing: CGFloat = 4

    // MARK: - Data

    var index: NSInteger = 0

    /// Set to true to show the cURL copy button (used in detail page header)
    var showCurlButton: Bool = false {
        didSet { curlButton.isHidden = !showCurlButton }
    }

    var httpModel: NetworkTransaction? {
        didSet { configure() }
    }

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Card view
        cardView.backgroundColor = Self.cardBackgroundColor
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // Status line (inside card, left edge)
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLine)

        // --- Row 1 ---

        // Method
        methodLabel.font = .systemFont(ofSize: 12, weight: .bold)
        methodLabel.textColor = UIColor(white: 0.55, alpha: 1)
        methodLabel.setContentHuggingPriority(.required, for: .horizontal)
        methodLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Row number
        rowNumberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        rowNumberLabel.textColor = UIColor(white: 0.65, alpha: 1)
        rowNumberLabel.setContentHuggingPriority(.required, for: .horizontal)
        rowNumberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Status dot (small circle for errors)
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        // Status code
        statusCodeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        statusCodeLabel.textAlignment = .right
        statusCodeLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusCodeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Host tag pill (lives in row 1, after method)
        hostTagLabel.font = .systemFont(ofSize: 9, weight: .bold)
        hostTagLabel.textColor = .white
        hostTagLabel.textAlignment = .center
        hostTagLabel.layer.cornerRadius = 4
        hostTagLabel.clipsToBounds = true
        hostTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        hostTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6
        topRow.addArrangedSubview(rowNumberLabel)
        topRow.addArrangedSubview(methodLabel)
        topRow.addArrangedSubview(hostTagLabel)
        topRow.addArrangedSubview(topSpacer)
        topRow.addArrangedSubview(statusDot)
        topRow.addArrangedSubview(statusCodeLabel)

        // --- Row 2: URL ---

        urlLabel.font = .systemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = UIColor(white: 0.85, alpha: 1)
        urlLabel.numberOfLines = 5
        urlLabel.lineBreakMode = .byTruncatingTail

        // --- Row 3: tags left, timestamp right ---

        // Configure all tag pills
        let allPills: [PaddedLabel] = [contentTypeTagLabel, sizeTagLabel, durationTagLabel]
        for pill in allPills {
            pill.font = .systemFont(ofSize: 9, weight: .bold)
            pill.textColor = .white
            pill.textAlignment = .center
            pill.layer.cornerRadius = 4
            pill.clipsToBounds = true
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Tags stack (left side of bottom row)
        tagsStack.axis = .horizontal
        tagsStack.spacing = 4
        tagsStack.alignment = .center
        tagsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagsStack.addArrangedSubview(contentTypeTagLabel)
        tagsStack.addArrangedSubview(sizeTagLabel)
        tagsStack.addArrangedSubview(durationTagLabel)

        // Timestamp (right side) — lower priority so tags always show fully
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = DebugTheme.accentColor
        timeLabel.textAlignment = .right
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Viewed indicator (eye icon, shown after opening request details)
        viewedIcon.isHidden = true
        viewedIcon.contentMode = .scaleAspectFit
        viewedIcon.translatesAutoresizingMaskIntoConstraints = false
        viewedIcon.setContentHuggingPriority(.required, for: .horizontal)
        viewedIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let viewedConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        viewedIcon.image = UIImage(systemName: "eye.fill", withConfiguration: viewedConfig)?
            .withTintColor(UIColor(white: 0.35, alpha: 1), renderingMode: .alwaysOriginal)
        viewedIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        viewedIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        // Pin indicator
        pinIcon.isHidden = true
        pinIcon.contentMode = .scaleAspectFit
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)
        pinIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pinConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        pinIcon.image = UIImage(systemName: "pin.fill", withConfiguration: pinConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        pinIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pinIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let bottomSpacer = UIView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 6
        bottomRow.addArrangedSubview(tagsStack)
        bottomRow.addArrangedSubview(bottomSpacer)
        bottomRow.addArrangedSubview(pinIcon)
        bottomRow.addArrangedSubview(viewedIcon)
        bottomRow.addArrangedSubview(timeLabel)

        // --- cURL button (hidden by default, shown in detail header) ---

        curlButton.isHidden = true
        curlButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        curlButton.layer.cornerRadius = 6
        curlButton.clipsToBounds = true
        var curlBtnConfig = UIButton.Configuration.plain()
        curlBtnConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        curlBtnConfig.imagePadding = 5
        curlBtnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        curlBtnConfig.baseForegroundColor = DebugTheme.accentColor
        curlButton.configuration = curlBtnConfig
        curlButton.addTarget(self, action: #selector(curlButtonTapped), for: .touchUpInside)

        let curlConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let curlIcon = UIImage(systemName: "terminal", withConfiguration: curlConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        curlButton.setImage(curlIcon, for: .normal)
        curlButton.setTitle("Copy cURL", for: .normal)
        curlButton.setTitleColor(DebugTheme.accentColor, for: .normal)

        // --- Main stack ---

        mainStack.axis = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(urlLabel)
        mainStack.addArrangedSubview(bottomRow)
        mainStack.addArrangedSubview(curlButton)
        cardView.addSubview(mainStack)

        // --- Constraints ---

        NSLayoutConstraint.activate([
            // Card inset from cell edges (creates spacing between cells)
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cellSpacing / 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Self.cellSpacing / 2)),

            // Status line inside card
            statusLine.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: cardView.topAnchor),
            statusLine.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            statusLine.widthAnchor.constraint(equalToConstant: 3),

            // Main stack inside card
            mainStack.leadingAnchor.constraint(equalTo: statusLine.trailingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            mainStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    // MARK: - Configure

    private func configure() {
        guard let model = httpModel else { return }

        // Row number
        rowNumberLabel.text = String(index + 1)

        // Method
        if let method = model.method {
            methodLabel.text = "[\(method)]"
        } else {
            methodLabel.text = ""
        }

        // Status code + colors
        let code = model.statusCode ?? "0"
        let statusColor = Self.colorForStatusCode(code)
        statusCodeLabel.text = code == "0" ? "\u{274C}" : code
        statusCodeLabel.textColor = statusColor
        statusLine.backgroundColor = statusColor

        // Status dot: show only for errors (4xx/5xx)
        let numericCode = Int(code) ?? 0
        if numericCode >= 400 || numericCode == 0 {
            statusDot.isHidden = false
            statusDot.backgroundColor = statusColor
        } else {
            statusDot.isHidden = true
        }

        // URL (full, including query parameters)
        let urlString = model.url?.absoluteString ?? ""
        urlLabel.text = urlString
        urlLabel.font = .systemFont(ofSize: 12, weight: .regular)

        // --- Tags ---

        // Content type tag (JSON, Multipart, Form, XML, etc.)
        configureContentTypeTag(model: model)

        // Host tag (in top row)
        configureHostTag(model: model)

        // Size tag
        let hasSize = model.size != nil && !model.size!.isEmpty && model.size != "0"
        sizeTagLabel.isHidden = !hasSize
        if hasSize {
            sizeTagLabel.text = model.size
            sizeTagLabel.backgroundColor = UIColor(red: 0.35, green: 0.40, blue: 0.75, alpha: 0.3) // muted purple
            sizeTagLabel.textColor = UIColor(red: 0.60, green: 0.65, blue: 0.95, alpha: 1)
        }

        // Duration tag
        let durationStr = Self.computeDuration(start: model.startTime, end: model.endTime)
        let hasDuration = (durationStr != "--")
        durationTagLabel.isHidden = !hasDuration
        if hasDuration {
            durationTagLabel.text = durationStr
            let durationColor = Self.colorForDuration(start: model.startTime, end: model.endTime)
            durationTagLabel.backgroundColor = durationColor.withAlphaComponent(0.25)
            durationTagLabel.textColor = durationColor
        }

        // Timestamp
        if let startTime = model.startTime {
            let ts = (startTime as NSString).doubleValue
            if ts == 0 {
                timeLabel.text = Self.formatDateTime(Date())
            } else {
                timeLabel.text = Self.formatDateTime(Date(timeIntervalSince1970: ts))
            }
        } else {
            timeLabel.text = ""
        }

        // Viewed indicator
        viewedIcon.isHidden = !model.isViewed

        // Pin indicator
        pinIcon.isHidden = !model.isPinned

        // Tagged highlight
        if model.isTag {
            cardView.backgroundColor = "#007aff".hexColor.withAlphaComponent(0.15)
        } else {
            cardView.backgroundColor = Self.cardBackgroundColor
        }
    }

    // MARK: - Content Type Tag

    private func configureContentTypeTag(model: NetworkTransaction) {
        // Detect from request Content-Type header
        let contentType = (model.requestHeaderFields?["Content-Type"] as? String
            ?? model.requestHeaderFields?["content-type"] as? String
            ?? "").lowercased()

        let detected: (label: String, hex: String)

        if contentType.contains("multipart/form-data") {
            detected = ("Multipart", "#E67E22")       // orange
        } else if contentType.contains("application/x-www-form-urlencoded") {
            detected = ("Form", "#9B59B6")             // purple
        } else if contentType.contains("application/json") || contentType.contains("text/json") {
            detected = ("JSON", "#3498DB")             // blue
        } else if contentType.contains("xml") {
            detected = ("XML", "#1ABC9C")              // teal
        } else if contentType.contains("text/plain") {
            detected = ("Text", "#95A5A6")             // gray
        } else if contentType.contains("application/octet-stream") {
            detected = ("Binary", "#7F8C8D")           // dark gray
        } else if contentType.contains("text/html") {
            detected = ("HTML", "#E74C3C")             // red
        } else {
            // Fallback: check requestSerializer or response mineType
            if model.requestSerializer == .form {
                detected = ("Form", "#9B59B6")
            } else if let mime = model.mineType?.lowercased(), mime.contains("json") {
                detected = ("JSON", "#3498DB")
            } else {
                detected = ("JSON", "#3498DB")         // default to JSON for API calls
            }
        }

        contentTypeTagLabel.isHidden = false
        contentTypeTagLabel.text = detected.label
        contentTypeTagLabel.backgroundColor = detected.hex.hexColor.withAlphaComponent(0.25)
        contentTypeTagLabel.textColor = detected.hex.hexColor
    }

    // MARK: - Host Tag Logic

    private func configureHostTag(model: NetworkTransaction) {
        guard let host = model.url?.host?.lowercased() else {
            hostTagLabel.isHidden = true
            return
        }

        let fullURL = (model.url?.absoluteString ?? "").lowercased()

        // 1. Custom tags — keyword is a substring of the full URL or the host.
        if let customMap = SwiftyDebug.networkTagMap {
            for (keyword, label) in customMap {
                let lowerKeyword = keyword.lowercased()
                if fullURL.contains(lowerKeyword) || host.contains(lowerKeyword) {
                    let color = Self.colorForTag(keyword)
                    hostTagLabel.isHidden = false
                    hostTagLabel.text = label
                    hostTagLabel.backgroundColor = color.withAlphaComponent(0.25)
                    hostTagLabel.textColor = color
                    return
                }
            }
        }

        // 2. WebView check
        if model.isWebViewRequest {
            let color = Self.colorForTag("web")
            hostTagLabel.isHidden = false
            hostTagLabel.text = "web"
            hostTagLabel.backgroundColor = color.withAlphaComponent(0.25)
            hostTagLabel.textColor = color
            return
        }

        // 3. Built-in known third-party tags
        let knownTags: [(keyword: String, label: String)] = [
            ("algolia",   "algolia"),
            ("onesignal", "one signal"),
            ("jitsu",     "jitsu"),
        ]

        for tag in knownTags {
            if host.contains(tag.keyword) {
                let color = Self.colorForTag(tag.keyword)
                hostTagLabel.isHidden = false
                hostTagLabel.text = tag.label
                hostTagLabel.backgroundColor = color.withAlphaComponent(0.25)
                hostTagLabel.textColor = color
                return
            }
        }

        // 4. Unknown third-party: show abbreviated host
        let color = Self.colorForTag(host)
        hostTagLabel.isHidden = false
        hostTagLabel.text = Self.abbreviateHost(host)
        hostTagLabel.backgroundColor = color.withAlphaComponent(0.2)
        hostTagLabel.textColor = color
    }

    // MARK: - Static Helpers

    /// Deterministic color from a string key (djb2 hash → hue)
    static func colorForTag(_ key: String) -> UIColor {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360.0
        return UIColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1)
    }

    static func colorForStatusCode(_ code: String) -> UIColor {
        guard let numeric = Int(code) else { return "#ff0000".hexColor }
        switch numeric {
        case 100..<200: return "#4b8af7".hexColor
        case 200..<300: return "#42d459".hexColor
        case 300..<400: return "#ff9800".hexColor
        default:        return "#ff0000".hexColor
        }
    }

    /// Green < 300ms, Yellow 300ms-1s, Red > 1s
    static func colorForDuration(start: String?, end: String?) -> UIColor {
        guard let startStr = start, let endStr = end else { return UIColor(white: 0.6, alpha: 1) }
        let startVal = (startStr as NSString).doubleValue
        let endVal = (endStr as NSString).doubleValue
        guard startVal > 0, endVal > 0 else { return UIColor(white: 0.6, alpha: 1) }

        let duration = endVal - startVal
        if duration < 0.3 { return "#42d459".hexColor }       // green: fast
        if duration < 1.0 { return "#ff9800".hexColor }       // yellow/orange: moderate
        return "#ff0000".hexColor                              // red: slow
    }

    static func computeDuration(start: String?, end: String?) -> String {
        guard let startStr = start, let endStr = end else { return "--" }
        let startVal = (startStr as NSString).doubleValue
        let endVal = (endStr as NSString).doubleValue

        guard startVal > 0, endVal > 0 else { return "--" }

        let duration = endVal - startVal
        if duration < 0.001 { return "<1ms" }
        if duration < 1.0 {
            let ms = Int(duration * 1000)
            return "\(ms)ms"
        }
        return String(format: "%.1fs", duration)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .current
        f.dateFormat = "HH:mm:ss - MM/dd"
        return f
    }()

    static func formatDateTime(_ date: Date) -> String {
        return dateTimeFormatter.string(from: date)
    }

    @objc private func curlButtonTapped() {
        onCurlTapped?()
    }

    private static func abbreviateHost(_ host: String) -> String {
        var short = host
        for prefix in ["www.", "api.", "cdn.", "m."] {
            if short.hasPrefix(prefix) {
                short = String(short.dropFirst(prefix.count))
                break
            }
        }
        for suffix in [".com", ".io", ".net", ".org", ".co"] {
            if short.hasSuffix(suffix) {
                short = String(short.dropLast(suffix.count))
                break
            }
        }
        if short.count > 12 {
            short = String(short.prefix(10)) + ".."
        }
        return short
    }
}
