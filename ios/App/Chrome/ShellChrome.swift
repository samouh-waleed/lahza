import DDDesign
import SwiftUI

/// A calm loading screen: the brand loader, never a bare spinner.
struct AppLoadingView: View {
    var label = "Loading"

    var body: some View {
        VStack(spacing: DDSpace.md) {
            DDLoader(.sun, size: 36, label: label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.dd(.bg))
    }
}

/// A route that does not exist (a stale or mistyped link): the copy and a way back.
struct NotFoundView: View {
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EmptyState(NotFoundCopy.title, message: NotFoundCopy.body, systemImage: "questionmark.circle",
                   actionTitle: NotFoundCopy.back) {
            dismiss()
            model.open(.ask)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.dd(.bg))
        .accessibilityIdentifier("not-found")
    }
}

nonisolated enum NotFoundCopy {
    static let title = "Nothing here"
    static let body = "This page has moved or the link is no longer available."
    static let back = "Back to Ask"
}

/// The opaque privacy cover (DDDesign `PrivacyCoverView`) whenever the scene is not active, so the
/// app switcher never snapshots photos. Applied at the root and inside every modal. Not shown
/// before the scene first becomes active, so launch hands off cleanly, nor while the iOS photo
/// prompt makes the scene inactive: the screen that explained it stays behind it (none of those
/// screens shows photos).
struct PrivacyCoverLayer: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasBeenActive = false
    /// From the photo prompt's start until the scene is active again: the answer can land before
    /// the scene leaves `.inactive`, and the cover must not flash in between.
    @State private var promptShown = false

    private var covered: Bool {
        switch scenePhase {
        case .active: false
        case .inactive: !(promptShown || model.photoAccess.isRequesting)
        default: true
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if hasBeenActive && covered {
                    PrivacyCoverView()
                        .transition(.identity)
                        .accessibilityIdentifier("privacy-cover")
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    hasBeenActive = true
                    promptShown = false
                }
            }
            .onChange(of: model.photoAccess.isRequesting) { _, requesting in
                if requesting {
                    promptShown = true
                } else if scenePhase == .active {
                    // The scene is already back (or never left, as with a DEBUG fake library).
                    promptShown = false
                }
            }
    }
}

extension View {
    func privacyCover() -> some View { modifier(PrivacyCoverLayer()) }
}

/// The toast host, drawn only on the topmost layer (the root, or the top modal), so a toast shows
/// once and above sheets. At most 3, 2.5 s each (DDDesign `DDToastCenter`).
struct ToastLayer: ViewModifier {
    let level: Int
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if model.router.modals.count == level {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .ddToastHost(model.toasts)
            }
        }
    }
}
