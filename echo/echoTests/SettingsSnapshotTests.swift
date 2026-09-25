import AppKit
import SwiftUI
import Testing

@testable import echo

/// Renders the real Settings window offscreen to a PNG, for checking UI changes by eye when the
/// app cannot be driven from a script. Writes to `$ECHO_BENCH_OUT/settings-*.png`.
///
/// Never changes the user's settings: it only renders what is already selected.
@Suite(
    "Settings snapshot",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["ECHO_UI_SNAPSHOT"] == nil)
)
@MainActor
struct SettingsSnapshotTests {
    @Test func renderGeneralPane() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = SettingsView(appState: EchoCoordinator.shared.appState)
                .frame(width: 640, height: 720)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(800))

            let bounds = hosting.bounds
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: bounds))
            hosting.cacheDisplay(in: bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let name = appearance == .aqua ? "light" : "dark"
            try png.write(to: BenchOutput.directory.appendingPathComponent("settings-general-\(name).png"))
            window.orderOut(nil)
        }
    }
}
