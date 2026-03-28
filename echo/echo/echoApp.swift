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
}

@main
struct echoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "Echo",
            systemImage: EchoCoordinator.shared.appState.isRecording
                ? "waveform.circle.fill"
                : "waveform.circle"
        ) {
            MenuBarView(
                appState: EchoCoordinator.shared.appState,
                onToggleRecording: { EchoCoordinator.shared.toggle() }
            )
        }

        Settings {
            SettingsView(appState: EchoCoordinator.shared.appState)
        }
    }
}
