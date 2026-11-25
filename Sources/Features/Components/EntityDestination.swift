import SwiftUI

extension View {
    /// Kept for source compatibility: iOS 15 has no value-based `navigationDestination`, so every
    /// navigation link now carries its destination directly (`MediaEntityDestinationView`).
    func entityDestinations() -> some View { self }
}

/// The screen a `MediaEntity` opens: playlist/album, artist or mood.
struct MediaEntityDestinationView: View {
    let entity: MediaEntity

    var body: some View {
        switch self.entity.target {
        case let .album(id), let .playlist(id):
            PlaylistDetailView(id: id, fallbackTitle: self.entity.title, thumbnailURL: self.entity.thumbnailURL)
        case let .artist(id):
            ArtistDetailView(id: id, fallbackName: self.entity.title)
        case let .mood(browseId, params):
            MoodCategoryView(browseId: browseId, params: params, title: self.entity.title)
        case .song, .unsupported:
            ContentUnavailableView(self.entity.title, systemImage: "music.note")
        }
    }
}

/// Sections for one mood / genre.
struct MoodCategoryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let browseId: String
    let params: String?
    let title: String

    @State private var sections: [HomeSection] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    var body: some View {
        Group {
            switch self.phase {
            case .loading:
                ProgressView()
            case let .failed(message):
                LoadFailureView(message: message) { Task { await self.load() } }
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(self.sections) { section in
                            ShelfView(section: section)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(self.title)
        .inlineNavigationTitle()
        .task { await self.load() }
    }

    private func load() async {
        self.phase = .loading
        do {
            self.sections = try await self.environment.client
                .getMoodCategory(browseId: self.browseId, params: self.params).sections
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }
}
