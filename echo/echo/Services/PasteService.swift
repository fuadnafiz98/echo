import AppKit
import CoreGraphics

/// One pasteboard's worth of items, as raw data per type.
typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

@MainActor
enum PasteService {
    private static var restoreTask: Task<Void, Never>?

    /// Per-item cap when snapshotting for restore.
    ///
    /// Copying a large image or a file promise out of the pasteboard takes real time, and doing
    /// it at paste time put that cost between the transcript and the text landing. Anything
    /// bigger than this is not preserved; the transcript still pastes.
    static let maxRestorableBytesPerItem = 4 * 1024 * 1024

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Pastes `text` into whatever the user was focused on before the chip appeared.
    /// Returns true if the simulated keystroke was sent, false if accessibility is not granted
    /// (text is still placed on the clipboard so the user can Cmd+V manually).
    /// Reads the current pasteboard so it can be put back after the paste.
    ///
    /// Call this during the take, not at paste time.
    static func snapshotClipboard() -> ClipboardSnapshot {
        guard DictationSettings.shared.restoreClipboard else { return [] }
        return snapshot(NSPasteboard.general)
    }

    @discardableResult
    static func paste(text: String, previousClipboard: ClipboardSnapshot? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = previousClipboard ?? snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        guard isAccessibilityGranted else {
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        guard DictationSettings.shared.restoreClipboard, !previous.isEmpty else {
            return true
        }

        restoreTask?.cancel()
        restoreTask = Task {
            let deadline = ContinuousClock.now + .milliseconds(2_500)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                if pasteboard.changeCount != changeCount {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard pasteboard.changeCount == changeCount else { return }
            restore(previous, to: pasteboard)
        }

        return true
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openMicrophoneSettings() {
        openPrivacySettings(legacyAnchor: "Privacy_Microphone")
    }

    static func openSpeechRecognitionSettings() {
        openPrivacySettings(legacyAnchor: "Privacy_SpeechRecognition")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings(legacyAnchor: "Privacy_Accessibility")
    }

    private static func openPrivacySettings(legacyAnchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(legacyAnchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(legacyAnchor)",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { continue }
            NSWorkspace.shared.open(url)
            return
        }
        if let settings = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) {
            NSWorkspace.shared.open(settings)
        }
    }

    /// Oversized items are dropped, not recorded as empty.
    ///
    /// An empty payload would still count as "something to restore", and restoring it clears the
    /// pasteboard and writes nothing back — losing both the original content and the transcript.
    /// Returning no items at all leaves the transcript on the clipboard, which is the intent.
    private static func snapshot(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        return items.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            var bytes = 0
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bytes += data.count
                if bytes > maxRestorableBytesPerItem {
                    Latency.note("clipboard item too large to restore — leaving the transcript on the clipboard")
                    return nil
                }
                payload[type] = data
            }
            return payload.isEmpty ? nil : payload
        }
    }

    private static func restore(
        _ snapshot: ClipboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { payload in
            guard !payload.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
