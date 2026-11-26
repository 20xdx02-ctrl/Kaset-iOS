import Foundation
#if os(iOS)
import UIKit
#endif

/// Shared, process-wide artwork cache. `AsyncImage` creates a fresh loader per row, so a
/// grid re-render (scroll, tab switch, sheet) fetched and decoded every cover again. This
/// keeps decoded images in an `NSCache` (evicted automatically under memory pressure) and
/// coalesces simultaneous requests for the same URL.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        // A few screens of covers; NSCache drops them before the OS starts jettisoning views.
        self.images.countLimit = 200
        self.images.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for url: URL) async -> PlatformImage? {
        let key = url.absoluteString as NSString
        if let cached = self.images.object(forKey: key) { return cached }
        if let pending = self.inFlight[url] { return await pending.value }

        let task = Task.detached(priority: .utility) { () -> PlatformImage? in
            // Cover art is public and immutable: no cookies, and the shared URL cache serves
            // repeat requests without hitting the network at all.
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = PlatformImage(data: data)
            else { return nil }
            #if os(iOS)
            // UIKit lazily decodes when the image is first drawn — on the main thread, in the
            // middle of a scroll. Render once in the background and cache the decoded bitmap.
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            #else
            return image
            #endif
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
}
