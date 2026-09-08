import AppKit
import ApplicationServices

enum DictationAppKind: String {
    case editor
    case mail
    case browser
    case chat
    case other

    var polishContext: String {
        switch self {
        case .mail: "email"
        case .chat: "general"
        case .editor, .browser, .other: "general"
        }
    }
}

struct DictationScene: Sendable {
    var kind: DictationAppKind
    var appName: String
    var bundleID: String
    var windowTitle: String
    var projectRoot: URL?
    var projectTerms: [String]
}

enum FrontmostContext {
    @MainActor
    static func capture(scanProject: Bool) async -> DictationScene {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let appName = app?.localizedName ?? "Unknown"
        let kind = classify(bundleID: bundleID)
        let pid = app?.processIdentifier

        return await Task.detached(priority: .userInitiated) {
            let window = focusedWindow(pid: pid)
            let title = window.title
            let document = window.documentURL

            var root: URL?
            var terms: [String] = []
            if scanProject, kind == .editor {
                if let document {
                    root = ProjectLexicon.root(containing: document)
                }
                if root == nil, let inferred = projectName(from: title) {
                    terms.append(inferred)
                }
                if let root {
                    terms.append(contentsOf: ProjectLexicon.terms(at: root, focusedFile: document))
                } else if let document {
                    terms.append(contentsOf: ProjectLexicon.fileTerms(for: document))
                }
            }

            return DictationScene(
                kind: kind,
                appName: appName,
                bundleID: bundleID,
                windowTitle: title,
                projectRoot: root,
                projectTerms: Array(Set(terms)).sorted()
            )
        }.value
    }

    private static func classify(bundleID: String) -> DictationAppKind {
        let id = bundleID.lowercased()
        if id.contains("cursor") || id.contains("todesktop") { return .editor }
        if editorIDs.contains(where: { id.hasPrefix($0) || id == $0 }) { return .editor }
        if id.contains("mail") || id.contains("outlook") { return .mail }
        if id.contains("safari") || id.contains("chrome") || id.contains("firefox")
            || id.contains("orion") || id.contains("arc") || id.contains("brave") {
            return .browser
        }
        if id.contains("slack") || id.contains("discord") || id.contains("telegram")
            || id.contains("messages") || id.contains("whatsapp") {
            return .chat
        }
        return .other
    }

    private static let editorIDs = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.zed",
        "com.jetbrains",
        "com.google.android.studio",
        "com.apple.dt.iphone-simulator",
    ]

    nonisolated private static func focusedWindow(pid: pid_t?) -> (title: String, documentURL: URL?) {
        guard let pid, AXIsProcessTrusted() else { return ("", nil) }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused
        else { return ("", nil) }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &docRef)
        let document: URL?
        if let string = docRef as? String {
            document = URL(string: string) ?? URL(fileURLWithPath: string)
        } else {
            document = nil
        }
        return (title, document)
    }

    nonisolated private static func projectName(from title: String) -> String? {
        let separators = [" — ", " – ", " - ", " | "]
        let appSuffixes: Set<String> = [
            "Cursor", "Visual Studio Code", "Code", "Xcode", "Zed", "Zed Preview",
            "Windsurf", "Antigravity", "IntelliJ IDEA", "WebStorm", "Android Studio",
        ]
        for separator in separators {
            let parts = title.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            var candidate = parts.last ?? ""
            if appSuffixes.contains(candidate), parts.count >= 2 {
                candidate = parts[parts.count - 2]
            }
            if !candidate.isEmpty, candidate.count < 48, !candidate.contains("/") {
                return candidate
            }
        }
        return nil
    }
}

nonisolated enum ProjectLexicon {
    private static let cacheTTL: TimeInterval = 5 * 60
    private static let cacheLock = NSLock()
    private static var rootCache: [String: (terms: [String], at: Date)] = [:]
    private static var fileCache: [String: (terms: [String], at: Date, mtime: Date?)] = [:]

    private static let skipFolders: Set<String> = [
        "node_modules", "DerivedData", ".git", "build", "Pods", ".build",
        "xcuserdata", "dist", "coverage", ".next", ".turbo", "target",
        "vendor", "__pycache__",
    ]

    private static let noisyFiles: Set<String> = [
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        "tsconfig.json", "readme.md", "cargo.toml", "cargo.lock",
        "package.swift", "package.resolved", ".gitignore", "license",
        "makefile", "changelog.md",
    ]

    private static let textExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rs",
        "rb", "kt", "java", "m", "mm", "h", "c", "cpp", "cc", "cs", "json",
        "md", "graphql", "gql", "sql", "toml", "yml", "yaml", "nt", "proto",
        "vue", "svelte", "xml", "plist", "sh", "txt",
    ]

    private static let camelRegex = try? NSRegularExpression(
        pattern: #"[A-Z][a-z]+(?:[A-Z][a-z0-9]+)+"#
    )
    private static let snakeRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+"#
    )
    private static let dottedRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z][\w-]*\.[A-Za-z0-9]{1,12}"#
    )
    private static let alnumRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z]{2,}[0-9][A-Za-z0-9]*"#
    )
    private static let packageNameRegex = try? NSRegularExpression(
        pattern: #"name:\s*"([^"]+)""#
    )
    private static let identityRegex = try? NSRegularExpression(
        pattern: #""identity"\s*:\s*"([^"]+)""#
    )

    static func root(containing url: URL) -> URL? {
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if dir.isFileURL, dir.path.hasPrefix("file:") {
            dir = URL(fileURLWithPath: dir.path)
        }
        let fm = FileManager.default
        for _ in 0..<10 {
            if isProjectRoot(dir, fileManager: fm) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func isProjectRoot(_ dir: URL, fileManager fm: FileManager) -> Bool {
        let markers = [".git", "Package.swift", "package.json", "Cargo.toml"]
        if markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            return true
        }
        let name = dir.lastPathComponent
        let known = [
            "\(name).xcodeproj",
            "\(name).xcworkspace",
            "echo.xcodeproj",
        ]
        return known.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    static func terms(at root: URL, focusedFile: URL?) -> [String] {
        var terms = cachedRootTerms(root)
        if let focusedFile {
            terms.append(contentsOf: fileTerms(for: focusedFile))
        }
        return uniqued(terms, cap: 48)
    }

    static func fileTerms(for url: URL) -> [String] {
        var terms: [String] = []
        let name = url.lastPathComponent
        if isUsefulFilename(name) {
            terms.append(name)
        }
        terms.append(contentsOf: cachedFileIdentifiers(url))
        return uniqued(terms, cap: 28)
    }

    private static func cachedRootTerms(_ root: URL) -> [String] {
        let key = root.standardizedFileURL.path
        cacheLock.lock()
        if let hit = rootCache[key], Date().timeIntervalSince(hit.at) < cacheTTL {
            let terms = hit.terms
            cacheLock.unlock()
            return terms
        }
        cacheLock.unlock()

        let terms = scanRoot(root)
        cacheLock.lock()
        if rootCache.count > 8 {
            rootCache.removeAll(keepingCapacity: true)
        }
        rootCache[key] = (terms, Date())
        cacheLock.unlock()
        return terms
    }

    private static func scanRoot(_ root: URL) -> [String] {
        var terms = [root.lastPathComponent]
        let fm = FileManager.default

        if let data = readPrefix(root.appendingPathComponent("package.json"), maxBytes: 64 * 1024),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["name"] as? String {
                terms.append(name)
                if let last = name.split(separator: "/").last {
                    terms.append(String(last))
                }
            }
            for key in ["dependencies", "devDependencies"] {
                if let deps = json[key] as? [String: Any] {
                    for name in deps.keys.prefix(20) where name.count >= 2 && name.count <= 48 {
                        terms.append(name)
                        if let last = name.split(separator: "/").last {
                            terms.append(String(last))
                        }
                    }
                }
            }
        }

        if let data = readPrefix(root.appendingPathComponent("Package.swift"), maxBytes: 64 * 1024) {
            terms.append(contentsOf: matches(packageNameRegex, in: data, cap: 16))
        }
        if let data = readPrefix(root.appendingPathComponent("Package.resolved"), maxBytes: 64 * 1024) {
            terms.append(contentsOf: matches(identityRegex, in: data, cap: 16))
        }
        if let data = readPrefix(root.appendingPathComponent("Cargo.toml"), maxBytes: 8 * 1024),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n").prefix(40) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("name"), let value = trimmed.split(separator: "=").last {
                    let name = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if name.count >= 2, name.count <= 40 { terms.append(name) }
                    break
                }
            }
        }

        if let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var folders = 0
            for child in children {
                let name = child.lastPathComponent
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    guard !skipFolders.contains(name), name.count >= 2, name.count <= 40 else { continue }
                    terms.append(name)
                    folders += 1
                    if folders >= 16 { break }
                } else if isUsefulFilename(name) {
                    terms.append(name)
                }
            }
        }

        return uniqued(terms, cap: 36)
    }

    private static func cachedFileIdentifiers(_ url: URL) -> [String] {
        let path = url.standardizedFileURL.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        cacheLock.lock()
        if let hit = fileCache[path],
           Date().timeIntervalSince(hit.at) < cacheTTL,
           hit.mtime == mtime {
            let terms = hit.terms
            cacheLock.unlock()
            return terms
        }
        cacheLock.unlock()

        let terms = scanFile(url)
        cacheLock.lock()
        if fileCache.count > 16 {
            fileCache.removeAll(keepingCapacity: true)
        }
        fileCache[path] = (terms, Date(), mtime)
        cacheLock.unlock()
        return terms
    }

    private static func scanFile(_ url: URL) -> [String] {
        let ext = url.pathExtension.lowercased()
        guard textExtensions.contains(ext) else { return [] }
        guard let data = readPrefix(url, maxBytes: 256 * 1024), !data.contains(0) else { return [] }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        var terms: [String] = []
        terms.append(contentsOf: matches(camelRegex, in: data, cap: 16, text: text))
        terms.append(contentsOf: matches(snakeRegex, in: data, cap: 12, text: text))
        terms.append(contentsOf: matches(alnumRegex, in: data, cap: 12, text: text))
        for name in matches(dottedRegex, in: data, cap: 16, text: text) where isUsefulFilename(name) {
            terms.append(name)
        }
        return uniqued(terms, cap: 24)
    }

    private static func isUsefulFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !noisyFiles.contains(lower) else { return false }
        guard name.count >= 3, name.count <= 64 else { return false }
        return name.contains(".") || name.contains("-") || name.contains("_")
            || name.contains(where: \.isNumber)
    }

    private static func readPrefix(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: maxBytes)
        return data?.isEmpty == true ? nil : data
    }

    private static func matches(
        _ regex: NSRegularExpression?,
        in data: Data,
        cap: Int,
        text: String? = nil
    ) -> [String] {
        guard let regex else { return [] }
        let source = text ?? String(data: data, encoding: .utf8) ?? ""
        guard !source.isEmpty else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var values: [String] = []
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, stop in
            guard let match else { return }
            let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(group, in: source) else { return }
            let value = String(source[swiftRange])
            if value.count >= 2, value.count <= 48 {
                values.append(value)
            }
            if values.count >= cap { stop.pointee = true }
        }
        return values
    }

    private static func uniqued(_ terms: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms {
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            unique.append(term)
            if unique.count >= cap { break }
        }
        return unique
    }
}
