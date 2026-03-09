//
//  NetworkDetailCell.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

class NetworkDetailCell: UITableViewCell {

    // MARK: - Card

    private let cardView = UIView()

    // MARK: - Title row

    let titleLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    let previewButton = UIButton(type: .system)

    // MARK: - Content

    let contentTextView = UITextView()
    let imgView = UIImageView()
    private let showFullButton = UIButton(type: .system)

    // MARK: - Constraint switching

    private var contentBottomConstraint: NSLayoutConstraint!
    private var showFullBottomConstraint: NSLayoutConstraint!
    private var imageBottomConstraint: NSLayoutConstraint!
    private var collapsedBottomConstraint: NSLayoutConstraint!

    /// Copy button trailing when preview IS visible
    private var copyTrailingToPreview: NSLayoutConstraint!
    /// Copy button trailing when preview is NOT visible
    private var copyTrailingToCard: NSLayoutConstraint!

    // MARK: - Colors

    private static let cardColor = UIColor(white: 0.11, alpha: 1)       // #1C1C1C
    private static let infoCardColor = UIColor(red: 0.14, green: 0.10, blue: 0.09, alpha: 1)
    private static let tealTitle = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
    private static let infoTitle = UIColor(red: 0.85, green: 0.45, blue: 0.35, alpha: 1)
    private static let contentColor = UIColor(white: 0.82, alpha: 1)
    private static let baseFont = UIFont(name: "Menlo", size: 11) ?? UIFont.systemFont(ofSize: 11)

    private static let truncateLength = 2000

    // MARK: - Data

    var tapEditViewCallback: ((NetworkDetailSection?) -> Void)?

    var detailModel: NetworkDetailSection? {
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

        // Card
        cardView.backgroundColor = Self.cardColor
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // Title
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = Self.tealTitle
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        // Copy button (icon only)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isHidden = true
        copyButton.addTarget(self, action: #selector(tapCopy), for: .touchUpInside)
        let copyConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let copyIcon = UIImage(systemName: "doc.on.doc", withConfiguration: copyConfig)?
            .withTintColor(Self.tealTitle, renderingMode: .alwaysOriginal)
        copyButton.setImage(copyIcon, for: .normal)
        cardView.addSubview(copyButton)

        // Preview button (matches Show Full Response style: dark bg + teal text)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        previewButton.layer.cornerRadius = 6
        previewButton.clipsToBounds = true
        var previewBtnConfig = UIButton.Configuration.plain()
        previewBtnConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        previewBtnConfig.imagePadding = 4
        previewBtnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        previewBtnConfig.baseForegroundColor = Self.tealTitle
        previewButton.configuration = previewBtnConfig
        previewButton.addTarget(self, action: #selector(tapPreview), for: .touchUpInside)

        let previewConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let previewIcon = UIImage(systemName: "doc.text.magnifyingglass", withConfiguration: previewConfig)?
            .withTintColor(Self.tealTitle, renderingMode: .alwaysOriginal)
        previewButton.setImage(previewIcon, for: .normal)
        previewButton.setTitle("Preview", for: .normal)
        previewButton.isHidden = true
        cardView.addSubview(previewButton)

        // Content text view
        contentTextView.isEditable = false
        contentTextView.isScrollEnabled = false
        contentTextView.backgroundColor = .clear
        contentTextView.textColor = Self.contentColor
        contentTextView.font = Self.baseFont
        contentTextView.textContainer.lineFragmentPadding = 0
        contentTextView.textContainerInset = .zero
        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        contentTextView.dataDetectorTypes = []
        cardView.addSubview(contentTextView)

        // "Show Full Response" button (below truncated content)
        showFullButton.translatesAutoresizingMaskIntoConstraints = false
        showFullButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        showFullButton.layer.cornerRadius = 6
        showFullButton.clipsToBounds = true
        var showFullBtnConfig = UIButton.Configuration.plain()
        showFullBtnConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        showFullBtnConfig.imagePadding = 5
        showFullBtnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        showFullBtnConfig.baseForegroundColor = Self.tealTitle
        showFullButton.configuration = showFullBtnConfig
        showFullButton.addTarget(self, action: #selector(tapPreview), for: .touchUpInside)

        let showFullCfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let showFullIco = UIImage(systemName: "arrow.down.left.and.arrow.up.right", withConfiguration: showFullCfg)?
            .withTintColor(Self.tealTitle, renderingMode: .alwaysOriginal)
        showFullButton.setImage(showFullIco, for: .normal)
        showFullButton.setTitle("Show Full Response", for: .normal)
        showFullButton.isHidden = true
        cardView.addSubview(showFullButton)

        // Image view
        imgView.contentMode = .scaleAspectFit
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.isHidden = true
        cardView.addSubview(imgView)

        // Bottom constraints (only one active at a time)
        contentBottomConstraint = contentTextView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10)
        showFullBottomConstraint = showFullButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10)
        imageBottomConstraint = imgView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -4)
        collapsedBottomConstraint = titleLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10)

        NSLayoutConstraint.activate([
            // Card inset
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            // Title
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),

            // Copy button (icon only, next to title)
            copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),

            // Preview button
            previewButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            // Content
            contentTextView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            contentTextView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            contentTextView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            // Show Full button (always chained below content, visibility toggles it)
            showFullButton.topAnchor.constraint(equalTo: contentTextView.bottomAnchor, constant: 10),
            showFullButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),

            // Image
            imgView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            imgView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 4),
            imgView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -4),
            imgView.heightAnchor.constraint(equalTo: imgView.widthAnchor),

            // Default bottom
            contentBottomConstraint,
        ])

        // Switchable copy button trailing constraints
        copyTrailingToPreview = copyButton.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -12)
        copyTrailingToCard = copyButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12)
        copyTrailingToCard.isActive = true
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.attributedText = nil
        titleLabel.text = nil
        contentTextView.attributedText = nil
        contentTextView.text = nil
        contentTextView.isHidden = true
        imgView.image = nil
        imgView.isHidden = true
        showFullButton.isHidden = true
        copyButton.isHidden = true
        previewButton.isHidden = true

        // Reset bottom constraints
        contentBottomConstraint.isActive = false
        showFullBottomConstraint.isActive = false
        imageBottomConstraint.isActive = false
        collapsedBottomConstraint.isActive = false
        contentBottomConstraint.isActive = true

        // Reset copy button position
        copyTrailingToPreview.isActive = false
        copyTrailingToCard.isActive = true
    }

    // MARK: - Configure

    private func configure() {
        guard let model = detailModel else { return }

        let isInfo = model.isInfoOnly
        let isCollapsed = model.blankContent == "..."
        let hasImage = model.image != nil
        let hasContent = !(model.content?.isEmpty ?? true)
        let showPreview = model.showPreview && hasContent
        let mustInPreview = model.mustInPreview

        // Title (with optional size annotation pill)
        let titleColor = isInfo ? Self.infoTitle : Self.tealTitle
        if let size = model.sizeTag, !size.isEmpty {
            let attr = NSMutableAttributedString(string: model.title ?? "", attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: titleColor,
            ])
            attr.append(NSAttributedString(string: "  \(size)", attributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor(white: 0.42, alpha: 1),
            ]))
            titleLabel.attributedText = attr
        } else {
            titleLabel.attributedText = nil
            titleLabel.text = model.title
            titleLabel.textColor = titleColor
        }

        // Card color
        cardView.backgroundColor = isInfo ? Self.infoCardColor : Self.cardColor

        // Copy button — show for non-info, non-curl sections with content
        let isCurlSection = model.title == "REQUEST CURL"
        copyButton.isHidden = !hasContent || isInfo || isCurlSection

        // Preview button (top-right) — switch copy button constraint
        previewButton.isHidden = !showPreview
        copyTrailingToPreview.isActive = showPreview
        copyTrailingToCard.isActive = !showPreview

        // Reset showFull button
        showFullButton.isHidden = true

        // Layout states
        if isCollapsed {
            contentTextView.isHidden = true
            imgView.isHidden = true
        } else if hasImage {
            contentTextView.isHidden = true
            imgView.isHidden = false
            imgView.image = model.image
        } else {
            imgView.isHidden = true
            contentTextView.isHidden = !hasContent

            if hasContent {
                let content = model.content!
                let isCurl = isCurlSection

                if isInfo {
                    // Info sections: plain text, dimmer
                    contentTextView.attributedText = nil
                    contentTextView.text = content
                    contentTextView.font = .systemFont(ofSize: 13)
                    contentTextView.textAlignment = .natural
                    contentTextView.textColor = UIColor(white: 0.55, alpha: 1)
                } else if mustInPreview {
                    // Large content: show truncated preview with highlighting + button
                    let truncated = String(content.prefix(Self.truncateLength)) + "\n..."
                    contentTextView.attributedText = isCurl ? Self.highlightCurl(truncated) : Self.highlightJSON(truncated)
                    contentTextView.textAlignment = .natural
                    showFullButton.setTitle(isCurl ? "Show Full cURL" : "Show Full Response", for: .normal)
                    showFullButton.isHidden = false
                } else {
                    // Normal content: full syntax highlighting
                    contentTextView.attributedText = isCurl ? Self.highlightCurl(content) : Self.highlightJSON(content)
                    contentTextView.textAlignment = .natural
                }
            }
        }

        // Switch bottom constraints
        contentBottomConstraint.isActive = false
        showFullBottomConstraint.isActive = false
        imageBottomConstraint.isActive = false
        collapsedBottomConstraint.isActive = false

        if isCollapsed || (!hasContent && !hasImage) {
            collapsedBottomConstraint.isActive = true
        } else if hasImage {
            imageBottomConstraint.isActive = true
        } else if !showFullButton.isHidden {
            showFullBottomConstraint.isActive = true
        } else {
            contentBottomConstraint.isActive = true
        }

        // Signal that the text view's size has changed.
        // Do NOT call layoutIfNeeded() here — it forces a synchronous layout
        // during cellForRowAt, causing UITableView to re-measure other cells
        // while they are in the prepareForReuse() collapsed state, making
        // sections appear to vanish on scroll. Let automaticDimension +
        // systemLayoutSizeFitting handle height calculation instead.
        contentTextView.invalidateIntrinsicContentSize()
    }

    @objc private func tapCopy() {
        guard let content = detailModel?.content, !content.isEmpty else { return }
        UIPasteboard.general.string = content

        // Brief visual feedback — flash the icon color
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let checkIcon = UIImage(systemName: "checkmark", withConfiguration: config)?
            .withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
        copyButton.setImage(checkIcon, for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let originalIcon = UIImage(systemName: "doc.on.doc", withConfiguration: config)?
                .withTintColor(Self.tealTitle, renderingMode: .alwaysOriginal)
            self?.copyButton.setImage(originalIcon, for: .normal)
        }
    }

    @objc private func tapPreview() {
        tapEditViewCallback?(detailModel)
    }

    // MARK: - JSON Syntax Highlighting

    static func highlightJSON(_ text: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: UIColor(white: 0.60, alpha: 1)  // default: braces, brackets, commas
        ])

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Keys: "someKey" :
        if let regex = try? NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: tealTitle, range: match.range)
            }
        }

        // String values after colon: : "someValue"
        if let regex = try? NSRegularExpression(pattern: ":\\s*(\"[^\"]*\")", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: UIColor(red: 0.82, green: 0.60, blue: 0.34, alpha: 1), range: match.range(at: 1))
            }
        }

        // Numbers: : 123 or : -1.5
        if let regex = try? NSRegularExpression(pattern: ":\\s*(-?\\d+\\.?\\d*)([,\\s\\}\\]])", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1), range: match.range(at: 1))
            }
        }

        // Booleans & null
        if let regex = try? NSRegularExpression(pattern: ":\\s*(true|false|null)\\b", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: UIColor(red: 0.88, green: 0.42, blue: 0.42, alpha: 1), range: match.range(at: 1))
            }
        }

        return attr
    }

    // MARK: - cURL Syntax Highlighting

    static func highlightCurl(_ text: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: UIColor(white: 0.82, alpha: 1)
        ])

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let flagColor = UIColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 1)       // blue
        let urlColor = UIColor(red: 0.26, green: 0.83, blue: 0.35, alpha: 1)        // green
        let stringColor = UIColor(red: 0.82, green: 0.60, blue: 0.34, alpha: 1)     // orange
        let cmdColor = UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1)        // purple

        // "curl" command keyword
        if let regex = try? NSRegularExpression(pattern: "^curl\\b", options: []) {
            let boldFont = UIFont(name: "Menlo-Bold", size: 11) ?? UIFont.boldSystemFont(ofSize: 11)
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: cmdColor, range: match.range)
                attr.addAttribute(.font, value: boldFont, range: match.range)
            }
        }

        // Flags: -X, -H, -d, --data-binary
        if let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(-X|-H|-d|--data-binary)\\b", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: flagColor, range: match.range(at: 1))
            }
        }

        // Single-quoted strings: '...'
        if let regex = try? NSRegularExpression(pattern: "'[^']*'", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                let matchStr = nsText.substring(with: match.range)
                if matchStr.contains("://") {
                    attr.addAttribute(.foregroundColor, value: urlColor, range: match.range)
                } else {
                    attr.addAttribute(.foregroundColor, value: stringColor, range: match.range)
                }
            }
        }

        // Line continuation backslashes
        if let regex = try? NSRegularExpression(pattern: "\\\\$", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: UIColor(white: 0.45, alpha: 1), range: match.range)
            }
        }

        return attr
    }
}
