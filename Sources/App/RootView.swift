import SwiftUI

/// Launch routing: unknown → splash, otherwise the tabs (signed-out users are guests). The player's web
/// view stays attached to the window as a hidden 1×1 view for the whole app lifetime so audio
/// keeps running.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    /// Shared by every cover's context menu; one sheet instead of one per card.
    @StateObject private var addToPlaylist = AddToPlaylistPresenter()

    var body: some View {
        Group {
            switch environment.auth.state {
            case .unknown:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signedIn:
                // Signed-out users browse as guests; sign-in lives on the navigation bar button.
                #if os(iOS)
                MainTabView()
                #else
                MacMainWindow()
                #endif
            }
        }
        .environmentObject(self.addToPlaylist)
        .task { await environment.start() }
        .task(id: environment.auth.state) {
            guard environment.auth.state == .signedIn else { return }
            await environment.newReleases.requestNotificationPermissionIfNeeded()
            await environment.newReleases.checkIfDue(client: environment.client, auth: environment.auth)
        }
        .onChange(of: self.scenePhase) { phase in
            switch phase {
            case .active:
                Task { await environment.listening.sync() }
                guard environment.auth.state == .signedIn else { return }
                Task { await environment.newReleases.checkIfDue(client: environment.client, auth: environment.auth) }
            case .background:
                environment.newReleases.scheduleBackgroundCheck()
                environment.listening.flush()
                Task { await environment.listening.sync() }
            default:
                break
            }
        }
        .sheet(isPresented: $environment.isLoginPresented) {
            #if os(iOS)
            LoginView(dataStore: environment.loginDataStore) { Task { await environment.loginFinished() } }
            #else
            VStack(spacing: 0) {
                HStack {
                    Text("Sign in to YouTube Music").font(.headline)
                    Spacer()
                    Button("Cancel") { environment.isLoginPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                LoginView(dataStore: environment.loginDataStore) { Task { await environment.loginFinished() } }
            }
            .frame(width: 500, height: 650)
            #endif
        }
        .sheet(item: self.$addToPlaylist.source) { source in
            AddToPlaylistSheet(source: source)
        }
    }
}
