import Foundation
import LZBilling
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// Search in the app (search spec §9.2): the store over the fake seed library and an in-memory index, `-LZQuery`,
/// and the memory warning.
@MainActor @Suite struct SearchWiringTests {
    private func app(query: String? = nil) -> AppModel { SearchTestApp.make(.unlocked, query: query) }

    private func eventually(_ app: AppModel, _ condition: () -> Bool) async -> Bool {
        await SearchTestApp.eventually(app, condition)
    }

    private func bestCount(_ app: AppModel) -> Int { SearchTestApp.bestCount(app) }

    @Test func theQueryArgumentParses() {
        let launch = DebugLaunch.parse { ["LZQuery": "  Al-Nakheel Park ", "LZSeed": "hero"][$0] }
        #expect(launch.query == "Al-Nakheel Park")
        #expect(DebugLaunch.parse { $0 == "LZQuery" ? "  " : nil }.query == nil)
        var dependencies = AppDependencies.live()
        launch.apply(to: &dependencies)
        #expect(dependencies.queryAtLaunch == "Al-Nakheel Park")
        #expect(dependencies.label == "debug:seed-hero+query")
    }

    @Test func aQueryAtLaunchSearchesOnceTheIndexIsReady() async {
        let app = app(query: "Al-Nakheel Park")
        app.start()
        #expect(app.router.selectedTab == .ask)
        #expect(await eventually(app) { if case .results = app.search.state { true } else { false } })
        #expect(app.search.text == "Al-Nakheel Park")
        #expect(bestCount(app) == SeedScenario.hero.items(.nakheel).count)
    }

    @Test func searchingEditingAndWideningRunAgain() async {
        let app = app()
        app.start()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        await app.index.placeNamesSettled()
        app.search.submit("Al-Nakheel Park during Ramadan 2024")
        #expect(await eventually(app) { if case .noMatch = app.search.state { true } else { false } })
        guard let offer = app.search.result?.noMatch?.offers.first else {
            Issue.record("no widening offer")
            return
        }
        app.search.widen(offer)
        #expect(await eventually(app) { if case .results = app.search.state { true } else { false } })
        #expect(app.search.text == "Al-Nakheel Park")
        #expect(bestCount(app) == SeedScenario.hero.items(.nakheel).count)

        app.search.apply([.add(.media(.videos))])
        #expect(await eventually(app) { app.search.text == "Al-Nakheel Park videos" && bestCount(app) == 3 })

        app.search.setLayout(.grid)
        #expect(SearchStore(engine: nil, index: app.index, kv: app.dependencies.kv, clock: SystemClock()).layout == .grid)
    }

    @Test func aMemoryWarningReleasesSearchCaches() async {
        let app = app()
        app.start()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        app.search.submit("Greece")
        #expect(await eventually(app) { if case .results = app.search.state { true } else { false } })
        app.didReceiveMemoryWarning()
        app.search.submit("Greece")
        #expect(await eventually(app) { if case .results = app.search.state { true } else { false } }, "searches again after dropping its caches")
    }
}

/// An app over the fake hero library (search spec §9.3's now, fake Apple Maps, Riyadh as the device zone) for the
/// search tests. Every test says whether its user has unlocked the full library: a free search covers only the last
/// 12 months.
@MainActor enum SearchTestApp {
    enum Unlock {
        /// Search covers every year.
        case unlocked
        /// Search covers the last 12 months (decision 34).
        case free
    }

    static func make(_ unlock: Unlock, query: String? = nil, maps: FakeMapsClient = SeedMaps.client()) -> AppModel {
        AppModel(dependencies: dependencies(unlock, query: query, maps: maps))
    }

    static func dependencies(_ unlock: Unlock, query: String? = nil, maps: FakeMapsClient = SeedMaps.client()) -> AppDependencies {
        var dependencies = AppDependencies.testHost()
        dependencies.purchases = FakePurchasesClient(unlocked: unlock == .unlocked)
        dependencies.kv.setString(unlock == .unlocked ? EntitlementStore.Status.unlocked.rawValue : EntitlementStore.Status.free.rawValue,
                                  forKey: KVKey.device(KVSuffix.entitlementCache))
        let photos = FakePhotoLibraryClient(access: .full, answer: .full, counts: [.full: 561, .limited: 40])
        dependencies.photoLibrary = photos
        dependencies.libraryReader = FakeLibraryReader(.seed(.hero), following: photos)
        dependencies.maps = maps
        dependencies.mapsPerMinute = 60_000
        dependencies.network = FakeNetworkStatus(reachable: true)
        dependencies.deviceTimeZone = { TimeZone(identifier: "Asia/Riyadh")! }
        dependencies.clock = OffsetClock(pinnedNow: HeroSuite.now)
        dependencies.queryAtLaunch = query
        AppPreferences(kv: dependencies.kv).markOnboardingCompleted(at: Date())
        return dependencies
    }

    /// A started app whose index is built and whose places are named.
    static func ready(_ unlock: Unlock, maps: FakeMapsClient = SeedMaps.client()) async -> AppModel {
        let app = make(unlock, maps: maps)
        app.start()
        _ = await eventually(app) { app.index.status.phase == .ready }
        await app.index.placeNamesSettled()
        return app
    }

    /// Waits up to 10 s for `condition`.
    static func eventually(_ app: AppModel, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            await app.index.settled()
            await app.search.settled()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Submits `text` and waits for its result or no-match.
    static func search(_ app: AppModel, _ text: String) async -> SearchResult? {
        app.search.submit(text)
        _ = await eventually(app) {
            switch app.search.state {
            case .results, .noMatch, .failed: true
            default: false
            }
        }
        return app.search.result
    }

    static func bestCount(_ app: AppModel) -> Int {
        app.search.result?.hits.count { $0.tier == .best } ?? 0
    }
}
