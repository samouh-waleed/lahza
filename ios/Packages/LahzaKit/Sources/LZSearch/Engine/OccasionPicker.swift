import Foundation
import LZIndex

/// Picks "the first time" or "the last time" a search matched: the earliest or latest occasion of its Best matches
/// (its More matches when none is Best). An occasion is a whole trip when the query asks for trips or names a city,
/// region or country and the match is on a trip; otherwise the match's moment, or its day before moments are grouped.
/// Undated photos never count, and received photos and screenshots only when nothing else matched, so a photo saved
/// late at home doesn't beat a real outing.
struct OccasionPicker {
    let snapshot: SearchSnapshot
    let query: PreparedQuery

    enum Key: Hashable {
        case trip(Int32)
        case moment(Int32)
        /// A day whose photos aren't grouped into moments yet.
        case day(Int32)
    }

    /// One occasion: when its matches were taken (Unix seconds).
    struct Span {
        var key: Key
        var start: Int64
        var end: Int64

        var isTrip: Bool { if case .trip = key { true } else { false } }
    }

    struct Pick {
        var chosen: Span
        /// The occasions a search covers (all of them, or a free search's that end after its start), the chosen one
        /// included.
        var covered: Int
        /// Every covered occasion is a trip.
        var allTrips: Bool
        /// The chosen occasion is older than a free search covers: the first time began before its start, the last
        /// time ended before it.
        var isEarlier: Bool
    }

    /// The occasion `order` (first or last) asks for among `hits` (every hit, before a free search's scope), nil when no
    /// dated hit is Best or More. `since`: a free search's start.
    func pick(_ order: SearchOrder, hits: [ScoredAsset], since: Int64?) -> Pick? {
        let dated = hits.filter { $0.tier <= .more && snapshot.isDated(Int($0.index)) }
        let tier: Tier = dated.contains { $0.tier == .best } ? .best : .more
        let matches = dated.filter { $0.tier == tier }
        let camera = matches.filter { $0.junk >= 1 && !snapshot.has(.likelyReceived, Int($0.index)) }
        var spans: [Key: Span] = [:]
        for hit in camera.isEmpty ? matches : camera {
            let i = Int(hit.index), utc = snapshot.utc[i], key = key(i)
            if let span = spans[key] {
                spans[key] = Span(key: key, start: min(span.start, utc), end: max(span.end, utc))
            } else {
                spans[key] = Span(key: key, start: utc, end: utc)
            }
        }
        let all = Array(spans.values)
        let chosen = order == .last ? all.max { ($0.end, $0.start) < ($1.end, $1.start) } : all.min { ($0.start, $0.end) < ($1.start, $1.end) }
        guard let chosen else { return nil }
        let covered = all.filter { span in since.map { span.end >= $0 } ?? true }
        let isEarlier = since.map { (order == .last ? chosen.end : chosen.start) < $0 } ?? false
        return Pick(chosen: chosen, covered: covered.count, allTrips: covered.allSatisfy(\.isTrip), isEarlier: isEarlier)
    }

    /// Whether a hit (of any tier) belongs to the occasion: on the trip, in the moment (or saved the day of it), or
    /// on the day.
    func contains(_ hit: ScoredAsset, _ key: Key) -> Bool {
        let i = Int(hit.index)
        switch key {
        case .trip(let trip):
            return snapshot.trip[i] == trip
        case .moment(let moment):
            if case .receivedSameDay(let visit)? = hit.placeEvidence, visit == moment { return true }
            return snapshot.moment[i] == moment
        case .day(let day):
            return snapshot.moment[i] < 0 && snapshot.isDated(i) && snapshot.day[i] == day
        }
    }

    private func key(_ i: Int) -> Key {
        if byTrip, snapshot.trip[i] >= 0 { return .trip(snapshot.trip[i]) }
        if snapshot.moment[i] >= 0 { return .moment(snapshot.moment[i]) }
        return .day(snapshot.day[i])
    }

    /// Whole trips: the query asks for trips, or its place is a city, region or country (a park or a neighbourhood
    /// is visited, not travelled to).
    private var byTrip: Bool {
        if query.plan.event != nil { return true }
        guard let place = query.placeSlot?.candidate.resolved else { return false }
        return Self.isWide(place)
    }

    private static func isWide(_ place: ResolvedPlace) -> Bool {
        switch place {
        case .membership(let level, _, _, _): level != .locality
        case .anyOf(let parts): !parts.isEmpty && parts.allSatisfy(isWide)
        case .area, .categoryUnion: false
        }
    }
}
