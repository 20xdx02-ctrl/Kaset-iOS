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
///
/// The bitmap is always redrawn, even when it is already small enough: `UIImage(data:)` keeps
/// the JPEG compressed and decodes it lazily on first draw — i.e. on the main thread, in the
/// middle of a scroll. On an A8-class iPad that is one dropped frame per newly visible cover.
private func decodedArtwork(_ image: PlatformImage, maxPixelSize: CGFloat) -> PlatformImage {
    #if os(iOS)
    let width = image.size.width
    let height = image.size.height
    guard width > 0, height > 0 else { return image }
    // YouTube serves 16:9 thumbnails for videos and music-video entries. Every artwork
    // surface in the app is square, so centre-crop here, once, off the main thread, instead
    // of letting SwiftUI scale a wide bitmap into a square on every scroll frame.
    let side = min(width, height)
    let scale = min(1, maxPixelSize / max(width, height))
    let output = max(floor(side * scale), 1)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    // `image.size` already holds pixels; avoid multiplying the bitmap by the screen scale again.
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
        let offsetX = -(width - side) * 0.5 * scale
        let offsetY = -(height - side) * 0.5 * scale
        image.draw(in: CGRect(
            x: offsetX, y: offsetY,
            width: width * scale, height: height * scale
        ))
    }
    #else
    return image
    #endif
}

/// At most two covers are fetched/decompressed at once. An A8 iPad has two cores; decoding a
/// dozen JPEGs in parallel to warm several shelves at once starves the main thread and is a
/// common cause of stutter while scrolling. Waiting here does not block any thread.
private actor ArtworkDecodeGate {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static let shared = ArtworkDecodeGate()

    func acquire() async {
        if self.active < 2 {
            self.active += 1
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        if self.waiters.isEmpty {
            self.active -= 1
        } else {
            // The waiter takes over the slot that just freed up.
            self.waiters.removeFirst().resume()
        }
    }
}

/// Shared, process-wide artwork cache. `AsyncImage` creates a fresh loader per row, so a
/// grid re-render (scroll, tab switch, sheet) fetched and decoded every cover again. This
/// keeps decoded images in an `NSCache`, coalesces simultaneous requests for the same URL
/// and warms upcoming covers before their cells appear.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, PlatformImage>()
    /// Keyed by size as well as URL: the player needs a much larger bitmap than a card and must
    /// not reuse the 480px version cached while scrolling the shelves.
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private init() {
        // With 480px thumbnails each bitmap is well under 1 MB; this holds a few screens of
        // covers without competing with playback or the browsing models for memory.
        self.images.countLimit = 400
        self.images.totalCostLimit = 64 * 1024 * 1024
    }

    /// - Parameter targetPixels: longest side of the stored, square bitmap. Cards stay at 480;
    ///   the full-screen player asks for 1024 so a 720px YouTube thumbnail is not blown up.
    func image(for url: URL, targetPixels: Int = 480) async -> PlatformImage? {
        let cacheKey = "\(targetPixels)|\(url.absoluteString)"
        let key = cacheKey as NSString
        if let cached = self.images.object(forKey: key) { return cached }
        if let pending = self.inFlight[cacheKey] { return await pending.value }

        let task = Task.detached(priority: .utility) { () -> PlatformImage? in
            await ArtworkDecodeGate.shared.acquire()
            let image = await ArtworkCache.fetchAndDecode(url, targetPixels: targetPixels)
            await ArtworkDecodeGate.shared.release()
            return image
        }
        self.inFlight[cacheKey] = task
        let image = await task.value
        self.inFlight[cacheKey] = nil
        if let image {
            let bytes = Int(image.size.width * image.size.height) * 4
            self.images.setObject(image, forKey: key, cost: max(bytes, 1))
        }
        return image
    }

    private nonisolated static func fetchAndDecode(_ url: URL, targetPixels: Int) async -> PlatformImage? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await ArtworkHTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let image = PlatformImage(data: data)
        else { return nil }
        if targetPixels > 480 {
            let size = image.size
            Task { @MainActor in
                SpikeLog.shared.log(
                    "art",
                    "source \(Int(size.width))x\(Int(size.height)) ratio=\(String(format: "%.2f", size.width / size.height)) -> square"
                )
            }
        }
        // UIKit lazily decodes on first draw — on the main thread, in the middle of a
        // scroll. Render once in the background and cache the small, decoded bitmap.
        return decodedArtwork(image, maxPixelSize: CGFloat(targetPixels))
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
