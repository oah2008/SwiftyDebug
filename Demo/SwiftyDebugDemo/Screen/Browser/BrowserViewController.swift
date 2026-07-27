//
//  BrowserViewController.swift
//  SwiftyDebugDemo
//
//  A minimal in-app browser to exercise SwiftyDebug's WKWebView features:
//  console capture, network (XHR/fetch) capture, header interception, and the
//  Web View Storage editor (localStorage / sessionStorage / cookies).
//
//  Type any URL and Go. Then shake to open SwiftyDebug and inspect the Web tab,
//  intercept rules, or App tab -> Web View Storage.
//

import UIKit
import WebKit

final class BrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {

    private var webView: WKWebView!
    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let reloadButton = UIButton(type: .system)

    // Handy storage-heavy sites for testing the storage editor.
    private let quickSites = ["example.com", "github.com", "wikipedia.org", "developer.mozilla.org"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Browser"

        setupWebView()
        setupToolbar()
        setupQuickBar()
        layout()

        loadURLString("https://example.com")
    }

    // MARK: - Setup

    private func setupWebView() {
        // A normal WKWebView — SwiftyDebug swizzles WKWebView.init, so this is
        // automatically instrumented (console + network capture, intercept rules,
        // and it shows up in the Web View Storage picker).
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        view.addSubview(webView)
    }

    private func setupToolbar() {
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Enter a URL…"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.delegate = self
        urlField.font = .systemFont(ofSize: 15)
        view.addSubview(urlField)

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        view.addSubview(reloadButton)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        progressView.trackTintColor = .clear
        view.addSubview(progressView)
    }

    private let quickBar = UIScrollView()
    private func setupQuickBar() {
        quickBar.translatesAutoresizingMaskIntoConstraints = false
        quickBar.showsHorizontalScrollIndicator = false
        view.addSubview(quickBar)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        quickBar.addSubview(stack)

        for site in quickSites {
            let b = UIButton(type: .system)
            b.setTitle(site, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            b.addAction(UIAction { [weak self] _ in self?.loadURLString("https://\(site)") }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: quickBar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: quickBar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: quickBar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: quickBar.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: quickBar.heightAnchor, constant: -8),
        ])
    }

    private func layout() {
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            urlField.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            urlField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            reloadButton.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: 8),
            reloadButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            reloadButton.widthAnchor.constraint(equalToConstant: 28),

            quickBar.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 6),
            quickBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            quickBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            quickBar.heightAnchor.constraint(equalToConstant: 40),

            progressView.topAnchor.constraint(equalTo: quickBar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Loading

    private func loadURLString(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s) else { return }
        urlField.text = s
        webView.load(URLRequest(url: url))
        view.endEditing(true)
    }

    @objc private func reloadTapped() { webView.reload() }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        loadURLString(textField.text ?? "")
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString { urlField.text = url }
        navigationItem.title = webView.title
    }

    // MARK: - Progress

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                              change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(WKWebView.estimatedProgress) else { return }
        let p = Float(webView.estimatedProgress)
        progressView.setProgress(p, animated: true)
        progressView.alpha = (p >= 1.0) ? 0 : 1
        if p >= 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.progressView.setProgress(0, animated: false)
            }
        }
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
}
