import SwiftUI

/// Remote artwork with a neutral placeholder. Images come from the shared `ArtworkCache`, so
/// scrolling a grid does not start a new download and decode for every cell. Cards use a
/// lightweight thumbnail URL; large player artwork keeps the original one.
struct ArtworkView: View {
    let url: URL?
    var placeholder: String = "music.note"
    /// Player artwork is displayed much larger than a card and should stay crisp.
    var usesFullResolution = false
    /// Maximum dimension for Google-hosted covers (avatars need less than album art).
    var compactSize: Int = 400

    /// Resolved once per view value instead of on every `body` pass: mapping a YouTube URL
    /// builds `URLComponents`, and a shelf re-evaluates dozens of cells while scrolling.
    private let resolvedURL: URL?

    @State private var image: PlatformImage?

    init(url: URL?, placeholder: String = "music.note", usesFullResolution: Bool = false, compactSize: Int = 400) {
        self.url = url
        self.placeholder = placeholder
        self.usesFullResolution = usesFullResolution
        self.compactSize = compactSize
        self.resolvedURL = url.map {
            usesFullResolution ? $0 : ArtworkURL.compact($0, maxSize: compactSize)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: self.placeholder).foregroundStyle(.secondary))
            }
        }
        .task(id: self.resolvedURL) {
            self.image = nil
            guard let url = self.resolvedURL else { return }
            let loaded = await ArtworkCache.shared.image(for: url)
            // The cell may have been reused while the request was in flight.
            guard self.resolvedURL == url else { return }
            self.image = loaded
        }
    }
}

extension View {
    /// Warms the first covers of a shelf/list before their cells are rendered. Call once on
    /// the scroll container, not on individual rows.
    func prefetchArtwork(_ urls: [URL?], limit: Int = 12) -> some View {
        self.onAppear {
            let compacted = urls.compactMap { $0 }.map { ArtworkURL.compact($0) }
            ArtworkCache.shared.prefetch(compacted, limit: limit)
        }
    }
}
