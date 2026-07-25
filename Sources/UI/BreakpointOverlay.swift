//
//  BreakpointOverlay.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// A floating banner shown **over the host app** whenever requests are paused at
/// a breakpoint.
///
/// A paused request means the app is genuinely stuck waiting — usually showing a
/// spinner that will never finish. Without a visible signal that looks like an
/// app bug, so this banner sits above everything, says how many are held, and
/// takes one tap to open the editor and release them. (See BREAKPOINTS.)
final class BreakpointOverlay {

    static let shared = BreakpointOverlay()
    private init() {}

    private var window: PassthroughWindow?
    private var banner: BannerView?
    private var observer: NSObjectProtocol?

    /// Starts listening. Safe to call more than once.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .breakpointsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hide()
    }

    // MARK: - Presentation

    /// Re-evaluates whether the banner should be on screen. Call when the debug
    /// UI is presented/dismissed (the banner hides while the tool is open).
    func refreshVisibility() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let count = BreakpointCenter.shared.count
        // Never show the banner on top of the debug UI itself — you're already
        // looking at the tool, and the inbox is right there.
        if count > 0 && !Settings.shared.debugUIVisible {
            show(count: count)
        } else {
            hide()
        }
    }

    private func show(count: Int) {
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }

            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .alert - 2
            w.backgroundColor = .clear
            w.isHidden = false
            // The SDK is always LTR, even in an RTL host app.
            w.semanticContentAttribute = .forceLeftToRight

            let host = UIViewController()
            host.view.backgroundColor = .clear
            w.rootViewController = host

            let b = BannerView()
            b.onTap = { [weak self] in self?.openInbox() }
            b.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(b)
            NSLayoutConstraint.activate([
                b.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 12),
                b.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -12),
                b.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            ])
            w.passthroughExcept = b
            window = w
            banner = b

            b.alpha = 0
            b.transform = CGAffineTransform(translationX: 0, y: -20)
            UIView.animate(withDuration: 0.25) {
                b.alpha = 1
                b.transform = .identity
            }
        }
        banner?.update(count: count)
    }

    private func hide() {
        guard let w = window, let b = banner else { return }
        UIView.animate(withDuration: 0.2, animations: {
            b.alpha = 0
            b.transform = CGAffineTransform(translationX: 0, y: -20)
        }, completion: { _ in
            w.isHidden = true
            w.rootViewController = nil
        })
        window = nil
        banner = nil
    }

    /// Opens the debug UI straight on the paused-requests inbox.
    private func openInbox() {
        let presenter = DebugWindowPresenter.shared
        // If the debug UI isn't up yet, bring it up first.
        if !Settings.shared.debugUIVisible {
            presenter.displayedList = true
            let tabs = SwiftyDebugTabBarController()
            tabs.modalPresentationStyle = .fullScreen
            tabs.pendingInitialScreen = .breakpointInbox
            presenter.vc.present(tabs, animated: true)
        } else if let tabs = presenter.vc.presentedViewController as? SwiftyDebugTabBarController {
            tabs.showBreakpointInbox()
        }
        hide()
    }
}

// MARK: - Window that only catches touches on the banner

/// A window that lets every touch through to the host app except those landing
/// on `passthroughExcept` — so the banner never blocks the app underneath.
private final class PassthroughWindow: UIWindow {
    weak var passthroughExcept: UIView?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let target = passthroughExcept else { return false }
        let converted = convert(point, to: target)
        return target.bounds.contains(converted)
    }
}

// MARK: - Banner

private final class BannerView: UIView {

    var onTap: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView()
    private var pulse: CABasicAnimation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.16, green: 0.12, blue: 0.03, alpha: 0.97)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.systemOrange.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        iconView.image = UIImage(systemName: "pause.circle.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = UIColor(white: 0.75, alpha: 1)
        subtitleLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        semanticContentAttribute = .forceLeftToRight
        startPulsing()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int) {
        titleLabel.text = count == 1 ? "1 request paused" : "\(count) requests paused"
        subtitleLabel.text = "The app is waiting. Tap to edit and release."
    }

    /// A slow border pulse so it reads as "something is waiting on you".
    private func startPulsing() {
        let anim = CABasicAnimation(keyPath: "borderColor")
        anim.fromValue = UIColor.systemOrange.cgColor
        anim.toValue = UIColor.systemOrange.withAlphaComponent(0.35).cgColor
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "pulse")
    }

    @objc private func tapped() {
        UIView.animate(withDuration: 0.08, animations: {
            self.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            UIView.animate(withDuration: 0.08) { self.transform = .identity }
            self.onTap?()
        })
    }
}
