// NativePlayer.swift
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
final class NativePlayer: ObservableObject {
    @Published private(set) var state = NativePlaybackState()
    @Published private(set) var errorMessage: String?
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
            self.state.isLoading = true
            self.errorMessage = nil
            do {
                let info = try await NativeStreamResolver.resolve(videoID: videoID)
                guard !Task.isCancelled else { return }
                await self.attach(info)
            } catch is CancellationError {
            } catch {
                self.state.isLoading = false
                self.errorMessage = error.localizedDescription
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

        self.state = NativePlaybackState(
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
                self.state.isLoading = item.status != AVPlayerItem.Status.readyToPlay
                if item.status == AVPlayerItem.Status.failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed."
                }
            }
        }
        self.playheadObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, player == self.player else { return }
                self.state.isPlaying = player.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.state.position = time.seconds
                self.publishNowPlaying()
            }
        }

        player.play()
        self.state.isPlaying = true
        self.publishNowPlaying()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            self.state.isPlaying = false
        } else {
            player.play()
            self.state.isPlaying = true
        }
        self.publishNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), self.state.duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        self.state.position = clamped
        self.publishNowPlaying()
    }

    func stop() {
        self.loadTask?.cancel()
        self.player?.pause()
        self.player = nil
        self.state = NativePlaybackState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    @objc private nonisolated func itemDidFinish(_ notification: Notification) {
        Task { @MainActor in
            self.state.isPlaying = false
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
        guard self.state.videoID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.state.title ?? "",
            MPMediaItemPropertyArtist: self.state.author ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: self.state.position,
            MPNowPlayingInfoPropertyPlaybackRate: self.state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if self.state.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = self.state.duration
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
}
