import Foundation
import LZGeo
import LZIndex

/// A result laid out as a grid (search spec §7.1 item 8): each section's photos in the result's own order (card by
/// card, as the moment cards list them), under the section's header and then month headers; undated photos come under
/// "No date". Location unknown lists its photos only when opened. The viewer pages through ``tiles``, and switching
/// between Grid and Moments keeps the place through each tile's card.
public struct ResultGrid: Sendable, Hashable {
    /// A section of the result: its header, then its photos by month.
    public struct TierSection: Sendable, Hashable, Identifiable {
        public var tier: Tier
        /// "Inside Al-Nakheel Park", "Nearby or close in time", "Location unknown · 5".
        public var title: String
        public var caption: String?
        public var months: [Month]
        /// Location unknown while closed: the header only.
        public var isCollapsed: Bool

        public var id: Tier { tier }
    }

    /// Consecutive cards of one month (a month can come back within a section when a trip's cards span two).
    public struct Month: Sendable, Hashable, Identifiable {
        public var id: String
        /// Nil for undated photos.
        public var year: Int?
        public var month: Int?
        public var tiles: [Tile]
    }

    /// One photo or video.
    public struct Tile: Sendable, Hashable, Identifiable {
        public var hit: AssetHit
        /// The card it is in.
        public var card: MomentKey
        /// Its place in ``ResultGrid/tiles`` (the viewer's page).
        public var position: Int

        public var id: Int64 { hit.id }
    }

    public var sections: [TierSection]
    /// Every listed tile in order.
    public var tiles: [Tile]

    public init(_ result: SearchResult, showsUnknown: Bool) {
        var sections: [TierSection] = []
        var tiles: [Tile] = []
        for section in result.sections {
            let collapsed = section.tier == .locationUnknown && !showsUnknown
            var months: [Month] = []
            if !collapsed {
                for card in section.groups.flatMap(\.cards) {
                    let civil = card.id == MomentCard.noDateKey ? nil : LocalTime.civil(day: card.id.day)
                    if months.last.map({ $0.year != civil?.year || $0.month != civil?.month }) ?? true {
                        months.append(Month(id: "\(section.tier.rawValue)-\(months.count)", year: civil?.year, month: civil?.month, tiles: []))
                    }
                    for hit in card.hits {
                        let tile = Tile(hit: hit, card: card.id, position: tiles.count)
                        tiles.append(tile)
                        months[months.count - 1].tiles.append(tile)
                    }
                }
            }
            sections.append(TierSection(tier: section.tier, title: section.title, caption: section.caption, months: months, isCollapsed: collapsed))
        }
        self.sections = sections
        self.tiles = tiles
    }

    /// A card's first listed tile (where Grid opens when Moments showed that card on top).
    public func firstTile(of card: MomentKey) -> Tile? {
        tiles.first { $0.card == card }
    }
}
