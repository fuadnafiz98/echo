import AppKit
import SwiftUI

// MARK: – Transparent hosting view

/// NSHostingView.isOpaque returns true by default, which tells the macOS
/// window server to SKIP compositing anything behind this view.  That single
/// property is why blur, glass and material effects appear opaque.
/// Overriding it to false enables the compositor path that glassEffect and
/// NSVisualEffectView need to show the desktop through the window.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }
}

// MARK: – Panel controller

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private var hostingView: TransparentHostingView<PillOverlayView>?
    private var hideTask: Task<Void, Never>?

    func show(appState: AppState) {
        if let existing = panel {
            existing.orderFront(nil)
            return
        }

        hideTask?.cancel()
        hideTask = nil

        let pillView = PillOverlayView(appState: appState)
        let hosting = TransparentHostingView(rootView: pillView)

        // Measure SwiftUI's natural size
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        let fit = hosting.fittingSize
        let w   = max(fit.width,  80)
        let h   = max(fit.height, 32)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel      = true
        panel.level                = .floating
        panel.backgroundColor      = .clear
        panel.isOpaque             = false
        panel.hasShadow            = false
        panel.hidesOnDeactivate    = false
        panel.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        panel.contentView = hosting
        hosting.frame = panel.contentView?.bounds ?? .zero

        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFront(nil)

        self.panel       = panel
        self.hostingView = hosting

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }

        let capturedPanel = panel
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            capturedPanel.orderOut(nil)
            if self?.panel === capturedPanel {
                self?.panel       = nil
                self?.hostingView = nil
            }
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let sf = screen.visibleFrame
        let pw = panel.frame.size
        let x  = sf.origin.x + (sf.width  - pw.width)  / 2
        let y  = sf.origin.y + 20

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
