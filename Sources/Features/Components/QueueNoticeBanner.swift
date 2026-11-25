import SwiftUI

/// Short status pill for queue operations. The shell, Now Playing and the queue sheet each cover
/// the others, so each one shows it itself.
struct QueueNoticeBanner: ViewModifier {
    @EnvironmentObject private var environment: AppEnvironment
    /// Player updates are observed here instead of through `environment`: forwarding
    /// every player tick through the app-wide environment invalidated the whole view tree.
    @EnvironmentObject private var observedPlayer: KasetPlayer

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = self.environment.player.queueNotice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: self.environment.player.queueNotice)
    }
}

extension View {
    func queueNoticeBanner() -> some View { self.modifier(QueueNoticeBanner()) }
}
