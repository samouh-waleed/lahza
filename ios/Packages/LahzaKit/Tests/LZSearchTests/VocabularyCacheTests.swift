import Foundation
import GRDB
import LZCore
import LZGeo
import Testing
@testable import LZIndex
@testable import LZSearch

/// The parse vocabulary follows the index version, at most once per debounce while versions churn.
@Suite struct VocabularyCacheTests {
    @Test func rebuiltPerVersionAndDebounced() async throws {
        let index = try await SearchFixture.heroIndex()
        let clock = FixedClock(SearchFixture.now)
        let cache = VocabularyCache(gazetteer: SearchFixture.gazetteer, clock: clock, debounce: .seconds(2))
        let first = await cache.vocabulary(reader: index.reader)
        #expect(first.ownNames.contains("al nakheel park") && first.ownNames.contains("diriyah"))
        #expect(first.savedAliases.isEmpty)
        #expect(!first.ownNames.contains("paris"), "only places with photos")

        try await index.database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (id, name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES (7, 'My pitch', 'my pitch', 24.759, 46.644, 250, 0, 0, 0)
                """)
            try Meta.bumpVersion(db)
        }
        #expect(await cache.vocabulary(reader: index.reader).savedAliases.isEmpty, "a new version within 2 s keeps the vocabulary")
        await clock.advance(by: .seconds(3))
        #expect(await cache.vocabulary(reader: index.reader).savedAliases == ["my pitch": 7, "pitch": 7], "then it is rebuilt")

        await cache.release()
        #expect(await cache.vocabulary(reader: index.reader).ownNames == first.ownNames)
        #expect(await cache.vocabulary(reader: nil).ownNames.isEmpty, "no index: the gazetteer only")
    }
}
