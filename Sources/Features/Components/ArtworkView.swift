import SwiftUI

/// Remote artwork with a neutral placeholder. Images come from the shared `ArtworkCache`, so
/// scrolling a grid does not start a new download and decode for every cell.
struct ArtworkView: View {
    let url: URL?
    var placeholder: String = "music.note"

    @State private var image: PlatformImage?

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
        .task(id: self.url) {
            self.image = nil
            guard let url = self.url else { return }
            let loaded = await ArtworkCache.shared.image(for: url)
            // The cell may have been reused while the request was in flight.
            guard self.url == url else { return }
            self.image = loaded
        }
    }
}
