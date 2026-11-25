import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var router = NotificationRouter.shared
    @StateObject private var modelHolder = ObservableHolder<BrowsePageModel>()
    private var model: BrowsePageModel? {
        get { self.modelHolder.inner }
        nonmutating set { self.modelHolder.inner = newValue }
    }
    @State private var pendingDestination: MediaEntity?

    var body: some View {
        NavigationStackCompat {
            Group {
                if let model {
                    BrowsePageView(model: model, emptyMessage: "No recommendations yet.") {
                        NewReleasesShelf()
                        MixesShelf()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Home")
            .entityDestinations()
            .background(self.pendingDestinationLink)
            .toolbar { SettingsToolbarButton() }
        }
        .onAppear { self.handlePending(self.router.pendingEntity) }
        .onChange(of: self.router.pendingEntity) { self.handlePending($0) }
        .task(id: self.environment.auth.state) {
            let model = self.model ?? BrowsePageModel(type: .home, client: self.environment.client)
            self.model = model
            await model.load(force: true)
        }
    }

    /// A `NavigationLink` driven by a notification tap, since value-based navigation needs iOS 16.
    private var pendingDestinationLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { self.pendingDestination != nil },
                set: { if !$0 { self.pendingDestination = nil } }
            ),
            destination: {
                if let entity = self.pendingDestination {
                    MediaEntityDestinationView(entity: entity)
                }
            },
            label: { EmptyView() }
        )
        .hidden()
    }

    private func handlePending(_ entity: MediaEntity?) {
        guard let entity else { return }
        self.router.pendingEntity = nil
        if case .song = entity.target {
            self.environment.playEntity(entity)
            self.environment.isNowPlayingPresented = true
        } else {
            self.pendingDestination = entity
        }
    }
}
