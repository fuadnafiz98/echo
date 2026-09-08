import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Tiny one-shot luma sample of the pixels behind the chip. Image is discarded.
@MainActor
enum BackdropSampler {
    private static var content: SCShareableContent?
    private static var contentAt: ContinuousClock.Instant?

    static func reset() {
        content = nil
        contentAt = nil
    }

    static var hasAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Call from Settings only. Never prompt on the hotkey path.
    @discardableResult
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func prewarm() async {
        guard hasAccess else { return }
        _ = try? await shareableContent()
    }

    static func isDark(below window: NSWindow) async -> Bool? {
        guard let luminance = await sample(below: window) else { return nil }
        return luminance < 0.52
    }

    private static func sample(below window: NSWindow) async -> CGFloat? {
        guard hasAccess else { return nil }
        do {
            let shareable = try await shareableContent()
            guard let screen = window.screen ?? NSScreen.main else { return nil }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
            let display = shareable.displays.first(where: { $0.displayID == displayID })
                ?? shareable.displays.first
            guard let display else { return nil }

            let exclude = shareable.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: exclude)
            let rect = sourceRect(of: window, on: screen)
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false
            configuration.showsCursor = false
            configuration.sourceRect = rect
            configuration.width = 24
            configuration.height = 12

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return luminance(of: image)
        } catch {
            return nil
        }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        if let content, let contentAt, ContinuousClock.now - contentAt < .seconds(45) {
            return content
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        content = fresh
        contentAt = .now
        return fresh
    }

    private static func sourceRect(of window: NSWindow, on screen: NSScreen) -> CGRect {
        let frame = window.frame
        let screenFrame = screen.frame
        return CGRect(
            x: frame.minX - screenFrame.minX,
            y: screenFrame.maxY - frame.maxY,
            width: max(frame.width, 8),
            height: max(frame.height, 8)
        )
    }

    private static func luminance(of image: CGImage) -> CGFloat? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.08 else { return nil }
        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
