import Foundation
import LZGeo
import LZIndex

/// What a search found: the query as understood, the hits grouped into sections of moment cards (and trips), the
/// totals, what was searched, and why nothing matched when nothing did (search spec §6.7).
public struct SearchResult: Sendable, Identifiable {
    public var id: UUID
    public var query: ResolvedQuery
    /// Best, then More, then Location unknown, then Weaker (only when asked for); empty sections are left out.
    public var sections: [ResultSection]
    /// Best and More.
    public var totals: Totals
    public var coverage: Coverage
    public var noMatch: NoMatch?
    /// The slots left out ("soccer", "with Ahmed"), in text order.
    public var unsupported: [QuerySlot]
    /// "Lahza can't see what's in photos yet, so “soccer” was left out. Showing all your photos at Al-Nakheel Park."
    public var unsupportedNotice: String?
    /// Hits behind "Show weaker" (counted even when they aren't shown).
    public var weakerCount: Int
    /// Hits a free search's scope left out: taken before ``SearchScope/since(_:)``, in the tiers the result lists
    /// (Best, More and Location unknown; Weaker too while shown). 0 for the whole library.
    public var lockedCount: Int
    public var timings: Timings

    /// Every hit in display order: section by section, card by card, in each card's order.
    public var hits: [AssetHit] { sections.flatMap { $0.groups.flatMap(\.cards).flatMap(\.hits) } }

    /// Every card in display order.
    public var cards: [MomentCard] { sections.flatMap { $0.groups.flatMap(\.cards) } }
}

/// The query as search understood it: the parsed slots and what each resolved to (the "Understood as" chips), and a
/// picker when a place was ambiguous.
public struct ResolvedQuery: Sendable, Hashable {
    public var parsed: ParsedQuery
    public var slots: [ResolvedSlot]
    public var picker: PlacePicker?
    /// The query asked Apple Maps.
    public var searchedAppleMaps: Bool

    /// The words of a place slot: as typed (or rendered after an edit), else the place's name.
    public func typedWords(slot id: Int) -> String? {
        guard let slot = parsed.slot(id) else { return nil }
        if let typed = slot.span?.substring(of: parsed.text) { return typed }
        if case .place(let place) = slot.value { return place.words }
        return nil
    }
}

/// One slot and what it resolved to.
public struct ResolvedSlot: Sendable, Hashable, Identifiable {
    public enum Resolution: Sendable, Hashable {
        case place(PlaceResolution)
        case time(TimeResolution)
        case media(MediaFilter)
        case event(EventKind)
        /// Not searchable in this version (people, what's in photos), or a place or date Lahza couldn't use.
        case unsupported
    }

    public var slot: QuerySlot
    public var resolution: Resolution
    /// The chip's text: "Al-Nakheel Park", "Last summer · Jun – Aug 2026", "Videos", "Trips", "soccer".
    public var chip: String
    /// SF Symbol for the chip.
    public var systemImage: String
    /// A date chip's quick changes in its editor ("Summer 2025 · Every summer · Any time").
    public var timePresets: [TimePreset] = []
    /// An area place's radius, for the editor's Tight · Normal · Wide.
    public var radius: PlaceRadius?

    public var id: Int { slot.id }

    public var isSupported: Bool { if case .unsupported = resolution { false } else { true } }
}

/// An area's radius as searched, and the place editor's choices: Tight is half its own radius, Normal its own, Wide
/// twice it; "near" doubles whichever is chosen.
public struct PlaceRadius: Sendable, Hashable {
    public enum Choice: String, Sendable, Hashable, CaseIterable {
        case tight, normal, wide

        public var factor: Double {
            switch self {
            case .tight: 0.5
            case .normal: 1
            case .wide: 2
            }
        }
    }

    /// The place's own radius in metres (Normal).
    public var natural: Double
    /// The radius the person chose, before "near" (nil: the place's own).
    public var chosen: Double?
    public var near: Bool

    public init(natural: Double, chosen: Double? = nil, near: Bool = false) {
        self.natural = natural
        self.chosen = chosen
        self.near = near
    }

    public func metres(_ choice: Choice) -> Double { natural * choice.factor }

    /// The choice the radius searched is, nil for another one (a "Widen to 2 km" tap).
    public var choice: Choice? {
        let radius = chosen ?? natural
        return Choice.allCases.first { abs(metres($0) - radius) < 1 }
    }
}

/// "Which Salam Park?" with a chip per candidate ("Riyadh · 10", "Dubai · 8"); choosing one replaces the slot's place
/// and is remembered for these words.
public struct PlacePicker: Sendable, Hashable {
    public struct Choice: Sendable, Hashable, Identifiable {
        public var candidate: PlaceCandidate
        /// "Riyadh · 10".
        public var label: String
        public var id: String { candidate.id }
    }

    public var slot: Int
    /// The words the person typed for the place (what a choice is remembered under).
    public var phrase: String
    public var question: String
    public var choices: [Choice]
    /// The candidate search ran with.
    public var chosen: String
}

/// A section of results.
public struct ResultSection: Sendable, Hashable, Identifiable {
    public var tier: Tier
    /// "Inside Al-Nakheel Park", "Matches", "Nearby or close in time", "Location unknown · 5", "Weaker matches".
    public var title: String
    public var caption: String?
    public var groups: [ResultGroup]

    public var id: Tier { tier }
}

/// A moment card, or a trip header wrapping its cards.
public enum ResultGroup: Sendable, Hashable, Identifiable {
    case moment(MomentCard)
    case trip(TripGroup)

    public var cards: [MomentCard] {
        switch self {
        case .moment(let card): [card]
        case .trip(let group): group.cards
        }
    }

    public var id: String {
        switch self {
        case .moment(let card): "m-\(card.id.day)-\(card.id.startUTC)"
        case .trip(let group): "t-\(group.trip.startDay)"
        }
    }
}

/// A trip's cards under its header ("Greece · 2 – 8 Jul 2023").
public struct TripGroup: Sendable, Hashable {
    public var trip: TripRow
    /// "Greece · 2 – 8 Jul 2023" in the iPhone's date format.
    public var title: String
    public var cards: [MomentCard]
}

/// One moment's hits (search spec §6.7). Dates and times are formatted by the app from ``moment`` (the same helper
/// the Moments tab uses).
public struct MomentCard: Sendable, Hashable, Identifiable {
    /// The moment's key; the "No date" group has day `Int32.min`.
    public var id: MomentKey
    /// Nil for the "No date" group.
    public var moment: MomentRow?
    /// The section the card is in: its best hit's tier.
    public var tier: Tier
    /// In time order.
    public var hits: [AssetHit]
    /// Every item of the moment (hits or not).
    public var wholeCount: Int
    public var photoCount: Int
    public var videoCount: Int
    /// Hits whose position comes from a located item of the same outing.
    public var borrowedCount: Int
    /// Up to 2 reasons most hits share, then "Includes 3 without location from this outing".
    public var reasons: [Reason]
    /// The geohash-7 cells of the moment's hits (place names are fetched for cards on screen first).
    public var cells: [String]
    /// max S + 0.05·ln(1 + hits), kept for later ranking.
    public var score: Double
    public var tripID: Int64?

    public static let noDateKey = MomentKey(day: Int32.min, startUTC: 0)
}

/// One matching photo or video.
public struct AssetHit: Sendable, Hashable, Identifiable {
    /// The asset row id.
    public var id: Int64
    public var localID: String
    public var kind: MediaKind
    /// Seconds (videos).
    public var duration: Double
    /// Unix seconds; nil when undated.
    public var utc: Int64?
    /// Local wall seconds (``LocalTime``); nil when undated.
    public var wall: Int64?
    public var tier: Tier
    public var score: Double
    public var slotScores: [SlotKind: Double]
    public var reasons: [Reason]
    /// A More member of a better card ("nearby").
    public var isNearby: Bool
}

/// Why something matched, from fixed templates (never generated).
public struct Reason: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case place, time, media, event, borrowed, caution, neutral
    }

    public var kind: Kind
    public var text: String
    public var systemImage: String

    public init(_ kind: Kind, _ text: String, _ systemImage: String) {
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
    }
}

/// Best and More together.
public struct Totals: Sendable, Hashable {
    public var moments: Int
    public var photos: Int
    public var videos: Int

    public var items: Int { photos + videos }
}

/// What was searched (the header's caption and the footer rows).
public struct Coverage: Sendable, Hashable {
    /// Assets searched.
    public var searched: Int
    /// About how many the library holds (the reading total while the first build runs).
    public var libraryTotal: Int?
    public var isPartial: Bool
    public var coveredSince: Date?
    public var isLimited: Bool
    /// Place-only queries: the share of the library without a location (never listed).
    public var unlocatedShare: Double?
    /// Time queries: assets without a reliable date (never listed).
    public var undatedExcluded: Int
    /// Hits whose location comes from the same outing.
    public var borrowedShown: Int
    /// "Searched all 563 photos", "Searched 12,400 of about 31,204 so far", "Searching the 40 photos you've shared".
    public var caption: String
    /// While the first build runs: "Searched your photos since Mar 2021, still reading older ones".
    public var header: String?
    /// "+2 without location from the same outing", "12 photos have no reliable date", "28% of your photos have no location".
    public var notes: [String]
}

/// Why nothing matched, and taps that widen the search (never automatic).
public struct NoMatch: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Each slot matches alone, the combination doesn't.
        case combination
        /// An area with photos only beyond its radius.
        case onlyBeyondRadius
        /// The place resolved but holds no photos.
        case placeEmpty
        case placeNotFound(PlaceNotFound)
        case timeEmpty
        case mediaEmpty
        case future
        /// Only words Lahza can't search yet.
        case onlyUnsupported
        /// The dates are older than what the first build has read so far.
        case stillReading
        /// A free search: everything that matched is older than the search's scope (``SearchResult/lockedCount``).
        case onlyEarlier
        case nothing
    }

    public var kind: Kind
    public var headline: String
    public var detail: String?
    public var offers: [WideningOffer]
    /// The library's example searches, whenever no offer is left, so there is always a next tap.
    public var examples: [ExampleSearch]
}

/// A tap that widens the search: edits applied to the query, with how many results they give.
public struct WideningOffer: Sendable, Hashable, Identifiable {
    /// "Al-Nakheel Park, any time", "Widen to 2 km", "Greece".
    public var label: String
    public var count: Int
    public var edits: [SlotEdit]

    public var id: String { label }
}

/// A search the library can answer, with its verified count ("Al-Nakheel Park · 85").
public struct ExampleSearch: Sendable, Hashable, Identifiable {
    public var text: String
    public var count: Int
    public var id: String { text }
}

/// Where a search's time went.
public struct Timings: Sendable, Hashable {
    public var parse: Duration = .zero
    public var resolve: Duration = .zero
    public var snapshot: Duration = .zero
    public var score: Duration = .zero
    public var group: Duration = .zero
    public var total: Duration = .zero
}

/// What the index says about itself when a search runs (the coverage line, the Apple Maps toggle).
public struct SearchIndexContext: Sendable, Hashable {
    public var isPartial: Bool
    public var coveredSince: Date?
    public var isLimited: Bool
    /// About how many photos and videos the library holds (nil: what the index holds).
    public var libraryTotal: Int?
    /// Settings › Search index › Apple Maps place names.
    public var appleMapsEnabled: Bool

    public init(isPartial: Bool = false, coveredSince: Date? = nil, isLimited: Bool = false, libraryTotal: Int? = nil, appleMapsEnabled: Bool = true) {
        self.isPartial = isPartial
        self.coveredSince = coveredSince
        self.isLimited = isLimited
        self.libraryTotal = libraryTotal
        self.appleMapsEnabled = appleMapsEnabled
    }

    /// From the index's status.
    public init(_ status: IndexStatus, appleMapsEnabled: Bool) {
        var total: Int?
        if case .reading(_, let all) = status.phase { total = all }
        self.init(isPartial: status.isPartial, coveredSince: status.coveredSince, isLimited: status.isLimited, libraryTotal: total,
                  appleMapsEnabled: appleMapsEnabled)
    }
}
