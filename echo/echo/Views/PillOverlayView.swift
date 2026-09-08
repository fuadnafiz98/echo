#if ECHO_LEGACY_OVERLAYS
import SwiftUI

struct PillOverlayView: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if appState.phase == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
            } else {
                AudioWaveView(levels: appState.audioLevels, barHeight: 16, tint: .primary)
                    .frame(width: 84)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ClearHostingBackground())
        .animation(.easeInOut(duration: 0.16), value: appState.phase)
    }
}

/// Walks up the AppKit hierarchy and clears the default NSHostingView fill
/// that otherwise paints an opaque dark slab over Liquid Glass.
private struct ClearHostingBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        var node: NSView? = view
        while let current = node {
            current.wantsLayer = true
            current.layer?.isOpaque = false
            current.layer?.backgroundColor = .clear
            node = current.superview
        }
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
    }
}
#endif
