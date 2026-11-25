// Compatibility.swift
// Back-ports of APIs introduced after iOS 15 / macOS 12 that the app uses.
// Everything here is compiled for both the iOS and the macOS target.

import Combine
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - ContentUnavailableView (iOS 17 / macOS 14)

/// Drop-in stand-in for SwiftUI's `ContentUnavailableView`, available on iOS 15 / macOS 12.
struct ContentUnavailableView: View {
    private let content: AnyView

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.content = AnyView(
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                if let description {
                    description
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    init<L: View>(@ViewBuilder label: () -> L) {
        self.content = AnyView(
            VStack(spacing: 12) {
                label()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    init<L: View, D: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder description: () -> D
    ) {
        self.content = AnyView(
            VStack(spacing: 12) {
                label()
                description()
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    init<L: View, D: View, A: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder description: () -> D,
        @ViewBuilder actions: () -> A
    ) {
        self.content = AnyView(
            VStack(spacing: 12) {
                label()
                description()
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                actions()
                    .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    /// Mimics `ContentUnavailableView.search(text:)` from iOS 17.
    static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            "No Results for \"\(text)\"",
            systemImage: "magnifyingglass",
            description: Text("Check the spelling or try a new search.")
        )
    }

    var body: some View { self.content }
}

// MARK: - Shape erasure (AnyShape is iOS 16 / macOS 13)

/// Drop-in stand-in for SwiftUI's `AnyShape`, available on iOS 15 / macOS 12.
///
/// `Shape` only exposes `path(in:)`, so erasing the concrete shape is a one-line wrapper.
struct AnyShapeCompat: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        self.pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        self.pathBuilder(rect)
    }
}

// MARK: - Navigation

/// `NavigationStack` replacement for iOS 15 / macOS 12. Value-based navigation
/// (`NavigationLink(value:)` + `navigationDestination`) is not available there, so screens use
/// destination-based links instead.
struct NavigationStackCompat<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        NavigationView { self.content }
            .navigationViewStyle(.stack)
        #else
        NavigationView { self.content }
        #endif
    }
}

// MARK: - Sharing (ShareLink is iOS 16 / macOS 13)

/// `ShareLink` replacement for iOS 15 / macOS 12.
struct ShareButton<Label: View>: View {
    let items: [Any]
    private let label: () -> Label

    init(items: [Any], @ViewBuilder label: @escaping () -> Label) {
        self.items = items
        self.label = label
    }

    var body: some View {
        Button(action: self.share) { self.label() }
    }

    private func share() {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        let controller = UIActivityViewController(activityItems: self.items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = root.view
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(controller, animated: true)
        #else
        let text = self.items.compactMap { item -> String? in
            if let string = item as? String { return string }
            if let url = item as? URL { return url.absoluteString }
            return nil
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Geometry and sheet helpers

extension View {
    /// `onGeometryChange` replacement for iOS 15 / macOS 12.
    func onGeometryChangeCompat<T: Equatable>(
        of transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        self.background(
            GeometryReader { proxy in
                let value = transform(proxy)
                Color.clear
                    .onAppear { action(value) }
                    .onChange(of: value) { action($0) }
            }
        )
    }

    /// `presentationDetents` needs iOS 16; on iOS 15 the sheet keeps its natural size.
    @ViewBuilder
    func kasetSheetDetents() -> some View {
        #if os(iOS)
        if #available(iOS 16, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Holding an optional ObservableObject in a View

/// Holds an optional `ObservableObject` and republishes its changes.
///
/// Before iOS 17 `@State var model: Model?` (with an `@Observable` model) invalidated the view
/// when the model changed. `@StateObject` cannot hold an optional, so views use
/// `@StateObject private var holder = ObservableHolder<Model>()` plus a computed `model`.
final class ObservableHolder<Object: ObservableObject>: ObservableObject {
    @Published var inner: Object? {
        didSet { self.resubscribe() }
    }

    private var subscription: AnyCancellable?

    init(_ value: Object? = nil) {
        self.inner = value
        self.resubscribe()
    }

    private func resubscribe() {
        self.subscription = self.inner?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

/// A dictionary of `ObservableObject`s that republishes every child's changes.
final class ObservableModels<Key: Hashable, Object: ObservableObject>: ObservableObject {
    @Published var values: [Key: Object] = [:] {
        didSet { self.resubscribe() }
    }

    private var subscriptions: [AnyCancellable] = []

    private func resubscribe() {
        self.subscriptions = self.values.values.map { object in
            object.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}
