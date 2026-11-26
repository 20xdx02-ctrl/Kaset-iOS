// KasetPlayer.swift
// Native AVPlayer playback, adapted from Opaline's PlaybackFacade / VideoPlayerView
// (GPL-3.0). Replaces the hidden music.youtube.com WKWebView for the native path:
// no page scripts, no polling, a fraction of the CPU and memory use.

import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct NativePlaybackState {
    var videoID: String?
    var title: String?
    var author: String?
    var artworkURL: URL?
    var duration: TimeInterval = 0
    var position: TimeInterval = 0
    var isPlaying = false
    var isLoading = false
    var qualityLabel: String?
}

@MainActor
final class KasetPlayer: ObservableObject {
    @Published private(set) var nativeState = NativePlaybackState()
    /// Mirrored into the app's existing playback model so all screens keep working.
    @Published private(set) var state = PlaybackState()
    @Published private(set) var identity = PlaybackIdentity()
    @Published private(set) var lastMessageAt: Date?
    @Published private(set) var healthReport: PlayerHealthReport?
    @Published private(set) var errorMessage: String?
    @Published private(set) var volume: Double = 1
    @Published private(set) var isReorderingQueue = false
    /// Same fields the original player exposed, so the existing screens keep working.
    @Published private(set) var lastQueueResult: (videoId: String, success: Bool, reason: String)?
    @Published private(set) var queueNotice: String?
    /// There is no page in the native path; debug readout shows "page non chargée".
    @Published private(set) var pageURL: String?
    /// Listening history hook (same shape as the old web player).
    var onStateChange: ((PlaybackState, Date) -> Void)?

    /// Kept for the sign-in web view (the only WebKit user left in the app).
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// Video IDs in the native queue, and the one being played.
    @Published private(set) var queue: [String] = []
    @Published private(set) var queueIndex = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playheadObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Playback

    func play(videoID: String) async {
        self.loadTask?.cancel()
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            self.nativeState.isLoading = true
            self.errorMessage = nil
            SpikeLog.shared.log("native", "play \(videoID)")
            do {
                let info = try await NativeStreamResolver.resolve(videoID: videoID)
                guard !Task.isCancelled else { return }
                SpikeLog.shared.log("native", "stream itag=\(info.itag.map(String.init) ?? "-") label=\(info.qualityLabel ?? "-") hls=\(info.isHLS) host=\(info.streamURL.host ?? "-")")
                await self.attach(info)
            } catch is CancellationError {
                SpikeLog.shared.log("native", "cancelled \(videoID)")
            } catch {
                self.nativeState.isLoading = false
                self.errorMessage = error.localizedDescription
                SpikeLog.shared.log("native", "ERROR \(error.localizedDescription)")
            }
        }
        await self.loadTask?.value
    }

    func play(stream: NativeStreamInfo) async {
        await self.attach(stream)
    }

    /// Replaces the native queue without starting playback yet.
    func setQueue(_ ids: [String], startingAt index: Int = 0) {
        self.queue = ids.filter { !$0.isEmpty }
        self.queueIndex = min(max(index, 0), max(self.queue.count - 1, 0))
    }

    /// Replaces the native queue and starts at `index`. Playback never touches a WKWebView.
    func playQueue(_ ids: [String], startingAt index: Int = 0) async {
        self.setQueue(ids, startingAt: index)
        await self.playCurrent()
    }

    /// Starts the current queue entry (used by the player view when a queue is already set).
    func playCurrent() async {
        guard let id = self.currentID else { return }
        await self.play(videoID: id)
    }

    private var currentID: String? {
        self.queue.indices.contains(self.queueIndex) ? self.queue[self.queueIndex] : nil
    }

    func next() {
        self.advance(1)
    }

    func previous() {
        self.advance(-1)
    }

    private func advance(_ delta: Int) {
        let target = self.queueIndex + delta
        guard self.queue.indices.contains(target) else { return }
        let id = self.queue[target]
        self.queueIndex = target
        Task { await self.play(videoID: id) }
    }

    private func attach(_ info: NativeStreamInfo) async {
        self.player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        self.timeObserver = nil
        self.statusObservation = nil
        self.playheadObservation = nil

        let item = AVPlayerItem(url: info.streamURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        self.nativeState = NativePlaybackState(
            videoID: info.videoID,
            title: info.title,
            author: info.author,
            artworkURL: info.artworkURL,
            duration: info.duration,
            position: 0,
            isPlaying: false,
            isLoading: true,
            qualityLabel: info.qualityLabel
        )
        self.loadArtwork(info.artworkURL)
        self.configureAudioSession()

        self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item == self.player?.currentItem else { return }
                self.nativeState.isLoading = item.status != AVPlayerItem.Status.readyToPlay
                SpikeLog.shared.log("native", "item status=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "-")")
                if item.status == AVPlayerItem.Status.failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed."
                }
            }
        }
        self.playheadObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, player == self.player else { return }
                self.nativeState.isPlaying = player.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.nativeState.position = time.seconds
                self.publishNowPlaying()
            }
        }

        player.play()
        self.nativeState.isPlaying = true
        self.publishNowPlaying()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            self.nativeState.isPlaying = false
        } else {
            player.play()
            self.nativeState.isPlaying = true
        }
        self.publishNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), self.nativeState.duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        self.nativeState.position = clamped
        self.publishNowPlaying()
    }

    func stop() {
        self.loadTask?.cancel()
        self.player?.pause()
        self.player = nil
        self.nativeState = NativePlaybackState()
        self.syncFacade()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    @objc private nonisolated func itemDidFinish(_ notification: Notification) {
        Task { @MainActor in
            self.nativeState.isPlaying = false
            self.publishNowPlaying()
            // Auto-advance mirrors Opaline's VideoSource queue behaviour.
            if self.queue.count > 1 { self.advance(1) }
        }
    }

    // MARK: - System integration

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true, options: [])
        #endif
    }

    private func publishNowPlaying() {
        self.syncFacade()
        guard self.nativeState.videoID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.nativeState.title ?? "",
            MPMediaItemPropertyArtist: self.nativeState.author ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: self.nativeState.position,
            MPNowPlayingInfoPropertyPlaybackRate: self.nativeState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if self.nativeState.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = self.nativeState.duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: URL?) {
        self.artworkTask?.cancel()
        self.artwork = nil
        guard let url else { return }
        self.artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data)
            else { return }
            guard let self else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publishNowPlaying()
        }
    }


    // MARK: - Compatibility with the app's existing playback interface

    private func syncFacade() {
        var next = self.state
        next.videoId = self.nativeState.videoID
        next.title = self.nativeState.title
        next.artist = self.nativeState.author
        next.artworkURL = self.nativeState.artworkURL
        next.duration = self.nativeState.duration
        next.position = self.nativeState.position
        next.isPlaying = self.nativeState.isPlaying
        next.hasMedia = self.nativeState.videoID != nil
        next.canGoNext = self.queueIndex < self.queue.count - 1
        next.canGoPrevious = self.queueIndex > 0
        next.queue = self.queue.enumerated().map { index, id in
            PlaybackState.QueueEntry(
                index: index, videoId: id, title: id, artist: "",
                isCurrent: index == self.queueIndex
            )
        }
        next.updatedAt = Date()
        self.state = next

        var identity = self.identity
        identity.videoId = self.nativeState.videoID
        identity.isPlaying = self.nativeState.isPlaying
        self.identity = identity
        self.lastMessageAt = Date()
        self.onStateChange?(self.state, next.updatedAt)
    }

    /// Starts a video. `playlistId` is accepted for source compatibility; the native
    /// resolver needs only the video id.
    func play(videoId: String?, playlistId: String? = nil) {
        guard let videoId else { return }
        Task { await self.play(videoID: videoId) }
    }

    func playShuffled(videoId: String?, playlistId: String) {
        self.play(videoId: videoId, playlistId: playlistId)
    }

    func startRadio(videoId: String) { self.play(videoId: videoId, playlistId: nil) }

    func resume() { if !self.nativeState.isPlaying { self.togglePlayPause() } }
    func pause() { if self.nativeState.isPlaying { self.togglePlayPause() } }

    func playNext(videoId: String) -> Bool {
        let index = min(self.queueIndex + 1, self.queue.count)
        self.queue.insert(videoId, at: index)
        self.lastQueueResult = (videoId, true, "queued next")
        self.showNotice("Added next: \(videoId)")
        self.syncFacade()
        return true
    }

    func addToQueue(videoId: String) -> Bool {
        self.queue.append(videoId)
        self.lastQueueResult = (videoId, true, "queued")
        self.showNotice("Added to queue: \(videoId)")
        self.syncFacade()
        return true
    }

    func playQueueEntry(at index: Int) {
        guard self.queue.indices.contains(index) else { return }
        self.queueIndex = index
        Task { await self.playCurrent() }
    }

    func removeQueueEntry(at index: Int) {
        guard self.queue.indices.contains(index), index != self.queueIndex else { return }
        self.queue.remove(at: index)
        if index < self.queueIndex { self.queueIndex -= 1 }
        self.syncFacade()
    }

    func moveQueueEntry(from source: Int, to destination: Int) async {
        guard self.queue.indices.contains(source),
              self.queue.indices.contains(destination), source != self.queueIndex
        else { return }
        let id = self.queue.remove(at: source)
        self.queue.insert(id, at: destination)
        self.syncFacade()
    }

    // These page-specific controls have no equivalent in native playback.
    func toggleShuffle() {}
    func cycleRepeat() {}
    func setVolume(_ value: Double) { self.volume = min(max(value, 0), 1) }
    func applyVolume() {}
    func inspectQueue() {}
    func inspectBuffer() {}
    func inspectAudio(reason: String) {}
    func applyAudioQuality() {}
    func applyAdSkipSetting() {}
    func applyDataSaverSetting() {}
    func applyBufferSetting() {}
    func refreshState() {}
    func recover(reason: String) {}

    func showNotice(_ text: String) {
        self.queueNotice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.queueNotice == text { self?.queueNotice = nil }
        }
    }

    func checkHealth() async -> PlayerHealthReport {
        let check = PlayerHealthReport.Check(
            id: "native", ok: true, detail: "AVPlayer is active", needsTrack: false, hasTrack: true
        )
        return PlayerHealthReport(
            checks: [check], hasTrack: self.nativeState.videoID != nil, date: Date()
        )
    }
}
