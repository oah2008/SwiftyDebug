//
//  NetworkTimelineChartViews.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

// MARK: - TimelineRow

/// One drawable request on the waterfall.
///
/// Everything needed to draw and label a row is resolved **once**, here, from
/// the transaction's in-memory fields (`startTime`/`endTime` strings, status,
/// `searchIndex`). Nothing in this type touches `requestData`/`responseData`,
/// which are disk-backed — a waterfall re-lays out on every pan/zoom frame, so
/// a single file read per row would be fatal.
struct TimelineRow {

    /// Requests slower than this are considered "slow" by the Slow filter chip.
    /// Stated in the chip title so the threshold is never a mystery.
    static let slowThreshold: Double = 1.0

    /// Anything longer than this is treated as a broken timestamp rather than a
    /// real duration (a garbage `endTime` would otherwise stretch the whole
    /// session axis to hours and squash every real bar to zero pixels).
    static let maxPlausibleDuration: Double = 3600

    let model: NetworkTransaction
    /// Absolute seconds since 1970. Always > 0 (rows without one are dropped).
    let start: Double
    /// Absolute end. Equals `start` for in-flight / unusable end timestamps.
    let end: Double
    let statusCode: Int
    let hasError: Bool
    /// No usable `endTime` — drawn as a minimum-width gray stub, never as a
    /// bar of garbage length.
    let isInFlight: Bool
    let method: String
    let path: String
    let host: String

    var duration: Double { max(0, end - start) }
    var isSlow: Bool { !isInFlight && duration > Self.slowThreshold }
    var isFailure: Bool { hasError || statusCode >= 400 || (statusCode == 0 && !isInFlight) }

    // MARK: - Build

    /// Returns nil when the transaction has no usable start timestamp — such a
    /// row has no position on the axis, so it is skipped instead of drawn at 0.
    static func make(from model: NetworkTransaction) -> TimelineRow? {
        let start = ((model.startTime ?? "") as NSString).doubleValue
        guard start.isFinite, start > 0 else { return nil }

        let rawEnd = ((model.endTime ?? "") as NSString).doubleValue
        let endIsUsable = rawEnd.isFinite
            && rawEnd > 0
            && rawEnd >= start
            && (rawEnd - start) <= maxPlausibleDuration
        let inFlight = !endIsUsable

        let errorText = (model.errorDescription ?? "") + (model.errorLocalizedDescription ?? "")
        let code = Int(model.statusCode ?? "0") ?? 0

        let index = model.searchIndex
        let url = model.url as URL?
        var path = index?.path ?? url?.path ?? ""
        if path.isEmpty { path = "/" }

        return TimelineRow(
            model: model,
            start: start,
            end: endIsUsable ? rawEnd : start,
            statusCode: code,
            hasError: !errorText.isEmpty,
            isInFlight: inFlight,
            method: (model.method ?? index?.method ?? "").uppercased(),
            path: path,
            host: index?.host ?? url?.host ?? ""
        )
    }

    // MARK: - Presentation

    /// 2xx green · 3xx accent · 4xx orange · 5xx/error red · in-flight/unknown gray.
    var barColor: UIColor {
        if hasError { return .systemRed }
        switch statusCode {
        case 200..<300: return .systemGreen
        case 300..<400: return DebugTheme.accentColor
        case 400..<500: return .systemOrange
        case 500...:    return .systemRed
        default:        return UIColor(white: 0.45, alpha: 1)
        }
    }

    var statusText: String {
        if hasError { return "ERR" }
        if statusCode <= 0 { return isInFlight ? "···" : "—" }
        return String(statusCode)
    }

    var durationText: String {
        if isInFlight { return "pending" }
        let d = duration
        if d < 0.001 { return "<1ms" }
        if d < 1 { return "\(Int((d * 1000).rounded()))ms" }
        return String(format: "%.2fs", d)
    }

    /// Middle-truncated path: long REST paths keep both the resource root and
    /// the trailing id, which is where the information actually is.
    func shortPath(maxLength: Int = 30) -> String {
        TimelineRow.middleTruncate(path, maxLength: maxLength)
    }

    static func middleTruncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 6, text.count > maxLength else { return text }
        let keep = maxLength - 1
        let head = keep / 2
        let tail = keep - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}

// MARK: - TimelineAxis

/// Maps session time to horizontal points.
///
/// `trackWidth` is the *visible* width of the bar area; `zoom` stretches the
/// content beyond it, and the difference is what the horizontal scroll offset
/// travels over. At `zoom == 1` the whole session fits exactly and there is
/// nothing to scroll.
struct TimelineAxis {

    /// Absolute epoch seconds of the earliest captured request.
    var sessionStart: Double = 0
    /// Session length in seconds. Always > 0 (clamped by the owner).
    var span: Double = 1
    /// Visible width of the bar track, in points.
    var trackWidth: CGFloat = 1
    var zoom: CGFloat = 1

    var contentWidth: CGFloat { max(trackWidth, trackWidth * zoom) }

    var pointsPerSecond: CGFloat {
        guard span > 0, span.isFinite, contentWidth > 0 else { return 0 }
        return contentWidth / CGFloat(span)
    }

    var maxOffset: CGFloat { max(0, contentWidth - trackWidth) }

    /// X position (in content coordinates, before the scroll offset) of an
    /// absolute timestamp.
    func x(forAbsolute time: Double) -> CGFloat {
        CGFloat(time - sessionStart) * pointsPerSecond
    }
}

// MARK: - Tick math

/// Shared tick generation so the ruler and the grid overlay can never drift
/// apart: both ask this for the same `(axis, offset, width)` and get the same
/// list back.
enum TimelineTicks {

    struct Tick {
        /// Elapsed seconds since session start.
        let elapsed: Double
        /// X in view coordinates (offset already applied).
        let x: CGFloat
    }

    /// A "nice" 1/2/5 × 10ⁿ step that keeps ticks at least `minSpacing` apart.
    static func step(pointsPerSecond pps: CGFloat, minSpacing: CGFloat) -> Double {
        guard pps > 0, minSpacing > 0 else { return 1 }
        let raw = Double(minSpacing / pps)
        guard raw.isFinite, raw > 0 else { return 1 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        for multiple in [1.0, 2.0, 5.0] where base * multiple >= raw {
            return base * multiple
        }
        return base * 10
    }

    static func visibleTicks(axis: TimelineAxis,
                             offset: CGFloat,
                             width: CGFloat,
                             minSpacing: CGFloat = 66) -> (step: Double, ticks: [Tick]) {
        let pps = axis.pointsPerSecond
        guard pps > 0, width > 0, axis.span > 0 else { return (1, []) }

        let s = step(pointsPerSecond: pps, minSpacing: minSpacing)
        let pointsPerStep = s * Double(pps)
        guard s > 0, pointsPerStep.isFinite, pointsPerStep > 0.5 else { return (s, []) }

        var index = max(0, floor(Double(offset) / pointsPerStep))
        var ticks: [Tick] = []
        // Hard cap: a pathological axis must never spin here.
        while ticks.count < 256 {
            let elapsed = index * s
            if elapsed > axis.span + s { break }
            let x = CGFloat(elapsed) * pps - offset
            if x > width + 1 { break }
            if x >= -1 { ticks.append(Tick(elapsed: elapsed, x: x)) }
            index += 1
        }
        return (s, ticks)
    }

    /// Label for an elapsed value, with the precision implied by the step so a
    /// 20ms-step ruler doesn't print every tick as "0s".
    static func label(elapsed: Double, step: Double) -> String {
        if elapsed <= 0 { return "0" }
        if elapsed >= 60 {
            let minutes = Int(elapsed / 60)
            let seconds = elapsed - Double(minutes) * 60
            return String(format: "%dm%02.0fs", minutes, seconds)
        }
        if step >= 1 { return String(format: "%.0fs", elapsed) }
        if step >= 0.1 { return String(format: "%.1fs", elapsed) }
        if step >= 0.01 { return String(format: "%.2fs", elapsed) }
        return String(format: "%.0fms", elapsed * 1000)
    }
}

// MARK: - Ruler

/// The elapsed-time header. One custom-drawn view for the whole ruler — never a
/// view per tick — redrawn only when the offset or zoom actually changes.
final class NetworkTimelineRulerView: UIView {

    private var axis = TimelineAxis()
    private var offset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(axis: TimelineAxis, offset: CGFloat) {
        self.axis = axis
        self.offset = offset
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }

        // Baseline
        ctx.setFillColor(UIColor(white: 0.22, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

        let (step, ticks) = TimelineTicks.visibleTicks(axis: axis, offset: offset, width: bounds.width)
        guard !ticks.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ]

        for tick in ticks {
            ctx.setFillColor(UIColor(white: 0.32, alpha: 1).cgColor)
            ctx.fill(CGRect(x: tick.x.rounded(), y: bounds.height - 5, width: 1, height: 4))

            let text = TimelineTicks.label(elapsed: tick.elapsed, step: step) as NSString
            let size = text.size(withAttributes: attrs)
            var textX = tick.x - size.width / 2
            textX = min(max(textX, 0), max(0, bounds.width - size.width))
            text.draw(at: CGPoint(x: textX, y: bounds.height - 6 - size.height), withAttributes: attrs)
        }
    }
}

// MARK: - Grid overlay

/// Vertical gridlines drawn once, above the rows, aligned to the ruler ticks.
/// Non-interactive so taps fall through to the table underneath.
final class NetworkTimelineGridView: UIView {

    private var axis = TimelineAxis()
    private var offset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        forceLTR()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(axis: TimelineAxis, offset: CGFloat) {
        self.axis = axis
        self.offset = offset
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        let (_, ticks) = TimelineTicks.visibleTicks(axis: axis, offset: offset, width: bounds.width)
        ctx.setFillColor(UIColor(white: 1, alpha: 0.055).cgColor)
        for tick in ticks {
            ctx.fill(CGRect(x: tick.x.rounded(), y: 0, width: 1, height: bounds.height))
        }
    }
}

// MARK: - Row cell

/// One waterfall row: a fixed gutter (method / path / status) plus a bar track.
///
/// The bar is a **single plain UIView** whose frame is recomputed from the axis
/// — panning and pinching therefore move ~20 visible views, not one view per
/// pixel and not a full redraw. Row height is fixed on purpose: a waterfall
/// needs a uniform grid, and fixed heights keep the frozen gutter and the
/// scrolling bars in lockstep.
final class NetworkTimelineRowCell: UITableViewCell {

    static let reuseID = "SwiftyDebugTimelineRow"

    static let rowHeight: CGFloat = 46
    static let cardInset: CGFloat = 12
    static let cardPadding: CGFloat = 10
    static let gutterWidth: CGFloat = 146
    static let trackGap: CGFloat = 8
    static let minBarWidth: CGFloat = 4
    static let barHeight: CGFloat = 12

    /// X of the bar track in the cell's (and the view controller's) coordinate
    /// space — the ruler and grid overlay use this too so all three align.
    static var trackOriginX: CGFloat { cardInset + cardPadding + gutterWidth + trackGap }

    /// Trailing inset of the track from the right edge of the screen.
    static var trackTrailingInset: CGFloat { cardInset + cardPadding }

    static func trackWidth(forWidth width: CGFloat) -> CGFloat {
        max(1, width - trackOriginX - trackTrailingInset)
    }

    // MARK: - Subviews

    private let card = UIView()
    private let methodLabel = UILabel()
    private let statusLabel = UILabel()
    private let pathLabel = UILabel()
    private let track = UIView()
    private let barView = UIView()
    private let durationLabel = UILabel()

    // MARK: - State

    private var row: TimelineRow?
    private var axis = TimelineAxis()
    private var offset: CGFloat = 0

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        methodLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        methodLabel.textColor = UIColor(white: 0.45, alpha: 1)
        methodLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(methodLabel)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        statusLabel.textAlignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(statusLabel)

        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = UIColor(white: 0.86, alpha: 1)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.numberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pathLabel)

        track.backgroundColor = .clear
        track.clipsToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(track)

        barView.layer.cornerRadius = 3
        barView.layer.cornerCurve = .continuous
        track.addSubview(barView)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        durationLabel.textColor = UIColor(white: 0.55, alpha: 1)
        track.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.cardInset),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.cardInset),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            methodLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.cardPadding),
            methodLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),

            statusLabel.trailingAnchor.constraint(equalTo: card.leadingAnchor,
                                                  constant: Self.cardPadding + Self.gutterWidth),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: methodLabel.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: methodLabel.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: methodLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: methodLabel.bottomAnchor, constant: 2),
            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -6),

            track.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                           constant: Self.cardPadding + Self.gutterWidth + Self.trackGap),
            track.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.cardPadding),
            track.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            track.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
        ])

        forceLTR()
    }

    // MARK: - Configure

    func configure(row: TimelineRow, axis: TimelineAxis, offset: CGFloat) {
        self.row = row
        self.axis = axis
        self.offset = offset

        methodLabel.text = row.method.isEmpty ? "—" : row.method
        pathLabel.text = row.shortPath()
        statusLabel.text = row.statusText
        statusLabel.textColor = row.barColor

        let color = row.barColor
        barView.backgroundColor = row.isInFlight ? color.withAlphaComponent(0.5) : color
        durationLabel.text = row.durationText
        durationLabel.textColor = row.isInFlight
            ? UIColor(white: 0.45, alpha: 1)
            : color.withAlphaComponent(0.85)
        durationLabel.sizeToFit()

        setNeedsLayout()
    }

    /// Called on every pan/zoom frame for visible cells only.
    func applyAxis(_ axis: TimelineAxis, offset: CGFloat) {
        self.axis = axis
        self.offset = offset
        layoutBar()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBar()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        row = nil
        barView.isHidden = true
        durationLabel.isHidden = true
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.12) {
            self.card.backgroundColor = highlighted
                ? UIColor(white: 0.20, alpha: 1)
                : UIColor(white: 0.13, alpha: 1)
        }
    }

    // MARK: - Bar geometry

    private func layoutBar() {
        guard let row = row else {
            barView.isHidden = true
            durationLabel.isHidden = true
            return
        }
        let width = track.bounds.width
        let height = track.bounds.height
        guard width > 0, height > 0 else { return }

        let pps = axis.pointsPerSecond
        let startX = axis.x(forAbsolute: row.start) - offset
        let rawWidth = CGFloat(row.duration) * pps
        let barWidth = max(rawWidth.isFinite ? rawWidth : 0, Self.minBarWidth)
        let endX = startX + barWidth

        // Fully outside the visible track: hide instead of compositing.
        guard endX >= -2, startX <= width + 2 else {
            barView.isHidden = true
            durationLabel.isHidden = true
            return
        }

        // Clamp the drawn rect: a heavily zoomed bar can be tens of thousands of
        // points wide, and there is no reason to hand that to the compositor.
        let clampedStart = max(startX, -20)
        let clampedEnd = min(endX, width + 20)
        barView.isHidden = false
        barView.frame = CGRect(x: clampedStart,
                               y: ((height - Self.barHeight) / 2).rounded(),
                               width: max(1, clampedEnd - clampedStart),
                               height: Self.barHeight)

        // Duration text sits just after the bar, flipped to the leading side
        // when the bar ends near the right edge.
        let labelSize = durationLabel.bounds.size
        var labelX = endX + 6
        if labelX + labelSize.width > width {
            labelX = startX - labelSize.width - 6
        }
        labelX = min(max(labelX, 0), max(0, width - labelSize.width))
        durationLabel.isHidden = labelSize.width <= 0
        durationLabel.frame = CGRect(x: labelX,
                                     y: ((height - labelSize.height) / 2).rounded(),
                                     width: labelSize.width,
                                     height: labelSize.height)
    }
}
