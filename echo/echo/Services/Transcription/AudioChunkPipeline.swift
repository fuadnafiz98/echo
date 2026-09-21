import Accelerate
import Foundation
import os

nonisolated struct ChunkPipelineFailure: Error {}

/// Transcribes a take in windows while it is still being spoken.
///
/// Whisper and Parakeet are batch recognisers: handed the whole take at stop, their cost is linear
/// in its length, so a long dictation stalls for seconds after the user has stopped talking. This
/// feeds them fixed windows as the audio arrives, so at stop only the final partial window is
/// outstanding.
///
/// Windows are cut at the quietest point near the boundary so a word is rarely split. If any window
/// fails the pipeline marks itself failed and the caller falls back to transcribing the whole take,
/// which is always still available in the collector's snapshot.
nonisolated final class AudioChunkPipeline: @unchecked Sendable {
    /// `(samples, isFinalWindow) -> text`. Calls are serialised; never invoked concurrently.
    typealias Transcribe = @Sendable ([Float], Bool) async throws -> String

    private let windowFrames: Int
    private let boundarySearchFrames: Int
    private let transcribe: Transcribe

    private let lock = NSLock()
    private var pending: [Float] = []
    private var pieces: [String] = []
    private var chain: Task<Void, Never>?
    /// Every window task, so cancelling actually stops the queued ones and not just the newest.
    private var queued: [Task<Void, Never>] = []
    private var failed = false
    private var totalFrames = 0
    private var finished = false

    init(
        windowSeconds: Double,
        boundarySearchSeconds: Double = 1.5,
        transcribe: @escaping Transcribe
    ) {
        windowFrames = Int(windowSeconds * AudioResampler.targetSampleRate)
        boundarySearchFrames = Int(boundarySearchSeconds * AudioResampler.targetSampleRate)
        self.transcribe = transcribe
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalFrames
    }

    /// Whether the pipeline saw essentially all of the captured audio.
    ///
    /// Guards against pasting a transcript that is missing its opening because the pipeline was
    /// installed late. One window of slack absorbs the ordinary raggedness at the very end.
    func sawAtLeast(frames expected: Int) -> Bool {
        guard expected > 0 else { return true }
        let slack = Int(0.75 * AudioResampler.targetSampleRate)
        return frameCount + slack >= expected
    }

    /// Called from the collector's IO queue. Never blocks on recognition.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard !failed, !finished else {
            lock.unlock()
            return
        }
        pending.append(contentsOf: samples)
        totalFrames += samples.count
        guard pending.count >= windowFrames else {
            lock.unlock()
            return
        }
        let cut = Self.cutPoint(
            in: pending,
            preferred: windowFrames,
            searchBack: boundarySearchFrames
        )
        let chunk = Array(pending[0..<cut])
        pending.removeFirst(cut)
        enqueueLocked(chunk, isFinal: false)
        lock.unlock()
    }

    /// Drains the queue, transcribes whatever is left and returns the joined transcript.
    /// Throws ``ChunkPipelineFailure`` if any window failed — transcribe the whole take instead.
    func finish() async throws -> String {
        lock.lock()
        finished = true
        let tail = pending
        pending = []
        let inFlight = chain
        chain = nil
        queued = []
        let alreadyFailed = failed
        lock.unlock()

        await inFlight?.value

        lock.lock()
        let failedDuringDrain = failed
        var collected = pieces
        lock.unlock()

        // A failed *window* means the transcript has a hole in it, so the caller must redo the
        // whole take.
        if alreadyFailed || failedDuringDrain {
            throw ChunkPipelineFailure()
        }

        // A failed *tail* is different: everything before it is already transcribed correctly.
        // Recognisers reject very short audio outright — FluidAudio throws below 0.3 s, and Whisper
        // is prone to hallucinating on a fragment — so a tail that is too short to be speech is
        // dropped rather than allowed to sink the take.
        if !tail.isEmpty {
            if tail.count >= Self.minimumTailFrames {
                do {
                    collected.append(try await transcribe(tail, true))
                } catch {
                    Latency.note("final window failed, keeping the \(collected.count) already transcribed")
                }
            } else if Self.containsSpeech(tail) {
                // Short but audible: pad to the minimum the recognisers accept rather than lose it.
                var padded = tail
                padded.append(contentsOf: [Float](repeating: 0, count: Self.minimumTailFrames - tail.count))
                do {
                    collected.append(try await transcribe(padded, true))
                } catch {
                    Latency.note("padded final window failed, keeping the rest")
                }
            }
        }

        return collected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Abandons any queued work. Safe to call from a cancellation path.
    func cancel() {
        lock.lock()
        finished = true
        failed = true
        pending = []
        let outstanding = queued
        queued = []
        chain = nil
        lock.unlock()
        for task in outstanding {
            task.cancel()
        }
    }

    /// One second. Comfortably above FluidAudio's 0.3 s floor and long enough that Whisper is
    /// not being asked to guess at a fragment.
    private static let minimumTailFrames = Int(AudioResampler.targetSampleRate)

    private static func containsSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        }
        return rms > 0.012
    }

    /// Caller must hold `lock`.
    private func enqueueLocked(_ chunk: [Float], isFinal: Bool) {
        let previous = chain
        // The user ends up waiting on the last of these, so do not let them inherit the
        // background priority of the audio IO queue that enqueued them.
        let task = Task(priority: .userInitiated) { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if self.didFail { return }
            do {
                let text = try await self.transcribe(chunk, isFinal)
                self.lock.lock()
                self.pieces.append(text)
                self.lock.unlock()
            } catch {
                Latency.note("chunked transcription window failed: \(error.localizedDescription)")
                self.lock.lock()
                self.failed = true
                self.lock.unlock()
            }
        }
        chain = task
        queued.append(task)
        if queued.count > 64 {
            queued.removeFirst(queued.count - 64)
        }
    }

    /// Index to cut at: the quietest 20 ms inside the last `searchBack` frames of the window,
    /// so the split lands in a pause rather than mid-word.
    static func cutPoint(in samples: [Float], preferred: Int, searchBack: Int) -> Int {
        let limit = min(preferred, samples.count)
        guard limit > 0 else { return 0 }
        let step = max(Int(AudioResampler.targetSampleRate / 50), 64) // 20 ms
        let start = max(0, limit - searchBack)
        guard limit - start > step * 2 else { return limit }

        var bestIndex = limit
        var bestEnergy = Float.greatestFiniteMagnitude
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = start
            while index + step <= limit {
                var rms: Float = 0
                vDSP_rmsqv(base + index, 1, &rms, vDSP_Length(step))
                if rms < bestEnergy {
                    bestEnergy = rms
                    bestIndex = index + step / 2
                }
                index += step
            }
        }
        return max(1, min(bestIndex, limit))
    }
}
