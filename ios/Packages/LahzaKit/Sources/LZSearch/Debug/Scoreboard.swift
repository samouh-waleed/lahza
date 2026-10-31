#if DEBUG
import Foundation
import LZLibrary

/// The scoreboard (content search 5a, decision E32): the person's numbered searches, labelled in Photos, scored on
/// the iPhone. Album "LZ 07" holds the right photos for search 7 and "LZ 07 ?" the unsure ones, which are left out of
/// scoring; an empty "LZ 07" means the right answer is nothing. "AP 07" holds Apple Photos' answer (spike S1). Titles
/// never carry the search: its words are typed once into the scoreboard's own file, with its kind, and a third of the
/// searches is frozen as held-out.
///
/// The searches and the labelled photos are private: they stay on the iPhone, apart from exports the person copies into
/// plan-docs, and nothing prints them (``Report/summary`` has numbers only).
public enum Scoreboard {
    /// What a search asks about (PhotoBench's split: structure helps some kinds and hurts others).
    public enum Kind: String, Sendable, Hashable, Codable, CodingKeyRepresentable, CaseIterable {
        case what
        case whenWhere = "when-where"
        case who
        case mixed
        case firstTime = "first-time"
    }

    public enum Split: String, Sendable, Hashable, Codable {
        /// Tuned on.
        case dev
        /// Never tuned on: only its totals are shown.
        case heldOut = "held-out"
    }

    /// One numbered search as typed on the iPhone.
    public struct Entry: Sendable, Hashable, Codable {
        public var number: Int
        public var text: String
        public var kind: Kind?
        /// Nil until the split is frozen.
        public var split: Split?

        public init(number: Int, text: String, kind: Kind? = nil, split: Split? = nil) {
            self.number = number
            self.text = text
            self.kind = kind
            self.split = split
        }
    }

    // MARK: Albums

    public enum AlbumRole: Sendable, Hashable {
        /// "LZ 07": the right photos.
        case right
        /// "LZ 07 ?": unsure, left out.
        case unsure
        /// "AP 07": Apple Photos' answer.
        case apple
    }

    /// The search number and role of a scoreboard album ("LZ 07", "LZ 7 ?", "AP 07"); nil for any other album.
    public static func album(_ title: String) -> (number: Int, role: AlbumRole)? {
        let parts = title.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 || parts.count == 3, parts[1].count <= 3, parts[1].allSatisfy(\.isASCII), let number = Int(parts[1]), number > 0
        else { return nil }
        switch (parts[0], parts.count == 3 ? parts[2] : nil) {
        case ("LZ", nil): return (number, .right)
        case ("LZ", "?"): return (number, .unsure)
        case ("AP", nil): return (number, .apple)
        default: return nil
        }
    }

    /// Every scoreboard album's photos, by search number.
    public struct Labels: Sendable, Hashable {
        public var right: [Int: Set<String>] = [:]
        public var unsure: [Int: Set<String>] = [:]
        public var apple: [Int: Set<String>] = [:]

        public init(_ albums: [LibraryAlbum] = []) {
            for album in albums {
                guard let (number, role) = Scoreboard.album(album.title) else { continue }
                switch role {
                case .right: right[number, default: []].formUnion(album.localIDs)
                case .unsure: unsure[number, default: []].formUnion(album.localIDs)
                case .apple: apple[number, default: []].formUnion(album.localIDs)
                }
            }
        }

        /// Every labelled photo (right and unsure).
        public var allLocalIDs: [String] { Array(Set(right.values.joined()).union(unsure.values.joined())) }

        /// The numbers with an album of either kind.
        public var numbers: Set<Int> { Set(right.keys).union(unsure.keys) }
    }

    // MARK: The book

    /// The scoreboard's own file: what each number searches, its kind, and the frozen split.
    public struct Book: Sendable, Hashable, Codable {
        public var entries: [Int: Entry] = [:]
        /// Draws the held-out searches; set once.
        public var seed: UInt64
        public var frozen = false

        public init(seed: UInt64 = .random(in: 1...UInt64.max)) {
            self.seed = seed
        }

        public var sorted: [Entry] { entries.values.sorted { $0.number < $1.number } }

        /// Sets a search's words and kind. After the freeze a new number is drawn at once (about a third held out); an
        /// existing one keeps its split.
        public mutating func set(_ number: Int, text: String, kind: Kind?) {
            var entry = entries[number] ?? Entry(number: number, text: text)
            entry.text = text
            entry.kind = kind
            if frozen, entry.split == nil { entry.split = Self.draw(number, seed: seed) < UInt64.max / 3 ? .heldOut : .dev }
            entries[number] = entry
        }

        public mutating func remove(_ number: Int) {
            entries[number] = nil
        }

        /// Draws the held-out third, once: within each kind, and apart for searches whose answer is nothing
        /// (`nothing`), so every group keeps about a third held out. Searches without a kind form their own group.
        public mutating func freeze(nothing: Set<Int>) {
            guard !frozen else { return }
            let groups = Dictionary(grouping: entries.values) { "\($0.kind?.rawValue ?? "-")/\(nothing.contains($0.number))" }
            for group in groups.values {
                let order = group.map(\.number).sorted { Self.draw($0, seed: seed) < Self.draw($1, seed: seed) }
                let held = Int((Double(order.count) / 3).rounded())
                for (position, number) in order.enumerated() { entries[number]?.split = position < held ? .heldOut : .dev }
            }
            frozen = true
        }

        static func draw(_ number: Int, seed: UInt64) -> UInt64 {
            var z = seed &+ UInt64(number) &* 0x9e37_79b9_7f4a_7c15
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
    }

    // MARK: Scoring one search

    /// How one search did.
    public struct Outcome: Sendable, Hashable, Codable {
        public var number: Int
        public var kind: Kind?
        public var split: Split?
        /// Right photos in the index (labelled photos the index doesn't hold are left out, and counted in `missing`).
        public var right: Int
        public var missing: Int
        /// Unsure photos, left out of everything.
        public var unsure: Int
        /// Photos shown (Best, More and location unknown), unsure ones left out.
        public var returned: Int
        public var best: Int
        /// Right photos among those shown.
        public var found: Int
        /// Nil when the right answer is nothing.
        public var precision: Double?
        public var recall: Double?
        public var f1: Double?
        /// A right photo in the first 3 cards; nil when the right answer is nothing.
        public var hitAt3: Bool?
        /// Nothing in Best: the right call when the answer is nothing.
        public var declined: Bool
        /// Nothing shown at all.
        public var empty: Bool
        /// Right photos not shown, and photos shown that aren't right (for looking at on the iPhone, never printed).
        public var missed: [String] = []
        public var wrong: [String] = []

        public var expectsNothing: Bool { right == 0 && missing == 0 }
    }

    /// Scores what a search showed against its labels. `cards`: the photos of each card, in the order shown;
    /// `indexed`: the labelled photos the index holds. Right photos the index doesn't hold are left out on both sides, so
    /// a system shown them (Apple) isn't marked wrong for them.
    public static func score(_ entry: Entry, right labelled: Set<String>, unsure: Set<String>, indexed: Set<String>,
                             shown: [(localID: String, best: Bool)], cards: [[String]]) -> Outcome {
        let right = labelled.subtracting(unsure).intersection(indexed)
        let notIndexed = labelled.subtracting(unsure).subtracting(indexed)
        let missing = notIndexed.count
        var returned = Set<String>(), best = Set<String>()
        for item in shown where !unsure.contains(item.localID) && !notIndexed.contains(item.localID) {
            returned.insert(item.localID)
            if item.best { best.insert(item.localID) }
        }
        let found = returned.intersection(right).count
        var outcome = Outcome(number: entry.number, kind: entry.kind, split: entry.split, right: right.count, missing: missing, unsure: unsure.count,
                              returned: returned.count, best: best.count, found: found, declined: best.isEmpty, empty: returned.isEmpty,
                              missed: right.subtracting(returned).sorted(), wrong: returned.subtracting(right).sorted())
        guard !right.isEmpty else { return outcome }
        let precision = returned.isEmpty ? 0 : Double(found) / Double(returned.count)
        let recall = Double(found) / Double(right.count)
        outcome.precision = precision
        outcome.recall = recall
        outcome.f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        outcome.hitAt3 = cards.prefix(3).contains { $0.contains(where: right.contains) }
        return outcome
    }

    /// Scores a search's result.
    public static func score(_ entry: Entry, labels: Labels, indexed: Set<String>, result: SearchResult) -> Outcome {
        score(entry, right: labels.right[entry.number] ?? [], unsure: labels.unsure[entry.number] ?? [], indexed: indexed,
              shown: result.hits.map { ($0.localID, $0.tier == .best) }, cards: result.cards.map { $0.hits.map(\.localID) })
    }

    /// Scores Apple Photos' answer to a search ("AP 07"), nil without that album or a labelled one ("LZ 07"). Apple's
    /// results have no order or tiers: every photo counts as shown and as Best, and there is no Hit@3.
    public static func scoreApple(_ entry: Entry, labels: Labels, indexed: Set<String>) -> Outcome? {
        guard let answer = labels.apple[entry.number], labels.right[entry.number] != nil else { return nil }
        var outcome = score(entry, right: labels.right[entry.number] ?? [], unsure: labels.unsure[entry.number] ?? [], indexed: indexed,
                            shown: answer.sorted().map { ($0, true) }, cards: [])
        outcome.hitAt3 = nil
        return outcome
    }

    /// Runs every search with words and a labelled album and scores it (one without an "LZ" album isn't labelled yet, not
    /// a search whose answer is nothing); `search` runs one over the whole library (nil: search is off).
    public static func run(_ entries: [Entry], labels: Labels, indexed: Set<String>,
                           search: @Sendable (Entry) async throws -> SearchResult?) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for entry in entries where !entry.text.trimmingCharacters(in: .whitespaces).isEmpty && labels.right[entry.number] != nil {
            try Task.checkCancellation()
            guard let result = try await search(entry) else { continue }
            outcomes.append(score(entry, labels: labels, indexed: indexed, result: result))
        }
        return outcomes
    }

    // MARK: Report

    /// One group's totals.
    public struct Line: Sendable, Hashable, Codable {
        public var searches: Int
        /// Over the searches with right photos.
        public var f1: Double?
        public var precision: Double?
        public var recall: Double?
        public var hitAt3: Double?
        /// Searches whose answer is nothing, and how many of them declined (nothing in Best).
        public var nothing: Int
        public var declined: Int

        init(_ outcomes: [Outcome]) {
            searches = outcomes.count
            let scored = outcomes.filter { !$0.expectsNothing }
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            f1 = mean(scored.compactMap(\.f1))
            precision = mean(scored.compactMap(\.precision))
            recall = mean(scored.compactMap(\.recall))
            hitAt3 = mean(scored.compactMap(\.hitAt3).map { $0 ? 1 : 0 })
            let nothingSearches = outcomes.filter(\.expectsNothing)
            nothing = nothingSearches.count
            declined = nothingSearches.count(where: \.declined)
        }
    }

    /// A run's totals: per kind on the dev split, and the held-out split as one line.
    public struct Report: Sendable, Hashable, Codable {
        public var mode: String
        public var date: Date
        public var outcomes: [Outcome]
        public var dev: [Kind: Line]
        public var devTotal: Line
        public var heldOut: Line

        public init(mode: String, date: Date, outcomes: [Outcome]) {
            self.mode = mode
            self.date = date
            self.outcomes = outcomes
            let dev = outcomes.filter { $0.split != .heldOut }
            var lines: [Kind: Line] = [:]
            for kind in Kind.allCases {
                let group = dev.filter { $0.kind == kind }
                if !group.isEmpty { lines[kind] = Line(group) }
            }
            self.dev = lines
            devTotal = Line(dev)
            heldOut = Line(outcomes.filter { $0.split == .heldOut })
        }

        /// Numbers only, for the console: no words, no photos.
        public var summary: String {
            func format(_ line: Line) -> String {
                func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
                return "n \(line.searches), F1 \(number(line.f1)), P \(number(line.precision)), R \(number(line.recall)), Hit@3 \(number(line.hitAt3)), "
                    + "declined \(line.declined) of \(line.nothing)"
            }
            var lines = ["SCOREBOARD \(mode)", "dev: \(format(devTotal))"]
            for kind in Kind.allCases { if let line = dev[kind] { lines.append("  \(kind.rawValue): \(format(line))") } }
            lines.append("held-out: \(format(heldOut))")
            return lines.joined(separator: "\n")
        }
    }
}
#endif
