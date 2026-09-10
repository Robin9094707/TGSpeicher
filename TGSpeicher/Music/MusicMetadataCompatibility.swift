import AVFoundation

/// Compatibility shim for callers that still use the pre-3.3.1 metadata API.
/// Metadata passed here is always a local staged file; remote streaming metadata
/// continues to use MusicPlayer's bounded Telegram-specific path.
extension MusicMetadata {
    static func read(_ asset: AVURLAsset) async -> Result {
        await readLocal(asset)
    }
}
