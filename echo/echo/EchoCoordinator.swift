import SwiftUI

@Observable @MainActor
final class EchoCoordinator {
    static let shared = EchoCoordinator()

    let appState = AppState()
    private let hotkeyService = HotkeyService()
    private let audioEngine = AudioEngineService()
    private let transcriptionService = TranscriptionService()
    private let panelController = FloatingPanelController()

    func start() {
        hotkeyService.configure(
            keyCode: appState.hotkeyKeyCode,
            modifiers: appState.hotkeyModifiers,
            onToggle: { [weak self] in
                self?.toggle()
            }
        )

        audioEngine.onAudioLevels = { [weak self] levels in
            self?.appState.audioLevels = levels
        }

        audioEngine.onAudioBuffer = { [weak self] buffer in
            self?.transcriptionService.appendBuffer(buffer)
        }

        transcriptionService.onPartialTranscript = { [weak self] text in
            self?.appState.partialTranscript = text
        }

        hotkeyService.start()

        // Prompt for Accessibility permission (needed for paste simulation)
        if !PasteService.isAccessibilityGranted {
            PasteService.requestAccessibility()
        }
    }

    func stop() {
        hotkeyService.stop()
    }

    func toggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            break // Debounce
        }
    }

    private func startRecording() {
        appState.partialTranscript = ""
        appState.audioLevels = Array(repeating: 0, count: 16)

        // Show panel FIRST in idle state so the entrance animation triggers
        panelController.show(appState: appState)

        // Tiny delay so the panel is on screen before the spring animation fires
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            appState.phase = .recording
        }

        do {
            try audioEngine.start()
        } catch {
            appState.errorMessage = "Failed to start audio: \(error.localizedDescription)"
            appState.phase = .idle
            panelController.hide()
            return
        }

        Task {
            do {
                try await transcriptionService.startStreaming(providerType: appState.activeProvider)
            } catch {
                appState.errorMessage = "Transcription error: \(error.localizedDescription)"
                audioEngine.stop()
                appState.phase = .idle
                panelController.hide()
            }
        }
    }

    private func stopRecording() {
        appState.phase = .processing
        audioEngine.stop()

        Task {
            let start = ContinuousClock.now

            do {
                let text = try await transcriptionService.stopStreaming()

                // Keep the processing state visible for at least 600ms
                let elapsed = ContinuousClock.now - start
                if elapsed < .milliseconds(600) {
                    try? await Task.sleep(for: .milliseconds(600) - elapsed)
                }

                if !text.isEmpty {
                    PasteService.paste(text: text)
                }
            } catch {
                appState.errorMessage = "Failed to get transcription: \(error.localizedDescription)"
            }

            appState.phase = .idle
            appState.partialTranscript = ""
            appState.audioLevels = Array(repeating: 0, count: 16)
            panelController.hide()
        }
    }
}
