import SwiftUI

enum RecordingPhase {
    case idle
    case recording
    case processing
}

enum TranscriptionProviderType: String, CaseIterable {
    case apple = "Apple (On-Device)"
    case deepgram = "Deepgram"
    case mistral = "Mistral"
    case parakeet = "ParakeetTDT (Local)"
}

@Observable @MainActor
final class AppState {
    var phase: RecordingPhase = .idle
    var partialTranscript: String = ""
    var audioLevels: [Float] = Array(repeating: 0, count: 16)
    var errorMessage: String?
    var activeProvider: TranscriptionProviderType = .apple

    // Hotkey configuration
    var hotkeyKeyCode: UInt16 = 49 // Space
    var hotkeyModifiers: CGEventFlags = [.maskCommand, .maskShift]

    var isRecording: Bool { phase == .recording }
}
