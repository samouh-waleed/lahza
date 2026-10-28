import LZDesign
import LZGeo
import LZIndex
import SwiftUI

/// One moment: its day, place, time span (with the zone when it isn't this iPhone's), counts and every item in a
/// grid. Shared by Ask and Moments; the viewer and Save place come later.
struct MomentDetailScreen: View {
    let ref: MomentRef
    @Environment(AppModel.self) private var model
    @State private var detail: MomentDetailRows?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: LZSpace.xl) {
                    MomentHeader(moment: detail.moment, trip: trip(of: detail.moment), homeCountry: model.moments.homeCountryCode,
                                 deviceZone: model.dependencies.deviceTimeZone())
                    VStack(alignment: .leading, spacing: LZSpace.sm) {
                        Text(MomentCopy.allTitle(detail.members.count))
                            .lzText(.label)
                            .foregroundStyle(.lz(.muted))
                            .accessibilityAddTraits(.isHeader)
                        MomentGrid(members: detail.members)
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
}

/// The moment's date, place line, time span and counts.
private struct MomentHeader: View {
    let moment: MomentRow
    let trip: TripRow?
    let homeCountry: String?
    let deviceZone: TimeZone

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
                                MomentListRow(moment: moment, title: MomentCopy.timeSpan(moment)) {
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
