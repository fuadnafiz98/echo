import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    @AppStorage("deepgramAPIKey") private var deepgramAPIKey = ""
    @AppStorage("mistralAPIKey") private var mistralAPIKey = ""
    @State private var isRecordingShortcut = false
    @State private var shortcutDisplay = "Cmd+Shift+Space"

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            providersTab
                .tabItem {
                    Label("Providers", systemImage: "waveform")
                }
        }
        .frame(width: 450, height: 300)
    }

    private var generalTab: some View {
        Form {
            Section("Keyboard Shortcut") {
                HStack {
                    Text("Toggle Recording:")
                    Spacer()

                    Button {
                        isRecordingShortcut = true
                    } label: {
                        Text(isRecordingShortcut ? "Press shortcut..." : shortcutDisplay)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .onKeyPress { keyPress in
                        guard isRecordingShortcut else { return .ignored }
                        // Capture the key press
                        isRecordingShortcut = false
                        shortcutDisplay = formatShortcut(keyPress)
                        return .handled
                    }
                }
            }

            Section("STT Provider") {
                Picker("Active Provider", selection: $appState.activeProvider) {
                    ForEach(TranscriptionProviderType.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
            }
        }
        .padding()
    }

    private var providersTab: some View {
        Form {
            Section("Deepgram") {
                SecureField("API Key", text: $deepgramAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Mistral") {
                SecureField("API Key", text: $mistralAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("ParakeetTDT (Local)") {
                HStack {
                    Text("Model Status:")
                    Spacer()
                    Text("Not Downloaded")
                        .foregroundStyle(.secondary)
                    Button("Download") {
                        // TODO: Implement model download
                    }
                    .disabled(true)
                }
            }
        }
        .padding()
    }

    private func formatShortcut(_ keyPress: KeyPress) -> String {
        var parts: [String] = []
        if keyPress.modifiers.contains(.command) { parts.append("Cmd") }
        if keyPress.modifiers.contains(.shift) { parts.append("Shift") }
        if keyPress.modifiers.contains(.option) { parts.append("Opt") }
        if keyPress.modifiers.contains(.control) { parts.append("Ctrl") }
        parts.append(keyPress.characters.uppercased())
        return parts.joined(separator: "+")
    }
}
