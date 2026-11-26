import SwiftUI

/// Lyrics of whatever the native player is playing; follows track changes while open.
struct LyricsSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Player updates are observed here instead of through `environment`: forwarding
    /// every player tick through the app-wide environment invalidated the whole view tree.
    @EnvironmentObject private var observedPlayer: KasetPlayer
    @Environment(\.dismiss) private var dismiss

    let model: NowPlayingModel?

    var body: some View {
        let state = self.environment.player.state

        NavigationStackCompat {
            Group {
                switch self.model?.lyrics(for: state.videoId) {
                case let .synced(lyrics):
                    SyncedLyricsView(lyrics: lyrics)
                case let .plain(lyrics) where lyrics.isAvailable:
                    PlainLyricsView(lyrics: lyrics)
                case nil where state.videoId != nil:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
                }
            }
            .navigationTitle("Lyrics")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } } }
        }
        .task(id: state.videoId) {
            guard let videoId = state.videoId else { return }
            // The length picks the right LRCLib entry; it arrives with the stream metadata.
            var waits = 0
            while self.environment.player.state.duration <= 0, waits < 12 {
                try? await Task.sleep(nanoseconds: 250000000)
                waits += 1
            }
            guard !Task.isCancelled else { return }
            let current = self.environment.player.state
            await self.model?.loadLyrics(
                videoId: videoId, title: current.title, artist: current.artist, duration: current.duration
            )
        }
    }
}

/// Plain lyrics: one block of text.
struct PlainLyricsView: View {
    let lyrics: Lyrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(self.lyrics.text).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
                if let source = self.lyrics.source {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

/// Synced lyrics: the current line is highlighted and kept in view; tapping a line seeks there.
/// Scrolling by hand pauses the follow for a few seconds, as in Apple Music.
struct SyncedLyricsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Player updates are observed here instead of through `environment`: forwarding
    /// every player tick through the app-wide environment invalidated the whole view tree.
    @EnvironmentObject private var observedPlayer: KasetPlayer

    let lyrics: SyncedLyrics
    var fontSize: CGFloat = 28

    @State private var currentIndex: Int?
    @State private var followPausedUntil = Date.distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.offset) { index, line in
                        self.row(line, index: index)
                    }
                    Text("Source: \(Self.sourceName(self.lyrics.source))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { _ in
                    self.followPausedUntil = Date().addingTimeInterval(3)
                }
            )
            .onChange(of: self.currentIndex) { index in
                guard let index, Date() >= self.followPausedUntil else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
        }
        .task(id: self.lyrics) {
            while !Task.isCancelled {
                // Extrapolate from the last player state instead of waiting for a new tick;
                // 2 Hz is enough for synced lyrics and wakes the device half as often.
                let state = self.environment.player.state
                let timeMs = Int(state.position(at: Date()) * 1000)
                let index = self.lyrics.currentLineIndex(at: timeMs)
                if index != self.currentIndex { self.currentIndex = index }
                try? await Task.sleep(nanoseconds: 500000000)
            }
        }
    }

    private func row(_ line: SyncedLyricLine, index: Int) -> some View {
        let isCurrent = index == self.currentIndex
        return Button {
            Haptics.tap()
            self.followPausedUntil = .distantPast
            self.currentIndex = index
            self.environment.player.seek(to: TimeInterval(line.timeInMs) / 1000)
        } label: {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: self.fontSize, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .scaleEffect(isCurrent ? 1 : 0.96, anchor: .leading)
                .animation(.easeInOut(duration: 0.3), value: isCurrent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityHint("Plays from this line")
    }

    private static func sourceName(_ source: String) -> String {
        source == "YTMusic" ? "YouTube Music" : source
    }
}
