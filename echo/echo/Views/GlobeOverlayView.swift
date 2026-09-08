#if ECHO_LEGACY_OVERLAYS
import SwiftUI

struct GlobeOverlayView: View {
    @Bindable var appState: AppState
    var onToggle: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            GlobeMetalView(
                energy: appState.rmsEnergy,
                processing: appState.phase == .processing
            )
            .frame(width: 176, height: 176)
            .scaleEffect(1.0 + CGFloat(appState.rmsEnergy) * 0.08)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: appState.rmsEnergy)

            controlPill
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(.black.opacity(0.18)), in: .rect(cornerRadius: 36))
            } else {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .scaleEffect(appeared ? 1 : 0.78)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: appeared)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                appeared = true
            }
        }
    }

    private var controlPill: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if appState.phase == .recording {
                    AudioWaveView(levels: appState.audioLevels)
                        .frame(width: 148, height: 22)
                        .accessibilityLabel("Microphone level")
                } else {
                    Text(appState.engineLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onToggle) {
                Image(systemName: appState.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(appState.phase == .recording ? .white : .primary)
                    .frame(width: 34, height: 34)
                    .background {
                        if #available(macOS 26.0, *), appState.phase != .recording {
                            Circle()
                                .fill(.clear)
                                .glassEffect(.regular.interactive(), in: .circle)
                        } else {
                            Circle()
                                .fill(appState.phase == .recording ? Color.red : Color.primary.opacity(0.12))
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(appState.phase == .processing)
            .accessibilityLabel(appState.phase == .recording ? "Stop and transcribe" : "Start listening")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(minWidth: 280, maxWidth: 340)
        .background {
            if #available(macOS 26.0, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: .capsule)
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var statusLine: String {
        if !appState.partialTranscript.isEmpty {
            return appState.partialTranscript
        }
        return appState.overlayStatus
    }
}
#endif
