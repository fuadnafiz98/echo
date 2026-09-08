import AppKit
import Carbon
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: CGEventFlags
    var onChange: (UInt16, CGEventFlags) -> Void
    var onCapturingChange: (Bool) -> Void = { _ in }

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            setCapturing(!capturing)
        } label: {
            Text(capturing ? "Press keys…" : ShortcutFormatter.display(keyCode: keyCode, modifiers: modifiers))
                .font(.body.monospaced())
                .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Toggle Recording shortcut")
        .help("Click, then press the shortcut you want. Esc cancels.")
        .onDisappear {
            setCapturing(false)
        }
    }

    private func setCapturing(_ active: Bool) {
        capturing = active
        onCapturingChange(active)
        if active {
            startMonitor()
        } else {
            stopMonitor()
        }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                setCapturing(false)
                return nil
            }

            let flags = ShortcutFormatter.cgFlags(from: event.modifierFlags)
            guard ShortcutFormatter.isUsable(keyCode: event.keyCode, modifiers: flags) else {
                return nil
            }

            keyCode = event.keyCode
            modifiers = flags
            onChange(event.keyCode, flags)
            setCapturing(false)
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

enum ShortcutFormatter {
    static func display(keyCode: UInt16, modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        parts.append(keyName(keyCode))
        return parts.joined()
    }

    static func isUsable(keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
        let hasModifier = modifiers.contains(.maskCommand)
            || modifiers.contains(.maskControl)
            || modifiers.contains(.maskAlternate)
            || modifiers.contains(.maskShift)
        return hasModifier && !isModifierOnly(keyCode)
    }

    static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    private static func isModifierOnly(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return keyNameFromCarbon(keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func keyNameFromCarbon(_ keyCode: UInt16) -> String? {
        var keys = [UniChar](repeating: 0, count: 4)
        var length = 0
        var deadKey: UInt32 = 0
        let keyboard = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { pointer -> String? in
            guard let layout = pointer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKey,
                4,
                &length,
                &keys
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: keys, count: Int(length)).uppercased()
        }
    }
}
