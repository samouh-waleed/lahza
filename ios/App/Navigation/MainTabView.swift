import LZDesign
import SwiftUI

/// The three tabs (Ask · Moments · Settings), a native `TabView` whose Liquid Glass bar minimises
/// on scroll. Each tab has its own typed `NavigationStack`.
struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let router = model.router
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.userSelected($0) })) {
            ForEach(AppTab.allCases) { tab in
                Tab(value: tab) {
                    TabStack(tab: tab)
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                }
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Color.lz(.accent))
        .lzHaptic(.selection, trigger: router.userTabChanges)
    }
}

/// One tab's navigation stack: its root and typed pushes.
private struct TabStack: View {
    let tab: AppTab
    @Environment(AppModel.self) private var model

    var body: some View {
        let router = model.router
        NavigationStack(path: Binding(get: { router.path(for: tab) }, set: { router.paths[tab] = $0 })) {
            RouteScreen(route: router.root(for: tab))
                .navigationDestination(for: Route.self) { RouteScreen(route: $0) }
        }
    }
}
