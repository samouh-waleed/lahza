import Foundation
import LZIndex
import SwiftUI

/// The three tabs, in bar order.
nonisolated enum AppTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case ask, moments, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .moments: "Moments"
        case .settings: "Settings"
        }
    }

    /// A system glyph, so every tab has the same weight and native tint.
    var symbol: String {
        switch self {
        case .ask: "sparkle.magnifyingglass"
        case .moments: "rectangle.stack"
        case .settings: "gearshape"
        }
    }

    /// The tab's root route.
    var root: Route {
        switch self {
        case .ask: .ask
        case .moments: .moments
        case .settings: .settings
        }
    }
}

/// A sheet's height.
nonisolated enum SheetSize: Hashable, Sendable {
    case medium
    case large

    var detents: Set<PresentationDetent> {
        switch self {
        case .medium: [.medium, .large]
        case .large: [.large]
        }
    }
}

/// How a route is shown.
nonisolated enum RoutePresentation: Hashable, Sendable {
    /// A tab's root.
    case tabRoot
    /// Pushed on its tab's stack.
    case push
    case sheet(SheetSize)
    case fullScreen
}

/// A moment to open, and the tab it opens on (Ask or Moments).
nonisolated struct MomentRef: Hashable, Sendable {
    var key: MomentKey
    var origin: AppTab
    /// The search it was found by (results keep their reasons).
    var searchID: UUID?
}

/// A trip to open (by its first day), and the tab it opens on.
nonisolated struct TripRef: Hashable, Sendable {
    var startDay: Int32
    var origin: AppTab
}

/// Every place Lahza can open, typed.
nonisolated enum Route: Hashable, Sendable {
    // MARK: Tab roots

    case ask
    case moments
    case settings

    // MARK: Settings

    case photoAccess
    case appearance
    case privacy
    case subscription
    case acknowledgements
    /// Settings › Search index.
    case searchIndex

    // MARK: Moments (pushed on the tab they were opened from; not deep-linkable)

    case moment(MomentRef)
    case trip(TripRef)

    // MARK: Developer (DEBUG builds only: Release has no such case, so no way in)

    #if DEBUG
    /// Settings › Developer › Library census (Phase 0 spike S2).
    case libraryCensus
    /// Settings › Developer › Index inspector.
    case indexInspector
    #endif

    // MARK: Modals

    /// Lahza Plus plans (full screen).
    case paywall
    /// Onboarding again, from Settings.
    case onboarding

    // MARK: Fallback

    case notFound(path: String)

    /// The tab a pushed or root route belongs to (nil for modals).
    var tab: AppTab? {
        switch self {
        case .ask: .ask
        case .moments: .moments
        case .settings, .photoAccess, .appearance, .privacy, .subscription, .acknowledgements, .searchIndex: .settings
        case .moment(let ref): ref.origin
        case .trip(let ref): ref.origin
        #if DEBUG
        case .libraryCensus, .indexInspector: .settings
        #endif
        case .paywall, .onboarding, .notFound: nil
        }
    }

    var presentation: RoutePresentation {
        switch self {
        case .ask, .moments, .settings: .tabRoot
        case .photoAccess, .appearance, .privacy, .subscription, .acknowledgements, .searchIndex, .moment, .trip: .push
        #if DEBUG
        case .libraryCensus, .indexInspector: .push
        #endif
        case .paywall, .onboarding: .fullScreen
        case .notFound: .sheet(.medium)
        }
    }

    /// The stack a deep link shows for a pushed route (its tab root is implied).
    var deepLinkStack: [Route] {
        switch presentation {
        case .push: [self]
        default: []
        }
    }

    /// Sheets that prefer page sizing on iPad (none yet; the app is iPhone only).
    var prefersPageSizing: Bool { false }

    /// Routes that exist only in DEBUG builds (developer tools).
    static var developerRoutes: [Route] {
        #if DEBUG
        return [.libraryCensus, .indexInspector]
        #else
        return []
        #endif
    }

    /// The name `-LZRoute` uses (DEBUG).
    var debugName: String {
        switch self {
        case .ask: "ask"
        case .moments: "moments"
        case .settings: "settings"
        case .photoAccess: "photo-access"
        case .appearance: "appearance"
        case .privacy: "privacy"
        case .subscription: "subscription"
        case .acknowledgements: "acknowledgements"
        case .searchIndex: "search-index"
        case .moment: "moment"
        case .trip: "trip"
        #if DEBUG
        case .libraryCensus: "library-census"
        case .indexInspector: "index-inspector"
        #endif
        case .paywall: "paywall"
        case .onboarding: "onboarding"
        case .notFound: "not-found"
        }
    }

    init?(debugName: String) {
        // Moments and trips need a key, so they are not deep-linkable.
        let all: [Route] = [.ask, .moments, .settings, .photoAccess, .appearance, .privacy, .subscription, .acknowledgements, .searchIndex, .paywall,
                            .onboarding] + Route.developerRoutes
        guard let match = all.first(where: { $0.debugName == debugName.lowercased() }) else { return nil }
        self = match
    }
}
