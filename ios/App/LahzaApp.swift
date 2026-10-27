import SwiftUI

/// Lahza. ``AppModel`` is the composition root; ``RootView`` the window's root.
@main
struct LahzaApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
