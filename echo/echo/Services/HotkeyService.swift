import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    static var shared: HotkeyService?

    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var keyCode: UInt32 = 49                                      // Space
    var modifiers: UInt32 = UInt32(cmdKey) | UInt32(shiftKey)

    func configure(
        keyCode: UInt16,
        modifiers: CGEventFlags,
        onToggle: @escaping () -> Void
    ) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = carbonModifiers(from: modifiers)
        self.onToggle = onToggle
    }

    @discardableResult
    func start() -> Bool {
        HotkeyService.shared = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Use an explicit @convention(c) closure — bypasses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
        // which would otherwise prevent a plain func from being used as a C function pointer.
        let cCallback: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                HotkeyService.shared?.onToggle?()
            }
            return noErr
        }

        let appTarget = GetApplicationEventTarget()
        let status = InstallEventHandler(
            appTarget,
            cCallback,
            1, &spec,
            nil, &handlerRef
        )

        guard status == noErr else {
            print("[Echo] InstallEventHandler failed: \(status)")
            return false
        }

        return registerCurrentHotKey()
    }

    func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
        HotkeyService.shared = nil
    }

    func updateShortcut(keyCode: UInt16, modifiers: CGEventFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = carbonModifiers(from: modifiers)
        _ = registerCurrentHotKey()
    }

    private func registerCurrentHotKey() -> Bool {
        if let old = hotKeyRef { UnregisterEventHotKey(old); hotKeyRef = nil }

        let hotKeyID = EventHotKeyID(signature: 0x4543_484F /* ECHO */, id: 1)
        let regStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if regStatus != noErr {
            print("[Echo] RegisterEventHotKey failed: \(regStatus)")
        }
        return regStatus == noErr
    }

    private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand)   { result |= UInt32(cmdKey) }
        if flags.contains(.maskShift)     { result |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl)   { result |= UInt32(controlKey) }
        return result
    }
}

