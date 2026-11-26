import SwiftUI

extension View {
    /// Menus and context menus draw their icons with the tint; the accent colour is for the
    /// tab bar and primary actions, so menus use the neutral label colour instead.
    func neutralMenuTint() -> some View { self.tint(.primary) }
}

/// Square (or circular) artwork card used in shelves.
struct MediaCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Player updates are observed here instead of through `environment`: forwarding
    /// every player tick through the app-wide environment invalidated the whole view tree.
    @EnvironmentObject private var observedPlayer: KasetPlayer

    let entity: MediaEntity
    /// `nil` fills the proposed width (grids).
    var width: CGFloat? = AdaptiveLayout.cardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The square sets the size; the artwork only fills it. Drawn directly, a wide
            // (video) thumbnail in fill mode would widen the card past its grid column.
            self.artworkWithShape
                // A shadow on every grid cell forces an offscreen pass per row while scrolling.
                .overlay(alignment: .bottomTrailing) { self.quickPlay }
                .overlay(alignment: .topLeading) { self.nowPlayingBadge }
            Text(self.entity.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 2)
            if let subtitle = self.entity.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: self.width, alignment: .leading)
        .frame(maxWidth: self.width == nil ? .infinity : nil, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    /// Concrete shapes instead of an erased one: every cell builds this twice per pass.
    @ViewBuilder
    private var artworkWithShape: some View {
        if self.entity.isCircular {
            self.artwork
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.primary.opacity(0.08)) }
        } else {
            self.artwork
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }

    /// Fixed square in shelves, aspect-ratio square in grids. Avoids the extra `Color.clear`
    /// layer the card used to stack under every cover.
    @ViewBuilder
    private var artwork: some View {
        if let width = self.width {
            ArtworkView(url: self.entity.thumbnailURL)
                .frame(width: width, height: width)
        } else {
            ArtworkView(url: self.entity.thumbnailURL)
                .aspectRatio(1, contentMode: .fit)
        }
    }

    /// Animated bars on the cover of whatever the player is on (song, playlist, album).
    @ViewBuilder
    private var nowPlayingBadge: some View {
        let identity = self.observedPlayer.identity
        if self.entity.isCurrent(in: identity) {
            EqualizerView(isAnimating: identity.isPlaying, color: .white)
                .frame(width: 16, height: 14)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(8)
                .accessibilityLabel("Now playing")
        }
    }

    /// Playlists and albums open their page on tap; this plays them without opening it.
    @ViewBuilder
    private var quickPlay: some View {
        switch self.entity.target {
        case .playlist, .album:
            Button {
                Haptics.tap()
                self.environment.playEntity(self.entity)
            } label: {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Play \(self.entity.title)")
        default:
            EmptyView()
        }
    }
}

/// List row used by search results.
struct MediaRow: View {
    let entity: MediaEntity

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: self.entity.thumbnailURL)
                .frame(width: 56, height: 56)
                .clipShape(self.entity.isCircular ? AnyShapeCompat(Circle()) : AnyShapeCompat(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            VStack(alignment: .leading, spacing: 2) {
                Text(self.entity.title).font(.body).lineLimit(1)
                if let subtitle = self.entity.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Wraps content so a tap and the long-press menu send commands to the native player.
/// Songs and playlists play; albums and artists open their detail screen (K8).
struct MediaActions<Content: View>: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// One presenter for the whole app: a `.sheet` on every card made each shelf cell carry
    /// its own presentation machinery, which is expensive to build while scrolling.
    @EnvironmentObject private var addToPlaylist: AddToPlaylistPresenter

    let entity: MediaEntity
    @ViewBuilder var content: Content

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        self.actions
    }

    @ViewBuilder
    private var actions: some View {
        switch self.entity.target {
        case .song:
            Button(action: self.play) { self.content }
                .buttonStyle(.plain)
                .neutralMenuTint()
                .contextMenu { self.menu }
        case .playlist, .album:
            // Like the macOS app: the page opens; playing is an explicit action.
            NavigationLink { MediaEntityDestinationView(entity: self.entity) } label: { self.content }
                .buttonStyle(.plain)
                .neutralMenuTint()
                .contextMenu {
                    Button("Play", systemImage: "play.fill") { self.environment.playEntity(self.entity) }
                    if self.isSignedIn {
                        Button("Add to Playlist…", systemImage: "text.badge.plus") {
                            self.presentAddToPlaylist()
                        }
                    }
                }
        case .artist, .mood:
            NavigationLink { MediaEntityDestinationView(entity: self.entity) } label: { self.content }
                .buttonStyle(.plain)
        case .unsupported:
            self.content.opacity(0.5)
        }
    }

    private func play() {
        let player = self.environment.player
        switch self.entity.target {
        case let .song(videoId):
            player.setQueue(
                [videoId],
                metadata: [videoId: QueueTrackMetadata(
                    title: self.entity.title, artist: self.entity.subtitle ?? "", artworkURL: self.entity.thumbnailURL
                )]
            )
            player.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
        default:
            self.environment.playEntity(self.entity)
        }
    }

    private func presentAddToPlaylist() {
        switch self.entity.target {
        case let .song(videoId):
            self.addToPlaylist.present(.song(videoId: videoId, title: self.entity.title))
        case let .playlist(id), let .album(id):
            self.addToPlaylist.present(.collection(id: id, title: self.entity.title))
        default:
            break
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Play", systemImage: "play.fill", action: self.play)
        if let videoId = self.entity.videoId {
            Button("Play Next", systemImage: "text.insert") {
                self.environment.player.setQueueMetadata(
                    videoID: videoId, title: self.entity.title,
                    artist: self.entity.subtitle ?? "", artworkURL: self.entity.thumbnailURL
                )
                self.environment.player.playNext(videoId: videoId)
            }
            Button("Add to Queue", systemImage: "text.append") {
                self.environment.player.setQueueMetadata(
                    videoID: videoId, title: self.entity.title,
                    artist: self.entity.subtitle ?? "", artworkURL: self.entity.thumbnailURL
                )
                self.environment.player.addToQueue(videoId: videoId)
            }
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                self.environment.player.startRadio(videoId: videoId)
            }
            if self.isSignedIn {
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    self.presentAddToPlaylist()
                }
            }
        }
    }
}

/// Inline error with a retry action.
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(self.message)
        } actions: {
            Button("Try Again", action: self.retry)
        }
    }
}

