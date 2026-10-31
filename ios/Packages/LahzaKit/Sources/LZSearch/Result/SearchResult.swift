import Foundation
import LZGeo
import LZIndex

/// What a search found: the query as understood, the hits grouped into sections of moment cards (and trips), the
/// totals, what was searched, and why nothing matched when nothing did (search spec §6.7).
public struct SearchResult: Sendable, Identifiable {
    public var id: UUID
    public var query: ResolvedQuery
    /// Best, then More, then Location unknown, then Weaker (only when asked for); empty sections are left out. For the
    /// first or last time, only that occasion's photos.
    public var sections: [ResultSection]
    /// Best and More.
    public var totals: Totals
    public var coverage: Coverage
    public var noMatch: NoMatch?
    /// The slots left out ("soccer", "with Ahmed"), in text order.
    public var unsupported: [QuerySlot]
    /// "Lahza can't see what's in photos yet, so “soccer” was left out. Showing all your photos at Al-Nakheel Park."
    /// Above a no-match it ends at "left out.".
    public var unsupportedNotice: String?
    /// "The first time" or "the last time": the occasion shown and the times left out (nil for every other query).
    public var occasion: Occasion? = nil
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
    /// Why the Apple Maps search the place editor asked for couldn't be made (offline, busy); nil when it was made or
    /// none was asked for.
    public var appleMapsMissed: PlaceNotFound? = nil

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
        case order(SearchOrder)
        /// Words about what's in photos, searched by the photo tags they map to.
        case visual(VisualMatch)
        /// Not searchable in this version (people, words with no photo tag), or a place or date Lahza couldn't use.
        case unsupported
    }

    public var slot: QuerySlot
    public var resolution: Resolution
    /// The chip's text: "Al-Nakheel Park", "Last summer · Jun – Aug 2026", "Videos", "Trips", "First time", "soccer".
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

/// What a visual chip searched: the concept, its own tags (Best) and its related tags (More, E24), as people read them.
public struct VisualMatch: Sendable, Hashable {
    /// "hiking".
    public var concept: String
    /// "hiking".
    public var tags: [String]
    /// "trail", "mountain": searched loosely, unless removed.
    public var related: [String]
    /// The related tags were removed in the editor (they are listed, not searched).
    public var relatedRemoved: Bool
    /// A description the image model searches ("red car parked by the sea"); `tags` are the photo tags of the concepts
    /// it names, which add to it.
    public var described: Bool
    /// How many people it asks for, checked with Vision's counts ("without people", "two people").
    public var people: String?

    public init(concept: String, tags: [String], related: [String], relatedRemoved: Bool = false, described: Bool = false, people: String? = nil) {
        self.concept = concept
        self.tags = tags
        self.related = related
        self.relatedRemoved = relatedRemoved
        self.described = described
        self.people = people
    }
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

/// The one occasion a "first time" or "last time" search shows (a whole trip, or one moment), and the row after it
/// that lists every time ("9 later times · Show all").
public struct Occasion: Sendable, Hashable {
    /// ``SearchOrder/first`` or ``SearchOrder/last``.
    public var order: SearchOrder
    /// The occasion is a whole trip (else one moment, or a day not grouped into moments).
    public var isTrip: Bool
    /// The other times search found; a free search counts those it covers (what Show all lists).
    public var others: Int
    /// "9 later times", "1 later trip", "3 earlier times".
    public var othersLabel: String
    /// Show all's edits: after the first time every time oldest first, after the last time newest first.
    public var showAll: [SlotEdit]
}

/// A section of results.
public struct ResultSection: Sendable, Hashable, Identifiable {
    public var tier: Tier
    /// "Inside Al-Nakheel Park", "Matches", "First time in Dubai", "Nearby or close in time", "Location unknown · 5",
    /// "Weaker matches".
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
    public var isFavorite: Bool

    public init(id: Int64, localID: String, kind: MediaKind, duration: Double = 0, utc: Int64?, wall: Int64?, tier: Tier, score: Double = 1,
                slotScores: [SlotKind: Double] = [:], reasons: [Reason] = [], isNearby: Bool = false, isFavorite: Bool = false) {
        self.id = id
        self.localID = localID
        self.kind = kind
        self.duration = duration
        self.utc = utc
        self.wall = wall
        self.tier = tier
        self.score = score
        self.slotScores = slotScores
        self.reasons = reasons
        self.isNearby = isNearby
        self.isFavorite = isFavorite
    }
}

/// Why something matched, from fixed templates (never generated): a pill's few words, and the sentence "Why this
/// matched" says ("No GPS in this photo. Location comes from a photo taken 3 min earlier in the same outing.").
public struct Reason: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case place, time, media, event, visual, borrowed, caution, neutral
    }

    public var kind: Kind
    /// The pill: "In Al-Nakheel Park", "Summer 2025", "Location from the same outing".
    public var text: String
    public var systemImage: String
    /// The sentence: "Taken inside Al-Nakheel Park.", "Taken in summer 2025."
    public var detail: String

    /// `detail` defaults to the pill's words as a sentence.
    public init(_ kind: Kind, _ text: String, _ systemImage: String, detail: String? = nil) {
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
        self.detail = detail ?? "\(text)."
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
    /// "Searched all 563 photos", "Searched your last 12 months" (free), "Searched 12,400 of about 31,204 so far",
    /// "Searching the 40 photos you've shared".
    public var caption: String
    /// While the first build runs: "Searched your photos since Mar 2021, still reading older ones".
    public var header: String?
    /// "+2 without location from the same outing", "12 photos have no reliable date", "28% of your photos have no location".
    public var notes: [String]
    /// Words about what's in photos, while Lahza is still tagging them: "Checked 12,400 of 31,204 photos so far" (E25).
    public var visualLine: String? = nil
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
        /// No checked photo has the tags of words about what's in photos ("No photos tagged scuba diving among 1,204
        /// checked").
        case notTagged
        /// A description no photo matches confidently: no likely or precise tag, and the image model is sure of none.
        /// What it found waits behind "Show weaker".
        case notConfident
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

extension SearchCapabilities {
    /// What an index can search: words about what's in photos once it has a Vision pass, and any description once
    /// photos have vectors and the text model is on the iPhone (`textModel`).
    public init(_ status: IndexStatus, textModel: Bool = false) {
        self.init(visual: status.visual != nil, freeText: textModel && (status.visual?.embedded ?? 0) > 0)
    }
}
