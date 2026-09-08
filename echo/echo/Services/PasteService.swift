import AppKit
import CoreGraphics

@MainActor
enum PasteService {
    private static var restoreTask: Task<Void, Never>?

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Pastes `text` into whatever the user was focused on before the chip appeared.
    /// Returns true if the simulated keystroke was sent, false if accessibility is not granted
    /// (text is still placed on the clipboard so the user can Cmd+V manually).
    @discardableResult
    static func paste(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = snapshot(pasteboard)

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

    static func openScreenRecordingSettings() {
        openPrivacySettings(legacyAnchor: "Privacy_ScreenCapture")
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

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        return items.map { item in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    payload[type] = data
                }
            }
            return payload
        }
    }

    private static func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
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
