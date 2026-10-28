import Foundation
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// Random library changes: however they reach the index (deltas in small chunks, an expired token, missing
/// change details), the result equals a fresh full scan of the library as it ends up.
@Suite struct SyncPropertyTests {
    private static let places = [Fixture.nakheel, Fixture.athens, Fixture.sydney, Coordinate(latitude: 51.5073, longitude: -0.1657)]

    /// Applies `count` random operations: inserts, moves, re-dates, favourites, deletes, hides and unhides.
    private func mutate(_ reader: FakeLibraryReader, _ random: inout SplitMix, count: Int, serial: inout Int, hidden: inout Set<String>) {
        func coordinate() -> Coordinate? {
            guard Bool.random(using: &random) else { return nil }
            let place = Self.places.randomElement(using: &random)!
            return Coordinate(latitude: place.latitude + Double.random(in: -0.01...0.01, using: &random),
                              longitude: place.longitude + Double.random(in: -0.01...0.01, using: &random))
        }
        for _ in 0..<count {
            let existing = reader.allAssets
            switch Int.random(in: 0..<6, using: &random) {
            case 0, 1:
                serial += 1
                let undated = Int.random(in: 0..<10, using: &random) == 0
                reader.insert([Fixture.photo("n\(serial)", undated ? nil : Int64.random(in: 1_577_836_800...1_790_000_000, using: &random),
                                             at: coordinate(), kind: Int.random(in: 0..<5, using: &random) == 0 ? .video : .photo)])
            case 2:
                guard var asset = existing.randomElement(using: &random) else { continue }
                switch Int.random(in: 0..<4, using: &random) {
                case 0: asset.facts.coordinate = coordinate()
                case 1: asset.facts.creationDate = asset.facts.creationDate?.addingTimeInterval(Double(Int.random(in: -48...48, using: &random)) * 3_600)
                case 2: asset.facts.isFavorite.toggle()
                default: asset.facts.modificationDate = Fixture.now
                }
                reader.update([asset])
            case 3:
                guard let asset = existing.randomElement(using: &random) else { continue }
                reader.delete([asset.id])
                hidden.remove(asset.id)
            case 4:
                guard let asset = existing.filter({ !hidden.contains($0.id) }).randomElement(using: &random) else { continue }
                reader.hide([asset.id])
                hidden.insert(asset.id)
            default:
                guard let id = hidden.randomElement(using: &random) else { continue }
                reader.unhide([id])
                hidden.remove(id)
            }
        }
    }

    @Test(arguments: 0..<8) func randomChangesSyncedIncrementallyEqualAFreshScan(seed: UInt64) async throws {
        var random = SplitMix(seed: seed)
        let reader = FakeLibraryReader(.explicit(Fixture.library(40)))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader, settings: IndexerSettings(batchSize: 4))
        await Fixture.sync(indexer)
        var serial = 0
        var hidden = Set<String>()
        for _ in 0..<6 {
            mutate(reader, &random, count: Int.random(in: 1...8, using: &random), serial: &serial, hidden: &hidden)
            await Fixture.sync(indexer, .sync(.foreground))
        }
        #expect(await indexer.stats.fullScans == [.firstRun: 1], "seed \(seed): every round applied as a delta")
        #expect(await indexer.stats.deltas >= 4, "seed \(seed)")
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(Fixture.cleanBuild(of: reader)), "seed \(seed)")
        let token = try reader.currentToken()
        #expect(try await Fixture.meta(database).libraryToken == token)
    }

    @Test(arguments: 0..<4) func anExpiredTokenOrMissingDetailsEqualAFreshScan(seed: UInt64) async throws {
        var random = SplitMix(seed: seed + 100)
        let reader = FakeLibraryReader(.explicit(Fixture.library(40)))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader, settings: IndexerSettings(batchSize: 7))
        await Fixture.sync(indexer)
        var serial = 0
        var hidden = Set<String>()

        mutate(reader, &random, count: 12, serial: &serial, hidden: &hidden)
        reader.expireTokens()
        await Fixture.sync(indexer)
        #expect(await indexer.stats.fullScans[.tokenExpired] == 1)
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(Fixture.cleanBuild(of: reader)), "seed \(seed): expired token")

        mutate(reader, &random, count: 12, serial: &serial, hidden: &hidden)
        reader.setDetailsUnavailable(true)
        await Fixture.sync(indexer)
        reader.setDetailsUnavailable(false)
        #expect(await indexer.stats.fullScans[.detailsUnavailable] == 1)
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(Fixture.cleanBuild(of: reader)), "seed \(seed): details unavailable")
    }
}
