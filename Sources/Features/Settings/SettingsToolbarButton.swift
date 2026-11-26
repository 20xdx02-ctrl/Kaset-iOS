import SwiftUI

/// Account button shown in every tab's navigation bar; presents the settings sheet.
/// Shows the user's avatar when signed in, a person glyph otherwise.
struct SettingsToolbarButton: ToolbarContent {
    var body: some ToolbarContent {
        // macOS: the profile sits at the bottom of the sidebar and Settings is ⌘,.
        // Keep the item unconditional: `ToolbarContentBuilder.buildIf` is iOS 16+.
        ToolbarItem(placement: .trailingBar) {
            if !Platform.isMac {
                SettingsSheetButton()
            }
        }
    }
}

private struct SettingsSheetButton: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isPresented = false

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        // Signed in: opens Settings. Guest: tapping signs in, long press offers Settings.
        Menu {
            Button("Settings", systemImage: "gearshape") { self.isPresented = true }
        } label: {
            self.label
        } primaryAction: {
            if self.isSignedIn {
                self.isPresented = true
            } else {
                self.environment.isLoginPresented = true
            }
        }
        .neutralMenuTint()
        .accessibilityLabel(self.isSignedIn ? "Settings" : "Sign in")
        .sheet(isPresented: self.$isPresented) { SettingsView() }
    }

    @ViewBuilder
    private var label: some View {
        Group {
            if let url = self.environment.accountAvatarURL {
                ArtworkView(url: url, placeholder: "person.crop.circle.fill", compactSize: 120)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
    }
}
