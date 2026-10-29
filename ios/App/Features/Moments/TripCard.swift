import LZDesign
import LZIndex
import SwiftUI

/// One trip on the Moments tab's Trips list: a mosaic of up to five moment covers, the name and dates, the counts
/// and places. The whole card is one button and one VoiceOver element.
struct TripCard: View {
    let trip: TripRow
    let action: () -> Void

    private static let mosaicHeight: CGFloat = 176
    private static let gap: CGFloat = 3

    var body: some View {
        PaperCard(style: .raised, padding: LZSpace.md, action: action) {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                mosaic
                VStack(alignment: .leading, spacing: LZSpace.xs) {
                    Text(trip.label)
                        .lzText(.title)
                        .foregroundStyle(.lz(.ink))
                    Text(MomentCopy.tripDates(trip))
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.ink))
                    Text(MomentCopy.tripCaption(trip))
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                }
                .padding(.horizontal, LZSpace.xs)
                .padding(.bottom, LZSpace.xs)
                .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MomentCopy.spokenTrip(trip))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("trip-card-\(trip.startDay)")
    }

    /// The cover large on the left; the others fill the right half in rows of at most two.
    private var mosaic: some View {
        let ids = trip.thumbnailLocalIDs
        return HStack(spacing: Self.gap) {
            if let cover = ids.first { tile(cover) }
            let rows = Self.rows(Array(ids.dropFirst().prefix(4)))
            if !rows.isEmpty {
                VStack(spacing: Self.gap) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: Self.gap) { ForEach(row, id: \.self) { tile($0) } }
                    }
                }
            }
        }
        .frame(height: Self.mosaicHeight)
        .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(LZRadius.sm)), isUniform: false))
    }

    /// Two others stack; three or four make a row of two over the rest.
    static func rows(_ ids: [String]) -> [[String]] {
        switch ids.count {
        case 0: []
        case 1: [ids]
        case 2: ids.map { [$0] }
        default: [Array(ids.prefix(2)), Array(ids.dropFirst(2))]
        }
    }

    private func tile(_ id: String) -> some View {
        AssetThumbnail(localID: id, side: nil, radius: 0)
    }
}
