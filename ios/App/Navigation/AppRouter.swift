import Foundation
import Observation
import SwiftUI

/// One presented modal. Level 0 is presented by the root, level 1 by level 0's content, and so on,
/// so the paywall can open over a sheet.
struct ModalPresentation: Identifiable, Hashable {
    let id: UUID
    let route: Route
    let fullScreen: Bool
    let size: SheetSize

    init(route: Route, id: UUID = UUID()) {
        self.id = id
        self.route = route
        switch route.presentation {
        case .fullScreen:
            fullScreen = true
            size = .large
        case .sheet(let size):
            fullScreen = false
            self.size = size
        case .tabRoot, .push:
            // Tab routes are never presented; a cover keeps a misuse visible.
            fullScreen = true
            size = .large
        }
    }
}

/// Navigation state: the selected tab, each tab's stack and the modal stack. Views bind to it;
/// ``AppModel/open(_:)`` decides how a route opens and calls these.
@MainActor @Observable final class AppRouter {
    private(set) var selectedTab: AppTab = .ask
    /// Each tab's root route.
    private(set) var roots: [AppTab: Route] = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, $0.root) })
    /// Each tab's pushed routes.
    var paths: [AppTab: [Route]] = [:]
    /// Presented modals, bottom first.
    private(set) var modals: [ModalPresentation] = []
    /// Bumped when a tab is re-selected, so its screen can scroll to the top.
    private(set) var reselection: [AppTab: Int] = [:]
    /// Bumped when a tap on the bar changes the tab (the selection haptic; links stay silent).
    private(set) var userTabChanges = 0

    func root(for tab: AppTab) -> Route { roots[tab] ?? tab.root }

    func path(for tab: AppTab) -> [Route] { paths[tab] ?? [] }

    /// Any sheet or cover is up.
    var hasModal: Bool { !modals.isEmpty }

    /// The route on screen in the selected tab.
    var visibleTabRoute: Route { path(for: selectedTab).last ?? root(for: selectedTab) }

    // MARK: Tabs

    /// A tap on the tab bar. Re-tapping the current tab pops it to its root (iOS convention).
    func userSelected(_ tab: AppTab) {
        if tab == selectedTab {
            popToRoot(tab)
            reselection[tab, default: 0] += 1
        } else {
            selectedTab = tab
            userTabChanges += 1
        }
    }

    func select(_ tab: AppTab) { selectedTab = tab }

    func popToRoot(_ tab: AppTab) {
        paths[tab] = []
    }

    /// Deep-link navigation: select the tab and show `route`, replacing the tab's stack with the
    /// route's `deepLinkStack` (a tab root pops to it).
    func show(_ route: Route) {
        guard let tab = route.tab else { return }
        selectedTab = tab
        if case .tabRoot = route.presentation {
            roots[tab] = route
            paths[tab] = []
        } else {
            paths[tab] = route.deepLinkStack
        }
    }

    /// In-app navigation: push `route` on its tab's stack (selecting that tab).
    func push(_ route: Route) {
        guard let tab = route.tab else { return }
        if case .tabRoot = route.presentation {
            show(route)
            return
        }
        selectedTab = tab
        paths[tab, default: []].append(route)
    }

    func pop(_ tab: AppTab) {
        guard var path = paths[tab], !path.isEmpty else { return }
        path.removeLast()
        paths[tab] = path
    }

    // MARK: Modals

    func present(_ route: Route) {
        // The same modal twice (a double tap, a repeated link) is shown once.
        if modals.last?.route == route { return }
        modals.append(ModalPresentation(route: route))
    }

    /// Dismisses the modal at `level` and everything above it.
    func dismissModal(at level: Int) {
        guard level < modals.count else { return }
        modals.removeSubrange(level...)
    }

    func dismissTopModal() {
        guard !modals.isEmpty else { return }
        modals.removeLast()
    }

    func dismissAllModals() { modals.removeAll() }

    /// Dismisses the lowest modal matching `predicate` and everything above it.
    func dismissModals(where predicate: (ModalPresentation) -> Bool) {
        guard let level = modals.firstIndex(where: predicate) else { return }
        dismissModal(at: level)
    }

    func modal(at level: Int) -> ModalPresentation? {
        level < modals.count ? modals[level] : nil
    }

    // MARK: Reset

    /// Forget every stack and modal (the root leaving the tabs).
    func reset() {
        selectedTab = .ask
        roots = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, $0.root) })
        paths = [:]
        modals = []
    }
}
