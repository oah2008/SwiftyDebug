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

    /// The drag recogniser, kept so the long press can be told to recognise
    /// alongside it rather than cancelling it.
    private weak var panRecognizer: UIPanGestureRecognizer?

    /// Where the bubble starts, measured in the SDK WINDOW — never in
    /// `UIScreen.main.bounds`.
    ///
    /// On iPad Split View and Slide Over the app's window is a fraction of the
    /// screen, so a screen-derived y put the bubble below the window's bottom
    /// edge, off-screen and untappable, with no way to get it back.
    static var originalPosition: CGPoint {
        // The SDK window when it is usable, otherwise the host's key window.
        //
        // This is read from `SwiftyDebugViewController.viewDidLoad`, which runs
        // synchronously while `DebugWindowPresenter.enable()` is still assigning
        // `rootViewController` — the SDK window has no `windowScene` yet, so its
        // `safeAreaInsets` are zero and its bounds are still the screen's. Asking
        // it alone meant the notch offset could never apply and the Split View
        // sizing never took effect at the one call site there is.
        let sdkWindow = DebugWindowPresenter.shared.window
        let hostWindow = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        let reference: UIWindow? = sdkWindow.windowScene != nil ? sdkWindow : hostWindow

        let host = reference?.bounds ?? UIScreen.main.bounds
        let safeTop = reference?.safeAreaInsets.top ?? 0
        let notchOffset: CGFloat = safeTop > 24.0 ? 16 : 0
        return CGPoint(
            x: 1.875 + bubbleSize / 2,
            y: host.height / 2 - bubbleSize - notchOffset
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
        semanticContentAttribute = .forceLeftToRight
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

        // The press and the drag share one 25x25 view, so UIKit makes them
        // compete: a press wins after 0.5s and cancels the pan, and the bubble
        // refuses to move for anyone who holds it to aim before dragging. The
        // delegate below lets the drag carry on once the press has recognised.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        panRecognizer = pan
        addGestureRecognizer(pan)
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

    /// Remaps the docked position into the post-rotation size.
    ///
    /// Both axes read the pre-rotation size from the superview, which is still
    /// the old size while `viewWillTransition` is running. The horizontal one in
    /// particular must use the old WIDTH: `center.x` is a coordinate in the old
    /// width, and comparing it against half the old HEIGHT put every possible x
    /// on a portrait device below the threshold, so a right-docked bubble was
    /// thrown to the left edge by every portrait-to-landscape rotation. The
    /// fallback keeps the plain 90-degree swap for a bubble with no superview.
    func updateOrientation(newSize: CGSize) {
        let oldSize = superview?.bounds.size ?? CGSize(width: newSize.height, height: newSize.width)
        let yPercent = center.y / oldSize.height
        let newY = newSize.height * yPercent
        let newX = center.x < oldSize.width / 2
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

    /// Clearing every captured request is destructive and irreversible — each
    /// dropped transaction takes its two body files off disk with it — so it
    /// happens exactly once per press. A long press sends its action on `.began`,
    /// on every `.changed` and again on `.ended`, so an ungated body wiped the
    /// log two or more times for a single press.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
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

        // Measured in the view the bubble actually lives in — the SDK window's
        // root view, which `location` and `velocity` are already reported in —
        // and the insets of the window it is in, not some other scene's key
        // window.
        let containerBounds = superview?.bounds ?? UIScreen.main.bounds
        let safeArea = window?.safeAreaInsets ?? .zero
        let location = panner.location(in: superview)
        let velocity = panner.velocity(in: superview)

        let dock = Self.dockTarget(
            location: location,
            velocity: velocity,
            containerBounds: containerBounds,
            safeArea: safeArea
        )
        let finalCenter = dock.center

        UIView.animate(
            withDuration: dock.duration * 5,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 6,
            options: .allowUserInteraction
        ) { [weak self] in
            self?.center = finalCenter
            self?.transform = .identity
        }
    }

    /// Where a finished drag docks the bubble, in the coordinate space of the
    /// view it lives in, together with the duration the fling earned.
    ///
    /// `containerBounds` must be the SDK window's, never `UIScreen.main.bounds`:
    /// in iPad Split View or Slide Over the app owns a narrow column of a much
    /// wider display, so a snap target taken from the display lands hundreds of
    /// points outside the window. That is fatal rather than cosmetic —
    /// `SwiftyDebugViewController.shouldReceive(point:)` answers hit-testing
    /// with `bubble.frame.contains(point)`, so a bubble parked outside the
    /// window can never be tapped again and the debug UI is unreachable for the
    /// rest of the session.
    static func dockTarget(
        location: CGPoint,
        velocity: CGPoint,
        containerBounds: CGRect,
        safeArea: UIEdgeInsets
    ) -> (center: CGPoint, duration: CGFloat) {
        // Snap to nearest horizontal edge
        let finalX = location.x > containerBounds.width / 2
            ? containerBounds.width - edgeInset
            : edgeInset

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
        let minY = edgeInset + safeArea.top
        let maxY = containerBounds.height - safeArea.bottom - edgeInset
        finalY = min(max(finalY, minY), maxY)

        return (CGPoint(x: finalX, y: finalY), duration)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension Bubble: UIGestureRecognizerDelegate {

    /// Lets the drag keep running after the long press has recognised. Without
    /// it UIKit cancels the pan the moment the press wins, so pressing the
    /// bubble, aiming for half a second and then dragging moved nothing.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer === panRecognizer
    }
}
