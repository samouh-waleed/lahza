import LZDesign
import SwiftUI

/// The window's root: the root screen (launching, onboarding or the tabs), the modal layers, the
/// privacy cover and the toast host. The motion root and the feedback settings are installed here,
/// once per window.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootContent()
            .modifier(ModalLayer(level: 0))
            .privacyCover()
            .modifier(ToastLayer(level: 0))
            .lzMotionRoot()
            .lzFeedback(model.feedback)
            .environment(model.toasts)
            .environment(model.router)
            .preferredColorScheme(model.preferredColorScheme)
            .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
            .modifier(QAAccessibilityOverrides())
    }
}

/// The root screen, cross-faded (none under Reduce Motion).
private struct RootContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch model.root {
            case .launching:
                LaunchHoldView()
            case .onboarding:
                OnboardingView()
                    .transition(.opacity)
            case .tabs:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: model.root)
    }
}

/// Presents the router's modal at `level` (a sheet with detents, or a full-screen cover); each
/// modal's content presents the next level, so the paywall can open over a sheet.
struct ModalLayer: ViewModifier {
    let level: Int
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let router = model.router
        content
            .sheet(item: Binding(
                get: { router.modal(at: level).flatMap { $0.fullScreen ? nil : $0 } },
                set: { if $0 == nil, router.modal(at: level)?.fullScreen == false { router.dismissModal(at: level) } }
            )) { presentation in
                ModalContainer(presentation: presentation, level: level + 1)
                    // At accessibility sizes a half-height sheet shows little more than its title.
                    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : presentation.size.detents)
                    .modifier(ModalSizing(page: presentation.route.prefersPageSizing))
                    .presentationBackground(.lz(.bg))
                    .presentationCornerRadius(LZRadius.sheet)
            }
            .fullScreenCover(item: Binding(
                get: { router.modal(at: level).flatMap { $0.fullScreen ? $0 : nil } },
                set: { if $0 == nil, router.modal(at: level)?.fullScreen == true { router.dismissModal(at: level) } }
            )) { presentation in
                ModalContainer(presentation: presentation, level: level + 1)
            }
    }
}

/// Page sizing for the sheets that ask for it (``Route/prefersPageSizing``; it only changes iPad).
private struct ModalSizing: ViewModifier {
    let page: Bool

    func body(content: Content) -> some View {
        if page { content.presentationSizing(.page) } else { content }
    }
}

/// A modal's own navigation stack, with the next modal layer, the privacy cover and (when it is
/// on top) the toast host.
private struct ModalContainer: View {
    let presentation: ModalPresentation
    let level: Int
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            RouteScreen(route: presentation.route, inModal: true)
                .navigationDestination(for: Route.self) { RouteScreen(route: $0, inModal: true) }
        }
        .modifier(ModalLayer(level: level))
        .privacyCover()
        .modifier(ToastLayer(level: level))
        .modifier(QAAccessibilityOverrides())
    }
}
