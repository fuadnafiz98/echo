import SwiftUI
import AppKit

struct PillOverlayView: View {
    @Bindable var appState: AppState

    @State private var appeared = false
    @State private var dotPulse = false

    var body: some View {
        HStack(spacing: 7) {
            recordingDot
            waveOrSpinner
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(GlassPillModifier())
        // Entrance spring
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
                .frame(width: 14, height: 14)
                .scaleEffect(dotPulse ? 1.45 : 0.70)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dotPulse)

            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .scaleEffect(reactiveSz)
                .animation(.spring(duration: 0.08, bounce: 0.1), value: loudness)
        }
        .frame(width: 14, height: 14)
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

// MARK: – Glass pill modifier

/// Uses NSVisualEffectView (via NSViewRepresentable) for reliable desktop blur,
/// plus glassEffect on macOS 26 for Liquid Glass treatment.
/// TransparentHostingView.isOpaque == false enables the window server compositor.
private struct GlassPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(Capsule())
                }
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(Capsule())
                }
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
        }
    }
}

// MARK: – NSVisualEffectView wrapper

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material     = material
        view.blendingMode = blendingMode
        view.state        = .active
        view.wantsLayer   = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: – Processing wave (continuous sine sweep)

/// 10 bars animated by a continuous sine wave that flows left→right.
/// Uses TimelineView for per-frame updates — smooth, no state bookkeeping.
/// Width matches AudioWaveView (≈54pt).
private struct ProcessingWave: View {
    private let barCount = 10
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat   = 3.6   // 10×2 + 9×3.6 = 52.4 ≈ AudioWaveView 54.5
    private let maxH: CGFloat     = 22
    private let minH: CGFloat     = 3

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
        .frame(height: 26)
    }
}
