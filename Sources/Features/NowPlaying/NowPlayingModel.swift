import ImageIO
import SwiftUI

/// Rating and lyrics for the track the native player is playing. The track itself comes from
/// `PlaybackState`; this only adds what AVPlayer does not report.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var likeStatus: LikeStatus = .indifferent
    /// Artists of the current track, with ids, from the song metadata.
    @Published private(set) var artists: [Artist] = []
    /// Lyrics of `lyricsVideoId`; `nil` until loaded.
    @Published private(set) var lyrics: LyricResult?
    @Published private(set) var lyricsVideoId: String?
    @Published private(set) var isLoadingLyrics = false
    /// Average colour of the current artwork; drives the background gradient.
    @Published private(set) var artworkColor: PlatformColor?
    private var loadedVideoId: String?
    private var loadedArtworkURL: URL?
    private let client: YTMusicClient

    init(client: YTMusicClient) {
        self.client = client
    }

    func trackChanged(to videoId: String?) async {
        guard videoId != self.loadedVideoId else { return }
        self.loadedVideoId = videoId
        self.likeStatus = .indifferent
        self.artists = []
        guard let videoId else { return }
        if let song = try? await self.client.getSong(videoId: videoId), self.loadedVideoId == videoId {
            self.likeStatus = song.likeStatus ?? .indifferent
            self.artists = song.artists.filter(\.hasNavigableId)
        }
    }

    /// Artist to open for a tapped name: from metadata, else the top artist search result.
    func resolveArtist(named name: String?) async -> Artist? {
        if let first = self.artists.first { return first }
        guard let name, !name.isEmpty,
              let response = try? await self.client.search(query: name)
        else { return nil }
        return response.artists.first
    }

    func artworkChanged(to url: URL?) async {
        guard url != self.loadedArtworkURL else { return }
        self.loadedArtworkURL = url
        guard let url else {
            self.artworkColor = nil
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        // ImageIO decode + 1×1 redraw off the main thread: this runs on every track change
        // and used to stutter scroll/animation on older iPads.
        let color = await Task.detached(priority: .utility) { Self.averageColor(of: data) }.value
        guard let color, self.loadedArtworkURL == url else { return }
        self.artworkColor = color
    }

    /// Mean colour via a 1×1 redraw; cheap and stable for a background tint.
    nonisolated private static func averageColor(of data: Data) -> PlatformColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return PlatformColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
    }

    /// The song was liked outside this screen (Siri, Shortcuts).
    func likedElsewhere(videoId: String) {
        if videoId == self.loadedVideoId { self.likeStatus = .like }
    }

    func toggleLike(videoId: String) async {
        let next: LikeStatus = self.likeStatus == .like ? .indifferent : .like
        let previous = self.likeStatus
        self.likeStatus = next
        do {
            try await self.client.rateSong(videoId: videoId, rating: next)
        } catch {
            self.likeStatus = previous
        }
    }

    /// Lyrics for a track, `nil` while they load or when they belong to another track.
    func lyrics(for videoId: String?) -> LyricResult? {
        guard let videoId, videoId == self.lyricsVideoId else { return nil }
        return self.lyrics
    }

    /// YouTube Music and LRCLib are asked in parallel; synced lyrics win over plain ones, and
    /// YouTube Music wins a tie.
    func loadLyrics(videoId: String, title: String?, artist: String?, duration: TimeInterval) async {
        guard videoId != self.lyricsVideoId || self.lyrics == nil else { return }
        self.lyricsVideoId = videoId
        self.lyrics = nil
        self.isLoadingLyrics = true

        let client = self.client
        async let youtube = (try? await client.getLyrics(videoId: videoId)) ?? .unavailable
        async let lrclib: LyricResult = if let title, let artist {
            await LRCLibClient.search(title: title, artist: artist, duration: duration > 0 ? duration : nil)
        } else {
            .unavailable
        }
        let result = Self.preferred(await youtube, await lrclib)

        guard self.lyricsVideoId == videoId else { return }
        self.lyrics = result
        self.isLoadingLyrics = false
    }

    static func preferred(_ youtube: LyricResult, _ lrclib: LyricResult) -> LyricResult {
        for candidate in [youtube, lrclib] {
            if case let .synced(lyrics) = candidate, !lyrics.isEmpty { return candidate }
        }
        for candidate in [youtube, lrclib] where candidate.isAvailable {
            return candidate
        }
        return .unavailable
    }
}

/// Progress bar with a drag-to-seek gesture. While dragging it shows the finger position;
/// on release it sends one `seek` command and keeps showing that position until the player
/// reports a time near it (or a short timeout), so it does not jump back.
struct ScrubberView: View {
    let state: PlaybackState
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @State private var pendingSeek: (target: TimeInterval, until: Date)?

    var body: some View {
        VStack(spacing: 6) {
            // The scrubber extrapolates from the last state update; 2 Hz is smooth enough
            // for a progress bar and halves SwiftUI work on older iPads.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let duration = max(self.state.duration, 0)
                let position = self.displayedPosition(at: context.date, duration: duration)
                let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

                VStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.22))
                            Capsule().fill(.white.opacity(0.72)).frame(width: max(proxy.size.width * fraction, 0))
                        }
                        .frame(height: self.dragFraction == nil ? 6 : 10)
                        .clipShape(Capsule())
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: self.dragFraction == nil)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard duration > 0 else { return }
                                    self.dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                                }
                                .onEnded { value in
                                    guard duration > 0 else { return }
                                    let target = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                                    self.dragFraction = nil
                                    self.pendingSeek = (target, Date().addingTimeInterval(3))
                                    self.onSeek(target)
                                }
                        )
                    }
                    .frame(height: 16)

                    HStack {
                        Text(Self.format(position))
                        Spacer()
                        Text("\u{2212}" + Self.format(max(0, duration - position)))
                    }
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .opacity(self.state.duration > 0 ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.format(self.state.position())) of \(Self.format(self.state.duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 10
            let current = self.state.position()
            switch direction {
            case .increment: self.onSeek(min(current + step, self.state.duration))
            case .decrement: self.onSeek(max(current - step, 0))
            @unknown default: break
            }
        }
    }

    private func displayedPosition(at date: Date, duration: TimeInterval) -> TimeInterval {
        if let dragFraction { return dragFraction * duration }
        let live = self.state.position(at: date)
        if let pending = self.pendingSeek {
            // Hold the target until the player catches up with it (within 2 s) or the timeout.
            if date < pending.until, abs(live - pending.target) > 2 { return pending.target }
        }
        return live
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Subtle scale-down on press, used for the player's icon buttons.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
