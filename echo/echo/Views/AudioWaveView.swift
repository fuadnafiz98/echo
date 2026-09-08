import SwiftUI

struct AudioWaveView: View {
    static let barCount = OverlayMetrics.barCount
    let levels: [Float]
    var barHeight: CGFloat = 16
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: 2.25) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RollingBar(
                    level: visualLevel(for: level(atVisualIndex: i)),
                    edgeFade: edgeFade(at: i),
                    maxH: barHeight,
                    tint: tint
                )
            }
        }
        .frame(height: barHeight)
    }

    private func level(atVisualIndex index: Int) -> Float {
        let sourceIndex = Self.barCount - 1 - index
        return sourceIndex < levels.count ? levels[sourceIndex] : 0
    }

    private func edgeFade(at index: Int) -> CGFloat {
        let edgeDistance = min(index, Self.barCount - 1 - index)
        switch edgeDistance {
        case 0: return 0.24
        case 1: return 0.48
        case 2: return 0.74
        default: return 1
        }
    }

    private func visualLevel(for raw: Float) -> CGFloat {
        let clamped = CGFloat(min(max(raw, 0), 1))
        guard clamped > 0.01 else { return 0 }

        return min(pow(clamped, 0.86), 1)
    }
}

private struct RollingBar: View {
    let level: CGFloat
    let edgeFade: CGFloat
    let maxH: CGFloat
    let tint: Color

    private let minH: CGFloat = 1.4
    private let width: CGFloat = 2

    private var height: CGFloat {
        minH + min(max(level, 0), 1) * (maxH - minH) * edgeFade
    }

    var body: some View {
        Capsule()
            .fill(tint.opacity(Double((0.20 + level * 0.70) * edgeFade)))
            .frame(width: width, height: minH)
            .scaleEffect(x: 1, y: height / minH, anchor: .center)
            .animation(.easeOut(duration: 0.045), value: height)
    }
}
