import SwiftUI

/// The single route-to-screen table.
struct RouteScreen: View {
    let route: Route
    /// The screen is inside a sheet or cover.
    var inModal = false

    var body: some View {
        switch route {
        case .ask: AskScreen()
        case .moments: MomentsScreen()
        case .settings: SettingsHomeScreen()
        case .photoAccess: PhotoAccessSettingsScreen()
        case .appearance: AppearanceSettingsScreen()
        case .privacy: PrivacySettingsScreen()
        case .fullLibrary: FullLibrarySettingsScreen()
        case .acknowledgements: AcknowledgementsScreen()
        case .searchIndex: SearchIndexScreen()
        case .savedPlaces: SavedPlacesScreen()
        case .moment(let ref): MomentDetailScreen(ref: ref)
        case .trip(let ref): TripDetailScreen(ref: ref)
        #if DEBUG
        case .libraryCensus: LibraryCensusScreen()
        case .indexInspector: IndexInspectorScreen()
        case .lockedResults: LockedResultsPreviewScreen()
        case .labelLab: LabelLabScreen()
        #endif
        case .paywall: PaywallScreen()
        case .onboarding: OnboardingView(revisit: true)
        case .notFound(let path): NotFoundView(path: path)
        }
    }
}
