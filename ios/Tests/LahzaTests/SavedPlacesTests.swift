import Foundation
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// Saved places in the app (search spec §7.3–7.4, PR 4 acceptance 5–6) over the fake hero library: Save place from a
/// nakheel moment, "at my pitch", the moment labels, the home choice, Rebuild keeps it, Delete index removes it.
@MainActor @Suite struct SavedPlacesTests {
    private func eventually(_ app: AppModel, _ condition: () -> Bool) async -> Bool {
        await SearchTestApp.eventually(app, condition)
    }

    /// The ten nakheel sessions (Apple Maps labels them with the park) and one's centre, as moment detail has it.
    private func nakheel(_ app: AppModel) async throws -> (keys: [MomentKey], center: Coordinate) {
        await app.moments.load()
        let keys = app.moments.moments.filter { $0.label == "Al-Nakheel Park" }.map(\.key)
        let first = try #require(keys.first)
        let center = try #require(await app.moments.moment(first)?.moment.center)
        return (keys, center)
    }

    private func labels(_ app: AppModel, _ keys: [MomentKey]) -> [String?] {
        keys.map { key in app.moments.moments.first { $0.key == key }?.label }
    }

    @Test func savingMyPitchMakesItSearchableAndLabelsItsMoments() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let (keys, center) = try await nakheel(app)
        #expect(keys.count == 10)
        _ = await SearchTestApp.search(app, "Al-Nakheel Park")
        await app.savedPlaces.load()
        #expect(app.savedPlaces.places.isEmpty && app.savedPlaces.isAvailable)
        #expect(await app.savedPlaces.count(around: center, radius: 250) == 85, "the sheet's live count")

        try await app.savedPlaces.save(name: "My pitch", center: center, radius: 250, isHome: false)
        #expect(app.savedPlaces.places.map(\.name) == ["My pitch"])
        #expect(app.savedPlaces.photoCounts.values.first == 85)
        #expect(await eventually(app) { labels(app, keys) == Array(repeating: "My pitch", count: 10) }, "Moments reads the saved name")

        let result = await SearchTestApp.search(app, "at my pitch")
        #expect(result?.query.slots.first?.chip == "My pitch")
        let best = Set(result?.hits.filter { $0.tier == .best }.compactMap { $0.utc.flatMap { SeedScenario.hero.item(matchingUTC: $0)?.number } } ?? [])
        #expect(best == Set(SeedScenario.hero.items(.nakheel).map(\.number)), "the 85 nakheel items")

        await #expect(throws: SavedPlaceError.nameTaken) { try await app.savedPlaces.save(name: "my pitch", center: center, radius: 100, isHome: false) }
        let place = try #require(app.savedPlaces.places.first)
        try await app.savedPlaces.update(place, name: "Saturday football", radius: 1_000, isHome: false)
        #expect(app.savedPlaces.places.map(\.name) == ["Saturday football"] && app.savedPlaces.places.first?.radius == 1_000)
        #expect(await eventually(app) { labels(app, keys) == Array(repeating: "Saturday football", count: 10) })
        try await app.savedPlaces.delete(place.id)
        #expect(app.savedPlaces.places.isEmpty)
        #expect(await eventually(app) { labels(app, keys) == Array(repeating: "Al-Nakheel Park", count: 10) })
    }

    @Test func rebuildKeepsSavedPlacesAndDeleteIndexRemovesThem() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let (keys, center) = try await nakheel(app)
        try await app.savedPlaces.save(name: "My pitch", center: center, radius: 250, isHome: false)
        try await app.savedPlaces.setHome(.noHome)
        #expect(app.savedPlaces.home == .noHome)

        await app.index.rebuild()
        #expect(await eventually(app) { app.index.status.phase == .ready && app.moments.trips.isEmpty && !app.moments.moments.isEmpty })
        await app.index.placeNamesSettled()
        await app.savedPlaces.load()
        #expect(app.savedPlaces.places.map(\.name) == ["My pitch"], "Rebuild keeps saved places")
        #expect(app.savedPlaces.home == .noHome, "and the home choice")
        #expect(await eventually(app) { labels(app, keys) == Array(repeating: "My pitch", count: 10) })

        await app.index.deleteIndex()
        #expect(!app.savedPlaces.isAvailable)
        app.index.buildAgain()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        await app.savedPlaces.load()
        #expect(app.savedPlaces.places.isEmpty, "Delete index removes them")
        if case .estimated(let base) = app.savedPlaces.home { #expect(base != nil) } else { Issue.record("home should be estimated again") }
    }

    @Test func homeCanBePickedFromTheNightPlaces() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        await app.savedPlaces.load()
        guard case .estimated(let estimated?) = app.savedPlaces.home else {
            Issue.record("no estimated home")
            return
        }
        let candidates = await app.savedPlaces.homeCandidates()
        #expect(candidates.first?.tile == estimated.tile && candidates.first?.isEstimate == true)
        #expect(SavedPlacesCopy.isCurrent(try #require(candidates.first), home: app.savedPlaces.home))
        let other = try #require(candidates.dropFirst().first)
        try await app.savedPlaces.setHome(.point(other.center))
        guard case .saved(let home) = app.savedPlaces.home else {
            Issue.record("home should be the picked place")
            return
        }
        #expect(home.name == "Home" && app.savedPlaces.places.isEmpty, "the picked home isn't listed with the named places")
        #expect(SavedPlacesCopy.isCurrent(other, home: app.savedPlaces.home))
        #expect(SavedPlacesCopy.homeSubtitle(app.savedPlaces.home) == "Set by you")
        try await app.savedPlaces.setHome(.estimated)
        #expect(await eventually(app) { app.savedPlaces.home == .estimated(estimated) }, "once the home bases are worked out again")
    }
}
