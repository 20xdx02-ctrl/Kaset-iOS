import SwiftUI

/// Mini player shown above the tab bar. Mirrors `PlaybackState`; buttons send commands to the
/// native AVPlayer engine.
struct MiniPlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Player updates are observed here instead of through `environment`: forwarding
    /// every player tick through the app-wide environment invalidated the whole view tree.
    @EnvironmentObject private var observedPlayer: KasetPlayer

    let onTap: () -> Void

    var body: some View {
        let state = self.environment.player.state

        HStack(spacing: 12) {
            Button(action: self.onTap) {
                HStack(spacing: 12) {
                    ArtworkView(url: state.artworkURL)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.title ?? "Not playing")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if state.isAd {
                            Text("Advertisement")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let artist = state.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")

            Button {
                Haptics.tap()
                self.environment.player.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.tap()
                self.environment.player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.primary)
            .disabled(!state.canGoNext)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
