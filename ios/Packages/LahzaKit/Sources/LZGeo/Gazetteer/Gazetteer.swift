import Foundation
import Synchronization

/// A GeoNames place (population 15,000 and up, or a capital or section of a city).
public struct GazetteerCity: Sendable, Hashable, Identifiable {
    public enum Kind: UInt8, Sendable, Hashable, Codable {
        /// A populated place.
        case city = 0
        /// The seat of a region (GeoNames PPLA…PPLA5).
        case seat = 1
        /// A country's capital (PPLC).
        case capital = 2
        /// A section of a city (PPLX), such as Dubai Marina: a locality, never a city label.
        case section = 3
    }

    public var geonameID: Int32
    public var name: String
    /// The ASCII form when it folds differently from ``name``, then English aliases.
    public var alternateNames: [String]
    public var coordinate: Coordinate
    public var population: Int
    public var kind: Kind
    /// ISO 3166 alpha-2.
    public var countryCode: String
    /// Nil when GeoNames gives the place no first-level region.
    public var admin1: GazetteerAdmin1?
    /// IANA zone identifier.
    public var timeZone: String

    public var id: Int32 { geonameID }
}

/// A first-level region (a Saudi region, a US state). Region names ("Riyadh Region", "Eastern
/// Province") are for matching typed names, never for labels.
public struct GazetteerAdmin1: Sendable, Hashable, Identifiable {
    public var geonameID: Int32
    public var name: String
    public var countryCode: String

    public var id: Int32 { geonameID }
}

/// What the gazetteer says about a position.
public struct GeoPlacement: Sendable, Hashable {
    /// The label city: the nearest by distance relative to its reach (see ``Gazetteer/locate(_:)``).
    public var city: GazetteerCity?
    /// The most populous city whose reach covers the position (usually ``city``; San Francisco for Oakland).
    public var metro: GazetteerCity?
    /// The nearest place within 5 km other than the city, sections included ("Dubai Marina").
    public var locality: GazetteerCity?
    /// The city's region, else the nearest place's if it is within 50 km.
    public var admin1: GazetteerAdmin1?
    /// The city's country, else the nearest place's if it is within 150 km.
    public var countryCode: String?
    /// The nearest place is within 50 km, or the 3 nearest are all within 150 km and share the country.
    public var countryConfident: Bool
    /// The nearest place's zone if it is within 1,000 km. Callers fall back to
    /// ``LocalTime/etcZoneIdentifier(longitude:)``.
    public var timeZone: String?
    /// Kilometres to the nearest place; infinity for an invalid position.
    public var nearestKm: Double

    public init(city: GazetteerCity? = nil, metro: GazetteerCity? = nil, locality: GazetteerCity? = nil, admin1: GazetteerAdmin1? = nil,
                countryCode: String? = nil, countryConfident: Bool = false, timeZone: String? = nil, nearestKm: Double = .infinity) {
        self.city = city
        self.metro = metro
        self.locality = locality
        self.admin1 = admin1
        self.countryCode = countryCode
        self.countryConfident = countryConfident
        self.timeZone = timeZone
        self.nearestKm = nearestKm
    }
}

/// The offline place list: city, region, country and time zone for a position, and place names for
/// the query parser. Reads the `LZGZ` file (``GazetteerFormat``) in place; no network.
public final class Gazetteer: Sendable {
    /// Kilometres, matching ``Coordinate/distance(to:)``.
    static let earthRadiusKm = 6_371.0
    /// Every candidate city is within its reach, and reach is at most 40 km.
    static let candidateKm = 60.0
    static let localityKm = 5.0
    static let admin1Km = 50.0
    static let countryKm = 150.0
    static let zoneKm = 1_000.0

    /// How far a city's name reaches: 0.6 km·√(population / 1000), clamped to 3–40 km.
    public static func reach(population: Int) -> Double {
        min(max(0.6 * (Double(population) / 1_000).squareRoot(), 3), 40)
    }

    private let data: Data
    let cityCount: Int
    private let citiesOffset: Int
    private let admin1Offset: Int
    private let admin1Count: Int
    private let stringsOffset: Int
    private let cellKeys: [UInt32]
    private let cellStarts: [Int]
    private let countries: [String]
    private let zones: [String]
    private let lookups = Mutex(Lookups())

    /// The yyyymmdd date of the GeoNames dump.
    public let sourceDate: Int
    /// The payload's CRC-32; changes whenever the data does.
    public let dataVersion: UInt32

    /// The resource bundled with the app (`cities15000.lzgz`), memory-mapped.
    public static func bundled() throws -> Gazetteer {
        guard let url = bundledURL else { throw GazetteerError.resourceMissing }
        return try Gazetteer(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    static var bundledURL: URL? { Bundle.module.url(forResource: "cities15000", withExtension: "lzgz") }

    #if DEBUG
    public static let verifiesChecksumByDefault = true
    #else
    public static let verifiesChecksumByDefault = false
    #endif

    /// Validates the header and every offset; the payload CRC is checked in DEBUG builds and tests.
    public init(data: Data, verifyChecksum: Bool = Gazetteer.verifiesChecksumByDefault) throws(GazetteerError) {
        let header = try data.withUnsafeBytes { raw in
            Result { () throws(GazetteerError) in try Header(raw, verifyChecksum: verifyChecksum) }
        }.get()
        self.data = data
        cityCount = header.cityCount
        citiesOffset = header.citiesOffset
        admin1Offset = header.admin1Offset
        admin1Count = header.admin1Count
        stringsOffset = header.stringsOffset
        cellKeys = header.cellKeys
        cellStarts = header.cellStarts
        countries = header.countries
        zones = header.zones
        sourceDate = header.sourceDate
        dataVersion = header.crc
    }

    // MARK: Lookup

    /// City, metro, locality, region, country and zone for `c`:
    /// 1. **nearest** is the closest place of any kind.
    /// 2. A candidate passes the guard if it is the nearest, or shares its country and region (any region
    ///    of the country when the nearest has none), so Dubai never names a point in Sharjah.
    /// 3. **city**: among non-section candidates that pass with distance ≤ ``reach(population:)``, the
    ///    smallest distance / reach (ties to the larger population); **metro**: the most populous of them.
    /// 4. **locality**: the nearest place within 5 km that is not the city.
    public func locate(_ c: Coordinate) -> GeoPlacement {
        guard c.isValid, cityCount > 0 else { return GeoPlacement() }
        return data.withUnsafeBytes { raw in
            var candidates = records(raw, near: c, withinKm: Self.candidateKm)
            candidates.sort { ($0.km, $0.index) < ($1.km, $1.index) }
            guard let nearest = candidates.first ?? self.nearest(raw, to: c) else { return GeoPlacement() }
            let nearestRegion = region(raw, nearest.region)

            var cities: [Candidate] = []
            for candidate in candidates where candidate.kind != .section && candidate.km <= Self.reach(population: candidate.population) {
                let passes = candidate.index == nearest.index
                    || (candidate.country == nearest.country && (nearestRegion.geonameID == 0 || candidate.region == nearest.region))
                if passes { cities.append(candidate) }
            }
            func ratio(_ a: Candidate) -> Double { a.km / Self.reach(population: a.population) }
            let city = cities.min { (ratio($0), -$0.population, $0.index) < (ratio($1), -$1.population, $1.index) }
            let metro = cities.min { (-$0.population, $0.km, $0.index) < (-$1.population, $1.km, $1.index) }
            let locality = candidates.first { $0.km <= Self.localityKm && $0.index != city?.index }

            var placement = GeoPlacement(nearestKm: nearest.km)
            placement.city = city.map { self.city(raw, at: $0.index) }
            placement.metro = metro.map { self.city(raw, at: $0.index) }
            placement.locality = locality.map { self.city(raw, at: $0.index) }
            if let city = placement.city {
                placement.admin1 = city.admin1
                placement.countryCode = city.countryCode
            } else {
                if nearest.km <= Self.admin1Km { placement.admin1 = admin1(raw, nearest.region) }
                if nearest.km <= Self.countryKm { placement.countryCode = countries[nearest.country] }
            }
            if nearest.km <= Self.admin1Km {
                placement.countryConfident = true
            } else if nearest.km <= Self.countryKm {
                let closest = records(raw, near: c, withinKm: Self.countryKm).sorted { ($0.km, $0.index) < ($1.km, $1.index) }.prefix(3)
                placement.countryConfident = closest.count == 3 && closest.allSatisfy { $0.country == nearest.country }
            }
            if nearest.km <= Self.zoneKm { placement.timeZone = zones[zone(raw, nearest.index)] }
            return placement
        }
    }

    /// The zone for a photo taken at `c`: the nearest place's within 1,000 km, else the
    /// fixed-offset `Etc/GMT∓n` zone for its longitude.
    public func timeZoneIdentifier(at c: Coordinate) -> String {
        locate(c).timeZone ?? LocalTime.etcZoneIdentifier(longitude: c.longitude)
    }

    /// The closest place and its distance in km (nil for an empty file).
    func nearest(to c: Coordinate) -> (city: GazetteerCity, km: Double)? {
        data.withUnsafeBytes { raw in nearest(raw, to: c).map { (city(raw, at: $0.index), $0.km) } }
    }

    /// Every place, in file order (tests and the build tool's round-trip check).
    func allCities() -> [GazetteerCity] {
        data.withUnsafeBytes { raw in (0..<cityCount).map { city(raw, at: $0) } }
    }

    // MARK: Names

    /// Places whose name, ASCII form, alias or article-less variant folds to `folded` (exact matches
    /// first, then prefixes), each group by population.
    public func cities(named folded: String, limit: Int) -> [GazetteerCity] {
        let matches = lookups.withLock { lookups in lookups.names(self).cities.matches(PlaceNames.fold(folded)) }
        return data.withUnsafeBytes { raw in
            func population(_ index: Int) -> Int {
                Int(raw.le(citiesOffset + index * GazetteerFormat.citySize + 12, as: UInt32.self) & GazetteerFormat.populationMask)
            }
            return Self.ranked(matches, limit: limit) { population($0) }.map { city(raw, at: $0) }
        }
    }

    /// Regions whose name folds to `folded` (exact first, then prefixes), each group by the population of
    /// their places.
    public func admin1s(named folded: String, limit: Int) -> [GazetteerAdmin1] {
        let (indices, population) = lookups.withLock { lookups in
            let names = lookups.names(self)
            return (names.regions.matches(PlaceNames.fold(folded)), names.regionPopulation)
        }
        return data.withUnsafeBytes { raw in Self.ranked(indices, limit: limit) { population[$0] }.compactMap { admin1(raw, $0) } }
    }

    /// Exact matches, then prefix matches, each by population (ties by file order), without repeats.
    private static func ranked(_ matches: (exact: [Int], prefix: [Int]), limit: Int, population: (Int) -> Int) -> [Int] {
        func byPopulation(_ indices: [Int]) -> [Int] {
            indices.map { ($0, population($0)) }.sorted { ($1.1, $0.0) < ($0.1, $1.0) }.map(\.0)
        }
        var seen = Set<Int>()
        return Array((byPopulation(matches.exact) + byPopulation(matches.prefix)).filter { seen.insert($0).inserted }.prefix(max(0, limit)))
    }

    public func city(geonameID: Int32) -> GazetteerCity? {
        guard let index = lookups.withLock({ $0.ids(self)[geonameID] }) else { return nil }
        return data.withUnsafeBytes { raw in city(raw, at: index) }
    }

    /// Drops the name and id indexes (about 3 MB); the next name lookup rebuilds them. Call on a memory warning.
    public func releaseNameIndex() {
        lookups.withLock { $0 = Lookups() }
    }

    // MARK: Records

    private struct Candidate {
        var index: Int
        var km: Double
        var population: Int
        var kind: GazetteerCity.Kind
        var region: Int
        var country: Int
    }

    /// Every place within `km` of `c`.
    private func records(_ raw: UnsafeRawBufferPointer, near c: Coordinate, withinKm km: Double) -> [Candidate] {
        var found: [Candidate] = []
        scan(raw, near: c, withinKm: km, limit: { km }) { index, distance in
            if distance <= km { found.append(candidate(raw, index, distance)) }
        }
        return found
    }

    /// The closest place: windows of 60, 240, 960… km until one holds a place (the last covers the globe).
    /// Inside a window, cells that can't beat the best so far are skipped.
    private func nearest(_ raw: UnsafeRawBufferPointer, to c: Coordinate) -> Candidate? {
        var km = Self.candidateKm
        while true {
            var best: (index: Int, km: Double)?
            scan(raw, near: c, withinKm: km, limit: { min(km, best?.km ?? .infinity) }) { index, distance in
                if distance <= km, best.map({ (distance, index) < ($0.km, $0.index) }) ?? true { best = (index, distance) }
            }
            if let best { return candidate(raw, best.index, best.km) }
            if km > .pi * Self.earthRadiusKm { return nil }
            km *= 4
        }
    }

    /// Visits the places in the 1° cells that can hold one within `km` of `c`, with their distances: latitude
    /// rows within km / R radians, nearest rows first, and the longitudes a great circle of that length can
    /// span at the window's poleward edge (all of them near a pole), wrapping at ±180°. A cell is skipped when
    /// even its closest corner is farther than `limit()`.
    private func scan(_ raw: UnsafeRawBufferPointer, near c: Coordinate, withinKm km: Double, limit: () -> Double,
                      _ visit: (_ index: Int, _ km: Double) -> Void) {
        let radians = Double.pi / 180
        let latitudeSpan = km / Self.earthRadiusKm / radians
        let south = c.latitude - latitudeSpan, north = c.latitude + latitudeSpan
        let poleward = max(abs(south), abs(north))
        let chord = sin(km / Self.earthRadiusKm / 2) / cos(poleward * radians)
        let columns: [ClosedRange<Int>]
        if poleward >= 90 || chord >= 1 {
            columns = [0...359]
        } else {
            let span = 2 * asin(chord) / radians + 1e-9
            let first = Int((c.longitude - span).rounded(.down)) + 180, last = Int((c.longitude + span).rounded(.down)) + 180
            if last - first >= 359 {
                columns = [0...359]
            } else if first < 0 {
                columns = [(first + 360)...359, 0...last]
            } else if last > 359 {
                columns = [first...359, 0...(last - 360)]
            } else {
                columns = [first...last]
            }
        }
        let centreRow = GazetteerFormat.cellRow(c.latitude), cosLatitude = cos(c.latitude * radians)
        let rows = (GazetteerFormat.cellRow(max(-90, south))...GazetteerFormat.cellRow(min(90, north))).sorted { abs($0 - centreRow) < abs($1 - centreRow) }

        /// A lower bound on the distance to any point of the cell: haversine with the smallest latitude and
        /// longitude gaps and the smallest cosine in the cell.
        func closestKm(_ key: UInt32) -> Double {
            let cellSouth = Double(Int(key) / 360 - 90), cellWest = Double(Int(key) % 360 - 180)
            let latitudeGap = max(0, cellSouth - c.latitude, c.latitude - (cellSouth + 1))
            var longitudeGap = 0.0
            if !(cellWest...(cellWest + 1)).contains(c.longitude) {
                func around(_ edge: Double) -> Double {
                    let gap = abs(c.longitude - edge).truncatingRemainder(dividingBy: 360)
                    return min(gap, 360 - gap)
                }
                longitudeGap = min(around(cellWest), around(cellWest + 1))
            }
            let cellCos = cos(max(abs(cellSouth), abs(cellSouth + 1)) * radians)
            let a = pow(sin(latitudeGap * radians / 2), 2) + cosLatitude * cellCos * pow(sin(longitudeGap * radians / 2), 2)
            return 2 * Self.earthRadiusKm * asin(min(1, a.squareRoot()))
        }

        for row in rows {
            for range in columns {
                var cell = firstCell(atOrAfter: UInt32(row * 360 + range.lowerBound))
                let lastKey = UInt32(row * 360 + range.upperBound)
                while cell < cellKeys.count, cellKeys[cell] <= lastKey {
                    defer { cell += 1 }
                    guard closestKm(cellKeys[cell]) - 1e-6 <= limit() else { continue }   // a little slack for rounding
                    let end = cell + 1 < cellStarts.count ? cellStarts[cell + 1] : cityCount
                    for index in cellStarts[cell]..<end {
                        let base = citiesOffset + index * GazetteerFormat.citySize
                        let position = Coordinate(latitude: GazetteerFormat.degrees(raw.le(base)), longitude: GazetteerFormat.degrees(raw.le(base + 4)))
                        visit(index, c.distance(to: position) / 1_000)
                    }
                }
            }
        }
    }

    private func candidate(_ raw: UnsafeRawBufferPointer, _ index: Int, _ km: Double) -> Candidate {
        let base = citiesOffset + index * GazetteerFormat.citySize
        let popKind: UInt32 = raw.le(base + 12)
        let region = Int(raw.le(base + 20, as: UInt16.self))
        return Candidate(index: index, km: km, population: Int(popKind & GazetteerFormat.populationMask),
                         kind: GazetteerCity.Kind(rawValue: UInt8(popKind >> 28)) ?? .city, region: region,
                         country: Int(raw.le(admin1Offset + region * GazetteerFormat.admin1Size + 4, as: UInt16.self)))
    }

    /// The index of the first non-empty cell whose key is `key` or more.
    private func firstCell(atOrAfter key: UInt32) -> Int {
        var low = 0, high = cellKeys.count
        while low < high {
            let mid = (low + high) / 2
            if cellKeys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func zone(_ raw: UnsafeRawBufferPointer, _ index: Int) -> Int {
        Int(raw.le(citiesOffset + index * GazetteerFormat.citySize + 22, as: UInt16.self))
    }

    private func region(_ raw: UnsafeRawBufferPointer, _ index: Int) -> (geonameID: Int32, country: Int, name: Int) {
        let base = admin1Offset + index * GazetteerFormat.admin1Size
        return (Int32(bitPattern: raw.le(base)), Int(raw.le(base + 4, as: UInt16.self)), Int(raw.le(base + 8, as: UInt32.self)))
    }

    private func admin1(_ raw: UnsafeRawBufferPointer, _ index: Int) -> GazetteerAdmin1? {
        let region = region(raw, index)
        guard region.geonameID != 0 else { return nil }
        return GazetteerAdmin1(geonameID: region.geonameID, name: string(raw, at: region.name), countryCode: countries[region.country])
    }

    func city(_ raw: UnsafeRawBufferPointer, at index: Int) -> GazetteerCity {
        let base = citiesOffset + index * GazetteerFormat.citySize
        let popKind: UInt32 = raw.le(base + 12)
        let regionIndex = Int(raw.le(base + 20, as: UInt16.self))
        let names = nameList(raw, at: Int(raw.le(base + 16, as: UInt32.self)))
        return GazetteerCity(
            geonameID: Int32(bitPattern: raw.le(base + 8)),
            name: names.first ?? "",
            alternateNames: Array(names.dropFirst()),
            coordinate: Coordinate(latitude: GazetteerFormat.degrees(raw.le(base)), longitude: GazetteerFormat.degrees(raw.le(base + 4))),
            population: Int(popKind & GazetteerFormat.populationMask),
            kind: GazetteerCity.Kind(rawValue: UInt8(popKind >> 28)) ?? .city,
            countryCode: countries[region(raw, regionIndex).country],
            admin1: admin1(raw, regionIndex),
            timeZone: zones[zone(raw, index)])
    }

    /// The NUL-terminated string at `offset` in the strings section.
    private func string(_ raw: UnsafeRawBufferPointer, at offset: Int) -> String {
        Header.string(raw, at: stringsOffset + offset)
    }

    /// The strings from `offset` up to the empty one that ends the list.
    private func nameList(_ raw: UnsafeRawBufferPointer, at offset: Int) -> [String] {
        var names: [String] = []
        var position = stringsOffset + offset
        while position < raw.count, raw[position] != 0 {
            let name = Header.string(raw, at: position)
            names.append(name)
            position += name.utf8.count + 1
        }
        return names
    }

    // MARK: Lazy indexes

    private struct Lookups {
        private var nameIndex: NameIndex?
        private var idIndex: [Int32: Int]?

        mutating func names(_ gazetteer: Gazetteer) -> NameIndex {
            if let nameIndex { return nameIndex }
            let built = gazetteer.buildNameIndex()
            nameIndex = built
            return built
        }

        mutating func ids(_ gazetteer: Gazetteer) -> [Int32: Int] {
            if let idIndex { return idIndex }
            let built = gazetteer.data.withUnsafeBytes { raw in
                Dictionary(uniqueKeysWithValues: (0..<gazetteer.cityCount).map {
                    (Int32(bitPattern: raw.le(gazetteer.citiesOffset + $0 * GazetteerFormat.citySize + 8)), $0)
                })
            }
            idIndex = built
            return built
        }
    }

    private struct NameIndex: Sendable {
        var cities: FoldedIndex
        var regions: FoldedIndex
        var regionPopulation: [Int]
    }

    private func buildNameIndex() -> NameIndex {
        data.withUnsafeBytes { raw in
            var cityKeys: [String: [Int]] = [:]
            var regionPopulation = [Int](repeating: 0, count: admin1Count)
            for index in 0..<cityCount {
                let base = citiesOffset + index * GazetteerFormat.citySize
                for name in nameList(raw, at: Int(raw.le(base + 16, as: UInt32.self))) {
                    for key in PlaceNames.variants(name) where cityKeys[key]?.last != index { cityKeys[key, default: []].append(index) }
                }
                regionPopulation[Int(raw.le(base + 20, as: UInt16.self))] += Int(raw.le(base + 12, as: UInt32.self) & GazetteerFormat.populationMask)
            }
            var regionKeys: [String: [Int]] = [:]
            for index in 0..<admin1Count {
                let region = region(raw, index)
                guard region.geonameID != 0 else { continue }
                for key in PlaceNames.variants(string(raw, at: region.name)) where regionKeys[key]?.last != index {
                    regionKeys[key, default: []].append(index)
                }
            }
            return NameIndex(cities: FoldedIndex(cityKeys), regions: FoldedIndex(regionKeys), regionPopulation: regionPopulation)
        }
    }
}

/// Folded names → record indices, with prefix search over the keys sorted by their UTF-8 bytes.
private struct FoldedIndex: Sendable {
    private let entries: [String: [Int]]
    private let keys: [String]

    init(_ entries: [String: [Int]]) {
        self.entries = entries
        keys = entries.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Indices under `folded` itself, and under longer keys that start with it.
    func matches(_ folded: String) -> (exact: [Int], prefix: [Int]) {
        guard !folded.isEmpty else { return ([], []) }
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid].utf8.lexicographicallyPrecedes(folded.utf8) { low = mid + 1 } else { high = mid }
        }
        var prefix: [Int] = []
        var position = low
        while position < keys.count, keys[position].utf8.starts(with: folded.utf8) {
            if keys[position] != folded { prefix += entries[keys[position]] ?? [] }
            position += 1
        }
        return (entries[folded] ?? [], prefix)
    }
}

/// The parsed, validated header and small tables.
private struct Header {
    var cityCount = 0, admin1Count = 0, citiesOffset = 0, admin1Offset = 0, stringsOffset = 0, sourceDate = 0
    var crc: UInt32 = 0
    var cellKeys: [UInt32] = [], cellStarts: [Int] = []
    var countries: [String] = [], zones: [String] = []

    init(_ raw: UnsafeRawBufferPointer, verifyChecksum: Bool) throws(GazetteerError) {
        let size = GazetteerFormat.headerSize
        guard raw.count >= 4, Array(raw[0..<4]) == GazetteerFormat.magic else { throw .badMagic }
        guard raw.count >= size else { throw .truncated }
        let version: UInt16 = raw.le(4)
        guard version == GazetteerFormat.version else { throw .unsupportedVersion(version) }
        cityCount = Int(raw.le(8, as: UInt32.self))
        let cellCount = Int(raw.le(12, as: UInt32.self))
        admin1Count = Int(raw.le(16, as: UInt32.self))
        let countryCount = Int(raw.le(20, as: UInt16.self))
        let zoneCount = Int(raw.le(22, as: UInt16.self))
        sourceDate = Int(raw.le(24, as: UInt32.self))
        let offsets = (0..<6).map { Int(raw.le(28 + $0 * 4, as: UInt32.self)) }
        let stringsLength = Int(raw.le(52, as: UInt32.self))
        crc = raw.le(56)
        let sizes = [cellCount * GazetteerFormat.cellSize, cityCount * GazetteerFormat.citySize, admin1Count * GazetteerFormat.admin1Size,
                     countryCount * GazetteerFormat.countrySize, zoneCount * GazetteerFormat.zoneSize, stringsLength]
        for (offset, length) in zip(offsets, sizes) where offset < size || offset + length > raw.count {
            throw .truncated
        }
        citiesOffset = offsets[1]
        admin1Offset = offsets[2]
        stringsOffset = offsets[5]
        if verifyChecksum, CRC32.checksum(UnsafeRawBufferPointer(rebasing: raw[size...])) != crc { throw .checksumMismatch }
        guard stringsLength == 0 || raw[stringsOffset + stringsLength - 1] == 0 else { throw .corrupt("strings") }
        func checkString(_ offset: Int) throws(GazetteerError) {
            guard offset < stringsLength else { throw .corrupt("string offset \(offset)") }
        }

        for index in 0..<countryCount {
            let base = offsets[3] + index * GazetteerFormat.countrySize
            countries.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[base..<base + 2]), as: UTF8.self))
        }
        for index in 0..<zoneCount {
            let offset = Int(raw.le(offsets[4] + index * GazetteerFormat.zoneSize, as: UInt32.self))
            try checkString(offset)
            zones.append(Header.string(raw, at: stringsOffset + offset))
        }
        for index in 0..<admin1Count {
            let base = admin1Offset + index * GazetteerFormat.admin1Size
            guard Int(raw.le(base + 4, as: UInt16.self)) < countryCount else { throw .corrupt("admin1 \(index) country") }
            try checkString(Int(raw.le(base + 8, as: UInt32.self)))
        }
        var previousKey: UInt32?
        for index in 0..<cellCount {
            let base = offsets[0] + index * GazetteerFormat.cellSize
            let key: UInt32 = raw.le(base), start = Int(raw.le(base + 4, as: UInt32.self))
            guard previousKey.map({ key > $0 }) ?? true, key < 180 * 360 else { throw .corrupt("cell \(index) key") }
            guard cityCount > start, start > (cellStarts.last ?? -1), index > 0 || start == 0 else { throw .corrupt("cell \(index) start") }
            previousKey = key
            cellKeys.append(key)
            cellStarts.append(start)
        }
        guard (cityCount == 0) == cellStarts.isEmpty else { throw .corrupt("cells") }
        var cell = 0
        for index in 0..<cityCount {
            let base = citiesOffset + index * GazetteerFormat.citySize
            while cell + 1 < cellStarts.count, cellStarts[cell + 1] <= index { cell += 1 }
            let lat = GazetteerFormat.degrees(raw.le(base)), lon = GazetteerFormat.degrees(raw.le(base + 4))
            guard (-90...90).contains(lat), (-180...180).contains(lon),
                  GazetteerFormat.cellKey(latitude: lat, longitude: lon) == cellKeys[cell] else { throw .corrupt("city \(index) position") }
            guard raw.le(base + 12, as: UInt32.self) >> 28 <= 3 else { throw .corrupt("city \(index) kind") }
            try checkString(Int(raw.le(base + 16, as: UInt32.self)))
            guard Int(raw.le(base + 20, as: UInt16.self)) < admin1Count, Int(raw.le(base + 22, as: UInt16.self)) < zoneCount else {
                throw .corrupt("city \(index) region or zone")
            }
        }
    }

    /// The NUL-terminated UTF-8 string at absolute `offset` (validation guarantees a NUL before the end).
    static func string(_ raw: UnsafeRawBufferPointer, at offset: Int) -> String {
        var end = offset
        while end < raw.count, raw[end] != 0 { end += 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<end]), as: UTF8.self)
    }
}
