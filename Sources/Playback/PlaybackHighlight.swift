import Combine

/// The small slice of playback that list rows and cover cards actually need.
///
/// They used to observe `KasetPlayer` directly, so every queue edit, volume change or
/// health update invalidated every visible cell. This object publishes only when the
/// current video or its play/pause state changes, which is what the equalizer badge and
/// the highlighted title depend on.
@MainActor
final class PlaybackHighlight: ObservableObject {
    @Published private(set) var identity = PlaybackIdentity()

    func update(_ identity: PlaybackIdentity) {
        guard identity != self.identity else { return }
        self.identity = identity
    }
}
