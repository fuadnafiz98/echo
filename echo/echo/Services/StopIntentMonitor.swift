import CoreGraphics
import Foundation
import Synchronization

/// Notices the user reaching for the stop shortcut.
///
/// Stopping with ⌘⇧Space means ⌘ and ⇧ go down 100–300 ms before Space. Polling the modifier
/// state during a take turns that into a head start: the tail can be decoded while the finger is
/// still on its way to Space, so the stop itself finds the work done.
///
/// Polls `CGEventSource.flagsState`, which needs no Input Monitoring or Accessibility permission,
/// every 25 ms and only while a take is recording. A false alarm (⌘⇧ for some other shortcut)
/// costs one speculative decode.
nonisolated final class StopIntentMonitor: Sendable {
    static let pollInterval: DispatchTimeInterval = .milliseconds(25)

    private static let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private struct State {
        var timer: DispatchSourceTimer?
        var armed = true
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "echo.stop-intent", qos: .userInitiated)

    /// Starts watching for `modifiers`. Does nothing for a shortcut without modifiers.
    func start(modifiers: CGEventFlags, onIntent: @escaping @Sendable () -> Void) {
        let wanted = modifiers.intersection(Self.relevant)
        stop()
        guard !wanted.isEmpty else { return }
        // Modifiers still held from the start shortcut must be released before a press counts.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        state.withLock { $0.armed = false }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let held = CGEventSource.flagsState(.combinedSessionState).intersection(Self.relevant)
            let fire = self.state.withLock { s -> Bool in
                if held.isSuperset(of: wanted) {
                    guard s.armed else { return false }
                    s.armed = false
                    return true
                }
                if held.isEmpty { s.armed = true }
                return false
            }
            if fire { onIntent() }
        }
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(5))
        state.withLock { $0.timer = timer }
        timer.resume()
    }

    func stop() {
        let timer = state.withLock { s -> DispatchSourceTimer? in
            let timer = s.timer
            s.timer = nil
            return timer
        }
        timer?.cancel()
    }

    deinit {
        stop()
    }
}
