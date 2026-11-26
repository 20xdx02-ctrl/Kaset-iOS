import SwiftUI

/// Apple Music-style shell: Home · Discover · Collections · Search, with the mini player just
/// above the tab bar.
///
/// The mini player is inset inside each tab's content, never on the `TabView` itself: on iOS 15
/// a bottom safe-area inset applied to the `TabView` draws over the tab bar and hides it.
struct MainTabView: View {
    enum Tab: Hashable {
        case home, discover, collections, search
    }

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var router = NotificationRouter.shared
    @State private var selection: Tab = .home

    var body: some View {
        TabView(selection: self.$selection) {
            self.tab(.home, title: "Home", systemImage: "house") { HomeView() }
            self.tab(.discover, title: "Discover", systemImage: "sparkles") { DiscoverView() }
            self.tab(.collections, title: "Collections", systemImage: "square.stack") { CollectionsView() }
            self.tab(.search, title: "Search", systemImage: "magnifyingglass") { SearchView() }
        }
        .queueNoticeBanner()
        .onChange(of: self.router.homeRequest) { _ in self.selection = .home }
        .fullScreenCover(isPresented: self.$environment.isNowPlayingPresented) {
            NowPlayingView()
        }
    }

    /// Keeps the tab bar clear: the accessory belongs to the selected tab's content area, so
    /// UIKit still lays out the tab bar below it.
    @ViewBuilder
    private func tab<Content: View>(
        _ tab: Tab,
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerView(onTap: { self.environment.isNowPlayingPresented = true })
            }
            .tabItem { Label(title, systemImage: systemImage) }
            .tag(tab)
    }
}
