import Foundation
import LZGeo
import LZIndex
import LZLibrary

/// How well one asset matches a slot (0.05…1), and why. An unknown slot (no position, no reliable date) scores 0.5
/// and keeps the asset out of Best and More (search spec S12).
struct SlotScore: Sendable, Hashable {
    var value: Double
    var isUnknown = false

    static let unknown = SlotScore(value: 0.5, isUnknown: true)
}

/// Why a place slot scored what it did.
enum PlaceEvidence: Sendable, Hashable {
    /// Inside an area (or a member of a place); `metro` when only the city's metro holds it.
    case inside(metro: Bool)
    /// Outside an area, `metres` from its centre.
    case near(metres: Double)
    /// Located, but not in the place.
    case outside
    /// No position: saved the day of a visit to the place (moment id).
    case receivedSameDay(Int32)
    /// No position: during a trip whose country or city is the place (trip id).
    case tripBorrow(Int32)
    case unknown
}

/// Why a time slot scored what it did.
enum TimeEvidence: Sendable, Hashable {
    case inside
    /// Outside the dates: `days` moment days before (negative) or after (positive) them.
    case nearMiss(days: Int)
    /// Outside a part of the day by `minutes` (negative before, positive after).
    case minutesOff(Int)
    case wrongWeekday
    /// Outside the recurring months by `days`.
    case monthsOff(Int)
    case outside
    case unreliable
}

/// The result tiers (search spec §6.5), best first.
public enum Tier: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    /// Inside every slot.
    case best
    /// Close to the place or the dates, or saved the same day.
    case more
    /// No position, but every other slot matches exactly (shown collapsed).
    case locationUnknown
    /// Behind "Show weaker".
    case weaker

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One asset that made a tier, with its slot scores and evidence.
struct ScoredAsset: Sendable {
    var index: Int32
    var tier: Tier
    var score: Double
    var junk: Double
    var place: SlotScore?
    var placeEvidence: PlaceEvidence?
    var time: SlotScore?
    var timeEvidence: TimeEvidence?
    var event: SlotScore?
}

/// A resolved place flattened for scoring: areas and membership places (a photo scores by its best one).
struct PlaceTarget: Sendable {
    struct Area: Sendable {
        var center: Coordinate
        var radius: Double
    }

    struct Member: Sendable {
        var level: MembershipLevel
        /// −1 when no photo is in the place (a gazetteer place).
        var id: Int32
    }

    var areas: [Area] = []
    var members: [Member] = []

    init(_ place: ResolvedPlace) {
        add(place)
    }

    private mutating func add(_ place: ResolvedPlace) {
        switch place {
        case .area(let center, let radius, _, _):
            areas.append(Area(center: center, radius: radius))
        case .membership(let level, let id, _, _):
            members.append(Member(level: level, id: id.flatMap { $0 >= 0 && $0 <= Int64(Int32.max) ? Int32($0) : nil } ?? -1))
        case .categoryUnion(let parts), .anyOf(let parts):
            for part in parts { add(part) }
        }
    }

    /// The farthest a located photo can be from an area's centre and still score above 0.1.
    func reach(_ area: Area) -> Double { 2.6 * area.radius + 100 }
}

/// What a query scores: its resolved slots (search spec §6.5). Media is a hard filter; place, time and event are
/// fused with equal weights, unknown slots included at 0.5.
struct ScoringPlan: Sendable {
    var place: PlaceTarget?
    var time: TimeConstraint?
    var event: EventKind?
    var media: MediaFilter?

    var scoredSlots: Int { (place == nil ? 0 : 1) + (time == nil ? 0 : 1) + (event == nil ? 0 : 1) }

    /// No slot to score or filter by: nothing to list.
    var isEmpty: Bool { scoredSlots == 0 && media == nil }
}

/// Scores and tiers every asset of a snapshot for a plan, in one pass (search spec §6.5).
struct Scorer {
    let snapshot: SearchSnapshot
    let plan: ScoringPlan
    private let ranges: [Range<Int64>]?
    private var sameDayVisits: [Int32: Int32?] = [:]

    static let junkFactor = 0.5
    static let floor = 0.02

    init(snapshot: SearchSnapshot, plan: ScoringPlan) {
        self.snapshot = snapshot
        self.plan = plan
        ranges = plan.time?.ranges.map { $0.sorted { $0.lowerBound < $1.lowerBound } }
    }

    // MARK: The pass

    /// Every asset that makes a tier (Weaker included), in snapshot order (newest first), and how many assets the
    /// media filter keeps that have no reliable date (left out of a time query, counted in the coverage line).
    mutating func run() -> (hits: [ScoredAsset], unreliableDates: Int) {
        var hits: [ScoredAsset] = []
        for index in candidates() {
            let i = Int(index)
            guard passesMedia(i), let hit = score(i) else { continue }
            hits.append(hit)
        }
        var unreliable = 0
        if plan.time != nil {
            for i in 0..<snapshot.count where (!snapshot.isDated(i) || snapshot.has(.dateUnreliable, i)) && passesMedia(i) { unreliable += 1 }
        }
        return (hits, unreliable)
    }

    /// The assets that can score: for area-only places, the located ones within reach and every unlocated one;
    /// otherwise all.
    private func candidates() -> [Int32] {
        guard let place = plan.place, place.members.isEmpty, !place.areas.isEmpty else { return Array(0..<Int32(snapshot.count)) }
        var seen = [Bool](repeating: false, count: snapshot.count)
        var found: [Int32] = []
        for area in place.areas {
            for index in snapshot.grid.candidates(near: area.center, within: place.reach(area), in: snapshot) where !seen[Int(index)] {
                seen[Int(index)] = true
                found.append(index)
            }
        }
        for index in snapshot.unlocated where !seen[Int(index)] {
            seen[Int(index)] = true
            found.append(index)
        }
        return found.sorted()
    }

    /// Kinds combine with OR, flags with AND.
    func passesMedia(_ i: Int) -> Bool {
        guard let media = plan.media else { return true }
        if !media.kinds.isEmpty {
            let kind: MediaKind = snapshot.isVideo(i) ? .video : .photo
            guard media.kinds.contains(kind) else { return false }
        }
        for flag in media.flags where !has(flag, i) { return false }
        return true
    }

    func has(_ flag: MediaFlag, _ i: Int) -> Bool {
        switch flag {
        case .screenshot: snapshot.has(.screenshot, i)
        case .screenRecording: snapshot.has(.screenRecording, i)
        case .selfie: snapshot.has(.selfie, i)
        case .favorite: snapshot.has(.favorite, i)
        case .livePhoto: snapshot.has(.livePhoto, i)
        case .portrait: snapshot.has(.depthEffect, i)
        case .panorama: snapshot.has(.panorama, i)
        case .sloMo: snapshot.has(.sloMo, i)
        case .timeLapse: snapshot.has(.timeLapse, i)
        case .burst: snapshot.has(.burstMember, i)
        }
    }

    // MARK: One asset

    /// The asset's slot scores and tier; nil when it makes no tier.
    mutating func score(_ i: Int) -> ScoredAsset? {
        let junk = snapshot.isScreenCapture(i) && plan.media?.asksForScreenCaptures != true ? Self.junkFactor : 1
        var asset = ScoredAsset(index: Int32(i), tier: .weaker, score: 0, junk: junk)
        var scores: [SlotScore] = []
        if let place = plan.place {
            let (score, evidence) = placeScore(i, place)
            asset.place = score
            asset.placeEvidence = evidence
            scores.append(score)
        }
        if let time = plan.time {
            let (score, evidence) = timeScore(i, time)
            asset.time = score
            asset.timeEvidence = evidence
            scores.append(score)
        }
        if let event = plan.event {
            let score = eventScore(i, event)
            asset.event = score
            scores.append(score)
        }
        asset.score = scores.isEmpty ? junk : junk * exp(scores.reduce(0) { $0 + log(max($1.value, Self.floor)) } / Double(scores.count))
        guard let tier = Self.tier(asset, scores: scores) else { return nil }
        asset.tier = tier
        return asset
    }

    /// The tier rules of search spec §6.5; nil when excluded.
    static func tier(_ asset: ScoredAsset, scores: [SlotScore]) -> Tier? {
        let anyUnknown = scores.contains(where: \.isUnknown)
        let anyLow = scores.contains { !$0.isUnknown && $0.value <= 0.1 }
        if !anyUnknown {
            let placeOK = asset.place.map { $0.value >= 0.85 } ?? true
            let timeOK = asset.time.map { $0.value >= 1 } ?? true
            let eventOK = asset.event.map { $0.value >= 1 } ?? true
            if placeOK, timeOK, eventOK, asset.junk >= 1 { return .best }
            if asset.score >= 0.5, !anyLow { return .more }
            if asset.score >= 0.35, !anyLow { return .weaker }
            return nil
        }
        // Location unknown: only the place is unknown, another slot is scored, and every other slot matches exactly.
        guard asset.place?.isUnknown == true, asset.junk >= 1, scores.count >= 2 else { return nil }
        let others = [asset.time, asset.event].compactMap { $0 }
        return others.allSatisfy({ !$0.isUnknown && $0.value >= 1 }) ? .locationUnknown : nil
    }

    // MARK: Place

    mutating func placeScore(_ i: Int, _ place: PlaceTarget) -> (SlotScore, PlaceEvidence) {
        let source = snapshot.source(i)
        if let position = snapshot.position(i) {
            let accuracy = source == .gps ? Double(snapshot.hAcc[i]) : -1
            var (value, evidence) = positionScore(i, position, accuracy: accuracy, place)
            switch source {
            case .momentNear: value *= 0.9
            case .momentFar: value *= 0.6
            case .gps, .none: break
            }
            return (SlotScore(value: value), evidence)
        }
        // No position: saved the day of a visit, during a trip to the place, or unknown.
        if snapshot.has(.likelyReceived, i), let visit = sameDayVisit(snapshot.day[i], place) { return (SlotScore(value: 0.6), .receivedSameDay(visit)) }
        let trip = snapshot.trip[i]
        if trip >= 0, let info = snapshot.trips[trip], !place.members.isEmpty {
            let matches = place.members.contains { member in
                member.id >= 0 && (member.level == .country ? info.countryPlace == member.id : member.level == .city && info.labelPlace == member.id)
            }
            if matches { return (SlotScore(value: 0.75), .tripBorrow(trip)) }
        }
        return (.unknown, .unknown)
    }

    /// The best score over the place's areas and membership places for an asset at `position`.
    private func positionScore(_ i: Int, _ position: Coordinate, accuracy: Double, _ place: PlaceTarget) -> (Double, PlaceEvidence) {
        var best: (Double, PlaceEvidence) = (0.05, .outside)
        for area in place.areas {
            let distance = position.distance(to: area.center)
            let value = Self.areaScore(distance: distance, radius: area.radius, accuracy: accuracy)
            if value > best.0 || (value == best.0 && best.1 == .outside) {
                best = (value, value >= 1 ? .inside(metro: false) : .near(metres: distance))
            }
        }
        for member in place.members where member.id >= 0 {
            let value: Double
            switch member.level {
            case .city: value = snapshot.city[i] == member.id ? 1 : snapshot.metro[i] == member.id ? 0.9 : 0.05
            case .locality: value = snapshot.locality[i] == member.id ? 1 : 0.05
            case .region: value = snapshot.region[i] == member.id ? 1 : 0.05
            case .country: value = snapshot.country[i] == member.id ? 1 : 0.05
            }
            if value > best.0 { best = (value, .inside(metro: value < 1)) }
        }
        return best
    }

    /// 1 inside the radius (after taking off the GPS accuracy), then fading: 1.5r → 0.78, 2r → 0.37, floor 0.05.
    static func areaScore(distance: Double, radius: Double, accuracy: Double) -> Double {
        let adjusted = accuracy >= 0 ? max(0, distance - min(accuracy, radius)) : distance
        guard adjusted > radius else { return 1 }
        let excess = (adjusted - radius) / radius
        return max(0.05, exp(-excess * excess))
    }

    /// A moment of `day` with a located item whose centre (area) or places (membership) score at least 0.85.
    private mutating func sameDayVisit(_ day: Int32, _ place: PlaceTarget) -> Int32? {
        guard day >= 0 else { return nil }
        if let cached = sameDayVisits[day] { return cached }
        var found: Int32?
        for momentID in snapshot.dayLocatedMoments[day] ?? [] {
            guard let moment = snapshot.moments[momentID] else { continue }
            var value = 0.0
            if let centroid = moment.centroid {
                for area in place.areas { value = max(value, Self.areaScore(distance: centroid.distance(to: area.center), radius: area.radius, accuracy: -1)) }
            }
            if !place.members.isEmpty, moment.representative >= 0, let position = snapshot.position(Int(moment.representative)) {
                value = max(value, positionScore(Int(moment.representative), position, accuracy: -1, PlaceTarget(members: place.members)).0)
            }
            if value >= 0.85 {
                found = momentID
                break
            }
        }
        sameDayVisits[day] = found
        return found
    }

    // MARK: Time

    func timeScore(_ i: Int, _ time: TimeConstraint) -> (SlotScore, TimeEvidence) {
        guard snapshot.isDated(i), !snapshot.has(.dateUnreliable, i) else { return (.unknown, .unreliable) }
        let wall = snapshot.wall[i]
        let day = snapshot.day[i] >= 0 ? snapshot.day[i] : LocalTime.momentDay(wallSeconds: wall)
        var value = 1.0
        var evidence = TimeEvidence.inside
        if let ranges, let miss = Self.distance(wall, outside: ranges) {
            value *= max(0.05, exp(-Double(miss.distance) / Double(max(time.tau, 1))))
            if let edge = miss.edge {
                let edgeDay = miss.after ? LocalTime.momentDay(wallSeconds: edge - 1) : Self.firstDay(of: edge)
                evidence = .nearMiss(days: Int(day - edgeDay))
            } else {
                evidence = .outside
            }
        }
        if let weekdays = time.weekdays, !weekdays.contains(LocalTime.weekday(day: day)) {
            value *= 0.05
            evidence = .wrongWeekday
        }
        if let windows = time.minuteWindows {
            let minute = LocalTime.minuteOfDay(wallSeconds: wall)
            if !windows.contains(where: { $0.contains(minute: minute) }) {
                let off = windows.map { Self.signedMinutes(minute, $0) }.min { abs($0) < abs($1) } ?? 0
                value *= max(0.05, exp(-Double(abs(off)) / Double(TimeConstraint.minuteTau)))
                if evidence == .inside { evidence = .minutesOff(off) }
            }
        }
        if let rule = time.months {
            let latitude = snapshot.isLocated(i) ? Double(snapshot.lat[i]) : nil
            let months = rule.months(latitude: latitude)
            let date = LocalTime.civil(day: day)
            if !months.contains(date.month) {
                let off = Self.daysOff(date, months: months)
                value *= max(0.05, exp(-Double(abs(off)) / 3))
                if evidence == .inside { evidence = .monthsOff(off) }
            }
        }
        return (SlotScore(value: value), evidence)
    }

    /// The distance from `wall` to the nearest range, whether it lies after that range, and the range's edge it is
    /// nearest (nil when there is no range at all); nil inside one.
    static func distance(_ wall: Int64, outside ranges: [Range<Int64>]) -> (distance: Int64, after: Bool, edge: Int64?)? {
        guard !ranges.isEmpty else { return (Int64.max / 4, false, nil) }
        var best: (distance: Int64, after: Bool, edge: Int64?)?
        for range in ranges {
            if range.contains(wall) { return nil }
            let candidate: (distance: Int64, after: Bool, edge: Int64?) = wall < range.lowerBound
                ? (range.lowerBound - wall, false, range.lowerBound) : (wall - range.upperBound + 1, true, range.upperBound)
            if best.map({ candidate.distance < $0.distance }) ?? true { best = candidate }
        }
        return best
    }

    /// The day a range starting at `start` is named for: its own day, or the next one for an event that starts at
    /// 18:00 on the eve (Hijri events).
    static func firstDay(of start: Int64) -> Int32 {
        LocalTime.momentDay(wallSeconds: start + 12 * 3_600)
    }

    /// Minutes from `minute` to a window, negative before it and positive after it (around the clock).
    static func signedMinutes(_ minute: Int, _ window: MinuteWindow) -> Int {
        func around(_ from: Int, _ to: Int) -> Int {
            let d = ((to - from) % 1_440 + 1_440) % 1_440
            return d > 720 ? d - 1_440 : d
        }
        let toStart = around(minute, window.start), sinceEnd = around(window.end, minute)
        return abs(toStart) <= abs(sinceEnd) ? -abs(toStart) : abs(sinceEnd) + 1
    }

    /// Days from `date` to the nearest allowed month: negative when the month ahead is nearer (the photo is before
    /// it), positive when the month behind is. Only the neighbouring months count; farther is 99.
    static func daysOff(_ date: (year: Int, month: Int, day: Int), months: Set<Int>) -> Int {
        let length = TimeResolver.daysInMonth(year: date.year, month: date.month)
        let previous = date.month == 1 ? 12 : date.month - 1, next = date.month == 12 ? 1 : date.month + 1
        let back = months.contains(previous) ? date.day : 99
        let ahead = months.contains(next) ? length - date.day + 1 : 99
        return back <= ahead ? back : -ahead
    }

    // MARK: Event

    func eventScore(_ i: Int, _ event: EventKind) -> SlotScore {
        let trip = snapshot.trip[i]
        guard trip >= 0 else { return SlotScore(value: 0.05) }
        switch event {
        case .trip: return SlotScore(value: 1)
        case .abroad: return SlotScore(value: snapshot.trips[trip]?.abroad == true ? 1 : 0.05)
        }
    }
}

extension PlaceTarget {
    init(members: [Member]) {
        self.members = members
    }
}
