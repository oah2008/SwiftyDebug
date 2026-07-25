//
//  NetworkMediaGridCell.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

/// Detail-section table cell that renders a compact media grid: up to 6 images
/// (3 per row) parsed from the response JSON, with a "Preview" / "Show all"
/// affordance mirroring the "SIMILAR REQUESTS" section. Tapping a thumbnail — or
/// "Show all" — opens the full gallery. (See JSON-MEDIA.)
final class NetworkMediaGridCell: UITableViewCell {

    // MARK: - Subviews

    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let showAllButton = UIButton(type: .system)
    private let gridStack = UIStackView()   // vertical stack of row stacks

    // MARK: - Callbacks

    /// Fired when a thumbnail (index) is tapped, or "Show all" (index = nil).
    var onSelectImage: ((_ startIndex: Int) -> Void)?
    var onShowAll: (() -> Void)?

    // MARK: - State

    private var imageURLs: [String] = []
    private var tokens: [ImageLoader.Token] = []

    private static let previewCount = 6
    private static let columns = 3
    private static let cardBg = UIColor(white: 0.11, alpha: 1)
    private static let tileBg = UIColor(white: 0.17, alpha: 1)
    private static let teal = UIColor(red: 0.30, green: 0.78, blue: 0.72, alpha: 1)
    private static let tileSpacing: CGFloat = 6

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
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.backgroundColor = Self.cardBg
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = Self.teal
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        showAllButton.setTitle("Show all", for: .normal)
        showAllButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        showAllButton.setTitleColor(Self.teal, for: .normal)
        showAllButton.translatesAutoresizingMaskIntoConstraints = false
        showAllButton.addTarget(self, action: #selector(showAllTapped), for: .touchUpInside)
        cardView.addSubview(showAllButton)

        gridStack.axis = .vertical
        gridStack.spacing = Self.tileSpacing
        gridStack.distribution = .fillEqually
        gridStack.semanticContentAttribute = .forceLeftToRight
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(gridStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),

            showAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            showAllButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            showAllButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            gridStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            gridStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            gridStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            gridStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
        ])

        forceLTR()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tokens.forEach { $0.cancel() }
        tokens.removeAll()
        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        imageURLs = []
        onSelectImage = nil
        onShowAll = nil
    }

    // MARK: - Configure

    func configure(imageURLs: [String]) {
        tokens.forEach { $0.cancel() }
        tokens.removeAll()
        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        self.imageURLs = imageURLs
        let total = imageURLs.count
        titleLabel.text = "MEDIA · \(total) image\(total == 1 ? "" : "s")"
        // "Show all" only when there are more than the preview grid can hold.
        showAllButton.isHidden = total <= Self.previewCount

        let shown = Array(imageURLs.prefix(Self.previewCount))
        // Estimate tile size for downsampling (screen width / 3, in pixels).
        let approxTile = (UIScreen.main.bounds.width - 24 - CGFloat(Self.columns - 1) * Self.tileSpacing) / CGFloat(Self.columns)
        let maxPixel = max(120, approxTile * UIScreen.main.scale)

        var currentRow: UIStackView?
        for (i, urlString) in shown.enumerated() {
            if i % Self.columns == 0 {
                let row = makeRowStack()
                gridStack.addArrangedSubview(row)
                currentRow = row
            }
            let tile = makeTile(index: i, urlString: urlString, maxPixel: maxPixel)
            currentRow?.addArrangedSubview(tile)
        }
        // Pad the last row so tiles keep square sizing.
        if let row = currentRow {
            let remainder = shown.count % Self.columns
            if remainder != 0 {
                for _ in 0..<(Self.columns - remainder) {
                    let spacer = UIView()
                    spacer.backgroundColor = .clear
                    row.addArrangedSubview(spacer)
                }
            }
        }
    }

    private func makeRowStack() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Self.tileSpacing
        row.distribution = .fillEqually
        row.semanticContentAttribute = .forceLeftToRight
        return row
    }

    private func makeTile(index: Int, urlString: String, maxPixel: CGFloat) -> UIView {
        let container = UIView()
        container.backgroundColor = Self.tileBg
        container.layer.cornerRadius = 8
        container.clipsToBounds = true
        container.heightAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let token = ImageLoader.shared.loadImage(urlString: urlString, maxPixel: maxPixel) { [weak imageView] image in
            imageView?.image = image
        }
        tokens.append(token)

        container.tag = index
        container.isUserInteractionEnabled = true
        container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tileTapped(_:))))
        return container
    }

    // MARK: - Actions

    @objc private func tileTapped(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag else { return }
        onSelectImage?(index)
    }

    @objc private func showAllTapped() {
        onShowAll?()
    }
}
