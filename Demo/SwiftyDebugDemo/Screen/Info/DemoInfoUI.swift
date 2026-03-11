//
//  DemoInfoUI.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

enum DemoInfoUIActions {
    case fireTestRequests
}

protocol DemoInfoUIDelegate:AnyObject {
    func doActions(_ actions: DemoInfoUIActions)
}

class DemoInfoUI: BaseUI {

    weak var delegate:DemoInfoUIDelegate?

    private let scrollView:UIScrollView = {
        let sv = UIScrollView()
        sv.showsVerticalScrollIndicator = false
        return sv
    }()

    private let contentStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }()

    private let bannerView = InfoBannerView()

    private let featuresCard = InfoCardView(title: "Features Enabled in This Demo", items: [
        (icon: "globe",                            text: "Network monitoring (all requests)"),
        (icon: "photo.on.rectangle",               text: "Media monitoring (Pokemon sprites)"),
        (icon: "terminal",                         text: "Console log capture"),
        (icon: "tag.fill",                         text: "Custom URL tags (Posts API / PokeAPI)"),
        (icon: "iphone.radiowaves.left.and.right", text: "Shake to toggle bubble"),
    ])

    private let codeCard = InfoCodeCardView(
        title: "How It's Set Up",
        code: """
        import SwiftyDebug

        // In AppDelegate.application(_:didFinishLaunchingWithOptions:)

        SwiftyDebug.monitorAllUrls  = true
        SwiftyDebug.monitorMedia    = true
        SwiftyDebug.enableConsoleLog = true

        SwiftyDebug.addTag(keyword: "jsonplaceholder",
                           label: "Posts API")
        SwiftyDebug.addTag(keyword: "pokeapi",
                           label: "PokeAPI")

        SwiftyDebug.enable()
        """
    )

    private let apisCard = InfoCardView(title: "APIs Used in This Demo", items: [
        (icon: "list.bullet.rectangle", text: "JSONPlaceholder — Posts, Comments, Users"),
        (icon: "star.circle",           text: "PokeAPI — Pokemon list & details"),
        (icon: "photo",                 text: "PokeAPI Sprites — Pokemon images (PNG)"),
    ])

    private let fireButton:UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Fire Test Requests", for: .normal)
        btn.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        btn.backgroundColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        btn.tintColor = .white
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 14
        var config = UIButton.Configuration.plain()
        config.imagePadding = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        btn.configuration = config
        return btn
    }()

    private let tipLabel:UILabel = {
        let lbl = UILabel()
        lbl.text = "Tap the bubble at the edge of the screen to open SwiftyDebug. Shake the device to toggle the bubble."
        lbl.font = .systemFont(ofSize: 12)
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        return lbl
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElements()
        setupConstraints()
        fireButton.addTarget(self, action: #selector(fireTestRequestsTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        backgroundColor = .systemGroupedBackground
        uiHolderView.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        contentStack.addArrangedSubview(bannerView)
        contentStack.addArrangedSubview(featuresCard)
        contentStack.addArrangedSubview(codeCard)
        contentStack.addArrangedSubview(apisCard)
        contentStack.addArrangedSubview(fireButton)
        contentStack.addArrangedSubview(tipLabel)
    }

    override func setupConstraints() {
        super.setupConstraints()
        scrollView.anchor([.fill(uiHolderView)])
        contentStack.anchor([.top(scrollView.topAnchor, 20), .bottom(scrollView.bottomAnchor, -40), .leading(uiHolderView.leadingAnchor, 20), .trailing(uiHolderView.trailingAnchor, -20)])
        fireButton.anchor([.height(52)])
    }

    @objc private func fireTestRequestsTapped() {
        delegate?.doActions(.fireTestRequests)
    }

    func showToast(_ message:String) {
        let toast = UILabel()
        toast.text = message
        toast.font = .systemFont(ofSize: 13, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 0.90)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.alpha = 0
        addSubview(toast)
        toast.anchor([.centerX(self), .bottom(safeAreaLayoutGuide.bottomAnchor, -20), .height(44)])

        UIView.animate(withDuration: 0.25) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
        }
    }
}
