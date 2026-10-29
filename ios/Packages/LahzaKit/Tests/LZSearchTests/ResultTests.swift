import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Grouping, cards, reasons and the coverage line (search spec §6.7) over the hero index.
@Suite struct ResultTests {
    static let hero = SeedScenario.hero

    @Test func cardsAreNewestFirstWithTheNoDateCardLast() async throws {
        let search = try await HeroSearch()
        let result = try await search.search("only photos")
        let best = try #require(result.sections.filter { $0.tier == .best }.first)
        let cards = best.groups.flatMap(\.cards)
        #expect(cards.last?.id == MomentCard.noDateKey)
        #expect(cards.last?.hits.count == Self.hero.items(.undated).count)
        let dated = cards.dropLast().map(\.id.startUTC)
        #expect(dated == dated.sorted(by: >), "newest first")
        for card in cards {
            let utcs = card.hits.compactMap(\.utc)
            #expect(utcs == utcs.sorted(), "a card's hits in time order")
        }
    }

    @Test func tripsGetHeadersWhenTheQueryIsAboutThem() async throws {
        let search = try await HeroSearch()
        let greece = try await search.search("Greece")
        #expect(greece.sections.allSatisfy { $0.groups.allSatisfy { if case .trip = $0 { true } else { false } } }, "a country abroad")
        let park = try await search.search("Al-Nakheel Park")
        #expect(park.sections.allSatisfy { $0.groups.allSatisfy { if case .moment = $0 { true } else { false } } })
        let summer = try await search.search("summer")
        let trips = summer.sections.first { $0.tier == .best }?.groups.compactMap { group -> String? in if case .trip(let trip) = group { trip.trip.label } else { nil } }
        #expect(Set(trips ?? []) == ["Greece", "Sydney"], "two Best cards share a trip")
    }

    @Test func reasonsUseTheirTemplates() async throws {
        let search = try await HeroSearch()
        let kingdom = try await search.search("near Kingdom Centre")
        let sufra = try #require(Self.hero.items(.sufra).first)
        let near = try #require(kingdom.reasons(of: sufra).first)
        #expect(near.hasSuffix(" m from Kingdom Centre") && near.hasPrefix("6"), "\(near)")
        #expect(kingdom.hits.first { $0.utc == sufra.utc }?.reasons.first?.kind == .caution)

        let years = try await search.search("3 years ago")
        let greek = try #require(Self.hero.items(.greece).first)
        #expect(years.reasons(of: greek) == ["2023 · 3 years ago"])

        let ramadan = try await search.search("Ramadan 2024")
        let eid = try #require(Self.hero.items(.eid).first)
        #expect(ramadan.reasons(of: eid) == ["Day after Ramadan 1445"])

        let videos = try await search.search("videos")
        let video = try #require(Self.hero.items.filter(\.isVideo).first)
        #expect(videos.reasons(of: video) == ["Video · 0:03"])

        let summer = try await search.search("last summer")
        let shown = Self.hero.items(.screens).filter { !summer.reasons(of: $0).isEmpty }
        let screenshot = try #require(shown.first)
        #expect(summer.reasons(of: screenshot).contains("Screenshot (ranked lower)"))

        let riyadh = try await search.search("Riyadh 2025")
        let orphan = try #require(Self.hero.items(.orphans).first)
        #expect(riyadh.reasons(of: orphan) == ["No location data", "2025"])
        let section = try #require(riyadh.sections.filter { $0.tier == .locationUnknown }.first)
        #expect(section.title == "Location unknown · 5")

        let park = try await search.search("Al-Nakheel Park")
        let borrowedCards = park.cards.filter { $0.borrowedCount > 0 }
        #expect(borrowedCards.count == 2)
        #expect(borrowedCards.allSatisfy { $0.reasons.map(\.text) == ["In Al-Nakheel Park", "Includes 1 without location from this outing"] })
        let received = try #require(Self.hero.items(.received).first)
        #expect(park.cards.first { card in card.hits.contains { $0.utc == received.utc } }?.reasons.map(\.text) == ["Saved the day of your Al-Nakheel Park visit"])
        #expect(park.sections.map(\.title) == ["Inside Al-Nakheel Park", "Nearby or close in time"])

        let greece = try await search.search("Greece")
        let unlocated = try #require(Self.hero.items(.greece).filter { !$0.isLocated }.first)
        #expect(greece.reasons(of: unlocated) == ["During your Greece trip"])
    }

    @Test func totalsAndCoverage() async throws {
        let search = try await HeroSearch()
        let park = try await search.search("Al-Nakheel Park")
        let nakheel = Self.hero.items(.nakheel), received = Self.hero.items(.received)
        #expect(park.totals.moments == 10 + received.count)
        #expect(park.totals.videos == nakheel.count(where: \.isVideo))
        #expect(park.totals.items == nakheel.count + received.count)
        #expect(park.coverage.caption == "Searched all \(Self.hero.items.count) photos")
        let unlocated = Self.hero.items.count { !$0.isLocated && $0.borrowing != .moment }
        let share = (Double(unlocated) / Double(Self.hero.items.count)).formatted(.percent.precision(.fractionLength(0)).locale(SearchFixture.uk))
        #expect(park.coverage.notes == ["+2 without location from the same outing", "\(share) of your photos have no location"])

        let since = Date(timeIntervalSince1970: 1_710_460_800)    // 15 Mar 2024
        let partial = try await search.search("2025", index: SearchIndexContext(isPartial: true, coveredSince: since, libraryTotal: 2_000))
        #expect(partial.coverage.caption == "Searched \(Self.hero.items.count) of about 2,000 so far")
        #expect(partial.coverage.header == "Searched your photos since Mar 2024, still reading older ones")
        #expect(partial.coverage.notes.contains("\(Self.hero.items(.undated).count) photos have no reliable date"))
        let limited = try await search.search("2025", index: SearchIndexContext(isLimited: true))
        #expect(limited.coverage.caption == "Searching the \(Self.hero.items.count) photos you’ve shared")
    }

    @Test func theFreemiumScopeDropsOlderHitsAfterTiering() async throws {
        let search = try await HeroSearch()
        let since = Date(timeIntervalSince1970: 1_767_225_600)    // 1 Jan 2026 UTC
        let scoped = try await search.search(SearchRequest(text: "Al-Nakheel Park", scope: .since(since)))
        let all = (Self.hero.items(.nakheel) + Self.hero.items(.received)).filter { $0.utc != nil }
        #expect(scoped.lockedCount == all.count { $0.utc! < 1_767_225_600 })
        #expect(scoped.hits.allSatisfy { ($0.utc ?? 0) >= 1_767_225_600 })
    }

    @Test func weakerMatchesShowOnlyWhenAskedFor() async throws {
        let search = try await HeroSearch()
        let hidden = try await search.search("Ramadan 2024")
        #expect(hidden.weakerCount > 0)
        #expect(!hidden.sections.contains { $0.tier == .weaker })
        let shown = try await search.search(SearchRequest(text: "Ramadan 2024", showWeaker: true))
        #expect(shown.sections.last?.tier == .weaker)
        #expect(shown.sections.last?.groups.flatMap(\.cards).flatMap(\.hits).count == hidden.weakerCount)
    }

    @Test func relativeDatesMoveOnWhileTheIndexStaysTheSame() async throws {
        let search = try await HeroSearch()
        let today = try await search.search("yesterday")
        let examples = try await search.engine.examples(reader: search.index.reader)
        search.clock.set(SearchFixture.now.addingTimeInterval(2 * 86_400))
        let later = try await search.search("yesterday")
        func start(_ result: SearchResult) -> Int64? {
            guard case .time(.constraint(let constraint))? = result.query.slots.first?.resolution else { return nil }
            return constraint.ranges?.first?.lowerBound
        }
        #expect(start(today) == SearchFixture.wall(2026, 10, 27, 4))
        #expect(start(later) == SearchFixture.wall(2026, 10, 29, 4), "two days on, “yesterday” is two days later")
        search.clock.set(SearchFixture.now.addingTimeInterval(366 * 86_400))
        #expect(try await search.engine.examples(reader: search.index.reader) != examples, "“last Ramadan” and “N years ago” a year on")
    }

    @Test func appleMapsGetsTheHomesAreaNeverItsPosition() async throws {
        let search = try await HeroSearch()
        _ = try await search.search("Sufra Grill")
        let home = try #require(try await search.index.reader.homeBase(year: nil)?.center)
        guard case .search(_, let region)? = search.maps.calls.first, let region else { Issue.record("calls \(search.maps.calls)"); return }
        #expect(region.center == Coordinate(latitude: home.latitude.rounded(), longitude: home.longitude.rounded()))
        #expect(region.center != home && region.spanDegrees == 4)
    }

    @Test func aDateLahzaCantUseIsQuotedAsTyped() {
        let copy = SearchCopy(locale: SearchFixture.uk, resolver: SearchFixture.saudi())
        let text = "Al-Nakheel Park national day"
        let slot = QuerySlot(id: 1, value: .time(.holiday(.nationalDay, .last)), span: TextSpan(location: 16, length: 12))
        let unusable = ResolvedSlot(slot: slot, resolution: .unsupported, chip: "National day of which country?", systemImage: "info.circle")
        #expect(copy.unsupportedNotice([unusable], text: text, showing: "at Al-Nakheel Park")
                == "Lahza can’t search for everything you asked yet, so “national day” was left out. Showing all your photos at Al-Nakheel Park.")
    }

    @Test func aReRunAfterTheIndexChangedFindsAPlaceReadSinceThen() async throws {
        let search = try await HeroSearch()
        let database = search.index.database
        // During the first build: Greece's photos and its row aren't read yet.
        try await database.write { db in
            try db.execute(sql: "UPDATE place_name SET name = 'zz' || name WHERE place_id = (SELECT id FROM place WHERE key = 'cc:GR')")
            try db.execute(sql: "UPDATE place SET key = 'hidden:GR' WHERE key = 'cc:GR'")
            _ = try Meta.bumpVersion(db)
        }
        let request = SearchRequest(text: "Greece")
        let before = try await search.search(request)
        #expect(before.noMatch?.kind == .placeEmpty)
        // They are now.
        try await database.write { db in
            try db.execute(sql: "UPDATE place SET key = 'cc:GR' WHERE key = 'hidden:GR'")
            try db.execute(sql: "UPDATE place_name SET name = substr(name, 3) WHERE place_id = (SELECT id FROM place WHERE key = 'cc:GR')")
            _ = try Meta.bumpVersion(db)
        }
        let asked = search.mapsSearches
        let rerun = try await search.engine.search(request, reader: search.index.reader, writer: search.index.writer, isRerun: true)
        #expect(rerun.noMatch == nil)
        #expect(rerun.totals.items == (try await search.search("Greece")).totals.items)
        #expect(search.mapsSearches == asked, "a re-run never asks Apple Maps")
        #expect(!rerun.query.searchedAppleMaps)
    }
}
