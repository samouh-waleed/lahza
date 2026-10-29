import Foundation
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// The grid layout of a result (search spec §7.1 item 8): sections, then months, in the result's order; Location
/// unknown only when opened; undated photos under "No date"; the badges a tile needs.
@Suite struct ResultGridTests {
    static let hero = SeedScenario.hero

    @Test func eachSectionListsItsPhotosByMonthInTheResultsOrder() async throws {
        let search = try await HeroSearch.shared.value
        let park = try await search.search("Al-Nakheel Park")
        let grid = ResultGrid(park, showsUnknown: false)
        #expect(grid.tiles.map(\.hit.id) == park.hits.map(\.id), "the viewer pages in the cards' order")
        #expect(grid.tiles.enumerated().allSatisfy { $0.offset == $0.element.position })
        #expect(grid.sections.map(\.title) == ["Inside Al-Nakheel Park", "Nearby or close in time"])
        for section in grid.sections {
            #expect(!section.isCollapsed)
            for month in section.months {
                #expect(!month.tiles.isEmpty)
                for tile in month.tiles {
                    let civil = LocalTime.civil(day: tile.card.day)
                    #expect(civil.year == month.year && civil.month == month.month)
                }
            }
            // Cards are newest first, so months descend; a month is one block unless a trip spans it.
            let months = section.months.map { ($0.year ?? 0) * 12 + ($0.month ?? 0) }
            #expect(months == months.sorted(by: >))
            #expect(Set(section.months.map(\.id)).count == section.months.count)
        }
        let card = try #require(park.cards.dropFirst(3).first)
        #expect(grid.firstTile(of: card.id)?.hit.id == card.hits.first?.id)
    }

    @Test func locationUnknownListsItsPhotosOnlyWhenOpened() async throws {
        let search = try await HeroSearch.shared.value
        let riyadh = try await search.search("Riyadh 2025")
        let unknown = riyadh.hits.count { $0.tier == .locationUnknown }
        #expect(unknown == 5)
        let closed = ResultGrid(riyadh, showsUnknown: false)
        let section = try #require(closed.sections.first { $0.tier == .locationUnknown })
        #expect(section.isCollapsed && section.months.isEmpty)
        #expect(section.title == "Location unknown · 5")
        #expect(closed.tiles.count == riyadh.hits.count - unknown)
        let open = ResultGrid(riyadh, showsUnknown: true)
        #expect(open.tiles.map(\.hit.id) == riyadh.hits.map(\.id))
    }

    @Test func undatedPhotosComeLastUnderNoDate() async throws {
        let search = try await HeroSearch.shared.value
        let photos = try await search.search("only photos")
        let grid = ResultGrid(photos, showsUnknown: true)
        let last = try #require(grid.sections.first { $0.tier == .best }?.months.last)
        #expect(last.year == nil && last.month == nil)
        #expect(last.tiles.count == Self.hero.items(.undated).count)
        #expect(last.tiles.allSatisfy { $0.card == MomentCard.noDateKey && $0.hit.utc == nil })
    }

    @Test func tilesKnowTheirVideoLengthFavouriteAndNearbyBadges() async throws {
        let search = try await HeroSearch()
        // The seed has no favourites: make one of the park's videos a favourite.
        let video = try #require(Self.hero.items(.nakheel).first { $0.isVideo })
        try await search.index.database.write { db in
            try db.execute(sql: "UPDATE asset SET flags = flags | ? WHERE created_utc = ?", arguments: [AssetFlags.favorite.rawValue, video.utc])
            _ = try Meta.bumpVersion(db)
        }
        await search.index.reader.releaseSnapshot()
        let park = try await search.search("Al-Nakheel Park")
        let grid = ResultGrid(park, showsUnknown: false)
        let tile = try #require(grid.tiles.first { $0.hit.utc == video.utc })
        #expect(tile.hit.kind == .video && tile.hit.duration == 3)
        #expect(tile.hit.isFavorite)
        #expect(grid.tiles.count(where: \.hit.isFavorite) == 1)
        // The "nearby" dot: a More photo inside a better card, never a photo of the More section's own cards.
        let cards = Dictionary(park.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tile in grid.tiles {
            #expect(tile.hit.isNearby == (tile.hit.tier == .more && (cards[tile.card]?.tier ?? .more) < .more))
        }
    }
}
