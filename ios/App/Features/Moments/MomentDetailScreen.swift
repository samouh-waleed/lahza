import LZDesign
import LZGeo
import LZIndex
import SwiftUI

/// One moment: its day, place and items. A plain list for now; the photo grid comes with the Moments tab's
/// design.
struct MomentDetailScreen: View {
    let ref: MomentRef
    @Environment(AppModel.self) private var model
    @State private var detail: MomentDetailRows?
    @State private var loaded = false

    var body: some View {
        Form {
            if let detail {
                Section {
                    Text(MomentCopy.title(detail.moment)).font(.headline)
                    Text(MomentCopy.subtitle(detail.moment)).foregroundStyle(.secondary)
                }
                Section(MomentCopy.allTitle(detail.members.count)) {
                    ForEach(detail.members) { member in
                        LabeledContent(member.wall.map(MomentCopy.time) ?? "–", value: member.isVideo ? "Video" : "Photo")
                    }
                }
            } else if loaded {
                Text(MomentCopy.gone).foregroundStyle(.secondary)
            }
        }
        .settingsForm(detail.map { MomentCopy.title($0.moment) } ?? MomentCopy.navigationTitle)
        .accessibilityIdentifier("moment-detail")
        .task(id: model.index.version) {
            detail = await model.moments.moment(ref.key)
            loaded = true
        }
    }
}

/// One trip's moments, day by day.
struct TripDetailScreen: View {
    let ref: TripRef
    @Environment(AppModel.self) private var model
    @State private var trip: TripRow?
    @State private var moments: [MomentRow] = []

    var body: some View {
        Form {
            if let trip {
                Section {
                    Text(MomentCopy.tripTitle(trip)).font(.headline)
                    Text(MomentCopy.counts(photos: trip.itemCount - trip.videoCount, videos: trip.videoCount)).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.day) { day in
                    Section(MomentCopy.dayTitle(day.day)) {
                        ForEach(day.moments) { moment in
                            Button {
                                model.open(.moment(MomentRef(key: moment.key, origin: ref.origin)))
                            } label: {
                                LabeledContent(moment.label ?? MomentCopy.unknownPlace, value: moment.itemCount.formatted())
                            }
                        }
                    }
                }
            }
        }
        .settingsForm(trip?.label ?? MomentCopy.tripNavigationTitle)
        .accessibilityIdentifier("trip-detail")
        .task(id: model.index.version) {
            trip = (try? await model.index.reader?.trips())?.first { $0.startDay == ref.startDay }
            moments = if let trip { await model.moments.moments(of: trip) } else { [] }
        }
    }

    private var days: [(day: Int32, moments: [MomentRow])] {
        Dictionary(grouping: moments, by: \.key.day).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Moment and trip words shared by the Moments screens.
nonisolated enum MomentCopy {
    static let navigationTitle = "Moment"
    static let tripNavigationTitle = "Trip"
    static let gone = "This moment changed. Go back to see it again."
    static let unknownPlace = "Unknown place"

    /// "Sat 22 Aug 2026".
    static func title(_ moment: MomentRow) -> String { dayTitle(moment.key.day) }

    static func dayTitle(_ day: Int32) -> String {
        let date = LocalTime.civil(day: day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let value = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? .now
        return value.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(Locale(identifier: "en_GB")))
    }

    /// "Al-Nakheel Park · 8 photos".
    static func subtitle(_ moment: MomentRow) -> String {
        [moment.label, counts(photos: moment.photoCount, videos: moment.videoCount)].compactMap { $0 }.joined(separator: " · ")
    }

    static func counts(photos: Int, videos: Int) -> String {
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append(photos == 1 ? "1 photo" : "\(photos.formatted()) photos") }
        if videos > 0 { parts.append(videos == 1 ? "1 video" : "\(videos.formatted()) videos") }
        return parts.joined(separator: " · ")
    }

    static func allTitle(_ count: Int) -> String { "All · \(count.formatted())" }

    /// "Greece · 2–8 Jul 2023".
    static func tripTitle(_ trip: TripRow) -> String { "\(trip.label) · \(dayRange(trip.startDay, trip.endDay))" }

    static func dayRange(_ first: Int32, _ last: Int32) -> String {
        let a = LocalTime.civil(day: first), b = LocalTime.civil(day: last)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if a.year != b.year { return "\(a.day) \(months[a.month - 1]) \(a.year) – \(b.day) \(months[b.month - 1]) \(b.year)" }
        if a.month != b.month { return "\(a.day) \(months[a.month - 1]) – \(b.day) \(months[b.month - 1]) \(b.year)" }
        return "\(a.day)–\(b.day) \(months[b.month - 1]) \(b.year)"
    }

    /// Local wall time "17:20".
    static func time(_ wall: Int64) -> String {
        let minute = LocalTime.minuteOfDay(wallSeconds: wall)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
