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
        case .subscription: SubscriptionSettingsScreen()
        case .acknowledgements: AcknowledgementsScreen()
        #if DEBUG
        case .libraryCensus: LibraryCensusScreen()
        #endif
        case .paywall: PaywallScreen()
        case .onboarding: OnboardingView(revisit: true)
        case .notFound(let path): NotFoundView(path: path)
        }
    }
}
