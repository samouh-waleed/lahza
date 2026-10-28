import LZDesign
import LZIndex
import LZLibrary
import SwiftUI

/// Moments: the library by date, as moments in month sections or as trips, with a year strip that jumps to a
/// year. Pages of 200 load as the list scrolls; an index change reloads what is shown, keeping the place.
struct MomentsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.moments
        Group {
            switch MomentsScreenState(access: model.photoAccess.access, status: model.index.status, store: store) {
            case .noAccess:
                ScrollView {
                    VStack(alignment: .leading, spacing: LZSpace.xl) {
                        Text(MomentCopy.intro).lzText(.body).foregroundStyle(.lz(.muted))
                        LibraryStatusCard()
                    }
                    .lzPage()
                    .padding(.vertical, LZSpace.lg)
                }
            case .reading:
                ScrollView { MomentsSkeleton().lzPage().padding(.vertical, LZSpace.lg) }
            case .deleted:
                EmptyState(MomentCopy.deletedTitle, message: MomentCopy.deletedBody, systemImage: "rectangle.stack",
                           actionTitle: MomentCopy.buildIndex) { model.index.buildAgain() }
                    .lzPage()
                    .frame(maxHeight: .infinity)
            case .unavailable(let message):
                EmptyState(message, message: IndexCopy.unavailableDetail, systemImage: "exclamationmark.triangle", tone: .neutral)
                    .lzPage()
                    .frame(maxHeight: .infinity)
            case .empty:
                EmptyState(MomentCopy.emptyTitle, message: MomentCopy.emptyBody, systemImage: "rectangle.stack")
                    .lzPage()
                    .frame(maxHeight: .infinity)
            case .list(let stillReading):
                MomentsList(stillReading: stillReading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.lz(.bg))
        .navigationTitle(MomentCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("moments")
        .task(id: model.index.reader?.generation) { await store.load() }
    }
}

/// What the Moments tab shows for the photo access and the index status.
nonisolated enum MomentsScreenState: Equatable {
    case noAccess
    /// The first build hasn't produced a moment yet.
    case reading
    case deleted
    case unavailable(String)
    /// Built, and the library has no moments.
    case empty
    case list(stillReading: Bool)

    @MainActor init(access: PhotoAccess, status: IndexStatus, store: MomentsStore) {
        self.init(access: access, status: status, hasMoments: !store.sections.isEmpty || !store.trips.isEmpty, hasLoaded: store.hasLoaded)
    }

    init(access: PhotoAccess, status: IndexStatus, hasMoments: Bool, hasLoaded: Bool) {
        switch status.phase {
        case .off(.deletedByUser):
            self = .deleted
        case .off(.protectedDataUnavailable):
            self = .unavailable(IndexCopy.headline(status))
        case .off(.noAccess):
            self = .noAccess
        case _ where !access.canRead:
            self = .noAccess
        case .failed(let message):
            self = hasMoments ? .list(stillReading: false) : .unavailable(message)
        case .preparing, .reading, .organizing:
            self = hasMoments ? .list(stillReading: status.isPartial) : .reading
        case .ready, .paused:
            if hasMoments { self = .list(stillReading: status.isPartial) } else { self = hasLoaded ? .empty : .reading }
        }
    }
}

/// The segmented control, the year strip and the moments or trips.
private struct MomentsList: View {
    let stillReading: Bool
    @Environment(AppModel.self) private var model
    @State private var selectedYear: Int?

    var body: some View {
        let store = model.moments
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    header(store: store, proxy: proxy)
                    switch store.mode {
                    case .moments: moments(store)
                    case .trips: trips(store)
                    }
                }
                .lzPage()
                .padding(.bottom, LZSpace.xl)
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: Header

    private func header(store: MomentsStore, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            Text(MomentCopy.intro).lzText(.body).foregroundStyle(.lz(.muted))
            LZSegmented(MomentCopy.modeLabel,
                        options: [LZChipOption(MomentsStore.Mode.moments, title: MomentCopy.momentsMode),
                                  LZChipOption(MomentsStore.Mode.trips, title: MomentCopy.tripsMode)],
                        selection: Binding(get: { store.mode }, set: { store.mode = $0 }))
                .accessibilityIdentifier("moments-mode")
            if store.mode == .moments, store.years.count > 1 {
                yearStrip(store: store, proxy: proxy)
            }
            if stillReading {
                Label(MomentCopy.stillReading, systemImage: "photo.stack")
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
            }
        }
        .padding(.top, LZSpace.lg)
        .padding(.bottom, LZSpace.sm)
    }

    private func yearStrip(store: MomentsStore, proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: LZSpace.sm) {
                ForEach(store.years) { year in
                    Button {
                        jump(to: year.year, store: store, proxy: proxy)
                    } label: {
                        Pill(MomentCopy.yearPill(year: year.year, moments: year.moments), tone: selectedYear == year.year ? .accent : .neutral)
                            .lzHitTarget()
                    }
                    .buttonStyle(LZPressStyle())
                    .accessibilityLabel(MomentCopy.spokenYear(year: year.year, moments: year.moments))
                    .accessibilityAddTraits(selectedYear == year.year ? .isSelected : [])
                    .accessibilityIdentifier("moments-year-\(year.year)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MomentCopy.yearsLabel)
    }

    private func jump(to year: Int, store: MomentsStore, proxy: ScrollViewProxy) {
        selectedYear = year
        Task {
            guard let section = await store.loadThrough(year: year) else { return }
            withAnimation(.snappy) { proxy.scrollTo(section, anchor: .top) }
        }
    }

    // MARK: Moments

    @ViewBuilder private func moments(_ store: MomentsStore) -> some View {
        let trips = Dictionary(store.trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ForEach(store.sections) { section in
            Section {
                ForEach(section.rows) { moment in
                    MomentListRow(moment: moment, trip: moment.tripID.flatMap { trips[$0] }) {
                        model.open(.moment(MomentRef(key: moment.key, origin: .moments)))
                    }
                    .onAppear { prioritize(moment) }
                }
            } header: {
                MonthHeader(section: section)
            }
            .id(section.id)
        }
        if store.hasMore {
            MomentsSkeleton(rows: 2)
                .padding(.top, LZSpace.sm)
                .task(id: store.moments.count) { await store.loadMore() }
        }
    }

    /// Apple Maps names the places of rows on screen first.
    private func prioritize(_ moment: MomentRow) {
        guard let cell = moment.cell else { return }
        model.index.prioritizePlaceNames(cells: [cell])
    }

    // MARK: Trips

    @ViewBuilder private func trips(_ store: MomentsStore) -> some View {
        if store.trips.isEmpty {
            EmptyState(MomentCopy.noTripsTitle, message: MomentCopy.noTripsBody, systemImage: "airplane")
        } else {
            VStack(spacing: LZSpace.lg) {
                ForEach(store.trips) { trip in
                    TripCard(trip: trip) { model.open(.trip(TripRef(startDay: trip.startDay, origin: .moments))) }
                }
            }
            .padding(.top, LZSpace.sm)
        }
    }
}

/// A pinned month heading: "August 2026 · 3 moments".
private struct MonthHeader: View {
    let section: MomentsStore.MonthSection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LZSpace.sm) {
            Text(MomentCopy.monthTitle(year: section.year, month: section.month))
                .lzText(.headline)
                .foregroundStyle(.lz(.ink))
            Text(MomentCopy.count(section.total, "moment"))
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LZSpace.lg)
        .padding(.bottom, LZSpace.xs)
        .background(.lz(.bg))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(MomentCopy.monthHeader(year: section.year, month: section.month, moments: section.total))
    }
}

/// Placeholder rows while the first moments are read.
struct MomentsSkeleton: View {
    var rows = 4
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            if rows > 2, showsCaption {
                Label(MomentCopy.readingTitle, systemImage: "photo.stack")
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.muted))
            }
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: LZSpace.md) {
                    SkeletonText(lines: 2, role: .subheadline)
                    HStack(spacing: MomentListRow.thumbnailSpacing) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBlock(radius: LZRadius.xs).frame(width: MomentListRow.thumbnailSide, height: MomentListRow.thumbnailSide)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MomentCopy.readingTitle)
    }
}
