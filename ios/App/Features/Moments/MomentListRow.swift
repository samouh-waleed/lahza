import LZDesign
import LZIndex
import SwiftUI

/// One moment in a list: the day, the place, the counts and a trip badge, then up to three square thumbnails at the
/// trailing edge. One button and one VoiceOver element. At accessibility text sizes the thumbnails go under the text.
struct MomentListRow: View {
    let moment: MomentRow
    var trip: TripRow?
    /// The first line: the day ("Sat 22 Aug"), or the start time under a day heading.
    var title: String?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let thumbnailSide: CGFloat = 64
    static let thumbnailSpacing: CGFloat = 3

    var body: some View {
        Button(action: action) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LZSpace.sm))
                : AnyLayout(HStackLayout(alignment: .center, spacing: LZSpace.md))
            layout {
                VStack(alignment: .leading, spacing: LZSpace.xxs) {
                    Text(title ?? MomentCopy.shortDay(moment.key.day))
                        .lzText(.headline)
                        .foregroundStyle(.lz(.ink))
                    Text(MomentCopy.place(moment))
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.ink))
                        .lineLimit(2)
                    Text(MomentCopy.counts(photos: moment.photoCount, videos: moment.videoCount))
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                    if let trip {
                        Pill(MomentCopy.tripBadge(trip), systemImage: "airplane", tone: .sage)
                            .padding(.top, LZSpace.xxs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                thumbnails
            }
            .padding(.vertical, LZSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(LZPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MomentCopy.spokenRow(moment, trip: trip))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("moments-row-\(moment.key.day)-\(moment.key.startUTC)")
    }

    private var thumbnails: some View {
        HStack(spacing: Self.thumbnailSpacing) {
            ForEach(moment.thumbnailLocalIDs.prefix(3), id: \.self) { id in
                AssetThumbnail(localID: id, side: Self.thumbnailSide)
            }
        }
    }
}
