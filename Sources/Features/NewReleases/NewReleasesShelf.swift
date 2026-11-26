import SwiftUI

/// "New from your artists" on Home: releases of the last 60 days, most recent first.
/// Hidden while there is nothing to show.
struct NewReleasesShelf: View {
    /// Observed directly: the watcher publishes throughout a check (cursor, resolved releases,
    /// prune). Going through the app-wide environment would invalidate every scrolling card.
    @EnvironmentObject private var newReleases: NewReleaseWatcher

    var body: some View {
        let releases = self.newReleases.shelf
        if !releases.isEmpty {
            ShelfView(title: String(localized: "New from your artists"), entities: releases.prefix(20).map(Self.entity))
        }
    }

    /// A one-track single is a song card (tap plays it); anything longer opens its page.
    /// The subtitle gives the release date when known, the kind otherwise.
    static func entity(for release: NewRelease) -> MediaEntity {
        let detail = release.releaseDate?.formatted(.dateTime.day().month(.abbreviated))
            ?? (release.isSingle ? String(localized: "Single") : String(localized: "Album"))
        let target: MediaEntity.Target = if release.isSingleTrack, let videoId = release.videoId {
            .song(videoId: videoId)
        } else {
            .album(id: release.id)
        }
        return MediaEntity(
            id: "new-release-\(release.id)", title: release.title,
            subtitle: release.artistName.isEmpty ? detail : "\(release.artistName) · \(detail)",
            thumbnailURL: release.thumbnailURL, target: target, isCircular: false
        )
    }
}
