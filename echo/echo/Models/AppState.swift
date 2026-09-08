import SwiftUI

enum RecordingPhase {
    case idle
    case recording
    case processing
}

@Observable @MainActor
final class AppState {
    var phase: RecordingPhase = .idle
    var partialTranscript: String = ""
    var audioLevels: [Float] = Array(repeating: 0, count: OverlayMetrics.barCount)
    var errorMessage: String?
    var statusMessage: String?

    /// Empty-take copy. The menu extra must not keep this after idle — it looks like Echo is listening now.
    static let emptyTakeError = "Heard nothing. Try again a little closer to the mic."

    @ObservationIgnored
    private var emptyTakeDismissTask: Task<Void, Never>?

    var activeProvider: TranscriptionProviderType {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: "activeProvider") }
    }

    var whisperVariant: WhisperVariant {
        didSet { UserDefaults.standard.set(whisperVariant.rawValue, forKey: "whisperVariant") }
    }

    var parakeetVariant: ParakeetVariant {
        didSet { UserDefaults.standard.set(parakeetVariant.rawValue, forKey: "parakeetVariant") }
    }

    var hotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: CGEventFlags {
        didSet { UserDefaults.standard.set(hotkeyModifiers.rawValue, forKey: "hotkeyModifiers") }
    }

    var isRecording: Bool { phase == .recording }

    var rmsEnergy: Float {
        audioLevels.max() ?? 0
    }

    var engineLabel: String {
        switch activeProvider {
        case .apple: "Apple"
        case .whisper: whisperVariant.displayName
        case .parakeet: parakeetVariant.displayName
        case .deepgram: "Deepgram"
        case .mistral: "Mistral"
        }
    }

    var overlayStatus: String {
        switch phase {
        case .idle: "Ready"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    init() {
        let provider = UserDefaults.standard.string(forKey: "activeProvider")
            .flatMap(TranscriptionProviderType.init(rawValue:)) ?? .apple
        activeProvider = provider
        whisperVariant = UserDefaults.standard.string(forKey: "whisperVariant")
            .flatMap(WhisperVariant.init(rawValue:)) ?? .baseEn
        parakeetVariant = UserDefaults.standard.string(forKey: "parakeetVariant")
            .flatMap(ParakeetVariant.init(rawValue:)) ?? .v2English

        if let storedCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int {
            hotkeyKeyCode = UInt16(storedCode)
        } else {
            hotkeyKeyCode = 49
        }

        if let storedMods = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt64 {
            hotkeyModifiers = CGEventFlags(rawValue: storedMods)
        } else {
            hotkeyModifiers = [.maskCommand, .maskShift]
        }
    }

    var selectedEngine: TranscriptionProviderType {
        get { activeProvider }
        set { selectEngine(newValue) }
    }

    func canSelect(_ type: TranscriptionProviderType) -> Bool {
        let library = ModelLibrary.shared
        switch type {
        case .apple:
            return true
        case .whisper:
            return library.firstReadyWhisper() != nil
        case .parakeet:
            return library.firstReadyParakeet() != nil
        case .deepgram:
            return !(UserDefaults.standard.string(forKey: "deepgramAPIKey") ?? "").isEmpty
        case .mistral:
            return !(UserDefaults.standard.string(forKey: "mistralAPIKey") ?? "").isEmpty
        }
    }

    func selectableProviders() -> [TranscriptionProviderType] {
        TranscriptionProviderType.allCases.filter { canSelect($0) || $0 == activeProvider }
    }

    func selectEngine(_ type: TranscriptionProviderType) {
        switch type {
        case .apple, .deepgram, .mistral:
            guard canSelect(type) else {
                errorMessage = type == .apple
                    ? nil
                    : TranscriptionError.missingAPIKey.errorDescription
                return
            }
            activeProvider = type
            EchoCoordinator.shared.prewarmAfterUse(type)

        case .whisper:
            let library = ModelLibrary.shared
            if library.isReady(.whisper(whisperVariant)) {
                activeProvider = .whisper
                EchoCoordinator.shared.prewarmAfterUse(.whisper)
                return
            }
            if let ready = library.firstReadyWhisper() {
                whisperVariant = ready
                activeProvider = .whisper
                EchoCoordinator.shared.prewarmAfterUse(.whisper)
                return
            }
            errorMessage = TranscriptionError.modelNotDownloaded.errorDescription

        case .parakeet:
            let library = ModelLibrary.shared
            if library.isReady(.parakeet(parakeetVariant)) {
                activeProvider = .parakeet
                EchoCoordinator.shared.prewarmAfterUse(.parakeet)
                return
            }
            if let ready = library.firstReadyParakeet() {
                parakeetVariant = ready
                activeProvider = .parakeet
                EchoCoordinator.shared.prewarmAfterUse(.parakeet)
                return
            }
            errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
        }
    }

    func useWhisper(_ variant: WhisperVariant) {
        guard ModelLibrary.shared.isReady(.whisper(variant)) else {
            errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            return
        }
        whisperVariant = variant
        activeProvider = .whisper
        EchoCoordinator.shared.prewarmAfterUse(.whisper)
    }

    func useParakeet(_ variant: ParakeetVariant) {
        guard ModelLibrary.shared.isReady(.parakeet(variant)) else {
            errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            return
        }
        parakeetVariant = variant
        activeProvider = .parakeet
        EchoCoordinator.shared.prewarmAfterUse(.parakeet)
    }

    func presentEmptyTakeError() {
        errorMessage = Self.emptyTakeError
        emptyTakeDismissTask?.cancel()
        emptyTakeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if errorMessage == Self.emptyTakeError {
                errorMessage = nil
            }
        }
    }

    func clearEmptyTakeError() {
        guard errorMessage == Self.emptyTakeError else { return }
        emptyTakeDismissTask?.cancel()
        emptyTakeDismissTask = nil
        errorMessage = nil
    }

    func isLocalEngineReady() -> Bool {
        switch activeProvider {
        case .apple, .deepgram, .mistral:
            return true
        case .whisper:
            return ModelLibrary.shared.isReady(.whisper(whisperVariant))
        case .parakeet:
            return ModelLibrary.shared.isReady(.parakeet(parakeetVariant))
        }
    }

    func repairEngineIfNeeded() {
        switch activeProvider {
        case .whisper where !ModelLibrary.shared.isReady(.whisper(whisperVariant)):
            if let ready = ModelLibrary.shared.firstReadyWhisper() {
                whisperVariant = ready
            } else {
                activeProvider = .apple
                errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            }
        case .parakeet where !ModelLibrary.shared.isReady(.parakeet(parakeetVariant)):
            if let ready = ModelLibrary.shared.firstReadyParakeet() {
                parakeetVariant = ready
            } else {
                activeProvider = .apple
                errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            }
        default:
            break
        }
    }
}
