//
//  ConsoleCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

// MARK: - ConsoleCell (compact, flush cells for Console tab)

class ConsoleCell: UITableViewCell {

    // MARK: - UI

    private let contentLabel = UILabel()

    // MARK: - Colors

    private static let bgColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
    private static let normalTextColor = UIColor(white: 0.87, alpha: 1)
    private static let errorTextColor = UIColor(red: 1.0, green: 0.55, blue: 0.55, alpha: 1)
    private static let timestampColor = UIColor(white: 0.45, alpha: 1)
    private static let urlColor = UIColor(red: 0.30, green: 0.54, blue: 0.97, alpha: 1)
    private static let numberColor = UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1)
    private static let stringColor = UIColor(red: 0.82, green: 0.60, blue: 0.34, alpha: 1)
    private static let keyColor = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
    private static let boolColor = UIColor(red: 0.88, green: 0.42, blue: 0.42, alpha: 1)
    private static let searchHighlightColor = UIColor(red: 0.80, green: 0.72, blue: 0.0, alpha: 0.35)
    private static let currentMatchColor = UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 0.65)

    // MARK: - Fonts

    static let consoleFont = UIFont(name: "Menlo", size: 12)
        ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let consoleFontBold = UIFont(name: "Menlo-Bold", size: 12)
        ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let timestampFont = UIFont(name: "Menlo", size: 10)
        ?? UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    // MARK: - Pre-compiled regex (compiled ONCE, used by highlightConsoleText)

    private static let timestampRegex = try! NSRegularExpression(pattern: "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]")
    private static let tsExtractRegex = try! NSRegularExpression(pattern: "^\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]\\s*")
    private static let errorKeywordRegex = try! NSRegularExpression(pattern: "\\b(error|Error|ERROR|fault|FAULT|exception|Exception|EXCEPTION|crash|CRASH|fatal|FATAL)\\b")
    private static let warningKeywordRegex = try! NSRegularExpression(pattern: "\\b(warning|Warning|WARNING|warn|WARN)\\b")
    private static let urlRegex = try! NSRegularExpression(pattern: "https?://[^\\s]+")
    private static let stringLiteralRegex = try! NSRegularExpression(pattern: "\"[^\"]*\"")
    private static let numberRegex = try! NSRegularExpression(pattern: "(?<=\\s|=|:|,)(-?\\d+\\.?\\d*)(?=\\s|,|\\)|\\]|$)")
    private static let keyValueRegex = try! NSRegularExpression(pattern: "(\\w+)=")
    private static let jsonKeyRegex = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:")
    private static let jsonStringValueRegex = try! NSRegularExpression(pattern: ":\\s*(\"[^\"]*\")")
    private static let jsonNumberRegex = try! NSRegularExpression(pattern: ":\\s*(-?\\d+\\.?\\d*)([,\\s\\}\\]])")
    private static let jsonBoolRegex = try! NSRegularExpression(pattern: ":\\s*(true|false|null)\\b")

    private static let baseParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .natural
        p.lineSpacing = 1
        p.lineBreakMode = .byCharWrapping
        return p
    }()

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = Self.bgColor
        contentView.backgroundColor = Self.bgColor

        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.font = Self.consoleFont
        contentLabel.textColor = Self.normalTextColor
        contentLabel.numberOfLines = 0
        contentLabel.lineBreakMode = .byCharWrapping
        contentView.addSubview(contentLabel)

        NSLayoutConstraint.activate([
            contentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            contentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            contentLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            contentLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
        ])

        forceLTR()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentLabel.attributedText = nil
        contentLabel.text = nil
    }

    // MARK: - Configure

    func configure(with entry: ConsoleLineCache, searchQuery: String? = nil, isCurrentMatch: Bool = false) {
        if let attr = entry.attributedText {
            if let query = searchQuery, !query.isEmpty {
                contentLabel.attributedText = Self.applySearchHighlight(to: attr, query: query, isCurrentMatch: isCurrentMatch)
            } else {
                contentLabel.attributedText = attr
            }
        } else {
            let isError = (entry.color == .systemRed)
            if let query = searchQuery, !query.isEmpty {
                let plain = NSAttributedString(string: entry.text, attributes: [
                    .font: Self.consoleFont,
                    .foregroundColor: isError ? Self.errorTextColor : Self.normalTextColor,
                    .paragraphStyle: Self.baseParagraphStyle,
                ])
                contentLabel.attributedText = Self.applySearchHighlight(to: plain, query: query, isCurrentMatch: isCurrentMatch)
            } else {
                contentLabel.attributedText = nil
                contentLabel.text = entry.text
                contentLabel.textColor = isError ? Self.errorTextColor : Self.normalTextColor
                contentLabel.font = Self.consoleFont
            }
        }
    }

    // MARK: - Search Highlight (applied on top of syntax highlighting, not cached)

    static func applySearchHighlight(to source: NSAttributedString, query: String, isCurrentMatch: Bool) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: source)
        let nsText = mutable.string.lowercased() as NSString
        let queryLower = query.lowercased() as NSString
        let queryLen = queryLower.length
        guard queryLen > 0 else { return mutable }

        let color = isCurrentMatch ? currentMatchColor : searchHighlightColor
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.location < nsText.length {
            let found = nsText.range(of: queryLower as String, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            mutable.addAttribute(.backgroundColor, value: color, range: found)
            searchRange.location = found.location + found.length
            searchRange.length = nsText.length - searchRange.location
        }

        return mutable
    }

    // MARK: - Rich Console Text Highlighting (called by LogStore on background thread)

    /// Max characters to apply regex highlighting — longer lines get plain styled text
    private static let maxHighlightLength = 500

    static func highlightConsoleText(_ text: String, isError: Bool) -> NSAttributedString {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            return NSAttributedString(string: "", attributes: [.font: consoleFont])
        }

        let baseColor = isError ? errorTextColor : normalTextColor

        // Skip regex highlighting for very long lines to prevent multi-MB attributed strings
        if trimmed.count > maxHighlightLength {
            return NSAttributedString(string: trimmed, attributes: [
                .font: consoleFont,
                .foregroundColor: baseColor,
                .paragraphStyle: baseParagraphStyle,
            ])
        }

        let result = NSMutableAttributedString(string: trimmed, attributes: [
            .font: consoleFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraphStyle,
        ])
        let nsText = trimmed as NSString
        let full = NSRange(location: 0, length: nsText.length)

        // Detect JSON content (after optional timestamp)
        let tsMatch = tsExtractRegex.firstMatch(in: trimmed, range: full)
        let contentOffset: Int
        let contentAfterTimestamp: String
        if let tsMatch = tsMatch {
            contentOffset = tsMatch.range.length
            contentAfterTimestamp = nsText.substring(from: contentOffset).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            contentOffset = 0
            contentAfterTimestamp = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Cheap structural JSON check: O(1) vs JSONSerialization's O(n)
        if looksLikeJSON(contentAfterTimestamp) {
            let jsonRange = NSRange(location: contentOffset, length: nsText.length - contentOffset)
            applyJSONHighlighting(to: result, text: nsText, range: jsonRange)
        } else {
            applyGeneralHighlighting(to: result, text: trimmed, nsText: nsText, range: full, isError: isError)
        }

        // Timestamp coloring LAST so it always wins
        for m in timestampRegex.matches(in: trimmed, range: full) {
            result.addAttribute(.foregroundColor, value: timestampColor, range: m.range)
            result.addAttribute(.font, value: timestampFont, range: m.range)
        }

        return result
    }

    /// Cheap O(1) JSON detection — checks first/last character only
    private static func looksLikeJSON(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return false }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    // MARK: - JSON Highlighting

    private static func applyJSONHighlighting(to attr: NSMutableAttributedString, text: NSString, range: NSRange) {
        let substring = text.substring(with: range)
        let subFull = NSRange(location: 0, length: (substring as NSString).length)

        for m in jsonKeyRegex.matches(in: substring, range: subFull) {
            let adjusted = NSRange(location: m.range.location + range.location, length: m.range.length)
            attr.addAttribute(.foregroundColor, value: keyColor, range: adjusted)
        }

        for m in jsonStringValueRegex.matches(in: substring, range: subFull) {
            let r = m.range(at: 1)
            let adjusted = NSRange(location: r.location + range.location, length: r.length)
            attr.addAttribute(.foregroundColor, value: stringColor, range: adjusted)
        }

        for m in jsonNumberRegex.matches(in: substring, range: subFull) {
            let r = m.range(at: 1)
            let adjusted = NSRange(location: r.location + range.location, length: r.length)
            attr.addAttribute(.foregroundColor, value: numberColor, range: adjusted)
        }

        for m in jsonBoolRegex.matches(in: substring, range: subFull) {
            let r = m.range(at: 1)
            let adjusted = NSRange(location: r.location + range.location, length: r.length)
            attr.addAttribute(.foregroundColor, value: boolColor, range: adjusted)
        }
    }

    // MARK: - General Console Highlighting

    private static func applyGeneralHighlighting(to attr: NSMutableAttributedString, text: String, nsText: NSString, range: NSRange, isError: Bool) {
        for m in errorKeywordRegex.matches(in: text, range: range) {
            attr.addAttribute(.foregroundColor, value: UIColor.systemRed, range: m.range)
            attr.addAttribute(.font, value: consoleFontBold, range: m.range)
        }

        for m in warningKeywordRegex.matches(in: text, range: range) {
            attr.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: m.range)
        }

        for m in urlRegex.matches(in: text, range: range) {
            attr.addAttribute(.foregroundColor, value: urlColor, range: m.range)
            attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }

        for m in stringLiteralRegex.matches(in: text, range: range) {
            attr.addAttribute(.foregroundColor, value: stringColor, range: m.range)
        }

        if !isError {
            for m in numberRegex.matches(in: text, range: range) {
                attr.addAttribute(.foregroundColor, value: numberColor, range: m.range)
            }
        }

        for m in keyValueRegex.matches(in: text, range: range) {
            attr.addAttribute(.foregroundColor, value: keyColor, range: m.range(at: 1))
        }
    }
}
