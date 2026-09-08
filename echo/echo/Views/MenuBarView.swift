import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    var onToggleRecording: () -> Void

    @State private var accessibilityGranted = PasteService.isAccessibilityGranted

    var body: some View {
        VStack(spacing: 0) {
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

            Button {
                onToggleRecording()
            } label: {
                HStack {
                    Label(
                        appState.isRecording ? "Stop & Paste" : "Start Listening",
                        systemImage: appState.isRecording ? "stop.fill" : "microphone"
                    )
                    Spacer()
                    Text(ShortcutFormatter.display(
                        keyCode: appState.hotkeyKeyCode,
                        modifiers: appState.hotkeyModifiers
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.phase == .processing)

            Divider()

            Picker("Engine", selection: $appState.selectedEngine) {
                ForEach(appState.selectableProviders()) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .id(appState.selectableProviders().map(\.id))

            Divider()

            if let take = appState.statusMessage, !take.isEmpty {
                Text(Self.truncatedMenuLine(take))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let error = menuError {
                Text(Self.truncatedMenuLine(error))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if showsMenuStatus {
                Divider()
            }

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
            .simultaneousGesture(TapGesture().onEnded {
                AppDelegate.openSettingsWindow()
            })

            Divider()

            Button("Quit Echo") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            refreshAccessibility()
            if appState.phase == .idle {
                appState.clearEmptyTakeError()
            }
        }
    }

    private var menuError: String? {
        guard let error = appState.errorMessage, !error.isEmpty else { return nil }
        guard error != AppState.emptyTakeError else { return nil }
        return error
    }

    private var showsMenuStatus: Bool {
        let hasStatus = appState.statusMessage.map { !$0.isEmpty } ?? false
        return hasStatus || menuError != nil
    }

    private func refreshAccessibility() {
        accessibilityGranted = PasteService.isAccessibilityGranted
    }

    /// NSMenu width follows the longest unwrapped string; never feed it a full take.
    private static func truncatedMenuLine(_ text: String, limit: Int = 52) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
