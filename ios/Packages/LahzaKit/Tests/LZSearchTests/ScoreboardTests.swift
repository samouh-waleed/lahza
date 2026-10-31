import Foundation
import LZIndex
import LZLibrary
import Synchronization
import Testing
@testable import LZSearch

/// The DEBUG scoreboard (content search 5a, E32): album titles, scoring one search, the frozen split, the report, and a
/// run over the seed. Every search here is a seed search; real ones never leave the iPhone.
@Suite struct ScoreboardTests {
    @Test func numberedAlbumsAreReadByTitleOnly() {
        #expect(Scoreboard.album("LZ 07")! == (7, .right))
        #expect(Scoreboard.album("LZ 7 ?")! == (7, .unsure))
        #expect(Scoreboard.album("LZ 31")! == (31, .right))
        #expect(Scoreboard.album("AP 07")! == (7, .apple))
        #expect(Scoreboard.album(" LZ 12 ")! == (12, .right))
        for title in ["LZ07", "LZ 07 beach", "lz 07", "LZ 0", "LZ 1234", "Trip LZ 07", "AP 07 ?", "LZ ?", "LZ ٠٧", "Holidays"] {
            #expect(Scoreboard.album(title) == nil, "\(title)")
        }
    }

    @Test func labelsGatherEachNumbersAlbums() {
        let labels = Scoreboard.Labels([LibraryAlbum(title: "LZ 01", localIDs: ["a", "b"]), LibraryAlbum(title: "LZ 1", localIDs: ["c"]),
                                        LibraryAlbum(title: "LZ 01 ?", localIDs: ["d"]), LibraryAlbum(title: "AP 01", localIDs: ["a"]),
                                        LibraryAlbum(title: "LZ 30", localIDs: []), LibraryAlbum(title: "Beach", localIDs: ["z"])])
        #expect(labels.right == [1: ["a", "b", "c"], 30: []])
        #expect(labels.unsure == [1: ["d"]] && labels.apple == [1: ["a"]])
        #expect(labels.numbers == [1, 30])
        #expect(Set(labels.allLocalIDs) == ["a", "b", "c", "d"])
    }

    // MARK: One search

    @Test func aSearchIsScoredOnWhatItShowed() {
        let entry = Scoreboard.Entry(number: 4, text: "beach sunset", kind: .what, split: .dev)
        let outcome = Scoreboard.score(entry, right: ["a", "b", "c", "d", "e"], unsure: ["e"], indexed: ["a", "b", "c", "e"],
                                       shown: [("x", true), ("a", false), ("e", false)], cards: [["x"], ["a"], ["e"]])
        #expect(outcome.right == 3 && outcome.missing == 1 && outcome.unsure == 1, "d isn't in the index; e is unsure")
        #expect(outcome.returned == 2 && outcome.found == 1 && outcome.best == 1, "the unsure photo shown counts for nothing")
        #expect(outcome.precision == 0.5)
        #expect(abs((outcome.recall ?? 0) - 1.0 / 3) < 1e-9)
        #expect(abs((outcome.f1 ?? 0) - 0.4) < 1e-9)
        #expect(outcome.hitAt3 == true && !outcome.declined && !outcome.expectsNothing)
        #expect(outcome.missed == ["b", "c"] && outcome.wrong == ["x"])

        let late = Scoreboard.score(entry, right: ["a"], unsure: [], indexed: ["a"], shown: [("x", true), ("y", true), ("z", false), ("a", false)],
                                    cards: [["x"], ["y"], ["z"], ["a"]])
        #expect(late.hitAt3 == false && late.recall == 1)
        let none = Scoreboard.score(entry, right: ["a"], unsure: [], indexed: ["a"], shown: [], cards: [])
        #expect(none.f1 == 0 && none.precision == 0 && none.empty && none.declined)
    }

    @Test func aSearchWithNoAnswerShouldDecline() {
        let entry = Scoreboard.Entry(number: 31, text: "scuba diving", kind: .what)
        let declined = Scoreboard.score(entry, right: [], unsure: [], indexed: [], shown: [("x", false)], cards: [["x"]])
        #expect(declined.expectsNothing && declined.declined && !declined.empty)
        #expect(declined.f1 == nil && declined.hitAt3 == nil)
        let claimed = Scoreboard.score(entry, right: [], unsure: [], indexed: [], shown: [("x", true)], cards: [["x"]])
        #expect(!claimed.declined)
    }

    @Test func applesAnswerIsScoredFromItsAlbum() throws {
        let labels = Scoreboard.Labels([LibraryAlbum(title: "LZ 05", localIDs: ["a", "b"]), LibraryAlbum(title: "AP 05", localIDs: ["a", "x"]),
                                        LibraryAlbum(title: "LZ 06", localIDs: [])])
        let entry = Scoreboard.Entry(number: 5, text: "beach", kind: .what)
        let apple = try #require(Scoreboard.scoreApple(entry, labels: labels, indexed: ["a", "b"]))
        #expect(apple.precision == 0.5 && apple.recall == 0.5 && apple.hitAt3 == nil && !apple.declined)
        // A right photo Lahza hasn't indexed is left out of Apple's answer too, never counted as wrong.
        let unindexed = try #require(Scoreboard.scoreApple(entry, labels: labels, indexed: ["b"]))
        #expect(unindexed.right == 1 && unindexed.missing == 1 && unindexed.returned == 1 && unindexed.precision == 0)
        #expect(Scoreboard.scoreApple(Scoreboard.Entry(number: 7, text: "x"), labels: Scoreboard.Labels([LibraryAlbum(title: "AP 07", localIDs: ["a"])]),
                                      indexed: ["a"]) == nil, "no LZ album: not labelled yet")
        #expect(Scoreboard.scoreApple(Scoreboard.Entry(number: 6, text: "nothing"), labels: labels, indexed: []) == nil, "no AP album, no score")
    }

    // MARK: The split

    @Test func theHeldOutThirdIsDrawnPerKindAndFrozen() throws {
        var book = Scoreboard.Book(seed: 42)
        for number in 1...30 { book.set(number, text: "search \(number)", kind: Scoreboard.Kind.allCases[number % 5]) }
        for number in 31...39 { book.set(number, text: "nothing \(number)", kind: .what) }
        #expect(book.sorted.allSatisfy { $0.split == nil }, "nothing is drawn before the freeze")
        book.freeze(nothing: Set(31...39))
        for kind in Scoreboard.Kind.allCases {
            let group = book.sorted.filter { $0.kind == kind && $0.number <= 30 }
            #expect(group.count(where: { $0.split == .heldOut }) == 2, "\(kind): 2 of 6")
        }
        #expect(book.sorted.filter { $0.number > 30 }.count(where: { $0.split == .heldOut }) == 3, "3 of the 9 with no answer")

        let frozen = book
        book.freeze(nothing: [])
        book.set(4, text: "search 4, reworded", kind: .who)
        #expect(book.entries[4]?.split == frozen.entries[4]?.split, "a frozen split never changes")
        book.set(40, text: "nothing 40", kind: .what)
        #expect(book.entries[40]?.split != nil, "a later search is drawn at once")

        let decoded = try JSONDecoder().decode(Scoreboard.Book.self, from: try JSONEncoder().encode(book))
        #expect(decoded == book)
        #expect(Scoreboard.Book(seed: 42).seed == 42 && Scoreboard.Book().seed != 0)
    }

    // MARK: The report

    @Test func theReportSplitsKindsAndHidesHeldOutDetail() throws {
        func outcome(_ number: Int, _ kind: Scoreboard.Kind, _ split: Scoreboard.Split, f1: Double?, declined: Bool = false) -> Scoreboard.Outcome {
            Scoreboard.Outcome(number: number, kind: kind, split: split, right: f1 == nil ? 0 : 4, missing: 0, unsure: 0, returned: 4, best: declined ? 0 : 2,
                               found: 2, precision: f1, recall: f1, f1: f1, hitAt3: f1.map { $0 > 0.5 }, declined: declined, empty: false)
        }
        let report = Scoreboard.Report(mode: "tags", date: Date(timeIntervalSince1970: 0), outcomes: [
            outcome(1, .what, .dev, f1: 0.8), outcome(2, .what, .dev, f1: 0.4), outcome(3, .whenWhere, .dev, f1: 0.6),
            outcome(4, .what, .dev, f1: nil, declined: true), outcome(5, .what, .dev, f1: nil), outcome(6, .who, .heldOut, f1: 0.1),
        ])
        let what = try #require(report.dev[.what])
        #expect(what.searches == 4 && abs((what.f1 ?? 0) - 0.6) < 1e-9 && what.hitAt3 == 0.5)
        #expect(what.nothing == 2 && what.declined == 1)
        #expect(report.dev[.who] == nil, "held-out searches never show by kind")
        #expect(report.heldOut.searches == 1 && report.heldOut.f1 == 0.1)
        #expect(report.devTotal.searches == 5)
        #expect(report.summary.contains("what: n 4, F1 0.60") && report.summary.contains("held-out: n 1"))
        let decoded = try JSONDecoder().decode(Scoreboard.Report.self, from: try JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    // MARK: A run

    /// The seed's own tagged searches through the engine: "sunset" against the photos the seed tags sunset, and a word
    /// no photo shows, whose right answer is nothing.
    @Test func aRunScoresEachSearchThroughTheEngine() async throws {
        let search = try await HeroSearch.tagged.value
        let sunset = try await search.search("sunset")
        let shown = Set(sunset.hits.map(\.localID))
        #expect(!shown.isEmpty)
        let labels = Scoreboard.Labels([LibraryAlbum(title: "LZ 01", localIDs: Array(shown)), LibraryAlbum(title: "LZ 02", localIDs: [])])
        let entries = [Scoreboard.Entry(number: 1, text: "sunset", kind: .what, split: .dev),
                       Scoreboard.Entry(number: 2, text: "scuba diving", kind: .what, split: .heldOut),
                       Scoreboard.Entry(number: 3, text: " ", kind: .what),
                       Scoreboard.Entry(number: 4, text: "beach", kind: .what)]
        let indexed = try await search.index.reader.indexed(localIDs: labels.allLocalIDs)
        #expect(indexed == shown)
        let asked = Mutex<[Int]>([])
        let outcomes = try await Scoreboard.run(entries, labels: labels, indexed: indexed) { entry in
            asked.withLock { $0.append(entry.number) }
            return try await search.search(SearchRequest(text: entry.text, content: .all))
        }
        #expect(asked.withLock { $0 } == [1, 2], "a number without words, or without an album, isn't searched")
        #expect(outcomes[0].f1 == 1 && outcomes[0].hitAt3 == true)
        #expect(outcomes[1].expectsNothing && outcomes[1].declined)

        // Search v0 (no content signals) finds no sunset.
        let v0 = try await search.search(SearchRequest(text: "sunset", content: .none))
        #expect(v0.hits.isEmpty)
    }
}
