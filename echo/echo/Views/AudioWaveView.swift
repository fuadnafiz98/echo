import SwiftUI

/// 16 bars driven by AudioEngineService RMS levels.
/// Shallow Gaussian envelope: centre bars tallest, edges ~30% height.
/// Bars collapse to 1.5pt at silence (noise gate keeps levels at 0).

/// 

struct AudioWaveView: View {
    static let barCount = 16          // must match AppState.audioLevels.count
    let levels: [Float]               // caller guarantees count == barCount

    private let barWidth: CGFloat = 2
    private let barGap: CGFloat   = 1.2
    private let maxH: CGFloat     = 18
    private let minH: CGFloat     = 1.5

    var body: some View {
        HStack(alignment: .center, spacing: barGap) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let lvl   = i < levels.count ? levels[i] : 0
                let env   = gaussian(i)
                let h     = minH + CGFloat(lvl * env) * (maxH - minH)
                let alpha = 0.40 + Double(lvl) * 0.60

                Capsule()
                    .fill(.white.opacity(alpha))
                    .frame(width: barWidth, height: h)
                    .animation(.spring(duration: 0.10, bounce: 0.15), value: h)
            }
        }
        .frame(height: maxH)
    }

    /// Shallow Gaussian bell: 1.0 at centre, ~0.30 at edges
    private func gaussian(_ i: Int) -> Float {
        let centre   = Float(Self.barCount - 1) / 2.0
        let distance = (Float(i) - centre) / centre        // −1 … +1
        return exp(-1.2 * distance * distance)
    }
}
