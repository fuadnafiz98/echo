---
name: macos-native-ui
description: Use when writing or changing any SwiftUI view, window, toolbar, button, toggle, tab, form, sidebar, or Liquid Glass on macOS. Always apply. Never recreate system controls.
---

# macOS Native UI

Always apply on Echo UI work. Echo is a macOS 26.3+ menu-bar dictation app.

## Hard rules

- Never recreate system controls. Use `Button`, `Toggle`, `Picker`, `TabView`, `Form`, `LabeledContent`, `Settings`, `NavigationSplitView`.
- Never draw web-card UI (custom grey boxes, fake inputs, CSS-like stacks).
- Never open or click the Xcode GUI.
- After any UI change: **build → run → screenshot**. If it looks like a web card, rewrite with system controls.

## Liquid Glass

Read [liquid-glass](../liquid-glass/SKILL.md) and [pitfalls](../liquid-glass/references/pitfalls-and-solutions.md) before changing glass.

- Apply `.glassEffect` **after** layout/appearance, on the content, not as a `.background` fill.
- Group nearby glass in `GlassEffectContainer`. Use `@Namespace` + `glassEffectID` when the hierarchy morphs.
- Styles: `.regular` for chrome, `.clear` when the desktop must show through, `.identity` for Reduced Transparency.
- macOS glass buttons: `.buttonStyle(.glass)` plus `.tint(.clear)`.
- Floating `NSPanel` / HUD chips: SwiftUI `.glassEffect` cannot sample the desktop. Host content in `NSGlassEffectView` (`style`, `cornerRadius`, `contentView`) on a clear, non-opaque panel. Keep `NSHostingView.isOpaque = false` and a clear layer.

## Echo surfaces

- Overlay: tiny transparent chip. Wave while listening, spinner while transcribing. No globe, no stop button, no white card.
- Settings: native grouped `Form` + `NavigationSplitView`. Shortcut capture uses `ShortcutRecorder`, not a fake key field.
- Menu bar: `MenuBarExtra` system controls only.

## Build without Xcode

Read [xcodebuildmcp](../xcodebuildmcp/SKILL.md). Prefer XcodeBuildMCP tools.

```
Build: xcodebuild -scheme echo -destination 'platform=macOS'
```

Never use the Xcode GUI. Prefer XcodeBuildMCP tools.
