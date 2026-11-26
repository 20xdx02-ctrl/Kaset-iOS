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
    /// `maxresdefault` is not present for every video; fall back to the API's thumbnail.
    private let fallbackURL: URL?
    /// Cards use a 480px bitmap; the player keeps enough pixels for a full-screen cover.
    private let targetPixels: Int

    @State private var image: PlatformImage?

    init(url: URL?, placeholder: String = "music.note", usesFullResolution: Bool = false, compactSize: Int = 400) {
        self.url = url
        self.placeholder = placeholder
        self.usesFullResolution = usesFullResolution
        self.compactSize = compactSize
        self.targetPixels = usesFullResolution ? 1024 : 480
        if let url {
            if usesFullResolution {
                let full = ArtworkURL.fullResolution(url)
                self.resolvedURL = full
                self.fallbackURL = full == url ? nil : url
            } else {
                self.resolvedURL = ArtworkURL.compact(url, maxSize: compactSize)
                self.fallbackURL = nil
            }
        } else {
            self.resolvedURL = nil
            self.fallbackURL = nil
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
            var loaded = await ArtworkCache.shared.image(for: url, targetPixels: self.targetPixels)
            if loaded == nil, let fallback = self.fallbackURL {
                loaded = await ArtworkCache.shared.image(for: fallback, targetPixels: self.targetPixels)
            }
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
            // Every visible shelf fires this at once. On a two-core device, warming a dozen
            // covers per shelf queues more work than the cells themselves need — four is
            // enough to hide the first horizontal page without starving visible covers.
            ArtworkCache.shared.prefetch(compacted, limit: Platform.isMac ? limit : min(limit, 4))
        }
    }
}
