import Foundation

/// YouTube serves the same cover in several sizes. Rows and grids display artwork at roughly
/// 140-180 points, so asking for a 1280px image wastes bandwidth and decoded memory on every
/// cell. This helper maps the API's thumbnail URLs to the lightweight `mqdefault` variant;
/// Now Playing keeps the original URL.
enum ArtworkURL {
    /// - Parameter maxSize: largest dimension requested for Google-hosted artwork.
    static func compact(_ url: URL, maxSize: Int = 400) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        if host == "i.ytimg.com" || host == "ytimg.com" || host.hasSuffix(".ytimg.com") {
            return compactYouTube(url)
        }
        if host.contains("googleusercontent.com") || host.contains("gstatic.com") {
            return compactGoogle(url, maxSize: maxSize)
        }
        return url
    }

    /// `default` 120x90, `mqdefault` 320x180, `hqdefault` 480x360, `sddefault` 640x480,
    /// `maxresdefault` 1280x720. Cards request `mqdefault`; a smaller variant with `default`
    /// is already the cheapest one available, so it is left alone.
    private static func compactYouTube(_ url: URL) -> URL {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              parts[0] == "vi" || parts[0] == "vi_webp"
        else { return url }

        let version = String(parts[2]).lowercased()
        let alreadySmall = ["default", "mqdefault"].contains { version.hasPrefix($0) }
        guard !alreadySmall else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/vi/\(parts[1])/mqdefault.jpg"
        components?.query = nil
        return components?.url ?? url
    }

    /// Googleusercontent thumbnails carry their size as a trailing `=w1000-h1000-rw` (or
    /// `=s1000`) component. Rewriting just that suffix keeps the signed path intact.
    private static func compactGoogle(_ url: URL, maxSize: Int) -> URL {
        var string = url.absoluteString
        guard let equals = string.lastIndex(of: "=") else { return url }
        let suffix = String(string[string.index(after: equals)...])
        guard suffix.hasPrefix("w") || suffix.hasPrefix("h") || suffix.hasPrefix("s") else { return url }
        string = String(string[..<equals]) + "=w\(maxSize)-h\(maxSize)-rw"
        return URL(string: string) ?? url
    }
}
