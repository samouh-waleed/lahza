import DDBilling
import DDCore
import Foundation
import Testing
@testable import Lahza

@MainActor @Suite struct ShellTests {
    private func model(onboarded: Bool = false) -> AppModel {
        var dependencies = AppDependencies.testHost()
        if onboarded { AppPreferences(kv: dependencies.kv).markOnboardingCompleted(at: Date()) }
        dependencies.autoBoot = false
        return AppModel(dependencies: dependencies)
    }

    @Test func rootFollowsLaunchAndOnboarding() {
        let app = model()
        #expect(app.root == .launching)
        app.start()
        #expect(app.root == .onboarding)
        app.completeOnboarding()
        #expect(app.root == .tabs)
        #expect(AppPreferences(kv: app.dependencies.kv).onboardingCompleted)
    }

    @Test func returningLaunchGoesStraightToTheTabs() {
        let app = model(onboarded: true)
        app.start()
        #expect(app.root == .tabs)
    }

    @Test func routesOpenTheWayTheirPresentationSays() {
        let app = model(onboarded: true)
        app.start()
        app.open(.appearance)
        #expect(app.router.selectedTab == .settings)
        #expect(app.router.path(for: .settings) == [.appearance])
        app.open(.paywall)
        #expect(app.router.modals.map(\.route) == [.paywall])
        #expect(app.router.modals.first?.fullScreen == true)
        app.open(.paywall)
        #expect(app.router.modals.count == 1)
        app.open(.ask)
        #expect(app.router.selectedTab == .ask)
        #expect(app.router.modals.isEmpty)
    }

    @Test func reselectingATabPopsToItsRoot() {
        let router = AppRouter()
        router.push(.privacy)
        #expect(router.selectedTab == .settings)
        router.userSelected(.settings)
        #expect(router.path(for: .settings).isEmpty)
    }

    @Test func appearanceIsRememberedOnTheDevice() {
        let app = model()
        #expect(app.appearance == .system)
        #expect(app.preferredColorScheme == nil)
        app.setAppearance(.dark)
        #expect(app.preferredColorScheme == .dark)
        #expect(AppPreferences(kv: app.dependencies.kv).appearance == .dark)
        app.setAppearance(.system)
        #expect(AppPreferences(kv: app.dependencies.kv).appearance == .system)
    }

    @Test func everyDebugRouteNameRoundTrips() {
        for route: Route in [.ask, .moments, .settings, .appearance, .privacy, .subscription, .acknowledgements, .paywall, .onboarding] {
            #expect(Route(debugName: route.debugName) == route)
        }
        #expect(Route(debugName: "nope") == nil)
    }

    @Test func noRouteIsLeftWithoutATabOrAModal() {
        for route: Route in [.ask, .moments, .settings, .appearance, .privacy, .subscription, .acknowledgements, .paywall, .onboarding] {
            switch route.presentation {
            case .tabRoot, .push: #expect(route.tab != nil)
            case .sheet, .fullScreen: #expect(route.tab == nil)
            }
        }
    }
}
