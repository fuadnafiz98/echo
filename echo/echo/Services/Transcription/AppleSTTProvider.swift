import AVFoundation
import Speech

final class AppleSTTProvider: TranscriptionProvider, @unchecked Sendable {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var lastTranscript: String = ""
    private var finalContinuation: CheckedContinuation<String, Never>?

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        lastTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't force on-device — let the system pick the fastest available model
        request.requiresOnDeviceRecognition = false

        self.recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.lastTranscript = text
                self.partialContinuation?.yield(text)

                if result.isFinal {
                    self.partialContinuation?.finish()
                    self.finalContinuation?.resume(returning: text)
                    self.finalContinuation = nil
                }
            }

            if error != nil {
                self.partialContinuation?.finish()
                self.finalContinuation?.resume(returning: self.lastTranscript)
                self.finalContinuation = nil
            }
        }
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopStreaming() async throws -> String {
        recognitionRequest?.endAudio()

        // Wait for final result with timeout
        let finalText: String = await withCheckedContinuation { continuation in
            self.finalContinuation = continuation

            // Timeout after 3 seconds — return whatever we have
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                if let cont = self.finalContinuation {
                    cont.resume(returning: self.lastTranscript)
                    self.finalContinuation = nil
                }
            }
        }

        cleanup()
        return finalText
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        partialContinuation?.finish()
        partialContinuation = nil
        finalContinuation = nil
    }
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case noResult

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition not authorized."
        case .recognizerUnavailable: "Speech recognizer is unavailable."
        case .noResult: "No transcription result received."
        }
    }
}
