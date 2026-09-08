/// Direct-distribution stance for Echo.
///
/// Sandbox is **off** (`ENABLE_APP_SANDBOX = NO`) and Hardened Runtime is **on**.
/// That matches Developer ID + notarized download. It is not Mac App Store ready.
///
/// If Echo ever ships on the Mac App Store, enable the sandbox and add at least:
/// - `com.apple.security.app-sandbox`
/// - `com.apple.security.device.audio-input` (already present)
/// - `com.apple.security.network.client` (already present)
/// - `com.apple.security.files.user-selected.read-write`
/// - `com.apple.security.files.bookmarks.app-scope` for model downloads and Application Support
///
/// Accessibility TCC and `CGEvent` ⌘V paste would need a different MAS strategy
/// (likely clipboard-only). Screen Recording is TCC, not an entitlement.
enum DistributionNotes {}
