import SwiftUI

struct PillOverlayView: View {
    @Bindable var appState: AppState

    @State private var appeared = false
    @State private var dotPulse = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.clear.tint(.black.opacity(0.05)), in: .capsule)
                .opacity(0.42)

            HStack(spacing: 6) {
                recordingDot
                waveOrSpinner
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .shadow(color: .black.opacity(0.03), radius: 4, y: 1)
        .scaleEffect(appeared ? 1 : 0.55)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.68), value: appeared)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                appeared = true
                dotPulse = true
            }
        }
    }

    // MARK: – Recording dot

    private var recordingDot: some View {
        let loudness = appState.audioLevels.max() ?? 0
        let reactiveSz: CGFloat = appState.phase == .recording
            ? 1.0 + CGFloat(loudness) * 0.50
            : 1.0

        return ZStack {
            Circle()
                .fill(dotColor.opacity(0.25))
                .frame(width: 12, height: 12)
                .scaleEffect(dotPulse ? 1.45 : 0.70)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dotPulse)

            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .scaleEffect(reactiveSz)
                .animation(.spring(duration: 0.08, bounce: 0.1), value: loudness)
        }
        .frame(width: 12, height: 12)
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
    }

    // MARK: – Wave / Spinner

    @ViewBuilder
    private var waveOrSpinner: some View {
        Group {
            if appState.phase == .processing {
                ProcessingWave()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                AudioWaveView(levels: appState.audioLevels)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.phase)
    }

    // MARK: – Helpers

    private var dotColor: Color {
        switch appState.phase {
        case .idle:       .white.opacity(0.35)
        case .recording:  .red
        case .processing: Color.orange
        }
    }
}

// MARK: – Processing wave (continuous sine sweep)

/// 10 bars animated by a continuous sine wave that flows left→right.
/// Uses TimelineView for per-frame updates — smooth, no state bookkeeping.
/// Width matches AudioWaveView (≈54pt).
private struct ProcessingWave: View {
    private let barCount = 10
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat   = 3.0
    private let maxH: CGFloat     = 16
    private let minH: CGFloat     = 2.5

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 4.0

            HStack(alignment: .center, spacing: barGap) {
                ForEach(0..<barCount, id: \.self) { i in
                    let t     = (sin(phase + Double(i) * 0.7) + 1) / 2   // 0…1
                    let h     = minH + CGFloat(t) * (maxH - minH)
                    let alpha = 0.30 + t * 0.55

                    Capsule()
                        .fill(Color.orange.opacity(alpha))
                        .frame(width: barWidth, height: h)
                }
            }
        }
        .frame(height: 18)
    }
}
