import DDBilling
import DDCore
import DDDesign
import Foundation
import Observation
import SwiftUI

/// The screen under the modals.
nonisolated enum RootScreen: Hashable, Sendable {
    /// Launch has not finished (the launch surface holds).
    case launching
    case onboarding
    case tabs
}

/// The composition root: builds the services, decides the root screen, opens every route and
/// follows the scene phase. Injected through the environment (`@Environment(AppModel.self)`).
@MainActor @Observable final class AppModel {
    /// The app's one model (built from ``AppDependencies/resolve()``).
    static let shared = AppModel(dependencies: .resolve())

    @ObservationIgnored let dependencies: AppDependencies
    let router = AppRouter()
    @ObservationIgnored let toasts = DDToastCenter()
    @ObservationIgnored let feedback = DDFeedbackSettings()
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let purchases: PurchasesService
    let entitlement: EntitlementStore

    private(set) var isReady = false
    private(set) var onboardingCompleted: Bool
    private(set) var appearance: AppearanceMode
    private(set) var scenePhase: ScenePhase = .inactive

    @ObservationIgnored private let log = Log("shell")

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        preferences = AppPreferences(kv: dependencies.kv)
        purchases = dependencies.makePurchasesService()
        entitlement = EntitlementStore(kv: dependencies.kv, entitlementIdentifier: dependencies.billingEnvironment.entitlementIdentifier)
        onboardingCompleted = preferences.onboardingCompleted
        appearance = preferences.appearance
        if dependencies.autoBoot { start() }
    }

    // MARK: Derived state

    var root: RootScreen {
        guard isReady else { return .launching }
        return onboardingCompleted ? .tabs : .onboarding
    }

    /// The window's colour scheme (nil follows the iPhone).
    var preferredColorScheme: ColorScheme? { (dependencies.appearanceOverride ?? appearance).colorScheme }

    // MARK: Launch

    /// Launch: preferences are read in `init`; billing starts in the background so it never holds
    /// the first screen (free search works without it).
    func start() {
        guard !isReady else { return }
        log.info("Launch (\(dependencies.label))", privacy: .public)
        isReady = true
        Task { await entitlement.start(with: purchases) }
        if let route = dependencies.initialRoute { open(route) }
    }

    // MARK: Navigation

    /// Opens `route` the way its presentation says.
    func open(_ route: Route) {
        switch route.presentation {
        case .tabRoot:
            router.dismissAllModals()
            router.show(route)
        case .push:
            router.dismissAllModals()
            router.push(route)
        case .sheet, .fullScreen:
            router.present(route)
        }
    }

    // MARK: Onboarding

    func completeOnboarding() {
        preferences.markOnboardingCompleted(at: dependencies.clock.now)
        onboardingCompleted = true
        router.dismissModals { $0.route == .onboarding }
    }

    // MARK: Settings

    func setAppearance(_ mode: AppearanceMode) {
        preferences.setAppearance(mode)
        appearance = mode
    }

    // MARK: Scene

    func scenePhaseChanged(_ phase: ScenePhase) {
        scenePhase = phase
    }

    // MARK: Billing

    /// A paywall model over the shared purchase service and entitlement.
    func makePaywallModel() -> PaywallModel {
        PaywallModel(purchases: purchases, entitlement: entitlement, environment: dependencies.billingEnvironment, clock: dependencies.clock)
    }
}
