import LZDesign
import LZGeo
import LZIndex
import LZSearch
import SwiftUI

/// One moment: its day, place, time span (with the zone when it isn't this iPhone's), counts and every item in a
/// grid. Shared by Ask and Moments: opened from a search, it shows the search's reasons and its matches first, then
/// the rest of the moment dimmed. The viewer and Save place come later.
struct MomentDetailScreen: View {
    let ref: MomentRef
    @Environment(AppModel.self) private var model
    @State private var detail: MomentDetailRows?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if let detail {
                let card = searchCard
                VStack(alignment: .leading, spacing: LZSpace.xl) {
                    MomentHeader(moment: detail.moment, trip: trip(of: detail.moment), homeCountry: model.moments.homeCountryCode,
                                 deviceZone: model.dependencies.deviceTimeZone(), reasons: card?.reasons ?? [])
                    if let card {
                        let split = MomentMatches(members: detail.members, card: card)
                        gridSection(MomentCopy.matchesTitle(split.matches.count), members: split.matches)
                            .accessibilityIdentifier("moment-matches")
                        if !split.others.isEmpty {
                            gridSection(MomentCopy.alsoTitle(split.others.count), members: split.others, dimmed: true)
                                .accessibilityIdentifier("moment-also")
                        }
                    } else {
                        gridSection(MomentCopy.allTitle(detail.members.count), members: detail.members)
                    }
                }
                .lzPage()
                .padding(.vertical, LZSpace.lg)
            } else if loaded {
                EmptyState(MomentCopy.goneTitle, message: MomentCopy.goneBody, systemImage: "rectangle.stack", tone: .neutral)
                    .lzPage()
            }
        }
        .background(.lz(.bg))
        .navigationTitle(detail.map { MomentCopy.shortDay($0.moment.key.day) } ?? MomentCopy.momentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("moment-detail")
        .task(id: model.index.version) {
            detail = await model.moments.moment(ref.key)
            loaded = true
            if let cell = detail?.moment.cell { model.index.prioritizePlaceNames(cells: [cell]) }
        }
    }

    private func trip(of moment: MomentRow) -> TripRow? {
        moment.tripID.flatMap { id in model.moments.trips.first { $0.id == id } }
    }

    /// The card of the search this moment was opened from. A search run again when the index changed keeps its
    /// moment keys, so the shown search's card is used.
    private var searchCard: MomentCard? {
        guard ref.searchID != nil else { return nil }
        return model.search.result?.cards.first { $0.id == ref.key }
    }

    /// A titled grid; `dimmed` fades the photos (the rest of a moment opened from a search), never the title.
    private func gridSection(_ title: String, members: [MomentDetailRows.Member], dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            Text(title)
                .lzText(.label)
                .foregroundStyle(.lz(.muted))
                .accessibilityAddTraits(.isHeader)
            MomentGrid(members: members)
                .opacity(dimmed ? 0.6 : 1)
        }
    }
}

/// A moment's items split by a search: those that matched (in its card), then the others.
nonisolated struct MomentMatches: Equatable {
    var matches: [MomentDetailRows.Member]
    var others: [MomentDetailRows.Member]

    init(members: [MomentDetailRows.Member], card: MomentCard) {
        let hits = Set(card.hits.map(\.id))
        matches = members.filter { hits.contains($0.id) }
        others = members.filter { !hits.contains($0.id) }
    }
}

/// The moment's date, place line, time span, counts and, from a search, why it matched.
private struct MomentHeader: View {
    let moment: MomentRow
    let trip: TripRow?
    let homeCountry: String?
    let deviceZone: TimeZone
    /// Why it matched, when opened from a search.
    var reasons: [Reason] = []

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            Text(MomentCopy.dayTitle(moment.key.day))
                .lzText(.display)
                .foregroundStyle(.lz(.ink))
            Label(MomentCopy.placeLine(moment, homeCountry: homeCountry), systemImage: "mappin.and.ellipse")
                .lzText(.body)
                .foregroundStyle(.lz(.ink))
            Label(time, systemImage: "clock")
                .lzText(.subheadline)
                .foregroundStyle(.lz(.muted))
            HStack(spacing: LZSpace.sm) {
                Text(MomentCopy.counts(photos: moment.photoCount, videos: moment.videoCount))
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.muted))
                if let trip {
                    Pill(MomentCopy.tripBadge(trip), systemImage: "airplane", tone: .sage)
                }
            }
            if !reasons.isEmpty {
                LZFlowLayout(spacing: LZSpace.xs, lineSpacing: LZSpace.xs) {
                    ForEach(reasons, id: \.self) { reason in
                        Pill(reason.text, systemImage: reason.systemImage, tone: AskCopy.tone(reason))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: String {
        [MomentCopy.timeSpan(moment), MomentCopy.zoneNote(moment, deviceZone: deviceZone)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Every item of a moment in time order: square tiles, a video's length, a favourite's heart.
private struct MomentGrid: View {
    let members: [MomentDetailRows.Member]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(members) { member in
                AssetThumbnail(localID: member.localID, side: nil, radius: LZRadius.xs)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        if member.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(LZSpace.xs + 1)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if member.isVideo {
                            Text(MomentCopy.duration(member.duration))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(LZSpace.xs + 1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(MomentGrid.label(member))
            }
        }
    }

    /// "Video, 0:42, favourite, 5:20 PM".
    static func label(_ member: MomentDetailRows.Member) -> String {
        var parts = [member.isVideo ? "Video, \(MomentCopy.duration(member.duration))" : "Photo"]
        if member.isFavorite { parts.append("favourite") }
        if let wall = member.wall {
            parts.append(Date(timeIntervalSince1970: TimeInterval(wall))
                .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt)))
        }
        return parts.joined(separator: ", ")
    }
}

/// One trip: its name, dates, counts and places, then its moments day by day.
struct TripDetailScreen: View {
    let ref: TripRef
    @Environment(AppModel.self) private var model
    @State private var moments: [MomentRow] = []
    @State private var loaded = false

    var body: some View {
        let trip = model.moments.trips.first { $0.startDay == ref.startDay }
        ScrollView {
            if let trip {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(alignment: .leading, spacing: LZSpace.sm) {
                        Text(trip.label).lzText(.display).foregroundStyle(.lz(.ink))
                        Label(MomentCopy.tripDates(trip), systemImage: "calendar")
                            .lzText(.body)
                            .foregroundStyle(.lz(.ink))
                        Text(MomentCopy.tripCaption(trip))
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.muted))
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, LZSpace.lg)
                    .padding(.bottom, LZSpace.sm)
                    ForEach(days, id: \.day) { day in
                        Section {
                            ForEach(day.moments) { moment in
                                MomentListRow(moment: moment, title: MomentCopy.startTime(moment)) {
                                    model.open(.moment(MomentRef(key: moment.key, origin: ref.origin)))
                                }
                            }
                        } header: {
                            Text(MomentCopy.tripDay(day.day, moments: day.moments))
                                .lzText(.headline)
                                .foregroundStyle(.lz(.ink))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, LZSpace.lg)
                                .padding(.bottom, LZSpace.xs)
                                .background(.lz(.bg))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .lzPage()
                .padding(.bottom, LZSpace.xl)
            } else if loaded {
                EmptyState(MomentCopy.tripGoneTitle, message: MomentCopy.goneBody, systemImage: "airplane", tone: .neutral)
                    .lzPage()
            }
        }
        .background(.lz(.bg))
        .navigationTitle(trip?.label ?? MomentCopy.tripTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("trip-detail")
        .task(id: model.index.version) {
            await model.moments.load()
            if let trip = model.moments.trips.first(where: { $0.startDay == ref.startDay }) {
                moments = await model.moments.moments(of: trip)
            } else {
                moments = []
            }
            loaded = true
        }
    }

    private var days: [(day: Int32, moments: [MomentRow])] {
        Dictionary(grouping: moments, by: \.key.day).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
