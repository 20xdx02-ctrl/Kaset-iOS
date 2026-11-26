// NativeStreamResolver.swift
// Ported from verback2308/Opaline (GPL-3.0): Core/API/Clients/AndroidClient.swift,
// Core/API/InnertubeClient+Playback.swift and Core/API/InnertubeClientPlayerParsing.swift.
// Resolves a playable stream and the metadata AVPlayer/MPNowPlayingInfoCenter need,
// without loading the YouTube Music web app in a hidden WKWebView.

import Foundation

/// Everything needed to play a video natively and to fill the lock-screen card.
struct NativeStreamInfo {
    let videoID: String
    let title: String
    let author: String
    let duration: TimeInterval
    let artworkURL: URL?
    let streamURL: URL
    let qualityLabel: String?
    let itag: Int?
    /// `true` when the URL is an HLS manifest rather than a single muxed file.
    let isHLS: Bool
}

enum NativeStreamError: LocalizedError {
    case badResponse
    case botCheck
    case noPlayableStream
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse: "The player response could not be read."
        case .botCheck: "YouTube asked for a bot check. Try again in a moment."
        case .noPlayableStream: "No playable stream was returned for this video."
        case let .badStatus(code): "The player request failed (\(code))."
        }
    }
}

/// Anonymous Android VR client: Opaline uses it for the muxed (video + audio)
/// progressive URL, which does not need a signature solver or a helper server.
enum NativeStreamResolver {
    private static let endpoint = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private static let clientVersion = "21.26.364"
    private static let userAgent =
        "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"

    static func resolve(videoID: String) async throws -> NativeStreamInfo {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("3", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(videoID: videoID))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NativeStreamError.badStatus(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NativeStreamError.badResponse }

        if let status = json["playabilityStatus"] as? [String: Any],
           let reason = status["status"] as? String,
           reason == "LOGIN_REQUIRED" || reason == "ERROR" {
            throw NativeStreamError.botCheck
        }

        let details = json["videoDetails"] as? [String: Any] ?? [:]
        let streaming = json["streamingData"] as? [String: Any]
        guard streaming != nil else { throw NativeStreamError.noPlayableStream }

        // Muxed formats first (video + audio in one file): no composition, no
        // byte-range HLS, and AVPlayer can start almost immediately.
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        // Cheapest usable formats first. The settings picker now really changes what AVPlayer
        // fetches: Low/Normal avoid the heaviest stream on weak devices and slow links.
        let muxed = formats
            .filter { Self.isMuxed($0) && Self.directURL($0) != nil }
            .sorted { Self.int($0["bitrate"]) < Self.int($1["bitrate"]) }
        let format: [String: Any]?
        switch PlaybackAudioQuality.current {
        case .low: format = muxed.first
        case .normal: format = muxed.isEmpty ? nil : muxed[muxed.count / 2]
        case .auto, .high: format = muxed.last
        }

        if let format, let url = Self.directURL(format) {
            return Self.info(videoID: videoID, details: details, url: url, format: format, isHLS: false)
        }

        // Some responses only carry an HLS manifest. AVPlayer plays it natively.
        if let manifest = streaming?["hlsManifestUrl"] as? String,
           let url = URL(string: manifest) {
            return NativeStreamInfo(
                videoID: videoID,
                title: Self.string(details["title"]) ?? videoID,
                author: Self.string(details["author"]) ?? "",
                duration: Self.duration(details),
                artworkURL: Self.artwork(details),
                streamURL: url,
                qualityLabel: nil,
                itag: nil,
                isHLS: true
            )
        }

        // Last resort: an adaptive video format. It has no audio, but it is a
        // valid video stream and lets the user see the picture rather than an error.
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        if let format = adaptive
            .filter({ Self.string($0["mimeType"])?.hasPrefix("video/") == true && Self.directURL($0) != nil })
            .max(by: { Self.int($0["bitrate"]) < Self.int($1["bitrate"]) }),
           let url = Self.directURL(format) {
            return Self.info(videoID: videoID, details: details, url: url, format: format, isHLS: false)
        }

        throw NativeStreamError.noPlayableStream
    }

    // MARK: - Request

    private static func body(videoID: String) -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": clientVersion,
                    "androidSdkVersion": 30,
                    "hl": "en",
                    "gl": "US",
                    "osName": "Android",
                    "osVersion": "11",
                    "userAgent": userAgent
                ],
                "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
                "request": ["useSsl": true, "internalExperimentFlags": []]
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
    }

    // MARK: - Parsing

    private static func info(
        videoID: String,
        details: [String: Any],
        url: URL,
        format: [String: Any],
        isHLS: Bool
    ) -> NativeStreamInfo {
        NativeStreamInfo(
            videoID: videoID,
            title: Self.string(details["title"]) ?? videoID,
            author: Self.string(details["author"]) ?? "",
            duration: Self.duration(details),
            artworkURL: Self.artwork(details),
            streamURL: url,
            qualityLabel: Self.string(format["qualityLabel"]),
            itag: format["itag"] as? Int,
            isHLS: isHLS
        )
    }

    private static func isMuxed(_ format: [String: Any]) -> Bool {
        guard let mime = Self.string(format["mimeType"]), mime.hasPrefix("video/mp4") else {
            return false
        }
        // Progressive formats carry an audio bitrate and an `mp4a` codec;
        // adaptive video formats carry neither.
        return format["audioBitrate"] != nil || mime.contains("mp4a")
    }

    private static func directURL(_ format: [String: Any]) -> URL? {
        guard let text = Self.string(format["url"]), !text.isEmpty else { return nil }
        return URL(string: text)
    }

    private static func duration(_ details: [String: Any]) -> TimeInterval {
        if let seconds = Self.string(details["lengthSeconds"]), let value = Double(seconds) {
            return value
        }
        return (details["lengthSeconds"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func artwork(_ details: [String: Any]) -> URL? {
        let thumbnails = details["thumbnail"] as? [String: Any]
        let list = thumbnails?["thumbnails"] as? [[String: Any]] ?? []
        return list.last.flatMap { Self.string($0["url"]) }.flatMap(URL.init(string:))
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
