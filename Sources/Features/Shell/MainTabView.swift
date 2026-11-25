import SwiftUI

/// Apple Music-style shell: Home · Discover · Collections · Search, with the mini player as a
/// bottom inset above the tab bar.
struct MainTabView: View {
    enum Tab: Hashable {
        case home, discover, collections, search
    }

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var router = NotificationRouter.shared
    @State private var selection: Tab = .home

    var body: some View {
        TabView(selection: self.$selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
                .tag(Tab.discover)
            CollectionsView()
                .tabItem { Label("Collections", systemImage: "square.stack") }
                .tag(Tab.collections)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        .queueNoticeBanner()
        .onChange(of: self.router.homeRequest) { _ in self.selection = .home }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView(onTap: { self.environment.isNowPlayingPresented = true })
        }
        .fullScreenCover(isPresented: self.$environment.isNowPlayingPresented) {
            NowPlayingView()
        }
    }
}
