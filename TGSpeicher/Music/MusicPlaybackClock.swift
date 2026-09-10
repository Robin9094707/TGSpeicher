import Combine

/// High-frequency playback updates are isolated from the music library and tabs.
@MainActor
final class MusicPlaybackClock: ObservableObject {
    @Published var elapsed = 0.0
    @Published var duration = 0.0
}
