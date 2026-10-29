import LZDesign
import LZIndex
import LZSearch
import SwiftUI

/// One moment in the results: up to four of its matching photos (the last showing "+N" when there are more), the
/// day, the place and time, the counts and why it matched. The whole card is one button and one VoiceOver element;
/// it opens the moment with its matches. The "No date" card has no moment to open.
struct MomentCardView: View {
    let card: MomentCard
    /// Today's day number, for "Yesterday" and the year left out this year.
    let today: Int32
    let homeCountry: String?
    let deviceZone: TimeZone
    let open: () -> Void
    @Environment(AppModel.self) private var model

    static let tiles = 4
    private static let gap: CGFloat = 3

    var body: some View {
        PaperCard(style: .raised, padding: LZSpace.md, action: card.moment == nil ? nil : open) {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                mosaic
                VStack(alignment: .leading, spacing: LZSpace.xs) {
                    Text(AskCopy.cardTitle(card, today: today))
                        .lzText(.title)
                        .foregroundStyle(.lz(.ink))
                    if let line = AskCopy.cardPlaceAndTime(card, homeCountry: homeCountry, deviceZone: deviceZone) {
                        Text(line)
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.ink))
                    }
                    Text(MomentCopy.counts(photos: card.photoCount, videos: card.videoCount))
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                    if !card.reasons.isEmpty {
                        LZFlowLayout(spacing: LZSpace.xs, lineSpacing: LZSpace.xs) {
                            ForEach(card.reasons, id: \.self) { reason in
                                Pill(reason.text, systemImage: reason.systemImage, tone: AskCopy.tone(reason))
                            }
                        }
                        .padding(.top, LZSpace.xxs)
                    }
                }
                .padding(.horizontal, LZSpace.xs)
                .padding(.bottom, LZSpace.xs)
                .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskCopy.spokenCard(card, today: today, homeCountry: homeCountry, deviceZone: deviceZone))
        .accessibilityAddTraits(card.moment == nil ? [] : .isButton)
        .accessibilityIdentifier("moment-card-\(card.id.day)-\(card.id.startUTC)")
        .onAppear { if !card.cells.isEmpty { model.index.prioritizePlaceNames(cells: card.cells) } }
    }

    /// Square tiles of the matches in time order (inside matches before nearby ones), leading; a video count badge.
    private var mosaic: some View {
        let ids = Self.tileIDs(card)
        let extra = card.hits.count - ids.count
        return HStack(spacing: Self.gap) {
            ForEach(Array(ids.enumerated()), id: \.offset) { position, id in
                AssetThumbnail(localID: id, side: nil, radius: LZRadius.xs)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if position == ids.count - 1, extra > 0 {
                            Text("+\((extra + 1).formatted())")
                                .font(.lz(.headline).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.lz(.scrim))
                                .clipShape(RoundedRectangle(cornerRadius: LZRadius.xs, style: .continuous))
                        }
                    }
            }
            ForEach(ids.count..<Self.tiles, id: \.self) { _ in
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if card.videoCount > 0 {
                Pill(card.videoCount.formatted(), systemImage: "play.fill", tone: .neutral)
                    .padding(LZSpace.xs + 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// The tiles' items: the card's matches, those inside first, then nearby ones, each in time order.
    static func tileIDs(_ card: MomentCard) -> [String] {
        let ordered = card.hits.filter { !$0.isNearby } + card.hits.filter(\.isNearby)
        return ordered.prefix(tiles).map(\.localID)
    }
}
