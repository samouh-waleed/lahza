import Foundation
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

/// Every place Lahza can open, typed.
nonisolated enum Route: Hashable, Sendable {
    // MARK: Tab roots

    case ask
    case moments
    case settings

    // MARK: Settings

    case appearance
    case privacy
    case subscription
    case acknowledgements

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
        case .settings, .appearance, .privacy, .subscription, .acknowledgements: .settings
        case .paywall, .onboarding, .notFound: nil
        }
    }

    var presentation: RoutePresentation {
        switch self {
        case .ask, .moments, .settings: .tabRoot
        case .appearance, .privacy, .subscription, .acknowledgements: .push
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

    /// The name `-LZRoute` uses (DEBUG).
    var debugName: String {
        switch self {
        case .ask: "ask"
        case .moments: "moments"
        case .settings: "settings"
        case .appearance: "appearance"
        case .privacy: "privacy"
        case .subscription: "subscription"
        case .acknowledgements: "acknowledgements"
        case .paywall: "paywall"
        case .onboarding: "onboarding"
        case .notFound: "not-found"
        }
    }

    init?(debugName: String) {
        let all: [Route] = [.ask, .moments, .settings, .appearance, .privacy, .subscription, .acknowledgements, .paywall, .onboarding]
        guard let match = all.first(where: { $0.debugName == debugName.lowercased() }) else { return nil }
        self = match
    }
}
