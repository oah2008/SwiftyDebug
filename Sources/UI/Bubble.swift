//
//  Bubble.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

protocol BubbleDelegate: AnyObject {
    func didTapBubble()
}

class Bubble: UIView {

    // MARK: - Constants

    private static let bubbleSize: CGFloat = 25
    private static let edgeInset: CGFloat = bubbleSize / 8 * 4.25

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

    weak var delegate: BubbleDelegate?

    private let counterLabel = UILabel()
    private var requestCount = 0

    static var originalPosition: CGPoint {
        let safeTop = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 0
        let notchOffset: CGFloat = safeTop > 24.0 ? 16 : 0
        return CGPoint(
            x: 1.875 + bubbleSize / 2,
            y: UIScreen.main.bounds.height / 2 - bubbleSize - notchOffset
        )
    }

    static var size: CGSize {
        CGSize(width: bubbleSize, height: bubbleSize)
    }

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
    }

    // MARK: - Setup

    private func setupAppearance() {
        backgroundColor = .black
        layer.cornerRadius = Self.bubbleSize / 2

        counterLabel.text = "0"
        counterLabel.textColor = .white
        counterLabel.textAlignment = .center
        counterLabel.adjustsFontSizeToFitWidth = true
        counterLabel.isHidden = true
        counterLabel.frame = CGRect(x: 0, y: 0, width: Self.bubbleSize, height: Self.bubbleSize)
        addSubview(counterLabel)
    }

    private func setupGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
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
            self?.refreshBubbleState()
        }
    }

    // MARK: - Orientation

    func updateOrientation(newSize: CGSize) {
        let oldHeight = newSize.width // pre-rotation height
        let yPercent = center.y / oldHeight
        let newY = newSize.height * yPercent
        let newX = frame.origin.x < oldHeight / 2
            ? Self.edgeInset
            : newSize.width - Self.edgeInset
        center = CGPoint(x: newX, y: newY)
    }

    // MARK: - Status Animation

    private func showStatusAnimation(_ content: String, insideBubble: Bool) {
        let isEmoji = (content == "🚀" || content == "❌")
        let labelSize: CGFloat = isEmoji ? 20 : 35

        let label = UILabel()
        label.text = content
        label.font = .boldSystemFont(ofSize: 14)

        if !isEmoji {
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.textColor = statusColor(for: content)
        }

        if insideBubble {
            label.frame = CGRect(
                x: frame.width / 2 - labelSize / 2,
                y: frame.height / 2 - labelSize / 2,
                width: labelSize, height: labelSize
            )
            addSubview(label)
        } else {
            label.frame = CGRect(
                x: center.x - labelSize / 2,
                y: center.y - labelSize / 2,
                width: labelSize, height: labelSize
            )
            superview?.addSubview(label)
        }

        UIView.animate(withDuration: 0.8, animations: {
            label.frame.origin.y = insideBubble ? -100 : (self.center.y - 100)
            label.alpha = 0
        }, completion: { _ in
            label.removeFromSuperview()
        })
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

    // MARK: - Counter

    private func updateCounter(_ count: Int) {
        requestCount = count
        counterLabel.text = String(requestCount)
        counterLabel.isHidden = (requestCount == 0)

        let fontSize: CGFloat
        switch requestCount {
        case ..<100:    fontSize = 11
        case ..<1000:   fontSize = 9
        case ..<10000:  fontSize = 7.5
        default:        fontSize = 7
        }
        counterLabel.font = .boldSystemFont(ofSize: fontSize)
    }

    // MARK: - Notification Handlers

    private func handleNetworkRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let statusCode = userInfo["statusCode"] as? String else { return }

        if Self.successCodes.contains(statusCode) {
            showStatusAnimation("🚀", insideBubble: true)
        } else if statusCode == "0" {
            showStatusAnimation("❌", insideBubble: true)
        } else {
            showStatusAnimation(statusCode, insideBubble: true)
        }

        updateCounter(requestCount + 1)
    }

    private func handleLogsCleared(_ notification: Notification) {
        let pinnedCount = (notification.userInfo?["pinnedCount"] as? Int) ?? 0
        updateCounter(pinnedCount)
    }

    /// Toggles visibility twice to force-refresh the bubble presenter.
    private func refreshBubbleState() {
        Settings.shared.bubbleVisible = !Settings.shared.bubbleVisible
        Settings.shared.bubbleVisible = !Settings.shared.bubbleVisible
    }

    // MARK: - Gesture Actions

    @objc private func handleTap() {
        delegate?.didTapBubble()
    }

    @objc private func handleLongPress() {
        NetworkRequestStore.shared.reset()
        let pinnedCount = NetworkRequestStore.shared.httpModels.count
        NotificationCenter.default.post(name: .allLogsCleared, object: nil, userInfo: ["pinnedCount": pinnedCount])
    }

    @objc private func handlePan(_ panner: UIPanGestureRecognizer) {
        if panner.state == .began {
            UIView.animate(withDuration: 0.5, delay: 0, options: .curveLinear) { [weak self] in
                self?.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
        }

        let offset = panner.translation(in: superview)
        panner.setTranslation(.zero, in: superview)
        center = CGPoint(x: center.x + offset.x, y: center.y + offset.y)

        guard panner.state == .ended || panner.state == .cancelled else { return }

        let safeArea = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets ?? .zero

        let screenBounds = UIScreen.main.bounds
        let location = panner.location(in: superview)
        let velocity = panner.velocity(in: superview)

        // Snap to nearest horizontal edge
        var finalX = location.x > screenBounds.width / 2
            ? screenBounds.width - Self.edgeInset
            : Self.edgeInset

        var finalY = location.y

        let horizontalVelocity = abs(velocity.x)
        let distanceX = abs(finalX - location.x)
        let velocityForce = sqrt(pow(velocity.x, 2) * pow(velocity.y, 2))

        let duration = velocityForce > 1000
            ? min(0.3, distanceX / horizontalVelocity)
            : 0.3

        if velocityForce > 1000 {
            finalY += velocity.y * duration
        }

        // Clamp to safe area
        let minY = Self.edgeInset + safeArea.top
        let maxY = screenBounds.height - safeArea.bottom - Self.edgeInset
        finalY = min(max(finalY, minY), maxY)

        UIView.animate(
            withDuration: duration * 5,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 6,
            options: .allowUserInteraction
        ) { [weak self] in
            self?.center = CGPoint(x: finalX, y: finalY)
            self?.transform = .identity
        }
    }
}
