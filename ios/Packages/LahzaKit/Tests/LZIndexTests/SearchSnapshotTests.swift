import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// The search snapshot (search spec §6.6): the assets as columns, newest first, with the moments, trips and the
/// located grid; kept per index version and dropped on request.
@Suite struct SearchSnapshotTests {
    static let hero = SeedScenario.hero

    @Test func theSnapshotHoldsEveryAssetNewestFirst() async throws {
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.structured(database, FakeLibraryReader(.seed(.hero))))
        let reader = IndexReader(database: database)
        let snapshot = try await reader.snapshot()
        #expect(snapshot.count == Self.hero.items.count)
        #expect(snapshot.version == (try await reader.indexVersion()))
        let dated = snapshot.utc.filter { $0 != Int64.min }
        #expect(dated == dated.sorted(by: >), "newest first")
        #expect(snapshot.utc.suffix(Self.hero.items(.undated).count).allSatisfy { $0 == Int64.min }, "undated last")
        #expect(snapshot.unlocated.count == Self.hero.items.count { !$0.isLocated && $0.borrowing != .moment })
        #expect(snapshot.placeSource.count { $0 == SearchSnapshot.PositionSource.momentNear.rawValue } == 2)
        #expect(snapshot.flags.indices.count { snapshot.has(.dateUnreliable, $0) } == Self.hero.items(.undated).count)
        #expect(snapshot.kind.count { $0 == 1 } == Self.hero.expectedVideoCount)
        #expect(snapshot.trips.count == Self.hero.trips.count)
        #expect(snapshot.trip.count { $0 >= 0 } == Self.hero.items.count { item in Self.hero.trips.contains { trip in item.momentDay.map { trip.contains(day: $0) } == true } })

        // Every moment with a located item has a representative inside it, and its day lists it.
        for (id, moment) in snapshot.moments where moment.representative >= 0 {
            #expect(snapshot.moment[Int(moment.representative)] == id)
            #expect(snapshot.dayLocatedMoments[moment.day]?.contains(id) == true)
        }

        // The grid finds what the index's own count finds.
        let park = Fixture.nakheel
        #expect(snapshot.indices(near: park, within: 400).count == (try await reader.countWithin(park, radius: 400)))
        #expect(snapshot.indices(near: park, within: 400).count == Self.hero.items(.nakheel).count)
        #expect(snapshot.indices(near: park, within: 400, ownGPSOnly: true).count == Self.hero.items(.nakheel).count { $0.isLocated })
    }

    @Test func theSnapshotIsKeptPerVersionAndCanBeDropped() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let reader = IndexReader(database: database)
        let empty = try await reader.snapshot()
        #expect(empty.count == 0)
        await Fixture.sync(Fixture.structured(database, FakeLibraryReader(.explicit(Fixture.library(5)))))
        // Within a second of the last build the cached one is kept while versions churn; dropping it rebuilds.
        #expect(try await reader.snapshot().count == 0)
        await reader.releaseSnapshot()
        let built = try await reader.snapshot()
        #expect(built.count == 5)
        #expect(built.version == (try await reader.indexVersion()))
    }
}
