# Echo

macOS 26.3 menu-bar dictation app. Scheme `echo`. Project `echo/echo.xcodeproj`.

Build: xcodebuild -scheme echo -destination 'platform=macOS'
Never use the Xcode GUI. Prefer XcodeBuildMCP tools.

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## Skills that always apply

- `macos-native-ui` — any SwiftUI view, window, toolbar, button, toggle, tab, form, sidebar, or Liquid Glass. Never recreate system controls.
- `liquid-glass` — Tahoe / iOS 26+ glass APIs, pitfalls, macOS vs iOS.
- `xcodebuildmcp` — build, run, screenshot, inspect. No Xcode window.

After any UI change: build → run → screenshot via XcodeBuildMCP. If it looks like a web card, rewrite with `Button` / `Toggle` / `TabView`.

## Overlay

Tiny transparent chip only: waveform while listening, spinner while transcribing. Host floating glass with `NSGlassEffectView` on a clear `NSPanel`.
