import Foundation
#if os(iOS)
import UIKit
#endif

/// A dedicated cache: artwork is public and immutable, so it never needs cookies or the same
/// small disk quota as API responses. Once a cover has been fetched, scrolling back to it is
/// served from disk even if the decoded bitmap was evicted from memory.
private enum ArtworkHTTP {
    static let cache = URLCache(
        memoryCapacity: 8 * 1024 * 1024,
        diskCapacity: 160 * 1024 * 1024,
        diskPath: "kaset.artwork"
    )

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = ArtworkHTTP.cache
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()
}

/// A full-size thumbnail decodes to several megabytes, while a card shows at most a couple of
/// hundred points. Downscaling off the main thread lets the in-memory cache hold many screens
/// of covers instead of just two or three.
private func decodedArtwork(_ image: PlatformImage, maxPixelSize: CGFloat) -> PlatformImage {
    #if os(iOS)
    let longestSide = max(image.size.width, image.size.height)
    guard longestSide > maxPixelSize else { return image }
    let scale = maxPixelSize / longestSide
    let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
    guard size.width >= 1, size.height >= 1 else { return image }
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    // `image.size` already holds pixels; avoid multiplying the bitmap by the screen scale again.
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    #else
    return image
    #endif
}

/// Shared, process-wide artwork cache. `AsyncImage` creates a fresh loader per row, so a
/// grid re-render (scroll, tab switch, sheet) fetched and decoded every cover again. This
/// keeps decoded images in an `NSCache`, coalesces simultaneous requests for the same URL
/// and warms upcoming covers before their cells appear.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private init() {
        // With 480px thumbnails each bitmap is well under 1 MB; this holds a few screens of
        // covers without competing with playback or the browsing models for memory.
        self.images.countLimit = 400
        self.images.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) async -> PlatformImage? {
        let key = url.absoluteString as NSString
        if let cached = self.images.object(forKey: key) { return cached }
        if let pending = self.inFlight[url] { return await pending.value }

        let task = Task.detached(priority: .utility) { () -> PlatformImage? in
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await ArtworkHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = PlatformImage(data: data)
            else { return nil }
            // UIKit lazily decodes on first draw — on the main thread, in the middle of a
            // scroll. Render once in the background and cache the small, decoded bitmap.
            return decodedArtwork(image, maxPixelSize: 480)
        }
        self.inFlight[url] = task
        let image = await task.value
        self.inFlight[url] = nil
        if let image {
            let bytes = Int(image.size.width * image.size.height) * 4
            self.images.setObject(image, forKey: key, cost: max(bytes, 1))
        }
        return image
    }

    /// Warms a row/list's first covers while the user is still looking at the header, so a
    /// fast scroll does not start a fresh download the instant each cell appears. Covers
    /// already cached (or in flight) are skipped by `image(for:)`.
    func prefetch(_ urls: [URL], limit: Int) {
        let batch = Array(urls.prefix(limit))
        guard !batch.isEmpty else { return }
        self.prefetchTask?.cancel()
        self.prefetchTask = Task.detached(priority: .utility) { [weak self] in
            for url in batch {
                guard !Task.isCancelled else { return }
                await self?.image(for: url)
            }
        }
    }
}
