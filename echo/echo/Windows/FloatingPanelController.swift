import AppKit

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private var chipView: OverlayChipView?
    private weak var glassView: NSGlassEffectView?
    private var currentSize = OverlayChipView.chipSize
    private var observeTask: Task<Void, Never>?
    private var backdropTask: Task<Void, Never>?
    var levelsProvider: (() -> [Float])?

    func prewarm() {
        guard panel == nil else { return }
        let built = makePanel()
        positionPanel(built.panel)
        built.panel.alphaValue = 0
        built.panel.orderFront(nil)
        built.panel.orderOut(nil)
        self.panel = built.panel
        self.chipView = built.chip
        self.glassView = built.glass
        self.currentSize = OverlayChipView.chipSize
    }

    func show(appState: AppState) {
        if panel == nil {
            prewarm()
        }
        guard let panel else { return }

        positionPanel(panel)
        panel.alphaValue = 1
        panel.orderFront(nil)
        startObserving(appState)
        startBackdropSampling()
    }

    func hide() {
        observeTask?.cancel()
        observeTask = nil
        stopBackdropSampling()
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        currentSize = OverlayChipView.chipSize
        if let panel {
            applyGeometry(OverlayChipView.chipSize, on: panel)
        }
        chipView?.isProcessing = false
        chipView?.levels = Array(repeating: 0, count: OverlayMetrics.barCount)
    }

    func stopBackdropSampling() {
        backdropTask?.cancel()
        backdropTask = nil
    }

    private func makePanel() -> (panel: NSPanel, chip: OverlayChipView, glass: NSGlassEffectView) {
        let size = OverlayChipView.chipSize
        let frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let chip = OverlayChipView(frame: frame)
        chip.autoresizingMask = [.width, .height]

        // Glass is the window. Do not wantsLayer / masksToBounds / fill it —
        // that flattens Liquid Glass into a charcoal plate.
        let glass = NSGlassEffectView(frame: frame)
        glass.style = .clear
        glass.cornerRadius = size.height / 2
        glass.tintColor = nil
        // Light HUD recipe — darkAqua glass reads as a charcoal plate on dark pages.
        glass.appearance = NSAppearance(named: .aqua)
        glass.contentView = chip

        panel.contentView = glass
        panel.setContentSize(size)
        return (panel, chip, glass)
    }

    private func startObserving(_ appState: AppState) {
        observeTask?.cancel()
        apply(appState)
        observeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.apply(appState)
                let interval: Duration = appState.phase == .recording
                    ? .milliseconds(42)
                    : .milliseconds(120)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func apply(_ appState: AppState) {
        let processing = appState.phase == .processing
        if chipView?.isProcessing != processing {
            chipView?.isProcessing = processing
            resize(forProcessing: processing)
        }
        if !processing {
            chipView?.levels = levelsProvider?() ?? appState.audioLevels
        }
    }

    private func startBackdropSampling() {
        backdropTask?.cancel()
        backdropTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            await self?.refreshBackdrop()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1600))
                guard !Task.isCancelled else { return }
                await self?.refreshBackdrop()
            }
        }
    }

    private func refreshBackdrop() async {
        guard let panel, let chipView else { return }
        if let isDark = await BackdropSampler.isDark(below: panel) {
            chipView.backdropIsDark = isDark
        }
    }

    private func resize(forProcessing isProcessing: Bool) {
        let targetSize = isProcessing ? OverlayChipView.processingSize : OverlayChipView.chipSize
        guard targetSize != currentSize, let panel else { return }

        currentSize = targetSize
        let frame = centeredFrame(for: targetSize, from: panel.frame)
        panel.setFrame(frame, display: true)
        applyGeometry(targetSize, on: panel)
    }

    private func applyGeometry(_ size: NSSize, on panel: NSPanel) {
        panel.setContentSize(size)
        let frame = NSRect(origin: .zero, size: size)
        let corner = size.height / 2
        glassView?.frame = frame
        glassView?.cornerRadius = corner
        chipView?.frame = frame
    }

    private func centeredFrame(for size: NSSize, from frame: NSRect) -> NSRect {
        NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let sf = screen.visibleFrame
        let pw = panel.frame.size
        let x = sf.origin.x + (sf.width - pw.width) / 2
        let y = sf.origin.y + 56

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
