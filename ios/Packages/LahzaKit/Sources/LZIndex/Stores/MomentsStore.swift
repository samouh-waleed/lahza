import Foundation
import LZGeo
import Observation

/// The Moments tab's data (search spec §7.2): every moment newest first in month sections, paged by
/// ``MomentKey`` 200 at a time, the moments per year for the year strip, and the trips. ``indexChanged()``
/// reloads as many moments as are shown, so the list keeps its place.
@MainActor @Observable public final class MomentsStore {
    public enum Mode: String, CaseIterable, Sendable, Hashable {
        case moments, trips
    }

    /// One local month of moments.
    public struct MonthSection: Sendable, Hashable, Identifiable {
        public var year: Int
        public var month: Int
        /// Every moment of the month, loaded or not.
        public var total: Int
        public var rows: [MomentRow]

        /// yyyymm.
        public var id: Int { year * 100 + month }
    }

    public struct YearCount: Sendable, Hashable, Identifiable {
        public var year: Int
        public var moments: Int

        public var id: Int { year }
    }

    public var mode: Mode = .moments
    public private(set) var sections: [MonthSection] = []
    public private(set) var years: [YearCount] = []
    public private(set) var trips: [TripRow] = []
    /// More moments than are loaded.
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    /// Nothing loaded yet since the index (re)opened.
    public private(set) var hasLoaded = false

    public static let pageSize = 200

    @ObservationIgnored private let index: IndexStore
    @ObservationIgnored private var rows: [MomentRow] = []
    @ObservationIgnored private var months: [Int: Int] = [:]
    @ObservationIgnored private var loadedVersion: Int64 = -1
    @ObservationIgnored private var loadedGeneration = -1

    public init(index: IndexStore) {
        self.index = index
    }

    /// Every moment loaded so far, newest first.
    public var moments: [MomentRow] { rows }

    /// Loads the first page, unless what is loaded is current.
    public func load() async {
        guard let reader = index.reader else { return clear() }
        guard reader.generation != loadedGeneration || index.version != loadedVersion else { return }
        await reload(limit: Self.pageSize)
    }

    /// The next page.
    public func loadMore() async {
        guard hasMore, !isLoading, let reader = index.reader, let last = rows.last else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await reader.moments(after: last.key, limit: Self.pageSize)
            rows += page
            hasMore = page.count == Self.pageSize
            rebuildSections()
        } catch {
            clear()
        }
    }

    /// The index changed: reloads as many moments as are loaded, so the list stays where it is. Nothing loads
    /// before the first ``load()``.
    public func indexChanged() async {
        guard index.reader != nil else { return clear() }
        guard hasLoaded else { return }
        await reload(limit: max(Self.pageSize, rows.count))
    }

    /// A trip's moments, oldest first (its day sections).
    public func moments(of trip: TripRow) async -> [MomentRow] {
        guard let reader = index.reader else { return [] }
        let rows = (try? await reader.moments(after: nil, limit: max(1, trip.momentCount * 2 + 50), filter: MomentFilter(tripID: trip.id))) ?? []
        return rows.reversed()
    }

    /// One moment and its items, or nil when it is gone.
    public func moment(_ key: MomentKey) async -> MomentDetailRows? {
        guard let reader = index.reader else { return nil }
        return try? await reader.moment(key)
    }

    /// The section the year strip scrolls to: the newest month of `year`.
    public func firstSection(of year: Int) -> MonthSection.ID? {
        sections.first { $0.year == year }?.id
    }

    private func reload(limit: Int) async {
        guard let reader = index.reader else { return clear() }
        let version = index.version
        isLoading = true
        defer { isLoading = false }
        do {
            async let page = reader.moments(after: nil, limit: limit)
            async let monthCounts = reader.momentMonths()
            async let tripRows = reader.trips()
            let (loaded, counts, loadedTrips) = try await (page, monthCounts, tripRows)
            rows = loaded
            hasMore = loaded.count == limit
            months = Dictionary(counts.map { ($0.id, $0.moments) }, uniquingKeysWith: +)
            years = Dictionary(grouping: counts, by: \.year).map { YearCount(year: $0.key, moments: $0.value.reduce(0) { $0 + $1.moments }) }
                .sorted { $0.year > $1.year }
            trips = loadedTrips
            loadedVersion = version
            loadedGeneration = reader.generation
            hasLoaded = true
            rebuildSections()
        } catch {
            clear()
        }
    }

    private func rebuildSections() {
        var sections: [MonthSection] = []
        for row in rows {
            let date = LocalTime.civil(day: row.key.day)
            let id = date.year * 100 + date.month
            if sections.last?.id == id {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(MonthSection(year: date.year, month: date.month, total: months[id] ?? 0, rows: [row]))
            }
        }
        self.sections = sections
    }

    /// The index is off or closed: nothing to show.
    private func clear() {
        rows = []
        sections = []
        years = []
        trips = []
        months = [:]
        hasMore = false
        hasLoaded = false
        loadedVersion = -1
        loadedGeneration = -1
    }
}
