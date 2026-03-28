import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    var onToggleRecording: () -> Void

    @Environment(\.openSettings) private var openSettings

    private var accessibilityGranted: Bool { PasteService.isAccessibilityGranted }

    var body: some View {
        VStack(spacing: 0) {
            // Accessibility warning banner
            if !accessibilityGranted {
                Button {
                    PasteService.openAccessibilitySettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Accessibility Required")
                                .font(.caption.bold())
                            Text("Tap to open System Settings")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Divider()
            }

            // Record toggle
            Button {
                onToggleRecording()
            } label: {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .foregroundStyle(appState.isRecording ? .red : .primary)
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                    Text("⇧⌘Space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.phase == .processing)

            Divider()

            // Provider picker
            Picker("Provider", selection: $appState.activeProvider) {
                ForEach(TranscriptionProviderType.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }

            Divider()

            // Error message
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                Divider()
            }

            Button("Settings...") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Echo") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
