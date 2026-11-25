// NativePlayerView.swift
// SwiftUI shell for the native (Opaline-derived) player. No WKWebView, no injected
// JavaScript, no polling: AVPlayer drives the UI directly.

import SwiftUI

struct NativePlayerView: View {
    @EnvironmentObject private var native: NativePlayer
    @Environment(\.dismiss) private var dismiss

    let videoID: String
    @State private var started = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Done") { self.dismiss() }
                Spacer()
                Text("Native player")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let quality = self.native.state.qualityLabel {
                    Text(quality).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            Spacer(minLength: 0)

            AsyncImage(url: self.native.state.artworkURL) { phase in
                Group {
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "music.note").font(.system(size: 48)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .aspectRatio(1, contentMode: .fit)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 6) {
                Text(self.native.state.title ?? "Loading…")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(self.native.state.author ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                ProgressView(
                    value: self.native.state.position,
                    total: max(self.native.state.duration, 1)
                )
                HStack {
                    Text(Self.time(self.native.state.position))
                    Spacer()
                    Text(Self.time(self.native.state.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)

            if let error = self.native.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack(spacing: 48) {
                Button {
                    self.native.seek(to: self.native.state.position - 10)
                } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 28))
                }
                Button {
                    if self.native.state.isLoading {
                        return
                    }
                    self.native.togglePlayPause()
                } label: {
                    Image(systemName: self.native.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                Button {
                    self.native.seek(to: self.native.state.position + 10)
                } label: {
                    Image(systemName: "goforward.10").font(.system(size: 28))
                }
            }
            .disabled(self.native.errorMessage != nil)

            Spacer(minLength: 0)
        }
        .padding(.vertical)
        .task {
            guard !self.started else { return }
            self.started = true
            await self.native.play(videoID: self.videoID)
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
