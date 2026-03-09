//
//  LogCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

// MARK: - LogPaddedLabel (pill-shaped tag)

private class LogPaddedLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: ceil(size.width) + textInsets.left + textInsets.right,
            height: ceil(size.height) + textInsets.top + textInsets.bottom
        )
    }
}

// MARK: - LogCell

class LogCell: UITableViewCell {

    // MARK: - Card container

    private let cardView = UIView()

    /// 3pt-wide vertical bar on the left edge of the card (like NetworkCell)
    private let statusLine = UIView()

    // MARK: - Top row: row#, source tag, type tag, json tag, spacer, timestamp

    private let rowNumberLabel = UILabel()
    private let sourceTagLabel = LogPaddedLabel()   // APP / 3RD PARTY / WEB
    private let typeTagLabel = LogPaddedLabel()     // NSLog / print / os_log / SDK / Code / console
    private let jsonTagLabel = LogPaddedLabel()     // JSON (if applicable)
    private let timeLabel = UILabel()

    // MARK: - Content

    private let contentLabel = UILabel()

    // MARK: - Show Full JSON button

    private let showFullButton = UIButton(type: .system)

    // MARK: - Bottom row: library label, spacer, copy, pin, viewed icon

    private let libraryLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let pinIcon = UIImageView()
    private let viewedIcon = UIImageView()

    // MARK: - Layout containers (UIStackView, matching NetworkCell pattern)

    private let topRow = UIStackView()
    private let bottomRow = UIStackView()
    private let mainStack = UIStackView()

    // MARK: - Callbacks

    var onShowFull: (() -> Void)?
    var onCopy: (() -> Void)?

    // MARK: - Constants

    private static let cardColor = UIColor(white: 0.11, alpha: 1)       // #1C1C1C
    private static let taggedCardColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.15)
    private static let cellSpacing: CGFloat = 4
    private static let tealColor = UIColor(red: 0.29, green: 0.76, blue: 0.76, alpha: 1)

    // Source colors (same as before)
    private static let appColor = UIColor(red: 0.26, green: 0.83, blue: 0.35, alpha: 1)        // green
    private static let thirdPartyColor = UIColor(red: 0.85, green: 0.65, blue: 0.30, alpha: 1) // orange
    private static let webColor = UIColor(red: 0.30, green: 0.54, blue: 0.97, alpha: 1)        // blue

    /// Max lines shown in the list cell for plain text
    static let maxLines = 4
    /// Max chars for JSON preview before showing "Show Full" button
    private static let jsonTruncateLength = 800

    // MARK: - Data

    var index: Int = 0

    var model: LogRecord? {
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

        // Status line (inside card, left edge) — matches NetworkCell
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLine)

        // --- Top row elements ---

        // Row number
        rowNumberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        rowNumberLabel.textColor = UIColor(white: 0.65, alpha: 1)
        rowNumberLabel.setContentHuggingPriority(.required, for: .horizontal)
        rowNumberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Source tag pill (APP / 3RD PARTY / WEB)
        sourceTagLabel.font = .systemFont(ofSize: 9, weight: .bold)
        sourceTagLabel.textColor = .white
        sourceTagLabel.textAlignment = .center
        sourceTagLabel.layer.cornerRadius = 4
        sourceTagLabel.clipsToBounds = true
        sourceTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        sourceTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Type tag pill (NSLog / print / os_log / SDK / Code / console)
        typeTagLabel.font = .systemFont(ofSize: 9, weight: .bold)
        typeTagLabel.textAlignment = .center
        typeTagLabel.layer.cornerRadius = 4
        typeTagLabel.clipsToBounds = true
        typeTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        typeTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // JSON tag pill
        jsonTagLabel.font = .systemFont(ofSize: 9, weight: .bold)
        jsonTagLabel.textAlignment = .center
        jsonTagLabel.layer.cornerRadius = 4
        jsonTagLabel.clipsToBounds = true
        jsonTagLabel.text = "JSON"
        jsonTagLabel.textColor = Self.tealColor
        jsonTagLabel.backgroundColor = Self.tealColor.withAlphaComponent(0.2)
        jsonTagLabel.isHidden = true
        jsonTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        jsonTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Timestamp
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = DebugTheme.accentColor
        timeLabel.textAlignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Top spacer
        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6
        topRow.addArrangedSubview(rowNumberLabel)
        topRow.addArrangedSubview(sourceTagLabel)
        topRow.addArrangedSubview(typeTagLabel)
        topRow.addArrangedSubview(jsonTagLabel)
        topRow.addArrangedSubview(topSpacer)
        topRow.addArrangedSubview(timeLabel)

        // --- Content ---

        contentLabel.font = UIFont(name: "Menlo", size: 11) ?? .systemFont(ofSize: 11)
        contentLabel.textColor = UIColor(white: 0.85, alpha: 1)
        contentLabel.numberOfLines = Self.maxLines
        contentLabel.lineBreakMode = .byTruncatingTail

        // --- Show Full JSON button ---

        showFullButton.isHidden = true
        showFullButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        showFullButton.layer.cornerRadius = 6
        showFullButton.clipsToBounds = true
        showFullButton.titleLabel?.font = .systemFont(ofSize: 7, weight: .bold)
        showFullButton.setTitleColor(Self.tealColor, for: .normal)
        var showFullConfig = UIButton.Configuration.plain()
        showFullConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        showFullConfig.imagePadding = 4
        showFullButton.configuration = showFullConfig

        let showFullCfg = UIImage.SymbolConfiguration(pointSize: 6, weight: .semibold)
        let showFullIco = UIImage(systemName: "arrow.down.left.and.arrow.up.right", withConfiguration: showFullCfg)?
            .withTintColor(Self.tealColor, renderingMode: .alwaysOriginal)
        showFullButton.setImage(showFullIco, for: .normal)
        showFullButton.setTitle("Show Full JSON", for: .normal)
        showFullButton.addTarget(self, action: #selector(showFullTapped), for: .touchUpInside)

        // --- Bottom row elements ---

        // Library / source label
        libraryLabel.font = .systemFont(ofSize: 10, weight: .medium)
        libraryLabel.textColor = UIColor(white: 0.50, alpha: 1)
        libraryLabel.numberOfLines = 1
        libraryLabel.lineBreakMode = .byTruncatingTail

        // Copy button
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: buttonConfig), for: .normal)
        copyButton.tintColor = DebugTheme.accentColor
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Pin indicator (shown when log is pinned)
        pinIcon.isHidden = true
        pinIcon.contentMode = .scaleAspectFit
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)
        pinIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pinConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        pinIcon.image = UIImage(systemName: "pin.fill", withConfiguration: pinConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        pinIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        pinIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        // Viewed indicator (eye icon, shown after user opens log details — same as NetworkCell)
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

        // Bottom spacer
        let bottomSpacer = UIView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 6
        bottomRow.addArrangedSubview(libraryLabel)
        bottomRow.addArrangedSubview(bottomSpacer)
        bottomRow.addArrangedSubview(copyButton)
        bottomRow.addArrangedSubview(pinIcon)
        bottomRow.addArrangedSubview(viewedIcon)

        // --- Main stack ---

        mainStack.axis = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(contentLabel)
        mainStack.addArrangedSubview(showFullButton)
        mainStack.addArrangedSubview(bottomRow)
        cardView.addSubview(mainStack)

        // --- Constraints ---

        NSLayoutConstraint.activate([
            // Card inset from cell edges
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cellSpacing / 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Self.cellSpacing / 2)),

            // Status line inside card
            statusLine.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: cardView.topAnchor),
            statusLine.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            statusLine.widthAnchor.constraint(equalToConstant: 3),

            // Main stack inside card (matching NetworkCell padding)
            mainStack.leadingAnchor.constraint(equalTo: statusLine.trailingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            mainStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Configure

    private func configure() {
        guard let model = model else { return }

        // Row number
        rowNumberLabel.text = String(index + 1)

        // Source tag pill (APP / 3RD PARTY / WEB)
        let sourceColor = Self.colorForSource(model.logSource)
        sourceTagLabel.text = Self.sourceLabel(model.logSource)
        sourceTagLabel.backgroundColor = sourceColor.withAlphaComponent(0.25)
        sourceTagLabel.textColor = sourceColor

        // Status line color
        let contentStr = model.content ?? ""
        if model.color == .systemRed || contentStr.lowercased().contains("error") || contentStr.lowercased().contains("fault") {
            statusLine.backgroundColor = .systemRed
        } else {
            statusLine.backgroundColor = sourceColor
        }

        // Type tag pill (NSLog / print / os_log / SDK / Code / console)
        let typeName = model.logTypeName
        if typeName.isEmpty {
            typeTagLabel.isHidden = true
        } else {
            typeTagLabel.isHidden = false
            typeTagLabel.text = typeName
            let typeColor = Self.colorForType(typeName)
            typeTagLabel.backgroundColor = typeColor.withAlphaComponent(0.2)
            typeTagLabel.textColor = typeColor
        }

        // Timestamp
        if let date = model.date {
            timeLabel.text = Self.formatTime(date)
        } else {
            timeLabel.text = ""
        }

        // Detect JSON content
        let jsonContent = Self.extractJSON(from: model)
        let isJSON = jsonContent != nil
        jsonTagLabel.isHidden = !isJSON

        // Content
        showFullButton.isHidden = true
        if isJSON, let json = jsonContent {
            let prettyJSON = Self.prettyPrint(json) ?? json
            if prettyJSON.count > Self.jsonTruncateLength {
                let truncated = String(prettyJSON.prefix(Self.jsonTruncateLength)) + "\n..."
                contentLabel.attributedText = NetworkDetailCell.highlightJSON(truncated)
                contentLabel.numberOfLines = 0
                showFullButton.isHidden = false
            } else {
                contentLabel.attributedText = NetworkDetailCell.highlightJSON(prettyJSON)
                contentLabel.numberOfLines = 0
            }
        } else {
            contentLabel.attributedText = nil
            contentLabel.text = contentStr
            contentLabel.textColor = model.color ?? UIColor(white: 0.85, alpha: 1)
            contentLabel.numberOfLines = Self.maxLines
        }

        // Library / source name (bottom row) — show library · subsystem · category
        var metaParts: [String] = []
        let name = model.sourceName
        if !name.isEmpty && name != model.logTypeName {
            metaParts.append(name)
        }
        if !model.subsystem.isEmpty {
            metaParts.append(model.subsystem)
        }
        if !model.category.isEmpty {
            metaParts.append(model.category)
        }
        libraryLabel.text = metaParts.isEmpty ? "" : metaParts.joined(separator: " · ")

        // Pin indicator
        pinIcon.isHidden = !model.isPinned

        // Viewed indicator
        viewedIcon.isHidden = !model.isViewed

        // Card background
        if model.isTag {
            cardView.backgroundColor = Self.taggedCardColor
        } else if model.isSelected {
            cardView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        } else {
            cardView.backgroundColor = Self.cardColor
        }

        // Reset copy button icon
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: buttonConfig), for: .normal)
        copyButton.tintColor = DebugTheme.accentColor
    }

    // MARK: - Actions

    @objc private func showFullTapped() {
        onShowFull?()
    }

    @objc private func copyTapped() {
        onCopy?()

        // Flash green checkmark feedback
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.setImage(UIImage(systemName: "checkmark", withConfiguration: buttonConfig), for: .normal)
        copyButton.tintColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: buttonConfig), for: .normal)
            self.copyButton.tintColor = DebugTheme.accentColor
        }
    }

    // MARK: - Helpers

    /// Try to extract a valid JSON string from the log model
    static func extractJSON(from model: LogRecord) -> String? {
        // Quick prefix check: JSON must start with { or [
        let prefix = (model.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix("{") || prefix.hasPrefix("[") else { return nil }

        if let data = model.contentData,
           let str = String(data: data, encoding: .utf8),
           isValidJSON(str) {
            return str
        }
        if let content = model.content, isValidJSON(content) {
            return content
        }
        return nil
    }

    /// Pretty-print JSON string
    private static func prettyPrint(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return result
    }

    private static func sourceLabel(_ source: SwiftyDebugLogSource) -> String {
        switch source {
        case .app:        return "APP"
        case .thirdParty: return "3RD PARTY"
        case .web:        return "WEB"
        @unknown default: return "LOG"
        }
    }

    static func colorForSource(_ source: SwiftyDebugLogSource) -> UIColor {
        switch source {
        case .app:        return appColor
        case .thirdParty: return thirdPartyColor
        case .web:        return webColor
        @unknown default: return appColor
        }
    }

    private static func colorForType(_ typeName: String) -> UIColor {
        switch typeName {
        case "console": return webColor
        default:        return UIColor(white: 0.55, alpha: 1) // gray
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = NSTimeZone.system
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func formatTime(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }
}
