import AppKit
import CoreGraphics

@MainActor
enum PasteService {
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Pastes `text` into whatever the user was focused on before the pill appeared.
    /// Returns true if the simulated keystroke was sent, false if accessibility is not granted
    /// (text is still placed on the clipboard so the user can Cmd+V manually).
    @discardableResult
    static func paste(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isAccessibilityGranted else {
            // Text is on clipboard — user can paste with Cmd+V
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // Restore previous clipboard after 600ms
        if let previous {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        return true
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
