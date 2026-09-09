import Testing
@testable import echo

@Suite("Menu bar and Dock chrome")
struct AppChromeSettingsTests {
    @Test func settingsExposeNativeChromeToggles() throws {
        let settings = try AppSource.load("Views/SettingsView.swift")
        #expect(settings.contains("Toggle(\"Show in menu bar\""))
        #expect(settings.contains("Toggle(\"Show in Dock\""))
        #expect(settings.contains("Echo stays running. Open it again from Applications"))
        #expect(settings.contains("Tab(\"Stats\""))
        #expect(settings.contains("Tab(\"Resources\""))
        #expect(!settings.contains("UsageSettingsSection"))
        #expect(!settings.contains("LabeledContent(\"CPU\")"))
        #expect(!settings.contains("LabeledContent(\"Words spoken\")"))
        #expect(!settings.contains("Screen Recording"))
        #expect(!settings.contains("BackdropSampler"))
    }

    @Test func menuBarExtraUsesIsInsertedBinding() throws {
        let app = try AppSource.load("echoApp.swift")
        #expect(app.contains("MenuBarExtra(isInserted: $settings.showMenuBar)"))
        #expect(app.contains("setActivationPolicy"))
        #expect(app.contains("EchoMenuBarIcon.image"))
        #expect(app.contains("MenuBarWaveform"))
    }

    @Test func chromeKeysMatchRestoreClipboardPersistence() throws {
        let source = try AppSource.load("Services/Dictation/DictationSettings.swift")
        #expect(source.contains("showMenuBarKey = \"showMenuBar\""))
        #expect(source.contains("showInDockKey = \"showInDock\""))
        #expect(source.contains("var showMenuBar: Bool?"))
        #expect(source.contains("var showInDock: Bool?"))
        #expect(source.contains("var restoreClipboard: Bool?"))
    }

    @Test func frontmostContextUsesWorkspaceNotScreenPixels() throws {
        let source = try AppSource.load("Services/Dictation/FrontmostContext.swift")
        #expect(source.contains("NSWorkspace.shared.frontmostApplication"))
        #expect(source.contains("AXUIElementCopyAttributeValue"))
        #expect(!source.contains("ScreenCaptureKit"))
        #expect(!source.contains("SCShareableContent"))
        #expect(!source.contains("CGWindowListCreateImage"))
    }

    @Test func overlayDoesNotOpenACaptureSession() throws {
        let panel = try AppSource.load("Windows/FloatingPanelController.swift")
        let coordinator = try AppSource.load("EchoCoordinator.swift")
        #expect(!panel.contains("BackdropSampler"))
        #expect(!panel.contains("ScreenCaptureKit"))
        #expect(!panel.contains("startBackdropSampling"))
        #expect(!coordinator.contains("BackdropSampler"))
        #expect(!coordinator.contains("ScreenCaptureKit"))
    }
}
