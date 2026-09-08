import AppKit

/// Wave + spinner sitting in `NSGlassEffectView.contentView`.
/// No host CALayer and no fill — a full-size layer is what flattened the glass.
final class OverlayChipView: NSView {
    static let chipSize = NSSize(width: 112, height: 28)
    static let processingSize = NSSize(width: 36, height: 28)

    var levels: [Float] = Array(repeating: 0, count: OverlayMetrics.barCount) {
        didSet {
            guard levels != oldValue else { return }
            needsDisplay = true
        }
    }

    /// White waves on a dark page, black waves on a light page.
    var backdropIsDark = true {
        didSet {
            guard oldValue != backdropIsDark else { return }
            appearance = NSAppearance(named: backdropIsDark ? .darkAqua : .aqua)
            needsDisplay = true
        }
    }

    var isProcessing = false {
        didSet {
            guard oldValue != isProcessing else { return }
            invalidateIntrinsicContentSize()
            spinner.isHidden = !isProcessing
            if isProcessing {
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
            }
            needsDisplay = true
        }
    }

    private let spinner = NSProgressIndicator()
    private static let edgeFade: [CGFloat] = {
        let count = OverlayMetrics.barCount
        return (0..<count).map { index in
            switch min(index, count - 1 - index) {
            case 0: return 0.24
            case 1: return 0.48
            case 2: return 0.74
            default: return 1
            }
        }
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        appearance = NSAppearance(named: .darkAqua)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize {
        isProcessing ? Self.processingSize : Self.chipSize
    }

    override func layout() {
        super.layout()
        let size = spinner.fittingSize
        spinner.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isProcessing else { return }
        let inset = bounds.insetBy(dx: 10, dy: 5)
        guard inset.width > 0, inset.height > 0 else { return }

        let count = OverlayMetrics.barCount
        let gap: CGFloat = 2.1
        let barWidth: CGFloat = 2.25
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        let startX = inset.midX - totalWidth / 2
        let idle: CGFloat = 1.4
        let travel = max(inset.height - idle, 0)

        let fill = backdropIsDark
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor.black.withAlphaComponent(0.92)
        let halo = backdropIsDark
            ? NSColor.black.withAlphaComponent(0.42)
            : NSColor.white.withAlphaComponent(0.38)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 1.6, color: halo.cgColor)
        fill.setFill()

        for index in 0..<count {
            let raw = index < levels.count ? levels[count - 1 - index] : 0
            let level = visualLevel(for: raw)
            let height = idle + level * travel * Self.edgeFade[index]
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: inset.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 1.125, yRadius: 1.125).fill()
        }

        ctx.restoreGState()
    }

    private func visualLevel(for raw: Float) -> CGFloat {
        let clamped = CGFloat(min(max(raw, 0), 1))
        guard clamped > 0.01 else { return 0 }
        return min(pow(clamped, 0.86), 1)
    }
}
