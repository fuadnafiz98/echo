import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsPane(appState: appState)
            }
            Tab("Words", systemImage: "textformat.abc") {
                WordsSettingsPane()
            }
            Tab("Models", systemImage: "cpu") {
                ModelsSettingsPane(appState: appState)
            }
            Tab("Cloud", systemImage: "cloud") {
                CloudSettingsPane(appState: appState)
            }
            Tab("Stats", systemImage: "chart.bar") {
                StatsSettingsPane()
            }
            Tab("Resources", systemImage: "chart.xyaxis.line") {
                ResourcesSettingsPane()
            }
        }
    }
}

extension View {
    func echoSettingsForm() -> some View {
        formStyle(.grouped)
    }

    func settingsFooter() -> some View {
        lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EchoAppIconHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Echo")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(.none)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var appState: AppState
    @Bindable private var settings = DictationSettings.shared
    @State private var screenCaptureAllowed = BackdropSampler.hasAccess

    var body: some View {
        Form {
            Section {
                LabeledContent("Toggle Recording") {
                    ShortcutRecorder(
                        keyCode: $appState.hotkeyKeyCode,
                        modifiers: $appState.hotkeyModifiers,
                        onChange: { keyCode, modifiers in
                            EchoCoordinator.shared.updateShortcut(keyCode: keyCode, modifiers: modifiers)
                        },
                        onCapturingChange: { capturing in
                            EchoCoordinator.shared.setCapturingShortcut(capturing)
                        }
                    )
                }
            } header: {
                VStack(alignment: .leading, spacing: 16) {
                    EchoAppIconHeader()
                    Text("Dictation")
                }
            } footer: {
                Text("Click the shortcut, then press the keys you want. Press it to start listening, then again to transcribe and paste.")
                    .settingsFooter()
            }

            Section {
                Picker("Active Engine", selection: $appState.selectedEngine) {
                    ForEach(appState.selectableProviders()) { provider in
                        Text(enginePickerTitle(provider)).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .id(appState.selectableProviders().map(\.id))

                if let error = appState.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .settingsFooter()
                }
            } header: {
                Text("Engine")
            } footer: {
                Text(appState.activeProvider.subtitle)
                    .settingsFooter()
            }

            Section {
                LabeledContent {
                    SettingsLink {
                        Text("Open System Settings")
                    }
                    .simultaneousGesture(TapGesture().onEnded(openMicrophoneSettings))
                } label: {
                    Text("Microphone")
                    Text("Required")
                }
                LabeledContent {
                    SettingsLink {
                        Text("Open System Settings")
                    }
                    .simultaneousGesture(TapGesture().onEnded(openSpeechRecognitionSettings))
                } label: {
                    Text("Speech Recognition")
                    Text("Required for Apple")
                }
                LabeledContent {
                    SettingsLink {
                        Text("Open System Settings")
                    }
                    .simultaneousGesture(TapGesture().onEnded(openAccessibilitySettings))
                } label: {
                    Text("Accessibility")
                    Text("Needed to paste")
                }
                LabeledContent {
                    if screenCaptureAllowed {
                        Text("Allowed")
                            .foregroundStyle(.secondary)
                    } else {
                        SettingsLink {
                            Text("Allow")
                        }
                        .simultaneousGesture(TapGesture().onEnded(allowScreenRecording))
                        .accessibilityHint("Lets Echo sample a tiny patch of color behind the listening chip. Echo does not save the image.")
                    }
                } label: {
                    Text("Screen Recording")
                    Text("Optional, for the chip")
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility lets Echo paste into the app you were using. Without it, the transcript stays on the clipboard. Screen Recording is optional: Echo samples a tiny patch of color behind the chip so the waveform stays visible. It does not save the image.")
                    .settingsFooter()
            }

            Section {
                Toggle("Put my clipboard back after paste", isOn: $settings.restoreClipboard)
            } header: {
                Text("Paste")
            } footer: {
                Text("Echo copies the transcript, pastes it, then restores images and formatted text you had copied. Turn this off if a slow app sometimes pastes the old clipboard.")
                    .settingsFooter()
            }

            Section {
                Toggle("Show in menu bar", isOn: $settings.showMenuBar)
                Toggle("Show in Dock", isOn: $settings.showInDock)
            } header: {
                Text("Menu bar & Dock")
            } footer: {
                Text(chromeFooter)
                    .settingsFooter()
            }
        }
        .echoSettingsForm()
        .onAppear {
            screenCaptureAllowed = BackdropSampler.hasAccess
        }
    }

    private var chromeFooter: String {
        if !settings.showMenuBar && !settings.showInDock {
            "Echo stays running. Open it again from Applications or press the dictation shortcut, then use Settings to show the menu bar or Dock."
        } else {
            "Hide the menu bar extra or the Dock icon if you want a quieter desktop. Echo still listens from the dictation shortcut."
        }
    }

    private func enginePickerTitle(_ provider: TranscriptionProviderType) -> String {
        switch provider {
        case .apple: "Apple Speech"
        case .whisper: appState.whisperVariant.displayName
        case .parakeet: appState.parakeetVariant.displayName
        case .deepgram: "Deepgram"
        case .mistral: "Mistral"
        }
    }

    private func openMicrophoneSettings() {
        PasteService.openMicrophoneSettings()
    }

    private func openSpeechRecognitionSettings() {
        PasteService.openSpeechRecognitionSettings()
    }

    private func openAccessibilitySettings() {
        PasteService.openAccessibilitySettings()
    }

    private func allowScreenRecording() {
        screenCaptureAllowed = BackdropSampler.requestAccess()
        if screenCaptureAllowed {
            Task { await BackdropSampler.prewarm() }
        } else {
            PasteService.openScreenRecordingSettings()
        }
    }
}

// MARK: - Words

private struct WordsSettingsPane: View {
    @Bindable private var settings = DictationSettings.shared
    @State private var newWord = ""
    @State private var heard = ""
    @State private var written = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $newWord, prompt: Text("Aim2-core, plot.nt"))
                    .onSubmit(addWord)
                Button("Add Word", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if settings.vocabulary.isEmpty {
                    Text("No custom words yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.vocabulary, id: \.self) { word in
                        VocabularyWordRow(word: word) {
                            settings.removeVocabulary(word)
                        }
                    }
                }
            } header: {
                Text("Words")
            } footer: {
                Text("Type a name once — Aim2-core, plot.nt. Echo builds spoken forms from it, including short ones like m2 or “plot dot n t”.")
                    .settingsFooter()
            }

            Section {
                Toggle("Use names from the frontmost project", isOn: $settings.useFrontmostProject)
            } header: {
                Text("Context")
            } footer: {
                Text("When you dictate into an editor, Echo caches names from that project and the focused file for a few minutes — packages, folders, and identifiers like plot.nt. Those become local replacements, not a long speech prompt. Spoken paths, @handles, and filename extensions are glued on this Mac before paste.")
                    .settingsFooter()
            }

            Section {
                Toggle("Remove um, uh, and other fillers", isOn: $settings.stripFillers)
                Picker("Rewrite with", selection: $settings.cleanupEngine) {
                    Text(CleanupEngine.off.title).tag(CleanupEngine.off)
                    if TranscriptCleaner.shared.appleIntelligenceAvailable {
                        Text(CleanupEngine.appleIntelligence.title).tag(CleanupEngine.appleIntelligence)
                    }
                    if TranscriptCleaner.shared.s1MiniAvailable {
                        Text(CleanupEngine.s1Mini.title).tag(CleanupEngine.s1Mini)
                    }
                }
                .pickerStyle(.menu)
                .id(cleanupEngineAvailability)
            } header: {
                Text("Cleanup")
            } footer: {
                Text(cleanupCaption)
                    .settingsFooter()
            }

            Section {
                TextField("Heard", text: $heard, prompt: Text("aim two core"))
                TextField("Written", text: $written, prompt: Text("Aim2-core"))
                Button("Add Replacement", action: addReplacement)
                    .disabled(
                        heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                ForEach(settings.replacements) { rule in
                    LabeledContent(rule.heard) {
                        HStack(spacing: 8) {
                            Text(rule.written)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Remove") {
                                settings.removeReplacement(id: rule.id)
                            }
                        }
                    }
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Use this when the spoken form is not obvious. You can also type only the spelled name in either field.")
                    .settingsFooter()
            }
        }
        .echoSettingsForm()
        .onChange(of: settings.cleanupEngine) {
            if settings.cleanupEngine != .off {
                TranscriptCleaner.shared.prewarm()
            }
        }
    }

    private var cleanupEngineAvailability: String {
        "\(TranscriptCleaner.shared.appleIntelligenceAvailable)-\(TranscriptCleaner.shared.s1MiniAvailable)"
    }

    private var cleanupCaption: String {
        switch settings.cleanupEngine {
        case .off:
            "Paste uses fillers and replacements only. Apple Intelligence can also rewrite the take — it is not Siri. Filler removal runs on this Mac as soon as the transcript is ready."
        case .appleIntelligence:
            TranscriptCleaner.shared.appleIntelligenceStatus
        case .s1Mini:
            "S1-mini by Superwhisper rewrites the transcript on this Mac. Download a new copy from Models if you remove it."
        }
    }

    private func addWord() {
        settings.addVocabulary(newWord)
        newWord = ""
    }

    private func addReplacement() {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if !from.isEmpty, !to.isEmpty {
            settings.addReplacement(heard: from, written: to)
        } else {
            settings.addVocabulary(from.isEmpty ? to : from)
        }
        heard = ""
        written = ""
    }
}

private struct VocabularyWordRow: View {
    let word: String
    var onRemove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove", action: onRemove)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(word)
                if let caption = SpokenForms.settingsCaption(for: word) {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                BuiltInEngineRow(
                    title: "Apple Speech",
                    detail: "Built-in. On-device, no extra download.",
                    isActive: appState.activeProvider == .apple,
                    onUse: { appState.selectEngine(.apple) }
                )
            } header: {
                Text("On This Mac")
            } footer: {
                Text("Apple is ready immediately. Whisper and Parakeet download onto this Mac and run locally.")
                    .settingsFooter()
            }

            Section("Whisper") {
                ForEach(WhisperVariant.allCases) { variant in
                    LocalModelRow(
                        title: variant.displayName,
                        detail: "\(variant.detail) · \(variant.sizeLabel)",
                        modelID: .whisper(variant),
                        isActive: appState.activeProvider == .whisper && appState.whisperVariant == variant,
                        showsUseButton: true,
                        onUse: { appState.useWhisper(variant) }
                    )
                }
            }

            Section {
                LocalModelRow(
                    title: "S1-mini",
                    detail: "0.6B text normalizer · ~350 MB",
                    readyDetail: "Ready · cleans um, self-corrections, dates",
                    modelID: .s1Mini,
                    isActive: false,
                    showsUseButton: false
                )
            } header: {
                Text("S1-mini by Superwhisper")
            } footer: {
                Text("Cleans the transcript after recognition. Local, about 350 MB. The model must keep this name.")
                    .settingsFooter()
            }

            Section("Parakeet") {
                ForEach(ParakeetVariant.allCases) { variant in
                    LocalModelRow(
                        title: variant.displayName,
                        detail: "\(variant.detail) · \(variant.sizeLabel)",
                        modelID: .parakeet(variant),
                        isActive: appState.activeProvider == .parakeet && appState.parakeetVariant == variant,
                        showsUseButton: true,
                        onUse: { appState.useParakeet(variant) }
                    )
                }
            }
        }
        .echoSettingsForm()
    }
}

private struct BuiltInEngineRow: View {
    let title: String
    let detail: String
    let isActive: Bool
    var onUse: () -> Void

    var body: some View {
        LabeledContent {
            Button(isActive ? "Active" : "Use", action: onUse)
                .disabled(isActive)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LocalModelRow: View {
    let title: String
    let detail: String
    var readyDetail: String?
    let modelID: LocalModelID
    let isActive: Bool
    var showsUseButton = true
    var onUse: (() -> Void)?

    var body: some View {
        let row = ModelLibrary.shared.row(modelID)

        LabeledContent {
            switch row.status {
            case .downloading:
                ProgressView(value: row.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Downloading \(title)")
                    .accessibilityValue("\(Int((row.progress * 100).rounded())) percent")
            case .ready:
                HStack(spacing: 8) {
                    Button("Remove", role: .destructive) {
                        ModelLibrary.shared.delete(modelID)
                    }
                    if showsUseButton, let onUse {
                        Button(isActive ? "Active" : "Use", action: onUse)
                            .disabled(isActive)
                    }
                }
            case .missing, .failed:
                Button("Download") {
                    ModelLibrary.shared.download(modelID)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(row.status == .ready ? (readyDetail ?? detail) : detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = row.error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Cloud

private struct CloudSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("deepgramAPIKey") private var deepgramAPIKey = ""
    @AppStorage("mistralAPIKey") private var mistralAPIKey = ""
    @State private var showDeepgramKey = false
    @State private var showMistralKey = false

    var body: some View {
        Form {
            Section {
                APIKeyField(key: $deepgramAPIKey, revealed: $showDeepgramKey)
                Button(appState.activeProvider == .deepgram ? "Active" : "Use Deepgram") {
                    appState.activeProvider = .deepgram
                }
                .disabled(appState.activeProvider == .deepgram || deepgramAPIKey.isEmpty)
            } header: {
                Text("Deepgram")
            } footer: {
                Text("Sends the finished recording in one request.")
                    .settingsFooter()
            }

            Section {
                APIKeyField(key: $mistralAPIKey, revealed: $showMistralKey)
                Button(appState.activeProvider == .mistral ? "Active" : "Use Mistral") {
                    appState.activeProvider = .mistral
                }
                .disabled(appState.activeProvider == .mistral || mistralAPIKey.isEmpty)
            } header: {
                Text("Mistral")
            } footer: {
                Text("Sends the finished recording in one request.")
                    .settingsFooter()
            }
        }
        .echoSettingsForm()
    }
}

private struct APIKeyField: View {
    @Binding var key: String
    @Binding var revealed: Bool

    var body: some View {
        LabeledContent("API Key") {
            HStack {
                Group {
                    if revealed {
                        TextField("API Key", text: $key)
                    } else {
                        SecureField("API Key", text: $key)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .labelsHidden()

                Button(
                    revealed ? "Hide API Key" : "Show API Key",
                    systemImage: revealed ? "eye.slash" : "eye",
                    action: toggleReveal
                )
                .labelStyle(.iconOnly)
                .help(revealed ? "Hide API Key" : "Show API Key")
            }
        }
    }

    private func toggleReveal() {
        revealed.toggle()
    }
}
