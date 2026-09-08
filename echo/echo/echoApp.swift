import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EchoCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        EchoCoordinator.shared.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task.detached(priority: .utility) {
            await UsageStats.flushPending()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppChrome.applyAtLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Recovery when the extra and Dock icon are hidden: open Settings from Applications.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !DictationSettings.shared.showMenuBar {
            AppDelegate.openSettingsWindow()
        }
        return true
    }

    /// Menu-bar (LSUIElement) apps stay inactive, so `openSettings()` is often a no-op.
    static func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        DispatchQueue.main.async {
            let windows = NSApp.windows.filter { window in
                let id = window.identifier?.rawValue ?? ""
                return id.localizedCaseInsensitiveContains("settings")
                    || window.title.localizedCaseInsensitiveContains("Settings")
                    || window.className.localizedCaseInsensitiveContains("Settings")
            }
            let window = windows.first ?? NSApp.windows.last(where: { $0.canBecomeKey })
            if let window {
                SettingsWindowMetrics.fit(window)
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

enum SettingsWindowMetrics {
    static let minimum = NSSize(width: 800, height: 640)
    static let defaultSize = NSSize(width: 880, height: 860)

    static func fit(_ window: NSWindow) {
        window.minSize = minimum
        var frame = window.frame
        if frame.width < defaultSize.width || frame.height < defaultSize.height {
            frame.size.width = max(frame.width, defaultSize.width)
            frame.size.height = max(frame.height, defaultSize.height)
        }
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.size.width, visible.width)
            frame.size.height = min(frame.size.height, visible.height)
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        window.setFrame(frame, display: true)
    }
}

enum AppChrome {
    @MainActor
    static func applyAtLaunch() {
        applyDockVisibility(DictationSettings.shared.showInDock)
        ProcessInfo.processInfo.disableAutomaticTermination("Echo stays running")
    }

    @MainActor
    static func applyDockVisibility(_ showInDock: Bool) {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

@main
struct echoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        EchoMenuBarScene()

        Settings {
            SettingsView(appState: EchoCoordinator.shared.appState)
                .frame(
                    minWidth: SettingsWindowMetrics.minimum.width,
                    minHeight: SettingsWindowMetrics.minimum.height
                )
        }
        .defaultSize(
            width: SettingsWindowMetrics.defaultSize.width,
            height: SettingsWindowMetrics.defaultSize.height
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}

private struct EchoMenuBarScene: Scene {
    @Bindable private var settings = DictationSettings.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.showMenuBar) {
            MenuBarView(
                appState: EchoCoordinator.shared.appState,
                onToggleRecording: { EchoCoordinator.shared.toggle() }
            )
        } label: {
            Image(nsImage: EchoMenuBarIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("Echo")
        }
    }
}

enum EchoMenuBarIcon {
    static var image: NSImage {
        let named = NSImage(named: "MenuBarWaveform") ?? NSImage()
        let icon = named.copy() as? NSImage ?? named
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }
}
