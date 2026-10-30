import LZDesign
import LZIndex
import LZSearch
import SwiftUI

/// One row of a result's grid (search spec §7.1 item 8): a section's header, a month's header ("June 2025" and its
/// counts), or a row of square tiles with a video's length, a favourite's heart and a gold dot for a photo just outside
/// the place or dates. The grid is laid out as rows of the results' own lazy stack: a lazy grid nested in it loses its
/// place when the screen scrolls to a photo (switching from Moments).
nonisolated enum GridRow: Identifiable {
    case section(ResultGrid.TierSection)
    case month(ResultGrid.Month)
    case tiles([ResultGrid.Tile])

    static let minimum: CGFloat = 96
    static let gap: CGFloat = 3

    var id: String {
        switch self {
        case .section(let section): "gs-\(section.tier)"
        case .month(let month): "gm-\(month.id)"
        case .tiles(let tiles): Self.tilesID(tiles.first?.position ?? -1)
        }
    }

    static func tilesID(_ firstPosition: Int) -> String { "gt-\(firstPosition)" }

    /// As many tiles of at least 96 pt as fit `width`, 3 gaps apart (three before the width is known).
    static func columns(width: CGFloat) -> Int {
        width > 0 ? max(1, Int((width + gap) / (minimum + gap))) : 3
    }

    /// A tile's side in points at `width`.
    static func side(width: CGFloat) -> CGFloat {
        let columns = columns(width: width)
        return max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// The grid's rows: each section's header, then each month's header and its tiles, `columns` to a row.
    static func rows(_ grid: ResultGrid, columns: Int) -> [GridRow] {
        var rows: [GridRow] = []
        for section in grid.sections {
            rows.append(.section(section))
            for month in section.months {
                rows.append(.month(month))
                for start in stride(from: 0, to: month.tiles.count, by: max(1, columns)) {
                    rows.append(.tiles(Array(month.tiles[start..<min(month.tiles.count, start + columns)])))
                }
            }
        }
        return rows
    }

    /// The id of the row holding the tile at `position`.
    static func rowID(of position: Int, in grid: ResultGrid, columns: Int) -> String? {
        for month in grid.sections.flatMap(\.months) {
            guard let first = month.tiles.first?.position, position >= first, position < first + month.tiles.count else { continue }
            return tilesID(first + (position - first) / max(1, columns) * max(1, columns))
        }
        return nil
    }
}

/// One row of the grid.
struct GridRowView: View {
    let row: GridRow
    let columns: Int
    @Binding var showsUnknown: Bool
    let open: (ResultGrid.Tile) -> Void

    var body: some View {
        switch row {
        case .section(let section):
            Group {
                if section.tier == .locationUnknown {
                    SectionHeader(section.title, caption: section.caption, actionTitle: showsUnknown ? AskCopy.hide : AskCopy.show) {
                        showsUnknown.toggle()
                    }
                } else {
                    SectionHeader(section.title, caption: section.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, LZSpace.lg + LZSpace.md)
            .accessibilityIdentifier("result-section-\(section.tier)")
        case .month(let month):
            GridMonthHeader(month: month)
        case .tiles(let tiles):
            HStack(spacing: GridRow.gap) {
                ForEach(tiles) { tile in
                    GridTile(tile: tile) { open(tile) }
                        .frame(maxWidth: .infinity)
                }
                ForEach(tiles.count..<max(tiles.count, columns), id: \.self) { _ in
                    Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, GridRow.gap)
        }
    }
}

/// The thumbnails being prepared: the 60 tiles after the latest one to appear.
nonisolated struct GridPrefetch: Equatable {
    static let ahead = 60

    /// Tile positions being cached.
    private(set) var cached: Range<Int> = 0..<0

    /// The tile at `position` appeared: what to start caching (the part of the next 60 not yet cached) and what to stop
    /// (cached tiles no longer among them).
    mutating func appeared(_ position: Int, total: Int) -> (start: [Range<Int>], stop: [Range<Int>]) {
        let lower = min(total, position + 1)
        let window = lower..<min(total, lower + Self.ahead)
        defer { cached = window }
        guard window != cached else { return ([], []) }
        return (Self.subtracting(cached, from: window), Self.subtracting(window, from: cached))
    }

    /// The parts of `range` outside `other`.
    private static func subtracting(_ other: Range<Int>, from range: Range<Int>) -> [Range<Int>] {
        func part(_ lower: Int, _ upper: Int) -> Range<Int>? { lower < upper ? lower..<upper : nil }
        guard !other.isEmpty else { return range.isEmpty ? [] : [range] }
        return [part(range.lowerBound, min(range.upperBound, other.lowerBound)), part(max(range.lowerBound, other.upperBound), range.upperBound)]
            .compactMap { $0 }
    }

    /// Stops everything: the range that was cached.
    mutating func reset() -> Range<Int>? {
        defer { cached = 0..<0 }
        return cached.isEmpty ? nil : cached
    }
}

/// "June 2025" and its photo counts, or "No date".
struct GridMonthHeader: View {
    let month: ResultGrid.Month

    var body: some View {
        let videos = month.tiles.count { $0.hit.kind == .video }
        VStack(alignment: .leading, spacing: LZSpace.xxs) {
            Text(title)
                .lzText(.headline)
                .foregroundStyle(.lz(.ink))
            Text(MomentCopy.counts(photos: month.tiles.count - videos, videos: videos))
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LZSpace.md)
        .padding(.bottom, LZSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        guard let year = month.year, let number = month.month else { return AskCopy.noDate }
        return MomentCopy.monthTitle(year: year, month: number)
    }
}

/// One square tile; a tap opens the viewer on it.
private struct GridTile: View {
    let tile: ResultGrid.Tile
    let open: () -> Void

    var body: some View {
        let hit = tile.hit
        Button(action: open) {
            AssetThumbnail(localID: hit.localID, side: nil, radius: LZRadius.xs)
                .aspectRatio(1, contentMode: .fit)
                .assetTileBadges(isFavorite: hit.isFavorite, videoDuration: hit.kind == .video ? hit.duration : nil, isNearby: hit.isNearby)
                .contentShape(Rectangle())
        }
        .buttonStyle(LZPressStyle(scale: 0.97))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AssetTileCopy.label(isVideo: hit.kind == .video, duration: hit.duration, isFavorite: hit.isFavorite, wall: hit.wall,
                                                isNearby: hit.isNearby))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("grid-tile-\(hit.id)")
    }
}

/// Which moment cards (Moments) or tiles (Grid) are on screen, so switching layouts opens the other one at the same
/// photos. A plain object: scrolling never redraws the results.
@MainActor final class ResultsAnchor {
    /// The results' header is on screen: the top of the results, where both layouts start alike.
    var isHeaderVisible = true
    private var cards: Set<MomentKey> = []
    private var tiles: Set<Int> = []

    func card(_ key: MomentKey, isVisible: Bool) {
        if isVisible { cards.insert(key) } else { cards.remove(key) }
    }

    /// A row of tiles, by its first tile's position.
    func tile(_ position: Int, isVisible: Bool) {
        if isVisible { tiles.insert(position) } else { tiles.remove(position) }
    }

    /// Where `layout` should open, as the row id to scroll to: the row of the first tile of the top card on screen, or
    /// the card of the top tile; nil at the top of the results (the screen stays as it is). A header just above the
    /// row is scrolled to instead, so it goes under the pinned Moments | Grid and the photos stay in sight.
    func target(for layout: SearchStore.ResultsLayout, result: SearchResult, grid: ResultGrid, columns: Int, showsUnknown: Bool) -> String? {
        guard !isHeaderVisible else { return nil }
        switch layout {
        case .grid:
            guard let card = result.cards.first(where: { cards.contains($0.id) }), let tile = grid.firstTile(of: card.id),
                  let id = GridRow.rowID(of: tile.position, in: grid, columns: columns) else { return nil }
            let rows = GridRow.rows(grid, columns: columns)
            guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return id }
            if case .tiles = rows[index - 1] { return id }
            return rows[index - 1].id
        case .moments:
            guard let position = tiles.min(), grid.tiles.indices.contains(position) else { return nil }
            let id = ResultRow.cardID(grid.tiles[position].card)
            let rows = ResultRow.rows(result.sections, showsUnknown: showsUnknown)
            guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return id }
            if case .card = rows[index - 1] { return id }
            return rows[index - 1].id
        }
    }

    /// The layout switched: what was on screen is gone (the header stays as it was).
    func reset() {
        cards.removeAll()
        tiles.removeAll()
    }
}
