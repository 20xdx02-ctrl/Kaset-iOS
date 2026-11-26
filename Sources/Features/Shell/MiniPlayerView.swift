import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Mini player shown above the tab bar. Mirrors `PlaybackState`; buttons send commands to the
/// native AVPlayer engine.
///
/// It is drawn only while something is loaded, and with an opaque background: a full-width
/// `.ultraThinMaterial` over a scrolling list re-blurs the content on every frame, which is
/// the single most expensive thing an A8-class iPad can be asked to do.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: KasetPlayer

    let onTap: () -> Void

    var body: some View {
        if self.player.state.hasMedia {
            self.content(self.player.state)
        }
    }

    private func content(_ state: PlaybackState) -> some View {
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
                self.player.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.tap()
                self.player.next()
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
        .background(self.barBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var barBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
