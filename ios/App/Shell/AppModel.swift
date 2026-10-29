import LZBilling
import LZCore
import LZDesign
import Foundation
import LZGeo
import LZIndex
import LZLibrary
import Observation
import SwiftUI
import UIKit

/// The screen under the modals.
nonisolated enum RootScreen: Hashable, Sendable {
    /// Launch has not finished (the launch surface holds).
    case launching
    case onboarding
    case tabs
}

/// The composition root: builds the services, decides the root screen, opens every route and
/// follows the scene phase (re-reading photo access whenever Lahza returns to the foreground, and
/// resuming or pausing the search index). Injected through the environment (`@Environment(AppModel.self)`).
@MainActor @Observable final class AppModel {
    /// The app's one model (built from ``AppDependencies/resolve()``).
    static let shared = AppModel(dependencies: .resolve())

    @ObservationIgnored let dependencies: AppDependencies
    let router = AppRouter()
    @ObservationIgnored let toasts = LZToastCenter()
    @ObservationIgnored let feedback = LZFeedbackSettings()
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let purchases: PurchasesService
    let entitlement: EntitlementStore
    let photoAccess: PhotoAccessStore
    /// The offline place list, loaded once (nil only if the bundled file is broken: search is then off).
    @ObservationIgnored let gazetteer: Gazetteer?
    /// The search index: status, reader and Settings controls.
    let index: IndexStore
    /// The Moments tab's data.
    let moments: MomentsStore
    @ObservationIgnored let images: any AssetImageProvider
    /// The Apple Maps budget, shared by place naming and (later) search.
    @ObservationIgnored let mapsBudget: MapsBudget
    #if DEBUG
    /// DEBUG: Settings › Developer › Library census (Phase 0 spike S2). It lives here so a run
    /// carries on when its screen is left.
    @ObservationIgnored let censusRunner: CensusRunner
    #endif

    private(set) var isReady = false
    private(set) var onboardingCompleted: Bool
    private(set) var appearance: AppearanceMode
    private(set) var scenePhase: ScenePhase = .inactive

    /// The latest photo-access refresh (tests await it).
    @ObservationIgnored private(set) var photoRefresh: Task<Void, Never>?
    /// The scene went to the background since it was last active (a trip to iPhone Settings does).
    @ObservationIgnored private var leftForBackground = false
    @ObservationIgnored private var indexVersions: Task<Void, Never>?
    @ObservationIgnored private var memoryWarnings: Task<Void, Never>?
    @ObservationIgnored private let log = Log("shell")

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        preferences = AppPreferences(kv: dependencies.kv)
        purchases = dependencies.makePurchasesService()
        entitlement = EntitlementStore(kv: dependencies.kv, entitlementIdentifier: dependencies.billingEnvironment.entitlementIdentifier)
        photoAccess = PhotoAccessStore(client: dependencies.photoLibrary)
        gazetteer = Self.loadGazetteer()
        mapsBudget = MapsBudget(perMinute: dependencies.mapsPerMinute, clock: dependencies.clock)
        index = IndexStore(dependencies.makeIndexDependencies(gazetteer: gazetteer, budget: mapsBudget))
        moments = MomentsStore(index: index)
        images = dependencies.images
        #if DEBUG
        censusRunner = CensusRunner(source: dependencies.censusSource)
        #endif
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
    /// the first screen (free search works without it). Photo access is read and counted in the
    /// background too, and never asked for here.
    func start() {
        guard !isReady else { return }
        log.info("Launch (\(dependencies.label))", privacy: .public)
        isReady = true
        Task { await entitlement.start(with: purchases) }
        photoAccess.start()
        refreshPhotoAccess()
        startIndex()
        if let route = dependencies.initialRoute { open(route) }
    }

    /// The bundled gazetteer. A failure is a build error: a crash in DEBUG, a logged fault in Release (search off).
    private static func loadGazetteer() -> Gazetteer? {
        do {
            return try Gazetteer.bundled()
        } catch {
            #if DEBUG
            fatalError("The bundled gazetteer must load: \(error)")
            #else
            Log("index").fault("Gazetteer failed to load", privacy: .public)
            return nil
            #endif
        }
    }

    /// Starts the index (it opens or purges by photo access), refreshes Moments when the index changes and
    /// releases caches on a memory warning.
    private func startIndex() {
        index.start(observing: photoAccess)
        let index = index, moments = moments
        indexVersions = Task {
            for await _ in Observations({ index.version }) { await moments.indexChanged() }
        }
        memoryWarnings = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                self?.didReceiveMemoryWarning()
            }
        }
    }

    /// Drops what can be rebuilt: the gazetteer's name index and cached thumbnails.
    func didReceiveMemoryWarning() {
        gazetteer?.releaseNameIndex()
        images.stopAll()
        log.notice("Memory warning: caches released", privacy: .public)
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

    /// Onboarding's last step: the iOS photo prompt when access is undecided, then the tabs whatever
    /// the answer (Lahza works without access and points to Settings). Already decided, it finishes
    /// without asking.
    func finishOnboarding() async {
        await photoAccess.request()
        completeOnboarding()
    }

    // MARK: Photo library

    /// Re-reads photo access and recounts, in the background.
    @discardableResult
    func refreshPhotoAccess() -> Task<Void, Never> {
        let task = Task { await photoAccess.refresh() }
        photoRefresh = task
        return task
    }

    /// The system picker for the limited selection, then a recount.
    func chooseLimitedPhotos() async {
        await dependencies.presentLimitedLibraryPicker()
        await photoAccess.refresh()
    }

    // MARK: Settings

    func setAppearance(_ mode: AppearanceMode) {
        preferences.setAppearance(mode)
        appearance = mode
    }

    // MARK: Scene

    func scenePhaseChanged(_ phase: ScenePhase) {
        scenePhase = phase
        if isReady, phase != .inactive { index.setSceneActive(phase == .active) }
        switch phase {
        case .background:
            leftForBackground = true
            #if DEBUG
            censusRunner.appLeftForeground()
            #endif
        case .active where leftForBackground:
            // People change photo access in iPhone Settings; Lahza is not told, so it re-reads on
            // return. Brief blips (the iOS prompt, Control Center) never leave the app, and launch
            // has already counted, so neither recounts.
            leftForBackground = false
            refreshPhotoAccess()
        default:
            break
        }
    }

    // MARK: Billing

    /// A paywall model over the shared purchase service and entitlement.
    func makePaywallModel() -> PaywallModel {
        PaywallModel(purchases: purchases, entitlement: entitlement, environment: dependencies.billingEnvironment)
    }
}
