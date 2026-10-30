import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// The grid and the viewer on Ask (search spec §7.1, PR 4) over the fake hero library, unlocked: `-LZResultsLayout`,
/// switching layouts keeps the result (acceptance 3) and the place, the grid's rows and badges, the thumbnails prepared
/// ahead, and the viewer's pages, times with their zone, places and reasons (acceptance 4).
@MainActor @Suite struct GridAndViewerTests {
    static let hero = SeedScenario.hero
    private let phoenix = TimeZone(identifier: "America/Phoenix")!
    private let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    private let us = Locale(identifier: "en_US")

    /// The words with the narrow no-break space of "5:28 PM" made plain.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: Layout

    @Test func theLayoutArgumentStartsTheResultsWithoutRememberingIt() {
        let launch = DebugLaunch.parse { ["LZResultsLayout": "Grid", "LZSeed": "hero"][$0] }
        #expect(launch.resultsLayout == .grid)
        #expect(DebugLaunch.parse { $0 == "LZResultsLayout" ? "mosaic" : nil }.resultsLayout == nil)
        var dependencies = SearchTestApp.dependencies(.unlocked)
        launch.apply(to: &dependencies)
        #expect(dependencies.resultsLayout == .grid)
        #expect(dependencies.label.hasSuffix("+layout-grid"))
        let app = AppModel(dependencies: dependencies)
        #expect(app.search.layout == .grid)
        #expect(SearchStore(engine: nil, index: app.index, kv: app.dependencies.kv, clock: SystemClock()).layout == .moments, "not remembered")
    }

    /// Acceptance 3: Grid ↔ Moments keeps the result (no search runs again) and the layout is remembered.
    @Test func switchingLayoutsKeepsTheResult() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        app.search.setLayout(.grid)
        await app.search.settled()
        #expect(app.search.result?.id == result.id)
        #expect(app.search.state == .results(result))
        app.search.setLayout(.moments)
        #expect(app.search.result?.id == result.id)
        app.search.setLayout(.grid)
        #expect(SearchStore(engine: nil, index: app.index, kv: app.dependencies.kv, clock: SystemClock()).layout == .grid)
    }

    /// Scrolled into the results, the other layout opens at the same photos: Moments' top card → the grid's row of its first
    /// photo (or the month header just above it); the grid's top row → its card (or the header just above it).
    @Test func switchingLayoutsKeepsThePlace() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        let grid = ResultGrid(result, showsUnknown: false)
        let anchor = ResultsAnchor()
        let cards = result.cards
        anchor.card(cards[4].id, isVisible: true)
        anchor.card(cards[5].id, isVisible: true)
        #expect(anchor.target(for: .grid, result: result, grid: grid, columns: 3, showsUnknown: false) == nil, "at the top, the screen stays")
        anchor.isHeaderVisible = false
        // The fifth card starts a month: its month header is the target, so its photos sit under the pinned switch.
        let firstTile = try #require(grid.firstTile(of: cards[4].id))
        let month = try #require(grid.sections.flatMap(\.months).first { $0.tiles.first?.position == firstTile.position })
        #expect(anchor.target(for: .grid, result: result, grid: grid, columns: 3, showsUnknown: false) == GridRow.month(month).id)

        anchor.reset()
        let tile = grid.tiles[firstTile.position + 3]
        anchor.tile(tile.position, isVisible: true)
        anchor.tile(tile.position + 3, isVisible: true)
        #expect(anchor.target(for: .moments, result: result, grid: grid, columns: 3, showsUnknown: false) == ResultRow.cardID(tile.card))
        #expect(tile.card == cards[4].id)
        anchor.tile(tile.position + 3, isVisible: false)
        anchor.tile(tile.position, isVisible: false)
        #expect(anchor.target(for: .moments, result: result, grid: grid, columns: 3, showsUnknown: false) == nil)
    }

    // MARK: Grid

    @Test func theGridIsSectionThenMonthHeadersOverRowsOfTiles() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        let grid = ResultGrid(result, showsUnknown: false)
        #expect(GridRow.columns(width: 354) == 3)
        #expect(GridRow.columns(width: 96) == 1 && GridRow.columns(width: 0) == 3)
        #expect(GridRow.columns(width: 1000) == 10)
        let rows = GridRow.rows(grid, columns: 3)
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique")
        guard case .section(let best)? = rows.first, case .month(let month)? = rows.dropFirst().first else {
            Issue.record("expected the Best section's header, then a month's")
            return
        }
        #expect(best.title == "Inside Al-Nakheel Park")
        #expect(month.year == 2026 && month.month == 8)
        let tiles = rows.flatMap { row -> [ResultGrid.Tile] in if case .tiles(let tiles) = row { tiles } else { [] } }
        #expect(tiles.map(\.id) == grid.tiles.map(\.id), "the tiles in the grid's order")
        #expect(rows.allSatisfy { if case .tiles(let tiles) = $0 { (1...3).contains(tiles.count) } else { true } })
        for tile in grid.tiles {
            let id = try #require(GridRow.rowID(of: tile.position, in: grid, columns: 3))
            let row = try #require(rows.first { $0.id == id })
            guard case .tiles(let held) = row else { Issue.record("not a row of tiles"); continue }
            #expect(held.contains { $0.position == tile.position })
        }
        // A video shows its length; VoiceOver hears it, a favourite and "nearby".
        let video = try #require(grid.tiles.first { $0.hit.kind == .video })
        #expect(video.hit.duration == 3)
        #expect(plain(AssetTileCopy.label(isVideo: true, duration: 3, isFavorite: true, wall: video.hit.wall, isNearby: true, locale: us))
            == "Video, 0:03, favourite, nearby, 5:35 PM")
    }

    @Test func theNextSixtyThumbnailsArePrepared() {
        var prefetch = GridPrefetch()
        var change = prefetch.appeared(2, total: 200)
        #expect(change.start == [3..<63] && change.stop.isEmpty)
        change = prefetch.appeared(2, total: 200)
        #expect(change.start.isEmpty && change.stop.isEmpty)
        change = prefetch.appeared(11, total: 200)
        #expect(change.start == [63..<72] && change.stop == [3..<12])
        change = prefetch.appeared(5, total: 200)
        #expect(change.start == [6..<12] && change.stop == [66..<72], "scrolling back")
        change = prefetch.appeared(150, total: 200)
        #expect(change.start == [151..<200] && change.stop == [6..<66], "the end of the grid")
        #expect(prefetch.reset() == 151..<200)
        #expect(prefetch.reset() == nil)
    }

    // MARK: Viewer

    /// Acceptance 4: the viewer pages through the grid's photos in order, with their reasons, places and times in their
    /// zone.
    @Test func theViewerPagesThroughTheMatchesWithReasonsAndZoneTimes() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        let grid = ResultGrid(result, showsUnknown: false)
        let items = ViewerItem.items(grid, result: result)
        #expect(items.map(\.id) == grid.tiles.map(\.id))
        #expect(items.allSatisfy { !$0.reasons.isEmpty })
        let session = ViewerSession(items: items, start: 5)
        #expect(session.items[session.start].id == grid.tiles[5].id)

        // A photo of the 14 Jun 2025 session, from an iPhone in Phoenix and from one in Riyadh.
        let photo = try #require(Self.hero.items(.nakheel).first { $0.momentDay == LocalTime.day(year: 2025, month: 6, day: 14) && !$0.isVideo })
        let item = try #require(items.first { $0.utc == photo.utc })
        #expect(plain(ViewerCopy.dateTime(item, deviceZone: phoenix, locale: us)) == "Sat, Jun 14, 2025, 5:00 PM · Riyadh time")
        #expect(plain(ViewerCopy.dateTime(item, deviceZone: riyadh, locale: us)) == "Sat, Jun 14, 2025, 5:00 PM")
        #expect(ViewerCopy.placeLine(item, homeCountry: "SA") == "Al-Nakheel Park · Riyadh")
        #expect(item.reasons.map(\.text) == ["In Al-Nakheel Park"])
        let spoken = ViewerCopy.spokenTop(item, position: 2, count: 9, deviceZone: phoenix, homeCountry: "SA")
        #expect(spoken.hasPrefix("Photo 3 of 9, ") && spoken.hasSuffix(", Riyadh time, Al-Nakheel Park · Riyadh"), "\(spoken)")

        // "Why this matched": the borrowed position says where it came from.
        let borrowed = try #require(Self.hero.items(.nakheel).first { $0.borrowing == .moment })
        let borrowedItem = try #require(items.first { $0.utc == borrowed.utc })
        #expect(borrowedItem.reasons.map(\.detail) == [
            "Taken inside Al-Nakheel Park.", "No GPS in this photo. Location comes from a photo taken 5 min earlier in the same outing.",
        ])
        #expect(ViewerCopy.dateTime(ViewerItem(hit: AssetHit(id: 1, localID: "x", kind: .photo, utc: nil, wall: nil, tier: .best), moment: nil),
                                    deviceZone: phoenix) == "No date")
    }

    @Test func aPhotoWithoutAMomentNamesItsOffset() {
        // 14:00 UTC, 17:00 on the wall: three hours ahead, with no moment to name the zone.
        let hit = AssetHit(id: 1, localID: "x", kind: .photo, utc: 1_750_000_000, wall: 1_750_000_000 + 10_800, tier: .best)
        let item = ViewerItem(hit: hit, moment: nil)
        #expect(ViewerCopy.zoneNote(item, deviceZone: phoenix) == "GMT+3 time")
        #expect(ViewerCopy.zoneNote(item, deviceZone: riyadh) == nil)
        #expect(ViewerCopy.placeLine(item, homeCountry: "SA") == nil)
    }

    /// Moment detail opened from a search: a match pages with its reasons, the rest of the moment without.
    @Test func momentDetailTilesOpenTheViewerOnTheirGrid() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park videos"))
        let card = try #require(result.cards.first)
        let detail = try #require(await app.moments.moment(card.id))
        let split = MomentMatches(members: detail.members, card: card)
        let matches = MomentMatches.viewerItems(split.matches, moment: detail.moment, card: card)
        #expect(matches.map(\.id) == split.matches.map(\.id))
        #expect(matches.allSatisfy { $0.isVideo && $0.reasons.map(\.text).contains("Video · 0:03") })
        let others = MomentMatches.viewerItems(split.others, moment: detail.moment, card: nil)
        #expect(!others.isEmpty && others.allSatisfy(\.reasons.isEmpty))
    }

    @Test func aSeedVideoPlaysItsClip() async throws {
        let app = SearchTestApp.make(.unlocked)
        let video = try #require(Self.hero.items.first { $0.isVideo })
        guard case .item = await app.videos.playerItem(for: video.id) else {
            Issue.record("expected the seed clip")
            return
        }
        guard case .missing = await app.videos.playerItem(for: "not-a-video") else {
            Issue.record("expected missing")
            return
        }
    }
}
