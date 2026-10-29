import Foundation
import LZBilling
import LZCore
import LZGeo
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// A free user's search on Ask (decision 34, E11) over the fake hero library at the spec's now: the last 12 months, the
/// older matches counted for the unlock row, the answer when every match is older, examples that count what a tap
/// shows, and an unlock that shows the earlier years at once. Expectations come from the scenario's dates. Also E17
/// (examples after a no-match with no offer left), E18 (onboarding's example) and `-LZUnlocked`.
@MainActor @Suite struct FreeSearchTests {
    static let hero = SeedScenario.hero

    private func window(_ app: AppModel) throws -> Int64 {
        Int64(try #require(app.entitlement.searchStart(now: HeroSuite.now)).timeIntervalSince1970)
    }

    private func numbers(_ result: SearchResult?, _ tier: Tier) -> Set<Int> {
        Set(result?.hits.filter { $0.tier == tier }.compactMap { $0.utc.flatMap { Self.hero.item(matchingUTC: $0)?.number } } ?? [])
    }

    @Test func aFreeSearchShowsTheLastTwelveMonthsAndCountsTheRest() async throws {
        let app = await SearchTestApp.ready(.free)
        #expect(!app.entitlement.isUnlocked)
        let since = try window(app)
        let nakheel = Self.hero.items(.nakheel)
        let received = Self.hero.items(.received).filter { item in nakheel.contains { $0.momentDay == item.momentDay } }
        let recent = nakheel.filter { $0.utc! >= since }
        #expect(recent.count == nakheel.count { [2026].contains(LocalTime.civil(day: $0.momentDay!).year) }, "the 2026 sessions")

        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        // The scope is read at the search (the test clock runs on from the spec's now).
        guard case .since(let start)? = app.search.request?.scope else { Issue.record("not a free search"); return }
        #expect(abs(start.timeIntervalSince1970 - TimeInterval(since)) < 120)
        #expect(numbers(result, .best) == Set(recent.map(\.number)))
        #expect(result.lockedCount == nakheel.count { $0.utc! < since } + received.count { $0.utc! < since })
        #expect(LockedResultsRow.isShown(lockedCount: result.lockedCount, isUnlocked: false))
        #expect(BillingCopy.moreFromEarlierYears(result.lockedCount, locale: Locale(identifier: "en_US")) == "\(result.lockedCount) more from earlier years")
    }

    /// Greece (2023): nothing in the last 12 months, all 75 counted, and a headline that says why, never "nothing".
    @Test func everyMatchOlderSaysSoAndAnUnlockShowsThem() async throws {
        let app = await SearchTestApp.ready(.free)
        let greece = Self.hero.items(.greece)
        let result = try #require(await SearchTestApp.search(app, "Greece"))
        let noMatch = try #require(result.noMatch)
        #expect(noMatch.kind == .onlyEarlier)
        #expect(noMatch.headline == "No matches in the last 12 months.")
        #expect(result.lockedCount == greece.count && greece.count == 75)
        #expect(AskCopy.onlyEarlierDetail == "Search covers the last 12 months. Moments and trips show every year.")
        #expect(AskCopy.noMatchSymbol(.onlyEarlier) == "clock.arrow.circlepath")

        // Buying from the row: the search on screen runs again with every year, and the row goes.
        let paywall = app.makePaywallModel()
        await paywall.load()
        await paywall.purchase()
        #expect(app.entitlement.isUnlocked)
        #expect(await SearchTestApp.eventually(app) { app.search.result?.noMatch == nil && app.search.result?.id != result.id })
        #expect(app.search.result?.lockedCount == 0 && app.search.request?.scope == .wholeLibrary)
        #expect(numbers(app.search.result, .best) == Set(greece.filter(\.isLocated).map(\.number)))
        #expect(!LockedResultsRow.isShown(lockedCount: 75, isUnlocked: app.entitlement.isUnlocked))
    }

    /// The examples a free user sees count what tapping them shows.
    @Test func freeExamplesAreTruthful() async throws {
        let app = await SearchTestApp.ready(.free)
        // The index's last change also refreshes the examples (after a pause), which can cancel a request made just
        // before it lands: ask until they are there.
        for _ in 0..<150 where app.search.examples.isEmpty {
            app.search.refreshExamples(after: .zero)
            await app.search.settled()
            if app.search.examples.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let examples = app.search.examples
        #expect(!examples.isEmpty)
        #expect(!examples.contains { $0.text.hasSuffix(" trip") }, "every trip is older than 12 months")
        for example in examples {
            _ = await SearchTestApp.search(app, example.text)
            #expect(SearchTestApp.bestCount(app) == example.count, "\(example.text)")
        }
    }

    /// E17: a lone name no place confirms leaves no offer, so the examples follow it.
    @Test func noOfferLeftShowsTheExamples() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "kebab"))
        #expect(result.noMatch?.kind == .placeNotFound(.unconfirmed))
        #expect(result.noMatch?.offers.isEmpty == true)
        #expect(result.noMatch?.examples.map(\.text).first == "Dubai trip")
    }

    /// E18: onboarding quotes the same example as the field.
    @Test func onboardingQuotesTheFieldsExample() {
        #expect(OnboardingCopy.promises.first?.detail == "“Dubai last December” is enough.")
        #expect(AskCopy.prompt == "Dubai last December…")
    }

    @Test func theUnlockedArgumentStartsTheFakeStoreUnlockedOrFree() {
        for (value, unlocked) in [("1", true), ("0", false)] {
            let launch = DebugLaunch.parse { ["LZUnlocked": value, "LZSeed": "hero"][$0] }
            #expect(launch.unlocked == unlocked)
            var dependencies = AppDependencies.testHost()
            launch.apply(to: &dependencies)
            #expect(dependencies.purchases is FakePurchasesClient)
            #expect(dependencies.billingEnvironment.usesTestStore)
            #expect(dependencies.kv.string(forKey: KVKey.device(KVSuffix.entitlementCache)) == (unlocked ? "unlocked" : "free"))
            #expect(dependencies.label == "debug:\(unlocked ? "unlocked" : "free")+seed-hero")
            #expect(EntitlementStore(kv: dependencies.kv).isUnlocked == unlocked)
        }
        #expect(DebugLaunch.parse { $0 == "LZUnlocked" ? "maybe" : nil }.unlocked == nil)
    }
}
