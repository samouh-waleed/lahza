import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Scoring and tiers (search spec §6.5): the area fade, the borrowed, received, trip and unknown place scores, the time
/// fuzz, the screenshot penalty and every tier rule. Place and time scores are read off the hero index.
@Suite struct ScoringTests {
    static let hero = SeedScenario.hero

    // MARK: Areas

    @Test func areasFadeOutsideTheirRadius() {
        #expect(Scorer.areaScore(distance: 300, radius: 400, accuracy: -1) == 1)
        #expect(Scorer.areaScore(distance: 400, radius: 400, accuracy: -1) == 1)
        #expect(abs(Scorer.areaScore(distance: 600, radius: 400, accuracy: -1) - 0.78) < 0.005, "1.5r → 0.78")
        #expect(abs(Scorer.areaScore(distance: 800, radius: 400, accuracy: -1) - 0.37) < 0.005, "2r → 0.37")
        #expect(Scorer.areaScore(distance: 5_000, radius: 400, accuracy: -1) == 0.05, "a floor of 0.05")
        // The GPS accuracy comes off the distance, up to the radius.
        #expect(Scorer.areaScore(distance: 404, radius: 400, accuracy: 5) == 1)
        #expect(Scorer.areaScore(distance: 404, radius: 400, accuracy: -1) < 1)
        #expect(Scorer.areaScore(distance: 1_000, radius: 100, accuracy: 900) == Scorer.areaScore(distance: 900, radius: 100, accuracy: -1))
    }

    // MARK: Place scores on the hero index

    private func scorer(_ search: HeroSearch, _ text: String) async throws -> (Scorer, SearchSnapshot) {
        let snapshot = try await search.index.reader.snapshot()
        let context = try await search.engine.context(search.index.reader)
        let parsed = await search.engine.parse(text, reader: search.index.reader)
        let query = try await search.engine.prepare(parsed, overrides: ResolutionOverrides(), reader: search.index.reader, writer: search.index.writer,
                                                    snapshot: snapshot, context: context, appleMaps: true, isRerun: false, progress: nil)
        return (Scorer(snapshot: snapshot, plan: query.plan), snapshot)
    }

    private func index(of item: SeedItem, in snapshot: SearchSnapshot) -> Int {
        snapshot.utc.firstIndex(of: item.utc ?? Int64.min)!
    }

    @Test func photosWithoutAPositionScoreByWhatTheirDayOrTripSays() async throws {
        let search = try await HeroSearch()
        var (park, snapshot) = try await scorer(search, "Al-Nakheel Park")
        let target = try #require(park.plan.place)
        let borrowed = Self.hero.items(.nakheel).filter { !$0.isLocated }
        #expect(borrowed.count == 2)
        for item in borrowed {
            let (score, evidence) = park.placeScore(index(of: item, in: snapshot), target)
            #expect(abs(score.value - 0.9) < 1e-9 && evidence == .inside(metro: false), "position from the same outing: × 0.9")
        }
        for item in Self.hero.items(.received) {
            let (score, evidence) = park.placeScore(index(of: item, in: snapshot), target)
            #expect(score.value == 0.6, "received the day of a visit: 0.6")
            if case .receivedSameDay = evidence {} else { Issue.record("evidence \(evidence)") }
        }
        let screenshot = try #require(Self.hero.items(.screens).first)
        #expect(park.placeScore(index(of: screenshot, in: snapshot), target).0 == .unknown)

        var greece: Scorer
        (greece, snapshot) = try await scorer(search, "Greece")
        for item in Self.hero.items(.greece).filter({ !$0.isLocated }) {
            let (score, evidence) = greece.placeScore(index(of: item, in: snapshot), try #require(greece.plan.place))
            #expect(score.value == 0.75, "during a trip to the country: 0.75")
            if case .tripBorrow = evidence {} else { Issue.record("evidence \(evidence)") }
        }
        let home = try #require(Self.hero.items(.home).first)
        #expect(greece.placeScore(index(of: home, in: snapshot), try #require(greece.plan.place)).0.value == 0.05, "located elsewhere: 0.05")
    }

    // MARK: Time

    @Test func timeFuzzFollowsTheSpec() {
        let saudi = SearchFixture.saudi()
        #expect(saudi.resolve(.year(2025)).constraint?.tau == Int64(36.5 * 86_400), "a year → 36.5 days")
        #expect(saudi.resolve(.date(day: 14, month: 6, year: 2025)).constraint?.tau == Int64(3 * 86_400), "a day → 3 days")
        #expect(saudi.resolve(.season(.summer, .year(2025))).constraint?.tau == Int64(92 * 86_400 / 10), "a season → 9.2 days")
        #expect(saudi.resolve(.hijri(.ramadan, .year(2024), hijriYear: nil)).constraint?.tau == Int64(86_400), "Hijri events → 1 day")

        let evening = PartOfDay.evening.window
        #expect(Scorer.signedMinutes(21 * 60 + 45, evening) == 46, "45 minutes after 21:00, inclusive end")
        #expect(Scorer.signedMinutes(16 * 60 + 30, evening) == -30)
        #expect(Scorer.daysOff((2025, 9, 2), months: [6, 7, 8]) == 2, "two days after August")
        #expect(Scorer.daysOff((2025, 5, 30), months: [6, 7, 8]) == -2, "two days before June")
        #expect(Scorer.daysOff((2025, 1, 15), months: [6, 7, 8]) == 99)

        let ranges = [Int64(1_000)..<2_000, 5_000..<6_000]
        #expect(Scorer.distance(1_500, outside: ranges) == nil)
        #expect(Scorer.distance(2_500, outside: ranges)?.distance == 501)
        #expect(Scorer.distance(4_000, outside: ranges)?.distance == 1_000)
        #expect(Scorer.distance(4_000, outside: ranges)?.after == false)
    }

    @Test func nearMissesInTimeScoreByTheirFuzz() async throws {
        let search = try await HeroSearch()
        let (ramadan, snapshot) = try await scorer(search, "Ramadan 2024")
        let constraint = try #require(ramadan.plan.time)
        let eid = Self.hero.items(.eid).filter { $0.momentDay == LocalTime.day(year: 2024, month: 4, day: 10) }
        for item in eid {
            let (score, evidence) = ramadan.timeScore(index(of: item, in: snapshot), constraint)
            #expect(score.value > 0.7 && score.value < 0.8, "6–7 h after the 04:00 end, τ 1 day: ≈ 0.75–0.78")
            #expect(evidence == .nearMiss(days: 1))
        }
        let undated = try #require(Self.hero.items(.undated).first)
        #expect(ramadan.timeScore(index(of: undated, in: snapshot), constraint).0 == .unknown, "no reliable date: unknown")
    }

    // MARK: Tiers

    private func tier(place: Double? = nil, placeUnknown: Bool = false, time: Double? = nil, event: Double? = nil, junk: Double = 1) -> Tier? {
        var asset = ScoredAsset(index: 0, tier: .weaker, score: 0, junk: junk)
        var scores: [SlotScore] = []
        if let place {
            asset.place = placeUnknown ? .unknown : SlotScore(value: place)
            scores.append(asset.place!)
        }
        if let time {
            asset.time = SlotScore(value: time)
            scores.append(asset.time!)
        }
        if let event {
            asset.event = SlotScore(value: event)
            scores.append(asset.event!)
        }
        asset.score = scores.isEmpty ? junk : junk * exp(scores.reduce(0) { $0 + log(max($1.value, 0.02)) } / Double(scores.count))
        return Scorer.tier(asset, scores: scores)
    }

    @Test func tiersFollowTheirRules() {
        #expect(tier(place: 1, time: 1) == .best)
        #expect(tier(place: 0.85) == .best, "Best from 0.85")
        #expect(tier(place: 0.84) == .more)
        #expect(tier(place: 1, time: 0.99) == .more, "Best needs to be inside the dates")
        #expect(tier(event: 1) == .best)
        #expect(tier(event: 0.05) == nil)
        #expect(tier(place: 1, time: 1, junk: 0.5) == .more, "screenshots rank lower")
        #expect(tier(place: 0.4) == .weaker, "0.35 ≤ S < 0.5")
        #expect(tier(place: 0.3) == nil)
        #expect(tier(place: 1, time: 0.1) == nil, "no slot at 0.1 or below")
        #expect(tier(place: 0.5, placeUnknown: true, time: 1) == .locationUnknown)
        #expect(tier(place: 0.5, placeUnknown: true, time: 1, junk: 0.5) == nil, "Location unknown needs J = 1")
        #expect(tier(place: 0.5, placeUnknown: true, time: 0.9) == nil, "every other slot must match exactly")
        #expect(tier(place: 0.5, placeUnknown: true) == nil, "place-only queries never list photos without a location")
        #expect(tier(junk: 1) == .best, "a media-only query: every filtered asset scores 1")
    }
}
