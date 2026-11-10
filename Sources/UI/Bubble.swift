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

    // MARK: - Dock model

    /// The edge the bubble is docked to.
    ///
    /// Physical left/right, not leading/trailing: the SDK's window is forced
    /// left-to-right, and the vertical bar the dock has to clear is reported
    /// through the safe area, which is physical too.
    enum DockSide: Equatable {
        case left, right
    }

    /// Where the bubble is: an edge, and how far down it sits as a fraction of
    /// its container's height. This — not `center` — is the bubble's position.
    ///
    /// A center is a coordinate in one particular container size, and on iPhone
    /// Duo that size changes under the bubble every time the device folds,
    /// unfolds or rotates (466 x 678 outer, 951 x 669 inner). A center kept
    /// across that change is how a bubble docked to the outer display's right
    /// edge ended up in the middle of the unfolded screen. The model is
    /// re-applied to whatever size the container has now: see `redock(in:…)`.
    private(set) var dockSide: DockSide = .left
    private(set) var dockFraction: CGFloat = Bubble.initialDockFraction

    /// Just above the middle of the left edge, where the bubble has always first
    /// appeared.
    static let initialDockFraction: CGFloat = 0.45

    /// Set for the length of a drag, so a layout pass cannot yank the bubble
    /// back to its old dock from under the user's finger.
    private(set) var isBeingDragged = false

    /// Where the dock model last put the bubble. `center` differing from it
    /// means something other than the model moved the bubble, which is the only
    /// time the dock may be re-read from `center` (see `updateOrientation`).
    private var lastDockedCenter: CGPoint?

    static var size: CGSize {
        CGSize(width: bubbleSize, height: bubbleSize)
    }

    /// The distance from a docking edge to the bubble's center.
    static var dockInset: CGFloat { edgeInset }

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
    ///
    /// The safe area used here is the pre-rotation one — the new one does not
    /// exist yet. The layout pass the rotation triggers re-docks with the real
    /// one (`SwiftyDebugViewController.viewDidLayoutSubviews`), which matters on
    /// iPhone Duo, where rotating moves the vertical bar to the other edge.
    func updateOrientation(newSize: CGSize) {
        let oldSize = superview?.bounds.size ?? CGSize(width: newSize.height, height: newSize.width)
        let oldBounds = CGRect(origin: .zero, size: oldSize)
        // The dock model is the position. Re-read it from `center` only when
        // something other than the model put the bubble where it is. Comparing
        // against where the model would put it NOW is not the same test: the
        // safe-area clamp and the fold detour depend on inputs that differ between
        // the last layout and this call, so a clamped or fold-pushed spot would be
        // taken for a move and become the dock — creeping on every rotation, and
        // never returning once the device opens flat. And only from a bubble that
        // is on screen: one parked off-screen before its first layout keeps its
        // dock instead of turning the parking spot into "top-left".
        let movedByOtherThanTheModel = lastDockedCenter.map { hypot(center.x - $0.x, center.y - $0.y) > 1 } ?? true
        if oldBounds.contains(center), movedByOtherThanTheModel {
            captureDock(fromCenterIn: oldBounds)
        }
        let newCenter = Self.dockedCenter(
            side: dockSide,
            fraction: dockFraction,
            containerBounds: CGRect(origin: .zero, size: newSize),
            safeArea: superview?.safeAreaInsets ?? .zero
        )
        center = newCenter
        lastDockedCenter = newCenter
    }

    // MARK: - Docking

    /// Re-applies the dock model to the container's current size and safe area.
    ///
    /// Called on every layout of the bubble's container, so the bubble stays on
    /// its edge through anything that resizes the container — folding,
    /// unfolding, rotation, Split View — and clear of anything that moves the
    /// safe area, such as iPhone Duo's vertical status bar changing sides.
    ///
    /// A no-op mid-drag (the finger owns the bubble then) and for an empty
    /// container (nothing has been laid out yet, so there is no edge to dock to).
    func redock(in containerBounds: CGRect, safeArea: UIEdgeInsets, avoiding reservedRects: [CGRect] = []) {
        guard !isBeingDragged, containerBounds.width > 0, containerBounds.height > 0 else { return }
        let target = Self.dockedCenter(side: dockSide,
                                       fraction: dockFraction,
                                       containerBounds: containerBounds,
                                       safeArea: safeArea,
                                       avoiding: reservedRects)
        lastDockedCenter = target
        if abs(center.x - target.x) > 0.01 || abs(center.y - target.y) > 0.01 {
            center = target
        }
    }

    /// Records which edge the bubble is on and how far down, from its current
    /// center in a container of `containerBounds`.
    private func captureDock(fromCenterIn containerBounds: CGRect) {
        guard containerBounds.width > 0, containerBounds.height > 0 else { return }
        dockSide = center.x < containerBounds.midX ? .left : .right
        dockFraction = min(max((center.y - containerBounds.minY) / containerBounds.height, 0), 1)
    }

    /// The center of a bubble docked on `side` at `fraction` of the container's
    /// height.
    ///
    /// Every edge is measured inside the safe area: on iPhone Duo the status bar,
    /// the Dynamic Island and the app's navigation controls run down the side of
    /// the screen as one vertical bar, reported as an 84 pt left or right inset
    /// depending on how the device is held. Docking to the raw edge put the
    /// bubble underneath it.
    ///
    /// `reservedRects` are areas in the container's coordinates the bubble must
    /// not sit on — the fold of a partially folded iPhone Duo, where a control is
    /// hard to see and harder to tap. When the docked spot overlaps one, the
    /// bubble moves to the nearest spot beside it that is still inside the safe
    /// area, staying on the same edge where it can.
    static func dockedCenter(side: DockSide,
                             fraction: CGFloat,
                             containerBounds: CGRect,
                             safeArea: UIEdgeInsets,
                             avoiding reservedRects: [CGRect] = []) -> CGPoint {
        let usable = safeRect(in: containerBounds, safeArea: safeArea)
        let x = side == .left ? usable.minX : usable.maxX
        let y = containerBounds.minY + containerBounds.height * min(max(fraction, 0), 1)
        let docked = CGPoint(x: x, y: min(max(y, usable.minY), usable.maxY))
        return avoid(reservedRects, from: docked, within: usable)
    }

    /// The rectangle a bubble's CENTER may occupy: the container inset by the
    /// safe area and by `edgeInset` on every side. Collapses to the midline on an
    /// axis too small to hold the bubble, rather than inverting.
    static func safeRect(in containerBounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        var minX = containerBounds.minX + safeArea.left + edgeInset
        var maxX = containerBounds.maxX - safeArea.right - edgeInset
        var minY = containerBounds.minY + safeArea.top + edgeInset
        var maxY = containerBounds.maxY - safeArea.bottom - edgeInset
        if maxX < minX { minX = containerBounds.midX; maxX = minX }
        if maxY < minY { minY = containerBounds.midY; maxY = minY }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves `center` off every rectangle in `reservedRects`, to the nearest
    /// candidate beside one that is inside `usable`. Unchanged when it overlaps
    /// none, or when no candidate fits.
    static func avoid(_ reservedRects: [CGRect], from center: CGPoint, within usable: CGRect) -> CGPoint {
        let half = bubbleSize / 2
        let gap: CGFloat = 4
        var point = center
        for rect in reservedRects where !rect.isNull && !rect.isEmpty {
            let bubbleRect = CGRect(x: point.x - half, y: point.y - half, width: bubbleSize, height: bubbleSize)
            guard bubbleRect.intersects(rect) else { continue }
            let candidates = [
                CGPoint(x: point.x, y: rect.minY - half - gap),
                CGPoint(x: point.x, y: rect.maxY + half + gap),
                CGPoint(x: rect.minX - half - gap, y: point.y),
                CGPoint(x: rect.maxX + half + gap, y: point.y),
            ].filter { usable.insetBy(dx: -0.5, dy: -0.5).contains($0) }
            if let nearest = candidates.min(by: {
                hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
            }) {
                point = nearest
            }
        }
        return point
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
            isBeingDragged = true
            UIView.animate(withDuration: 0.5, delay: 0, options: .curveLinear) { [weak self] in
                self?.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
        }

        let offset = panner.translation(in: superview)
        panner.setTranslation(.zero, in: superview)
        center = CGPoint(x: center.x + offset.x, y: center.y + offset.y)

        guard panner.state == .ended || panner.state == .cancelled || panner.state == .failed else { return }
        isBeingDragged = false

        // Measured in the view the bubble actually lives in — the SDK window's
        // root view, which `location` and `velocity` are already reported in —
        // and that view's own safe area, which is the window's, iPhone Duo's
        // vertical bar included.
        guard let container = superview, container.bounds.width > 0, container.bounds.height > 0 else { return }
        let containerBounds = container.bounds
        let safeArea = container.safeAreaInsets
        let location = panner.location(in: container)
        let velocity = panner.velocity(in: container)

        let dock = Self.dockTarget(
            location: location,
            velocity: velocity,
            containerBounds: containerBounds,
            safeArea: safeArea
        )
        let finalCenter = Self.avoid(Self.reservedRects(in: container),
                                     from: dock.center,
                                     within: Self.safeRect(in: containerBounds, safeArea: safeArea))

        // The dock is the bubble's position from here on, in every size the
        // container will ever have.
        dockSide = finalCenter.x < containerBounds.midX ? .left : .right
        dockFraction = min(max((finalCenter.y - containerBounds.minY) / containerBounds.height, 0), 1)
        lastDockedCenter = finalCenter

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
        // Snap to the nearer horizontal edge of the SAFE area. On iPhone Duo the
        // vertical bar takes 84 pt of one side; the raw edge is underneath it,
        // and the midpoint that decides the side is the middle of what is left.
        let usable = safeRect(in: containerBounds, safeArea: safeArea)
        let finalX = location.x > usable.midX ? usable.maxX : usable.minX

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
        finalY = min(max(finalY, usable.minY), usable.maxY)

        return (CGPoint(x: finalX, y: finalY), duration)
    }

    /// The parts of `container` the bubble must not dock on, in its coordinates.
    ///
    /// iPhone Duo reports two kinds (iOS 27.1). The fold of a partially folded
    /// device is a *division* region: anything on it is hard to read and harder
    /// to tap. The under-display camera while it streams, and the Dynamic Island,
    /// are *occlusion* regions. Both are returned already widened by the
    /// clearance the system wants around interactive content, so avoiding the
    /// frame is enough. Empty everywhere else.
    static func reservedRects(in container: UIView) -> [CGRect] {
        if #available(iOS 27.1, *) {
            let regions = container.reservedRegions(kind: .division)
                + container.reservedRegions(kind: .occlusion)
            return regions.filter(\.isActive).map(\.frame)
        }
        return []
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
