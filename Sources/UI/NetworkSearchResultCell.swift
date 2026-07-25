//
//  NetworkSearchResultCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

// MARK: - PillLabel

private class PillLabel: UILabel {
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

// MARK: - NetworkSearchResultCell

/// The row used for every result while a search is active.
///
/// It deliberately mirrors `NetworkCell`'s card so the list stays scannable, and
/// adds one optional strip: a REQUEST/RESPONSE badge plus the matched excerpt
/// with the query highlighted. `NetworkCell` pins its card to both edges of
/// `contentView` and exposes no hook for an extra row, so the layout is
/// reproduced here rather than subclassed — the shared formatting rules still
/// come from `NetworkCell`'s static helpers.
///
/// The strip is driven by a `BodySearchMatch` straight out of
/// `ResponseBodySearch`, which already carries a whitespace-collapsed snippet
/// and the highlight range inside it. Nothing here reads a body: the disk read
/// happened once, on the scan's background queue.
final class NetworkSearchResultCell: UITableViewCell {

    static let reuseId = "NetworkSearchResultCell"

    // MARK: - Card

    private let cardView = UIView()
    private let statusLine = UIView()

    // MARK: - Row 1

    private let rowNumberLabel = UILabel()
    private let methodLabel = UILabel()
    private let hostTagLabel = PillLabel()
    private let statusDot = UIView()
    private let statusCodeLabel = UILabel()

    // MARK: - Row 2

    private let urlLabel = UILabel()

    // MARK: - Row 3

    private let contentTypeTagLabel = PillLabel()
    private let sizeTagLabel = PillLabel()
    private let durationTagLabel = PillLabel()
    private let timeLabel = UILabel()
    private let viewedIcon = UIImageView()
    private let pinIcon = UIImageView()
    private let interceptIcon = UIImageView()

    // MARK: - Row 4: body match strip

    private let matchStrip = UIStackView()
    private let matchSeparator = UIView()
    private let matchBadgeLabel = PillLabel()
    private let matchSnippetLabel = UILabel()

    // MARK: - Containers

    private let topRow = UIStackView()
    private let bottomRow = UIStackView()
    private let tagsStack = UIStackView()
    private let matchRow = UIStackView()
    private let mainStack = UIStackView()

    private static let cardBackgroundColor = UIColor(white: 0.11, alpha: 1)
    private static let cellSpacing: CGFloat = 4
    private static let snippetColor = UIColor(white: 0.7, alpha: 1)
    private static let snippetFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Request hits get their own colour so a glance separates "what we sent"
    /// from "what came back".
    private static let requestBadgeColor = UIColor(red: 0.60, green: 0.65, blue: 0.95, alpha: 1)

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

        cardView.backgroundColor = Self.cardBackgroundColor
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLine)

        // --- Row 1 ---

        methodLabel.font = .systemFont(ofSize: 12, weight: .bold)
        methodLabel.textColor = UIColor(white: 0.55, alpha: 1)
        methodLabel.setContentHuggingPriority(.required, for: .horizontal)
        methodLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        rowNumberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        rowNumberLabel.textColor = UIColor(white: 0.65, alpha: 1)
        rowNumberLabel.setContentHuggingPriority(.required, for: .horizontal)
        rowNumberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        statusCodeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        statusCodeLabel.textAlignment = .right
        statusCodeLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusCodeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        // --- Row 2 ---

        urlLabel.font = .systemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = UIColor(white: 0.85, alpha: 1)
        urlLabel.numberOfLines = 5
        urlLabel.lineBreakMode = .byTruncatingTail

        // --- Row 3 ---

        for pill in [contentTypeTagLabel, sizeTagLabel, durationTagLabel] {
            pill.font = .systemFont(ofSize: 9, weight: .bold)
            pill.textColor = .white
            pill.textAlignment = .center
            pill.layer.cornerRadius = 4
            pill.clipsToBounds = true
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        tagsStack.axis = .horizontal
        tagsStack.spacing = 4
        tagsStack.alignment = .center
        tagsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagsStack.addArrangedSubview(contentTypeTagLabel)
        tagsStack.addArrangedSubview(sizeTagLabel)
        tagsStack.addArrangedSubview(durationTagLabel)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = DebugTheme.accentColor
        timeLabel.textAlignment = .right
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        configureIndicator(viewedIcon, systemName: "eye.fill", color: UIColor(white: 0.35, alpha: 1), size: CGSize(width: 14, height: 10))
        configureIndicator(pinIcon, systemName: "pin.fill", color: DebugTheme.accentColor, size: CGSize(width: 12, height: 12))
        configureIndicator(interceptIcon, systemName: "bolt.fill", color: .systemOrange, size: CGSize(width: 12, height: 12))

        let bottomSpacer = UIView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 6
        bottomRow.addArrangedSubview(tagsStack)
        bottomRow.addArrangedSubview(bottomSpacer)
        bottomRow.addArrangedSubview(interceptIcon)
        bottomRow.addArrangedSubview(pinIcon)
        bottomRow.addArrangedSubview(viewedIcon)
        bottomRow.addArrangedSubview(timeLabel)

        // --- Row 4: body match strip ---

        matchSeparator.backgroundColor = UIColor(white: 0.18, alpha: 1)
        matchSeparator.translatesAutoresizingMaskIntoConstraints = false
        matchSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        matchBadgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        matchBadgeLabel.textAlignment = .center
        matchBadgeLabel.layer.cornerRadius = 4
        matchBadgeLabel.clipsToBounds = true
        matchBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        matchBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        matchSnippetLabel.font = Self.snippetFont
        matchSnippetLabel.textColor = Self.snippetColor
        matchSnippetLabel.numberOfLines = 2
        matchSnippetLabel.lineBreakMode = .byTruncatingTail

        matchRow.axis = .horizontal
        matchRow.alignment = .top
        matchRow.spacing = 6
        matchRow.addArrangedSubview(matchBadgeLabel)
        matchRow.addArrangedSubview(matchSnippetLabel)

        matchStrip.axis = .vertical
        matchStrip.spacing = 6
        matchStrip.alignment = .fill
        matchStrip.addArrangedSubview(matchSeparator)
        matchStrip.addArrangedSubview(matchRow)
        matchStrip.isHidden = true

        // --- Main stack ---

        mainStack.axis = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(urlLabel)
        mainStack.addArrangedSubview(bottomRow)
        mainStack.addArrangedSubview(matchStrip)
        cardView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cellSpacing / 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Self.cellSpacing / 2)),

            statusLine.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: cardView.topAnchor),
            statusLine.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            statusLine.widthAnchor.constraint(equalToConstant: 3),

            mainStack.leadingAnchor.constraint(equalTo: statusLine.trailingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            mainStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])

        forceLTR()
    }

    private func configureIndicator(_ imageView: UIImageView, systemName: String, color: UIColor, size: CGSize) {
        imageView.isHidden = true
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        let config = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        imageView.image = UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        imageView.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    // MARK: - Configure

    /// - Parameters:
    ///   - index: position in the result list, for the row number.
    ///   - query: used to highlight the hit inside the URL line.
    ///   - match: the body hit to show under the card, or nil for a result that
    ///     matched on metadata only.
    func configure(with model: NetworkTransaction, index: Int, query: String, match: BodySearchMatch?) {
        rowNumberLabel.text = String(index + 1)
        methodLabel.text = model.method.map { "[\($0)]" } ?? ""

        let code = model.statusCode ?? "0"
        let statusColor = NetworkCell.colorForStatusCode(code)
        statusCodeLabel.text = code == "0" ? "\u{274C}" : code
        statusCodeLabel.textColor = statusColor
        statusLine.backgroundColor = statusColor

        let numericCode = Int(code) ?? 0
        if numericCode >= 400 || numericCode == 0 {
            statusDot.isHidden = false
            statusDot.backgroundColor = statusColor
        } else {
            statusDot.isHidden = true
        }

        let urlString = model.url?.absoluteString ?? ""
        urlLabel.attributedText = Self.highlighted(urlString,
                                                   query: query,
                                                   base: UIColor(white: 0.85, alpha: 1),
                                                   font: .systemFont(ofSize: 12, weight: .regular))

        configureContentTypeTag(model: model)
        configureHostTag(model: model)

        let hasSize = model.size != nil && !model.size!.isEmpty && model.size != "0"
        sizeTagLabel.isHidden = !hasSize
        if hasSize {
            sizeTagLabel.text = model.size
            sizeTagLabel.backgroundColor = UIColor(red: 0.35, green: 0.40, blue: 0.75, alpha: 0.3)
            sizeTagLabel.textColor = UIColor(red: 0.60, green: 0.65, blue: 0.95, alpha: 1)
        }

        let durationStr = NetworkCell.computeDuration(start: model.startTime, end: model.endTime)
        let hasDuration = (durationStr != "--")
        durationTagLabel.isHidden = !hasDuration
        if hasDuration {
            durationTagLabel.text = durationStr
            let durationColor = NetworkCell.colorForDuration(start: model.startTime, end: model.endTime)
            durationTagLabel.backgroundColor = durationColor.withAlphaComponent(0.25)
            durationTagLabel.textColor = durationColor
        }

        if let startTime = model.startTime {
            let ts = (startTime as NSString).doubleValue
            timeLabel.text = NetworkCell.formatDateTime(ts == 0 ? Date() : Date(timeIntervalSince1970: ts))
        } else {
            timeLabel.text = ""
        }

        viewedIcon.isHidden = !model.isViewed
        pinIcon.isHidden = !model.isPinned
        if let url = model.url as URL? {
            interceptIcon.isHidden = !InterceptRuleStore.shared.hasRule(forURL: url)
        } else {
            interceptIcon.isHidden = true
        }

        cardView.backgroundColor = model.isTag
            ? "#007aff".hexColor.withAlphaComponent(0.15)
            : Self.cardBackgroundColor

        configureMatchStrip(match: match)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        urlLabel.attributedText = nil
        matchSnippetLabel.attributedText = nil
        matchBadgeLabel.text = nil
        matchStrip.isHidden = true
    }

    /// The extra line the plain list row does not have: which body matched, how
    /// many times, and the excerpt with the term picked out.
    private func configureMatchStrip(match: BodySearchMatch?) {
        guard let match = match else {
            matchStrip.isHidden = true
            matchSnippetLabel.attributedText = nil
            return
        }
        matchStrip.isHidden = false

        // `rawValue` is already "REQUEST" / "RESPONSE".
        var badge = match.side.rawValue
        if match.occurrences > 1 {
            badge += " \u{00D7}\(match.occurrences)\(match.isTruncatedScan ? "+" : "")"
        }
        let badgeColor = match.side == .request ? Self.requestBadgeColor : DebugTheme.accentColor
        matchBadgeLabel.text = badge
        matchBadgeLabel.backgroundColor = badgeColor.withAlphaComponent(0.22)
        matchBadgeLabel.textColor = badgeColor

        matchSnippetLabel.attributedText = Self.highlighted(
            match.snippet,
            range: match.highlightRange,
            base: Self.snippetColor,
            font: Self.snippetFont
        )
    }

    // MARK: - Highlighting

    private static func highlighted(_ text: String, query: String, base: UIColor, font: UIFont) -> NSAttributedString {
        let range = (text as NSString).range(of: query, options: [.caseInsensitive])
        return highlighted(text, range: range, base: base, font: font)
    }

    private static func highlighted(_ text: String, range: NSRange,
                                    base: UIColor, font: UIFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: base, .font: font]
        )
        // A stale/absent range simply means no highlight — never a crash.
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= attributed.length else {
            return attributed
        }
        attributed.addAttributes([
            .foregroundColor: UIColor.black,
            .backgroundColor: DebugTheme.accentColor,
        ], range: range)
        return attributed
    }

    // MARK: - Tags (mirrors NetworkCell)

    private func configureContentTypeTag(model: NetworkTransaction) {
        let contentType = (model.requestHeaderFields?["Content-Type"] as? String
            ?? model.requestHeaderFields?["content-type"] as? String
            ?? "").lowercased()

        let detected: (label: String, hex: String)

        if contentType.contains("multipart/form-data") {
            detected = ("Multipart", "#E67E22")
        } else if contentType.contains("application/x-www-form-urlencoded") {
            detected = ("Form", "#9B59B6")
        } else if contentType.contains("application/json") || contentType.contains("text/json") {
            detected = ("JSON", "#3498DB")
        } else if contentType.contains("xml") {
            detected = ("XML", "#1ABC9C")
        } else if contentType.contains("text/plain") {
            detected = ("Text", "#95A5A6")
        } else if contentType.contains("application/octet-stream") {
            detected = ("Binary", "#7F8C8D")
        } else if contentType.contains("text/html") {
            detected = ("HTML", "#E74C3C")
        } else if model.requestSerializer == .form {
            detected = ("Form", "#9B59B6")
        } else {
            detected = ("JSON", "#3498DB")
        }

        contentTypeTagLabel.isHidden = false
        contentTypeTagLabel.text = detected.label
        contentTypeTagLabel.backgroundColor = detected.hex.hexColor.withAlphaComponent(0.25)
        contentTypeTagLabel.textColor = detected.hex.hexColor
    }

    private func configureHostTag(model: NetworkTransaction) {
        guard let host = model.url?.host?.lowercased() else {
            hostTagLabel.isHidden = true
            return
        }

        let fullURL = (model.url?.absoluteString ?? "").lowercased()

        if !SwiftyDebug._tags.isEmpty {
            for (keyword, label) in SwiftyDebug._tags {
                let lowerKeyword = keyword.lowercased()
                if fullURL.contains(lowerKeyword) || host.contains(lowerKeyword) {
                    applyHostTag(label, key: keyword, alpha: 0.25)
                    return
                }
            }
        }

        if model.isWebViewRequest {
            applyHostTag("web", key: "web", alpha: 0.25)
            return
        }

        let knownTags: [(keyword: String, label: String)] = [
            ("algolia",   "algolia"),
            ("onesignal", "one signal"),
            ("jitsu",     "jitsu"),
        ]
        for tag in knownTags where host.contains(tag.keyword) {
            applyHostTag(tag.label, key: tag.keyword, alpha: 0.25)
            return
        }

        applyHostTag(Self.abbreviateHost(host), key: host, alpha: 0.2)
    }

    private func applyHostTag(_ label: String, key: String, alpha: CGFloat) {
        let color = NetworkCell.colorForTag(key)
        hostTagLabel.isHidden = false
        hostTagLabel.text = label
        hostTagLabel.backgroundColor = color.withAlphaComponent(alpha)
        hostTagLabel.textColor = color
    }

    private static func abbreviateHost(_ host: String) -> String {
        var short = host
        for prefix in ["www.", "api.", "cdn.", "m."] where short.hasPrefix(prefix) {
            short = String(short.dropFirst(prefix.count))
            break
        }
        for suffix in [".com", ".io", ".net", ".org", ".co"] where short.hasSuffix(suffix) {
            short = String(short.dropLast(suffix.count))
            break
        }
        if short.count > 12 {
            short = String(short.prefix(10)) + ".."
        }
        return short
    }
}
