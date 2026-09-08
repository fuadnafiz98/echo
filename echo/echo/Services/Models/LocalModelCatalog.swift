import Foundation

nonisolated enum TranscriptionProviderType: String, CaseIterable, Identifiable, Sendable {
    case apple
    case whisper
    case parakeet
    case deepgram
    case mistral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .deepgram: "Deepgram"
        case .mistral: "Mistral"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: "On-device system speech. Fast, private, no download."
        case .whisper: "Open-source Whisper via WhisperKit. Core ML on Apple Silicon."
        case .parakeet: "NVIDIA Parakeet via FluidAudio. Same family Handy uses."
        case .deepgram: "Cloud streaming. Requires an API key."
        case .mistral: "Cloud batch transcription. Requires an API key."
        }
    }

    var isLocal: Bool {
        switch self {
        case .apple, .whisper, .parakeet: true
        case .deepgram, .mistral: false
        }
    }
}

nonisolated enum WhisperVariant: String, CaseIterable, Identifiable, Sendable {
    case tinyEn = "tiny.en"
    case baseEn = "base.en"
    case smallEn = "small.en"
    case largeTurbo = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn: "Whisper Tiny (English)"
        case .baseEn: "Whisper Base (English)"
        case .smallEn: "Whisper Small (English)"
        case .largeTurbo: "Whisper Large v3 Turbo"
        }
    }

    var sizeLabel: String {
        switch self {
        case .tinyEn: "75 MB"
        case .baseEn: "145 MB"
        case .smallEn: "466 MB"
        case .largeTurbo: "626 MB"
        }
    }

    var detail: String {
        switch self {
        case .tinyEn: "Fastest. Good for short dictation on M1."
        case .baseEn: "Balanced speed and accuracy."
        case .smallEn: "Higher accuracy, still comfortable on M1."
        case .largeTurbo: "Best quality. Larger download."
        }
    }

    /// Hugging Face tokenizer repo WhisperKit looks up under `downloadBase/models/`.
    var tokenizerRepository: String {
        switch self {
        case .tinyEn: "openai/whisper-tiny.en"
        case .baseEn: "openai/whisper-base.en"
        case .smallEn: "openai/whisper-small.en"
        case .largeTurbo: "openai/whisper-large-v3"
        }
    }
}

nonisolated enum ParakeetVariant: String, CaseIterable, Identifiable, Sendable {
    case v2English = "v2"
    case v3Multilingual = "v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2English: "Parakeet TDT 0.6B v2"
        case .v3Multilingual: "Parakeet TDT 0.6B v3"
        }
    }

    var sizeLabel: String { "~600 MB" }

    var detail: String {
        switch self {
        case .v2English: "English-only. Highest recall, Handy-style default."
        case .v3Multilingual: "25 European languages plus English."
        }
    }
}

nonisolated enum LocalModelID: Hashable, Identifiable, Sendable {
    case whisper(WhisperVariant)
    case parakeet(ParakeetVariant)
    case s1Mini

    var id: String {
        switch self {
        case .whisper(let variant): "whisper.\(variant.rawValue)"
        case .parakeet(let variant): "parakeet.\(variant.rawValue)"
        case .s1Mini: "s1-mini"
        }
    }

    static var all: [LocalModelID] {
        WhisperVariant.allCases.map { .whisper($0) }
            + ParakeetVariant.allCases.map { .parakeet($0) }
            + [.s1Mini]
    }
}

nonisolated enum ModelRowStatus: String, Sendable, Equatable {
    case missing
    case downloading
    case ready
    case failed
}

nonisolated struct ModelRowSnapshot: Sendable, Equatable, Hashable {
    var status: ModelRowStatus
    var progress: Double
    var error: String?

    static let missing = ModelRowSnapshot(status: .missing, progress: 0, error: nil)
}

nonisolated struct ModelTransferError: LocalizedError, Sendable {
    let statusCode: Int?
    let message: String

    init(statusCode: Int? = nil, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    var errorDescription: String? {
        if let statusCode {
            return "Download failed (HTTP \(statusCode)). \(message)"
        }
        return message
    }

    static func from(_ error: Error) -> ModelTransferError {
        if let transfer = error as? ModelTransferError { return transfer }
        if let url = error as? URLError, let code = url.errorUserInfo["statusCode"] as? Int {
            return ModelTransferError(statusCode: code, message: url.localizedDescription)
        }
        let text = error.localizedDescription
        if let http = text.range(of: #"HTTP(?: status)?(?: code)?\s*(\d{3})"#, options: .regularExpression) {
            let digits = text[http].filter(\.isNumber)
            if let code = Int(digits) {
                return ModelTransferError(statusCode: code, message: text)
            }
        }
        return ModelTransferError(message: text)
    }
}
