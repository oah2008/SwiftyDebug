//
//  DynamicIslandBubble.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 09/03/2026.
//

import UIKit

protocol DynamicIslandBubbleDelegate: AnyObject {
    func didTapDynamicIsland()
}

class DynamicIslandBubble: UIView {

    // MARK: - Constants

    /// Compact pill dimensions (just counter)
    private static let compactWidth: CGFloat = 120
    private static let compactHeight: CGFloat = 37
    /// Expanded pill dimensions (counter + status indicator)
    private static let expandedWidth: CGFloat = 210
    private static let expandedHeight: CGFloat = 37

    private static let pillCornerRadius: CGFloat = 18.5

    /// The Y offset from the top of the screen (aligns visually with the Dynamic Island)
    private static let topOffset: CGFloat = 11

    private static let successCodes: Set<String> = [
        "200", "201", "202", "203", "204", "205", "206", "207", "208", "226"
    ]
    private static let informationalCodes: Set<String> = [
        "100", "101", "102", "103", "122"
    ]
    private static let redirectionCodes: Set<String> = [
        "300", "301", "302", "303", "304", "305", "306", "307", "308"
    ]

    // MARK: - Properties

    weak var delegate: DynamicIslandBubbleDelegate?

    private let counterLabel = UILabel()
    private let statusLabel = UILabel()
    private var requestCount = 0

    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    private var collapseWorkItem: DispatchWorkItem?

    /// Whether the Dynamic Island-style pill is currently in expanded state
    private var isExpanded = false

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupAppearance()
        setupGestures()
        setupObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        collapseWorkItem?.cancel()
    }

    // MARK: - Setup

    private func setupAppearance() {
        backgroundColor = .black
        layer.cornerRadius = Self.pillCornerRadius
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        // Counter label (left side of pill)
        counterLabel.text = "0"
        counterLabel.textColor = .white
        counterLabel.font = .systemFont(ofSize: 16, weight: .bold)
        counterLabel.textAlignment = .center
        counterLabel.isHidden = true
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counterLabel)

        // Status label (right side, shown on expand)
        statusLabel.text = ""
        statusLabel.font = .systemFont(ofSize: 18)
        statusLabel.textAlignment = .center
        statusLabel.alpha = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Size constraints
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.compactWidth)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.compactHeight)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,

            // Counter on the left-center
            counterLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            counterLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            counterLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            // Status on the right
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    /// Call after adding to superview to pin to top center
    func pinToTop(of parent: UIView) {
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: Self.topOffset),
        ])
    }

    private func setupGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress)))
    }

    private func setupObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .networkRequestCompleted, object: nil, queue: .main) { [weak self] notification in
            self?.handleNetworkRequest(notification)
        }
        nc.addObserver(forName: .allLogsCleared, object: nil, queue: .main) { [weak self] notification in
            self?.handleLogsCleared(notification)
        }
        nc.addObserver(forName: .forceShowDebugger, object: nil, queue: .main) { [weak self] _ in
            self?.refreshState()
        }
    }

    // MARK: - Expand / Collapse Animation

    private func expandWithStatus(_ content: String, color: UIColor) {
        collapseWorkItem?.cancel()

        statusLabel.text = content
        statusLabel.textColor = color

        isExpanded = true

        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.8, options: .curveEaseOut) {
            self.widthConstraint.constant = Self.expandedWidth
            self.statusLabel.alpha = 1
            self.superview?.layoutIfNeeded()
        }

        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func collapse() {
        isExpanded = false

        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5, options: .curveEaseInOut) {
            self.widthConstraint.constant = Self.compactWidth
            self.statusLabel.alpha = 0
            self.superview?.layoutIfNeeded()
        }
    }

    // MARK: - Counter

    private func updateCounter(_ count: Int) {
        requestCount = count
        counterLabel.text = String(requestCount)
        counterLabel.isHidden = (requestCount == 0)

        let fontSize: CGFloat
        switch requestCount {
        case ..<100:    fontSize = 16
        case ..<1000:   fontSize = 14
        case ..<10000:  fontSize = 12
        default:        fontSize = 10
        }
        counterLabel.font = .systemFont(ofSize: fontSize, weight: .bold)
    }

    // MARK: - Notification Handlers

    private func handleNetworkRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let statusCode = userInfo["statusCode"] as? String else { return }

        if Self.successCodes.contains(statusCode) {
            expandWithStatus("🚀", color: .white)
        } else if statusCode == "0" {
            expandWithStatus("❌", color: .white)
        } else {
            expandWithStatus(statusCode, color: statusColor(for: statusCode))
        }

        updateCounter(requestCount + 1)
    }

    private func handleLogsCleared(_ notification: Notification) {
        let pinnedCount = (notification.userInfo?["pinnedCount"] as? Int) ?? 0
        updateCounter(pinnedCount)
    }

    private func refreshState() {
        Settings.shared.bubbleVisible = !Settings.shared.bubbleVisible
        Settings.shared.bubbleVisible = !Settings.shared.bubbleVisible
    }

    private func statusColor(for code: String) -> UIColor {
        if Self.informationalCodes.contains(code) {
            return "#4b8af7".hexColor
        } else if Self.redirectionCodes.contains(code) {
            return "#ff9800".hexColor
        } else {
            return .red
        }
    }

    // MARK: - Gesture Actions

    @objc private func handleTap() {
        delegate?.didTapDynamicIsland()
    }

    @objc private func handleLongPress() {
        NetworkRequestStore.shared.reset()
        let pinnedCount = NetworkRequestStore.shared.httpModels.count
        NotificationCenter.default.post(name: .allLogsCleared, object: nil, userInfo: ["pinnedCount": pinnedCount])
    }
}
