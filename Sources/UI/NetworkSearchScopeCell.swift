//
//  NetworkSearchScopeCell.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import UIKit

/// First row of the result list while a query is active: a labelled scope
/// control that says, in words, what is being searched and how many extra hits
/// are waiting inside the disk-backed bodies.
///
/// Each chip is one `BodySearchSide`, which maps 1:1 onto
/// `ResponseBodySearch.Options.searchRequestBodies` / `searchResponseBodies`, so
/// what this row promises and what the engine actually scans can never drift
/// apart. Metadata (URL, headers, status, params…) is always on — that is what
/// the index-backed list search already does, and it costs no disk read.
final class NetworkSearchScopeCell: UITableViewCell {

    static let reuseId = "NetworkSearchScopeCell"

    /// One body scope chip.
    struct ScopeState {
        let side: BodySearchSide
        /// Hits from this side are merged into the list right now.
        let isOn: Bool
        /// A scan for this side is in flight — the chip says so instead of
        /// showing a stale or zero count.
        let isScanning: Bool
        /// Hits for the current query, or nil when this side was never scanned.
        let count: Int?
    }

    struct Config {
        /// The live query, quoted in the description so the card reads as a
        /// sentence about what the developer just typed.
        let query: String
        let metadataCount: Int
        let scopes: [ScopeState]
        let statusText: String
    }

    /// Fires with the side whose chip was tapped.
    var onToggle: ((BodySearchSide) -> Void)?

    // MARK: - Views

    private let cardView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let statusLabel = UILabel()
    private let chipsScrollView = UIScrollView()
    private let chipsStack = UIStackView()

    /// Chips are rebuilt per configure — keyed by side, never by row index.
    private var chipButtons: [BodySearchSide: UIButton] = [:]

    private static let cardBackgroundColor = UIColor(white: 0.11, alpha: 1)
    private static let chipHeight: CGFloat = 28

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.backgroundColor = Self.cardBackgroundColor
        cardView.layer.cornerRadius = 10
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = UIColor(white: 0.2, alpha: 1).cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        iconView.image = UIImage(systemName: "doc.text.magnifyingglass",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(iconView)

        titleLabel.text = "SEARCH INSIDE BODIES"
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cardView.addSubview(titleLabel)

        // The card has to say what it does. The old version was a bare icon in
        // the search row, which told the developer nothing about what it would
        // search, what it would cost, or why it was off.
        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = UIColor(white: 0.62, alpha: 1)
        descriptionLabel.numberOfLines = 0
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(descriptionLabel)

        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.42, alpha: 1)
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLabel)

        // A horizontal scroller keeps long labelled chips from clipping on
        // narrow devices instead of squeezing them into unreadable stubs.
        chipsScrollView.showsHorizontalScrollIndicator = false
        chipsScrollView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(chipsScrollView)

        chipsStack.axis = .horizontal
        chipsStack.spacing = 8
        chipsStack.alignment = .center
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsScrollView.addSubview(chipsStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 11),

            descriptionLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            descriptionLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            chipsScrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            chipsScrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            chipsScrollView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 9),
            chipsScrollView.heightAnchor.constraint(equalToConstant: Self.chipHeight),

            statusLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: chipsScrollView.bottomAnchor, constant: 8),
            // Pin the last element to the card bottom so the cell self-sizes.
            statusLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),

            chipsStack.leadingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.leadingAnchor),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.trailingAnchor),
            chipsStack.topAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.bottomAnchor),
            chipsStack.heightAnchor.constraint(equalTo: chipsScrollView.frameLayoutGuide.heightAnchor),
        ])

        forceLTR()
    }

    // MARK: - Configure

    func configure(with config: Config) {
        statusLabel.text = config.statusText
        descriptionLabel.text = Self.descriptionText(for: config)

        chipsStack.arrangedSubviews.forEach {
            chipsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        chipButtons.removeAll()

        for state in config.scopes {
            let button = makeChip(for: state)
            chipsStack.addArrangedSubview(button)
            chipButtons[state.side] = button
        }

        forceLTR()
    }

    /// Live progress text, updated without a reload so the row doesn't flicker
    /// while a scan ticks along.
    func setStatus(_ text: String) {
        statusLabel.text = text
    }

    /// Explains, in one sentence, what turning a chip on will do — and makes
    /// clear that the list above already covers URL/headers/status, so the
    /// developer knows this is *extra* reach rather than the whole search.
    private static func descriptionText(for config: Config) -> String {
        let term = config.query.isEmpty ? "your search" : "\u{201C}\(config.query)\u{201D}"
        let on = config.scopes.filter { $0.isOn }
        if on.isEmpty {
            return "The \(config.metadataCount) result\(config.metadataCount == 1 ? "" : "s") above matched a URL, header or status. "
                 + "Tap a payload below to also find \(term) inside it."
        }
        let names = on.map { title(for: $0.side).lowercased() }
        return "Also showing requests whose \(names.joined(separator: " or ")) contains \(term)."
    }

    // MARK: - Chips

    private func makeChip(for state: ScopeState) -> UIButton {
        let button = UIButton(type: .system)
        // A tick on the active chip so "which of these am I actually seeing?" is
        // answerable without relying on colour alone.
        let mark = state.isOn ? "\u{2713} " : ""
        button.setTitle(Self.pad("\(mark)\(Self.title(for: state.side)) \u{00B7} \(Self.countText(for: state))"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.layer.cornerRadius = Self.chipHeight / 2
        button.clipsToBounds = true
        button.layer.borderWidth = 1
        button.heightAnchor.constraint(equalToConstant: Self.chipHeight).isActive = true

        // A scope with zero hits stays tappable (the count can grow as more
        // requests land) but reads as inert.
        let hasHits = (state.count ?? 0) > 0
        if state.isOn {
            button.backgroundColor = DebugTheme.accentColor.withAlphaComponent(0.22)
            button.setTitleColor(DebugTheme.accentColor, for: .normal)
            button.layer.borderColor = DebugTheme.accentColor.cgColor
        } else {
            button.backgroundColor = UIColor(white: 0.16, alpha: 1)
            button.setTitleColor(UIColor(white: hasHits ? 0.8 : 0.42, alpha: 1), for: .normal)
            button.layer.borderColor = UIColor(white: hasHits ? 0.3 : 0.2, alpha: 1).cgColor
        }

        button.accessibilityLabel = "\(Self.title(for: state.side)), \(Self.countText(for: state)) matches"
        button.accessibilityHint = state.isOn
            ? "Double tap to remove these results from the list"
            : "Double tap to merge these results into the list"

        let side = state.side
        button.addAction(UIAction { [weak self] _ in
            self?.onToggle?(side)
        }, for: .touchUpInside)

        return button
    }

    private static func title(for side: BodySearchSide) -> String {
        switch side {
        case .request:  return "Request body"
        case .response: return "Response body"
        }
    }

    /// Never a stale number: a running scan says so, and a side that was never
    /// scanned invites the tap instead of claiming zero hits.
    /// Spelled out rather than a bare number: "4" next to "Response body" reads
    /// as an index, not as "four requests matched".
    private static func countText(for state: ScopeState) -> String {
        if state.isScanning { return "scanning\u{2026}" }
        guard let count = state.count else { return "tap to scan" }
        return count == 0 ? "no matches" : "\(count) found"
    }

    /// Space padding gives the pill horizontal breathing room without a
    /// UIButton.Configuration (which would fight the fixed chip height).
    private static func pad(_ text: String) -> String {
        return "  \(text)  "
    }
}
