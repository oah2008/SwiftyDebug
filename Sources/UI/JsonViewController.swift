//
//  JsonViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

class JsonViewController: UIViewController {

    private var textView: CustomTextView!
    private var imageView: UIImageView!

    var naviItemTitleLabel: UILabel?

    var editType: DetailContentType  = .unknown
    var detailModel: NetworkDetailSection?

    //log
    var logTitleString: String?
    var logModels: [LogRecord]?
    var logModel: LogRecord?
    var justCancelCallback:(() -> Void)?
    
    // MARK: - Log detail formatting

    private static let metaKeyColor = UIColor(white: 0.45, alpha: 1)
    private static let metaValueColor = UIColor(white: 0.78, alpha: 1)
    private static let headerFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    private static let contentFont = UIFont(name: "Menlo", size: 12) ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let separatorColor = UIColor(white: 0.22, alpha: 1)

    static func buildLogDetailAttributedString(model: LogRecord) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let lineBreak = NSAttributedString(string: "\n")

        // --- Metadata section ---
        func addMetaRow(key: String, value: String, valueColor: UIColor = metaValueColor) {
            let keyAttr = NSAttributedString(string: "\(key)  ", attributes: [
                .font: headerFont,
                .foregroundColor: metaKeyColor,
            ])
            let valAttr = NSAttributedString(string: value, attributes: [
                .font: headerFont,
                .foregroundColor: valueColor,
            ])
            result.append(keyAttr)
            result.append(valAttr)
            result.append(lineBreak)
        }

        // Source
        let sourceLabel: String
        switch model.logSource {
        case .app:        sourceLabel = "App"
        case .thirdParty: sourceLabel = "Third Party"
        case .web:        sourceLabel = "Web"
        @unknown default: sourceLabel = "Unknown"
        }
        addMetaRow(key: "Source", value: sourceLabel, valueColor: LogCell.colorForSource(model.logSource))

        // Type
        if !model.logTypeName.isEmpty {
            addMetaRow(key: "Type", value: model.logTypeName)
        }

        // Library / sender
        if !model.sourceName.isEmpty {
            addMetaRow(key: "Library", value: model.sourceName)
        }

        // Subsystem
        if !model.subsystem.isEmpty {
            addMetaRow(key: "Subsystem", value: model.subsystem)
        }

        // Category
        if !model.category.isEmpty {
            addMetaRow(key: "Category", value: model.category)
        }

        // Timestamp
        if let date = model.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            addMetaRow(key: "Time", value: formatter.string(from: date), valueColor: DebugTheme.accentColor)
        }

        // --- Separator line ---
        result.append(lineBreak)
        let separatorStr = String(repeating: "─", count: 40)
        result.append(NSAttributedString(string: separatorStr, attributes: [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: separatorColor,
        ]))
        result.append(lineBreak)
        result.append(lineBreak)

        // --- Content ---
        let rawContent: String
        if let data = model.contentData, let str = String(data: data, encoding: .utf8) {
            rawContent = str
        } else {
            rawContent = model.content ?? ""
        }

        // Try pretty-printing as JSON
        if let data = rawContent.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let prettyStr = String(data: pretty, encoding: .utf8) {
            result.append(NetworkDetailCell.highlightJSON(prettyStr))
        } else {
            // Try to detect key-value patterns and colorize
            let contentAttr = Self.formatPlainContent(rawContent, errorColor: model.color ?? .white)
            result.append(contentAttr)
        }

        // Paragraph style for the entire string
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineSpacing = 2
        result.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: result.length))

        return result
    }

    /// Format plain text content with some intelligence:
    /// - Color error/warning keywords
    /// - Highlight URLs
    /// - Detect key=value or key: value patterns
    private static func formatPlainContent(_ text: String, errorColor: UIColor) -> NSAttributedString {
        let base = NSMutableAttributedString(string: text, attributes: [
            .font: contentFont,
            .foregroundColor: UIColor(white: 0.85, alpha: 1),
        ])

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Highlight error/warning/fault keywords
        if let regex = try? NSRegularExpression(pattern: "\\b(error|Error|ERROR|fault|FAULT|exception|Exception|EXCEPTION|crash|CRASH|fatal|FATAL)\\b", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                base.addAttribute(.foregroundColor, value: UIColor.systemRed, range: match.range)
                base.addAttribute(.font, value: UIFont(name: "Menlo-Bold", size: 12) ?? UIFont.boldSystemFont(ofSize: 12), range: match.range)
            }
        }

        // Highlight warning keywords
        if let regex = try? NSRegularExpression(pattern: "\\b(warning|Warning|WARNING|warn|WARN)\\b", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                base.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: match.range)
            }
        }

        // Highlight URLs
        if let regex = try? NSRegularExpression(pattern: "https?://[^\\s]+", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                base.addAttribute(.foregroundColor, value: UIColor(red: 0.30, green: 0.54, blue: 0.97, alpha: 1), range: match.range)
                base.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }

        // Highlight numbers
        if let regex = try? NSRegularExpression(pattern: "(?<=\\s|:|=|\\[|\\()(-?\\d+\\.?\\d*)(?=\\s|,|;|\\]|\\)|$)", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                base.addAttribute(.foregroundColor, value: UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1), range: match.range(at: 1))
            }
        }

        // Highlight key=value or key: value patterns (the key part)
        if let regex = try? NSRegularExpression(pattern: "(?:^|\\s)([A-Za-z_][A-Za-z0-9_]*)\\s*[=:]", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                base.addAttribute(.foregroundColor, value: UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1), range: match.range(at: 1))
            }
        }

        // If the whole log is an error, tint the base text
        if errorColor == .systemRed {
            base.addAttribute(.foregroundColor, value: UIColor(red: 1.0, green: 0.7, blue: 0.7, alpha: 1), range: fullRange)
        }

        return base
    }

    @objc private func copyLogContent() {
        let text: String
        if let data = logModel?.contentData, let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            text = logModel?.content ?? ""
        }
        UIPasteboard.general.string = text

        // Flash checkmark feedback
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let checkIcon = UIImage(systemName: "checkmark", withConfiguration: config)
        navigationItem.rightBarButtonItem?.image = checkIcon
        navigationItem.rightBarButtonItem?.tintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let copyIcon = UIImage(systemName: "doc.on.doc", withConfiguration: config)
            self?.navigationItem.rightBarButtonItem?.image = copyIcon
            self?.navigationItem.rightBarButtonItem?.tintColor = DebugTheme.accentColor
        }
    }

    //MARK: - tool

    //detect format (JSON/Form)
    func detectSerializer() {
        guard let content = detailModel?.content else {
            detailModel?.requestSerializer = RequestSerializer.json//default JSON format
            return
        }
        
        if let _ = content.stringToDictionary() {
            //JSON format
            detailModel?.requestSerializer = RequestSerializer.json
        } else {
            //Form format
            detailModel?.requestSerializer = RequestSerializer.form
            
            if let jsonString = detailModel?.content?.formStringToJsonString() {
                textView.text = jsonString
                detailModel?.requestSerializer = RequestSerializer.json
                detailModel?.content = textView.text
            }
        }
    }
    
    
    //MARK: - init
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if let index = logModels?.firstIndex(where: { (model) -> Bool in
            return model.isSelected == true
        }) {
            logModels?[index].isSelected = false
        }
        
        logModel?.isSelected = true
        
        if let justCancelCallback = justCancelCallback {
            justCancelCallback()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Programmatic views
        view.backgroundColor = .black

        textView = CustomTextView(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = .boldSystemFont(ofSize: 12)
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        view.addSubview(textView)

        imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        naviItemTitleLabel = UILabel.init(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        naviItemTitleLabel?.textAlignment = .center
        naviItemTitleLabel?.textColor = DebugTheme.accentColor
        naviItemTitleLabel?.font = .boldSystemFont(ofSize: 20)
        naviItemTitleLabel?.text = detailModel?.title
        navigationItem.titleView = naviItemTitleLabel
        view.forceLTR()
        
        textView.textContainer.lineFragmentPadding = 15

        //detect type (default type URL)
        if detailModel?.title == "REQUEST HEADER" {
            editType = .requestHeader
        }
        if detailModel?.title == "RESPONSE HEADER" {
            editType = .responseHeader
        }
        
        //setup UI
        if editType == .requestHeader
        {
            imageView.isHidden = true
            textView.isHidden = false
            textView.text = String(detailModel?.requestHeaderFields?.dictionaryToString()?.dropFirst().dropLast().dropFirst().dropLast().dropFirst().dropFirst() ?? "").replacingOccurrences(of: "\",\n  \"", with: "\",\n\"")
        }
        else if editType == .responseHeader
        {
            imageView.isHidden = true
            textView.isHidden = false
            textView.text = String(detailModel?.responseHeaderFields?.dictionaryToString()?.dropFirst().dropLast().dropFirst().dropLast().dropFirst().dropFirst() ?? "").replacingOccurrences(of: "\",\n  \"", with: "\",\n\"")
        }
        else if editType == .log
        {
            imageView.isHidden = true
            textView.isHidden = false
            naviItemTitleLabel?.text = logTitleString

            // Copy button in nav bar
            let copyConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let copyIcon = UIImage(systemName: "doc.on.doc", withConfiguration: copyConfig)
            let copyBtn = UIBarButtonItem(image: copyIcon, style: .plain, target: self, action: #selector(copyLogContent))
            copyBtn.tintColor = DebugTheme.accentColor
            navigationItem.rightBarButtonItem = copyBtn

            if let model = logModel {
                textView.attributedText = Self.buildLogDetailAttributedString(model: model)
            }
        }
        else
        {
            if let content = detailModel?.content {
                imageView.isHidden = true
                textView.isHidden = false
                textView.text = content
                detectSerializer()//detect format (JSON/Form)
            }
            if let image = detailModel?.image {
                textView.isHidden = true
                imageView.isHidden = false
                imageView.image = image
            }
        }
    }
}
