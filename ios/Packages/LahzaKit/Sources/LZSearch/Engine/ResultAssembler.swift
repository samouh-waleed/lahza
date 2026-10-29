import Foundation
import LZGeo
import LZIndex

/// Groups scored hits into sections of moment cards, wraps trips under headers, and writes the reasons (search spec
/// §6.7): a card sits in the section of its best hit and is ordered newest first; undated hits go to a last "No date"
/// card; a card's reasons are the slot reasons most of its hits share.
struct ResultAssembler {
    let snapshot: SearchSnapshot
    let query: PreparedQuery
    let copy: SearchCopy
    let context: EngineContext

    struct Built {
        var sections: [ResultSection]
        var totals: Totals
        /// Best and More hits whose location is borrowed from the same outing.
        var borrowed: Int
    }

    /// How many hits a card's reason must hold to be shown on the card.
    static let sharedReasonShare = 0.5

    func assemble(_ hits: [ScoredAsset], reader: IndexReader) async throws -> Built {
        guard !hits.isEmpty else { return Built(sections: [], totals: Totals(moments: 0, photos: 0, videos: 0), borrowed: 0) }
        let momentIDs = Array(Set(hits.compactMap { hit -> Int64? in
            let moment = snapshot.moment[Int(hit.index)]
            return moment >= 0 ? Int64(moment) : nil
        }))
        async let momentRows = reader.momentRows(ids: momentIDs)
        async let localIDs = reader.localIdentifiers(for: hits.map { snapshot.id[Int($0.index)] })
        async let tripRows = reader.trips()
        let rows = Dictionary(try await momentRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let identifiers = try await localIDs
        let trips = Dictionary(try await tripRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Hits by card, in snapshot order (newest first): a moment, a day not yet grouped into moments, or no date.
        var order: [MomentKey] = []
        var byCard: [MomentKey: [ScoredAsset]] = [:]
        var cardMoment: [MomentKey: Int64] = [:]
        for hit in hits {
            let i = Int(hit.index)
            let key: MomentKey
            let moment = snapshot.moment[i]
            if moment >= 0, let row = rows[Int64(moment)] {
                key = row.key
                cardMoment[key] = row.id
            } else if snapshot.isDated(i), snapshot.day[i] >= 0 {
                key = MomentKey(day: snapshot.day[i], startUTC: Int64(snapshot.day[i]) * 86_400)
            } else {
                key = MomentCard.noDateKey
            }
            if byCard[key] == nil { order.append(key) }
            byCard[key, default: []].append(hit)
        }

        var cards: [MomentCard] = []
        var borrowed = 0
        for key in order {
            let members = byCard[key] ?? []
            let tier = members.map(\.tier).min() ?? .weaker
            let moment = cardMoment[key].flatMap { rows[$0] }
            var assetHits: [AssetHit] = []
            var cardBorrowed = 0
            var cells = Set<String>()
            for hit in members.reversed() {
                let i = Int(hit.index)
                let source = snapshot.source(i)
                if source == .momentNear || source == .momentFar {
                    cardBorrowed += 1
                    if hit.tier <= .more { borrowed += 1 }
                }
                if source == .gps, let position = snapshot.position(i) { cells.insert(GeoHash.encode(position, precision: 7)) }
                assetHits.append(assetHit(hit, localID: identifiers[snapshot.id[i]] ?? "", cardTier: tier, trips: trips))
            }
            let best = members.map(\.score).max() ?? 0
            cards.append(MomentCard(id: key, moment: moment, tier: tier, hits: assetHits, wholeCount: moment?.itemCount ?? members.count,
                                    photoCount: assetHits.count(where: { $0.kind == .photo }), videoCount: assetHits.count(where: { $0.kind == .video }),
                                    borrowedCount: cardBorrowed, reasons: cardReasons(assetHits, borrowed: cardBorrowed), cells: cells.sorted(),
                                    score: best + 0.05 * log(1 + Double(members.count)), tripID: moment?.tripID))
        }

        let groupTrips = shouldGroupTrips(cards, hits: hits)
        var sections: [ResultSection] = []
        for tier in Tier.allCases {
            let inTier = cards.filter { $0.tier == tier }.sorted(by: Self.newestFirst)
            guard !inTier.isEmpty else { continue }
            let count = hits.count(where: { $0.tier == tier })
            let (title, caption) = copy.sectionTitle(tier, place: query.placeSlot?.description, count: count)
            sections.append(ResultSection(tier: tier, title: title, caption: caption, groups: group(inTier, trips: groupTrips ? trips : [:])))
        }

        let shown = hits.filter { $0.tier <= .more }
        let shownCards = Set(cards.filter { card in card.hits.contains { $0.tier <= .more } }.map(\.id))
        let videos = shown.count(where: { snapshot.isVideo(Int($0.index)) })
        return Built(sections: sections, totals: Totals(moments: shownCards.count, photos: shown.count - videos, videos: videos), borrowed: borrowed)
    }

    /// Newest first; the "No date" card last.
    static func newestFirst(_ lhs: MomentCard, _ rhs: MomentCard) -> Bool {
        if (lhs.id == MomentCard.noDateKey) != (rhs.id == MomentCard.noDateKey) { return rhs.id == MomentCard.noDateKey }
        return (lhs.id.startUTC, lhs.id.day) > (rhs.id.startUTC, rhs.id.day)
    }

    // MARK: Trips

    /// Trips get headers when the query asks for trips, when the place is a country, region or city outside the
    /// home country, or when two Best cards share a trip.
    private func shouldGroupTrips(_ cards: [MomentCard], hits: [ScoredAsset]) -> Bool {
        if query.plan.event != nil { return true }
        if let place = query.placeSlot, case .membership(let level, _, let key, _) = place.candidate.resolved, level != .locality {
            if level == .country, let code = context.home?.countryCode, key != PlaceKey.country(code) { return true }
            if let home = context.homeCountryPlace, let first = hits.first(where: { $0.tier == .best }) {
                let country = snapshot.country[Int(first.index)]
                if country >= 0, country != home { return true }
            }
        }
        var bestPerTrip: [Int64: Int] = [:]
        for card in cards where card.tier == .best {
            if let trip = card.tripID { bestPerTrip[trip, default: 0] += 1 }
        }
        return bestPerTrip.values.contains { $0 >= 2 }
    }

    /// Cards in order, those of one trip gathered under its header where its newest card is.
    private func group(_ cards: [MomentCard], trips: [Int64: TripRow]) -> [ResultGroup] {
        guard !trips.isEmpty else { return cards.map(ResultGroup.moment) }
        var groups: [ResultGroup] = []
        var tripPosition: [Int64: Int] = [:]
        for card in cards {
            guard let id = card.tripID, let trip = trips[id] else {
                groups.append(.moment(card))
                continue
            }
            if let position = tripPosition[id], case .trip(var group) = groups[position] {
                group.cards.append(card)
                groups[position] = .trip(group)
            } else {
                tripPosition[id] = groups.count
                let title = "\(trip.label) · \(LocalDateFormat.dayRange(trip.startDay, trip.endDay, locale: copy.locale))"
                groups.append(.trip(TripGroup(trip: trip, title: title, cards: [card])))
            }
        }
        return groups
    }

    // MARK: Hits and reasons

    private func assetHit(_ hit: ScoredAsset, localID: String, cardTier: Tier, trips: [Int64: TripRow]) -> AssetHit {
        let i = Int(hit.index)
        var scores: [SlotKind: Double] = [:]
        if let place = hit.place { scores[.place] = place.value }
        if let time = hit.time { scores[.time] = time.value }
        if let event = hit.event { scores[.event] = event.value }
        return AssetHit(id: snapshot.id[i], localID: localID, kind: snapshot.isVideo(i) ? .video : .photo, duration: Double(snapshot.duration[i]),
                        utc: snapshot.isDated(i) ? snapshot.utc[i] : nil, wall: snapshot.isDated(i) ? snapshot.wall[i] : nil, tier: hit.tier,
                        score: hit.score, slotScores: scores, reasons: reasons(hit, trips: trips), isNearby: hit.tier > cardTier && hit.tier == .more)
    }

    /// The hit's reasons: place, borrowed location, time, trip, photo type.
    func reasons(_ hit: ScoredAsset, trips: [Int64: TripRow]) -> [Reason] {
        let i = Int(hit.index)
        var reasons: [Reason] = []
        if let evidence = hit.placeEvidence, let place = query.placeSlot?.description,
           let reason = copy.placeReason(evidence, place: place, trips: trips) {
            reasons.append(reason)
            if let borrowed = copy.borrowedReason(snapshot.source(i)) { reasons.append(borrowed) }
        }
        if let evidence = hit.timeEvidence, let reason = copy.timeReason(evidence, expression: query.timeExpression) { reasons.append(reason) }
        if query.plan.event != nil, snapshot.trip[i] >= 0, let trip = trips[Int64(snapshot.trip[i])] { reasons.append(SearchCopy.tripReason(trip)) }
        if let media = query.plan.media {
            if media.kinds == [.video], snapshot.isVideo(i) { reasons.append(SearchCopy.videoReason(duration: Double(snapshot.duration[i]))) }
            if media.flags.contains(.selfie) { reasons.append(SearchCopy.selfieReason) }
            if media.flags.contains(.favorite) { reasons.append(SearchCopy.favoriteReason) }
        }
        if hit.junk < 1 { reasons.append(SearchCopy.screenshotReason) }
        return reasons
    }

    /// Up to two slot reasons at least half the hits share (most shared first, then in the hits' own order: place,
    /// time, trip, photo type), then the borrowed-location line.
    private func cardReasons(_ hits: [AssetHit], borrowed: Int) -> [Reason] {
        var counts: [Reason: Int] = [:]
        var first: [Reason: (hit: Int, index: Int)] = [:]
        for (position, hit) in hits.enumerated() {
            // Borrowed locations get their own line below.
            var seen: Set<Reason> = []
            for (index, reason) in hit.reasons.enumerated() where reason.kind != .neutral && reason.systemImage != "link" {
                guard seen.insert(reason).inserted else { continue }
                counts[reason, default: 0] += 1
                if first[reason] == nil { first[reason] = (position, index) }
            }
        }
        let needed = Double(hits.count) * Self.sharedReasonShare
        var reasons = counts.filter { Double($0.value) >= needed }.keys
            .sorted { (-counts[$0]!, first[$0]!.hit, first[$0]!.index) < (-counts[$1]!, first[$1]!.hit, first[$1]!.index) }
            .prefix(2).map { $0 }
        if borrowed > 0 { reasons.append(SearchCopy.borrowedCardReason(borrowed)) }
        return reasons
    }

    // MARK: Coverage

    func coverage(searched: Int, index: SearchIndexContext, unreliable: Int, borrowed: Int) -> Coverage {
        var notes: [String] = []
        if borrowed > 0 { notes.append("+\(borrowed.formatted(.number.locale(copy.locale))) without location from the same outing") }
        if query.plan.time != nil, unreliable > 0 {
            notes.append(unreliable == 1 ? "1 photo has no reliable date" : "\(copy.photosCount(unreliable)) have no reliable date")
        }
        var share: Double?
        if query.plan.place != nil, query.plan.time == nil, query.plan.event == nil, snapshot.count > 0, !snapshot.unlocated.isEmpty {
            let value = Double(snapshot.unlocated.count) / Double(snapshot.count)
            share = value
            notes.append("\(value.formatted(.percent.precision(.fractionLength(0)).locale(copy.locale))) of your photos have no location")
        }
        var header: String?
        if index.isPartial, let since = index.coveredSince { header = copy.partialHeader(since: since, zone: context.zone) }
        return Coverage(searched: searched, libraryTotal: index.libraryTotal, isPartial: index.isPartial, coveredSince: index.coveredSince,
                        isLimited: index.isLimited, unlocatedShare: share, undatedExcluded: query.plan.time == nil ? 0 : unreliable,
                        borrowedShown: borrowed, caption: copy.coverageCaption(searched: searched, index: index), header: header, notes: notes)
    }
}
