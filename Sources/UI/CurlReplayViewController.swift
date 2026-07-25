//
//  CurlReplayViewController.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// Sends an imported cURL command and shows the response inline.
///
/// The request goes out through a normal `URLSession`, so SwiftyDebug's own
/// URLProtocol captures it and it also lands in the Network list like any other
/// request.
final class CurlReplayViewController: UIViewController {

    // MARK: - Input

    private let request: ParsedCurlRequest

    // MARK: - Views

    private let textView = UITextView()
    private lazy var sendItem = UIBarButtonItem(title: "Send", style: .done, target: self, action: #selector(sendTapped))

    // MARK: - Networking

    /// Retained for the lifetime of the screen: the flags in the command
    /// (`-k`, absence of `-L`) are transport policy, and only a delegate can apply them.
    private lazy var session: URLSession = {
        let delegate = CurlReplayTransportDelegate(
            followsRedirects: request.followsRedirects,
            allowsInsecureTLS: request.allowsInsecureTLS
        )
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()

    private var isSending = false

    // MARK: - Init

    init(request: ParsedCurlRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Replay"
        view.backgroundColor = .black

        sendItem.tintColor = DebugTheme.accentColor
        navigationItem.rightBarButtonItem = sendItem

        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
            )
            navigationItem.leftBarButtonItem?.tintColor = UIColor(white: 0.7, alpha: 1)
        }

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.backgroundColor = .black
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.alwaysBounceVertical = true
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        textView.attributedText = requestSummary()
        view.forceLTR()

        // The user tapped "Replay" — firing on arrival is the expected behaviour.
        send()
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        send()
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        showSpinner(true)

        let urlRequest = request.makeURLRequest()
        let started = Date()

        session.dataTask(with: urlRequest) { [weak self] data, response, error in
            let finished = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSending = false
                self.showSpinner(false)
                self.render(data: data, response: response, error: error,
                            duration: finished.timeIntervalSince(started))
            }
        }.resume()
    }

    private func showSpinner(_ sending: Bool) {
        if sending {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = DebugTheme.accentColor
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = sendItem
        }
    }

    // MARK: - Rendering

    private static let labelFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    private static let monoFont = UIFont(name: "Menlo", size: 12) ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func requestSummary() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(text(request.method + " ", font: Self.monoFont,
                           color: CurlImportViewController.color(forMethod: request.method)))
        result.append(text(request.url.absoluteString + "\n\n", font: Self.monoFont, color: UIColor(white: 0.9, alpha: 1)))

        for header in request.headers {
            result.append(text(header.name + "  ", font: Self.labelFont, color: UIColor(white: 0.45, alpha: 1)))
            result.append(text(header.value + "\n", font: Self.labelFont, color: UIColor(white: 0.78, alpha: 1)))
        }

        if let body = request.bodyString, !body.isEmpty {
            result.append(separator())
            result.append(text(prettyPrinted(body) + "\n", font: Self.monoFont, color: UIColor(white: 0.8, alpha: 1)))
        }

        result.append(separator())
        return result
    }

    private func render(data: Data?, response: URLResponse?, error: Error?, duration: TimeInterval) {
        let result = NSMutableAttributedString(attributedString: requestSummary())

        if let error = error as NSError? {
            result.append(text("FAILED  ", font: Self.monoFont, color: .systemRed))
            result.append(text(String(format: "%.2f s\n\n", duration), font: Self.labelFont, color: UIColor(white: 0.6, alpha: 1)))
            result.append(text(error.localizedDescription + "\n", font: Self.monoFont, color: .systemRed))
            textView.attributedText = result
            return
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let statusColor: UIColor = status < 300 ? .systemGreen : status < 400 ? .systemOrange : .systemRed

        result.append(text("\(status) ", font: Self.monoFont, color: statusColor))
        var meta = [String(format: "%.2f s", duration)]
        meta.append(ByteCountFormatter().string(fromByteCount: Int64(data?.count ?? 0)))
        if let mime = response?.mimeType { meta.append(mime) }
        result.append(text(meta.joined(separator: "  ·  ") + "\n\n", font: Self.labelFont, color: UIColor(white: 0.6, alpha: 1)))

        if let fields = http?.allHeaderFields as? [String: Any] {
            for key in fields.keys.sorted() {
                result.append(text(key + "  ", font: Self.labelFont, color: UIColor(white: 0.45, alpha: 1)))
                result.append(text("\(fields[key] ?? "")\n", font: Self.labelFont, color: UIColor(white: 0.78, alpha: 1)))
            }
        }

        result.append(separator())

        if let data, !data.isEmpty {
            if let body = String(data: data, encoding: .utf8) {
                result.append(text(prettyPrinted(body) + "\n", font: Self.monoFont, color: UIColor(white: 0.85, alpha: 1)))
            } else {
                let size = ByteCountFormatter().string(fromByteCount: Int64(data.count))
                result.append(text("Binary response (\(size))\n", font: Self.labelFont, color: UIColor(white: 0.6, alpha: 1)))
            }
        } else {
            result.append(text("Empty response body\n", font: Self.labelFont, color: UIColor(white: 0.6, alpha: 1)))
        }

        textView.attributedText = result
        textView.setContentOffset(.zero, animated: false)
    }

    private func text(_ string: String, font: UIFont, color: UIColor) -> NSAttributedString {
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private func separator() -> NSAttributedString {
        let line = String(repeating: "─", count: 40) + "\n\n"
        return text(line, font: .systemFont(ofSize: 8), color: UIColor(white: 0.22, alpha: 1))
    }

    private func prettyPrinted(_ string: String) -> String {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let result = String(data: pretty, encoding: .utf8) else {
            return string
        }
        return result
    }
}

// MARK: - Transport policy

/// Applies the two transport flags a cURL command can carry: `-k` (accept any
/// server trust) and the absence of `-L` (do not follow redirects, which is the
/// opposite of `URLSession`'s default).
private final class CurlReplayTransportDelegate: NSObject, URLSessionTaskDelegate {

    private let followsRedirects: Bool
    private let allowsInsecureTLS: Bool

    init(followsRedirects: Bool, allowsInsecureTLS: Bool) {
        self.followsRedirects = followsRedirects
        self.allowsInsecureTLS = allowsInsecureTLS
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followsRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard allowsInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
