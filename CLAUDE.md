# Echo

macOS 26.3 menu-bar dictation app. Scheme `echo`. Project `echo/echo.xcodeproj`.

Build: xcodebuild -scheme echo -destination 'platform=macOS'
Never use the Xcode GUI. Prefer XcodeBuildMCP tools.

Load these skills on every UI or build task (do not wait to be named):

- `.claude/skills/macos-native-ui/SKILL.md`
- `.claude/skills/liquid-glass/SKILL.md`
- `.claude/skills/xcodebuildmcp/SKILL.md`

Plugin: `liquid-glass@liquid-glass-skills`. MCP: `xcodebuildmcp` in `.mcp.json`.

After any UI change: build → run → screenshot. If it looks like a web card, rewrite with `Button` / `Toggle` / `TabView`.
