import Foundation

/// The `LZGZ` v1 file the gazetteer reads, written by `lz-gazetteer` from GeoNames' cities15000 dump.
/// Little-endian, read in place from a memory-mapped file:
///
/// ```
/// Header    64 B  "LZGZ" | version u16 | flags u16 | cityCount u32 | cellCount u32 | admin1Count u32
///                 | countryCount u16 | zoneCount u16 | sourceDate u32 (yyyymmdd)
///                 | section offsets u32 × 6 (cells, cities, admin1, countries, zones, strings)
///                 | stringsLength u32 | payloadCRC32 u32 | reserved u32
/// Cells      8 B  cellKey u32 (ascending) | firstCity u32 (the run ends at the next cell's first)
/// Cities    24 B  lat i32 (deg·1e5) | lon i32 | geonameID u32 | kind (top 4 bits) + population (low 28) u32
///                 | names u32 (offset of a NUL-separated list ending with an empty string) | admin1 u16 | zone u16
/// Admin1    12 B  geonameID u32 (0: the country's "no region" entry) | country u16 | pad u16 | name u32
/// Countries  2 B  ISO 3166 alpha-2;  Zones 4 B: name offset;  Strings: UTF-8, NUL-terminated, deduplicated
/// ```
///
/// Cities are sorted by (cellKey, population descending, geonameID) so a lookup scans a few 1° cells.
/// The payload CRC (everything after the header) doubles as the data version.
public enum GazetteerFormat {
    static let version: UInt16 = 1
    static let magic: [UInt8] = Array("LZGZ".utf8)
    static let headerSize = 64
    static let cellSize = 8
    static let citySize = 24
    static let admin1Size = 12
    static let countrySize = 2
    static let zoneSize = 4
    static let populationMask: UInt32 = 0x0FFF_FFFF
    static let coordinateScale = 100_000.0

    /// The 1° cell of a position: row floor(lat) + 90, column floor(lon) + 180, clamped so 90° and
    /// 180° stay in the last row and column.
    static func cellKey(latitude: Double, longitude: Double) -> UInt32 {
        UInt32(cellRow(latitude) * 360 + cellColumn(longitude))
    }

    static func cellRow(_ latitude: Double) -> Int { min(179, max(0, Int(latitude.rounded(.down)) + 90)) }
    static func cellColumn(_ longitude: Double) -> Int { min(359, max(0, Int(longitude.rounded(.down)) + 180)) }

    /// A degree value as stored (rounded to 1e-5°, about a metre).
    static func fixed(_ degrees: Double) -> Int32 { Int32((degrees * coordinateScale).rounded()) }
    static func degrees(_ fixed: Int32) -> Double { Double(fixed) / coordinateScale }

    // MARK: Writing

    /// One city as the build tool hands it over.
    public struct CitySource: Sendable, Hashable {
        public var geonameID: Int32
        /// The display name first, then the other names it answers to (ASCII form, aliases).
        public var names: [String]
        public var coordinate: Coordinate
        public var population: Int
        public var kind: GazetteerCity.Kind
        /// ISO 3166 alpha-2, upper case.
        public var countryCode: String
        /// GeoNames' admin1 code; nil or a code with no admin1 row means the country's "no region" entry.
        public var admin1Code: String?
        /// IANA zone identifier.
        public var timeZone: String

        public init(geonameID: Int32, names: [String], coordinate: Coordinate, population: Int, kind: GazetteerCity.Kind,
                    countryCode: String, admin1Code: String?, timeZone: String) {
            self.geonameID = geonameID
            self.names = names
            self.coordinate = coordinate
            self.population = population
            self.kind = kind
            self.countryCode = countryCode
            self.admin1Code = admin1Code
            self.timeZone = timeZone
        }
    }

    /// One first-level region (GeoNames admin1CodesASCII).
    public struct Admin1Source: Sendable, Hashable {
        public var countryCode: String
        public var code: String
        public var geonameID: Int32
        public var name: String

        public init(countryCode: String, code: String, geonameID: Int32, name: String) {
            self.countryCode = countryCode
            self.code = code
            self.geonameID = geonameID
            self.name = name
        }
    }

    /// The file for these cities. Deterministic: the same input in any order gives the same bytes.
    /// Only regions some city refers to are written.
    public static func encode(cities: [CitySource], admin1s: [Admin1Source], sourceDate: Int) throws(GazetteerError) -> Data {
        struct RegionKey: Hashable, Comparable {
            var country: String
            var code: String?
            static func < (a: RegionKey, b: RegionKey) -> Bool {
                (a.country, a.code ?? "") < (b.country, b.code ?? "")
            }
        }
        guard (19_000_101...99_991_231).contains(sourceDate) else { throw .invalidSource("source date \(sourceDate) is not yyyymmdd") }
        var known: [RegionKey: Admin1Source] = [:]
        for admin1 in admin1s { known[RegionKey(country: admin1.countryCode, code: admin1.code)] = admin1 }

        // Validate and place every city.
        struct Placed {
            var source: CitySource
            var lat: Int32
            var lon: Int32
            var cell: UInt32
            var region: RegionKey
        }
        var placed: [Placed] = []
        placed.reserveCapacity(cities.count)
        var ids = Set<Int32>()
        for city in cities {
            guard city.geonameID > 0, ids.insert(city.geonameID).inserted else { throw .invalidSource("duplicate or invalid id \(city.geonameID)") }
            guard let display = city.names.first, !display.isEmpty, city.names.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
                throw .invalidSource("bad names for \(city.geonameID)")
            }
            guard city.coordinate.latitude.isFinite, city.coordinate.longitude.isFinite,
                  (-90...90).contains(city.coordinate.latitude), (-180...180).contains(city.coordinate.longitude) else {
                throw .invalidSource("bad coordinate for \(city.geonameID)")
            }
            guard city.countryCode.utf8.count == 2, city.countryCode.utf8.allSatisfy({ (65...90).contains($0) }) else {
                throw .invalidSource("bad country \(city.countryCode) for \(city.geonameID)")
            }
            guard !city.timeZone.isEmpty, !city.timeZone.utf8.contains(0) else { throw .invalidSource("bad zone for \(city.geonameID)") }
            let lat = fixed(city.coordinate.latitude), lon = fixed(city.coordinate.longitude)
            var region = RegionKey(country: city.countryCode, code: city.admin1Code)
            if region.code == nil || known[region] == nil { region.code = nil }
            placed.append(Placed(source: city, lat: lat, lon: lon, cell: cellKey(latitude: degrees(lat), longitude: degrees(lon)), region: region))
        }
        placed.sort {
            ($0.cell, -$0.source.population, $0.source.geonameID) < ($1.cell, -$1.source.population, $1.source.geonameID)
        }

        let countries = Array(Set(placed.map(\.source.countryCode))).sorted()
        let zones = Array(Set(placed.map(\.source.timeZone))).sorted()
        let regions = Array(Set(placed.map(\.region))).sorted()
        guard countries.count <= Int(UInt16.max), zones.count <= Int(UInt16.max), regions.count <= Int(UInt16.max) else {
            throw .invalidSource("too many countries, zones or regions")
        }
        let countryIndex = Dictionary(uniqueKeysWithValues: countries.enumerated().map { ($1, UInt16($0)) })
        let zoneIndex = Dictionary(uniqueKeysWithValues: zones.enumerated().map { ($1, UInt16($0)) })
        let regionIndex = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($1, UInt16($0)) })

        var strings = StringTable()
        let zoneOffsets = zones.map { strings.add([$0]) }
        let regionOffsets = regions.map { region in strings.add([region.code == nil ? "" : known[region]?.name ?? ""]) }
        let nameOffsets = placed.map { strings.add($0.source.names, terminated: true) }

        var cells = Data(), records = Data(), regionTable = Data(), countryTable = Data(), zoneTable = Data()
        var lastCell: UInt32?
        for (index, city) in placed.enumerated() {
            if city.cell != lastCell {
                cells.append(le: city.cell)
                cells.append(le: UInt32(index))
                lastCell = city.cell
            }
            let population = UInt32(min(max(city.source.population, 0), Int(populationMask)))
            records.append(le: city.lat)
            records.append(le: city.lon)
            records.append(le: UInt32(city.source.geonameID))
            records.append(le: UInt32(city.source.kind.rawValue) << 28 | population)
            records.append(le: nameOffsets[index])
            records.append(le: regionIndex[city.region] ?? 0)
            records.append(le: zoneIndex[city.source.timeZone] ?? 0)
        }
        for (index, region) in regions.enumerated() {
            let geonameID = region.code == nil ? 0 : known[region]?.geonameID ?? 0
            regionTable.append(le: UInt32(bitPattern: geonameID))
            regionTable.append(le: countryIndex[region.country] ?? 0)
            regionTable.append(le: UInt16(0))
            regionTable.append(le: regionOffsets[index])
        }
        for country in countries { countryTable.append(contentsOf: Array(country.utf8)) }
        for offset in zoneOffsets { zoneTable.append(le: offset) }

        let sections = [cells, records, regionTable, countryTable, zoneTable, strings.bytes]
        var offsets: [UInt32] = []
        var position = headerSize
        for section in sections {
            offsets.append(UInt32(position))
            position += section.count
        }
        var payload = Data(capacity: position - headerSize)
        for section in sections { payload.append(section) }

        var file = Data(capacity: position)
        file.append(contentsOf: magic)
        file.append(le: version)
        file.append(le: UInt16(0))
        file.append(le: UInt32(placed.count))
        file.append(le: UInt32(cells.count / cellSize))
        file.append(le: UInt32(regions.count))
        file.append(le: UInt16(countries.count))
        file.append(le: UInt16(zones.count))
        file.append(le: UInt32(sourceDate))
        for offset in offsets { file.append(le: offset) }
        file.append(le: UInt32(strings.bytes.count))
        file.append(le: payload.withUnsafeBytes { CRC32.checksum($0) })
        file.append(le: UInt32(0))
        file.append(payload)
        return file
    }

    /// UTF-8 strings, each NUL-terminated, stored once.
    private struct StringTable {
        var bytes = Data()
        private var offsets: [Data: UInt32] = [:]

        /// The offset of these strings, written one after another; `terminated` adds the empty string
        /// that ends a name list.
        mutating func add(_ parts: [String], terminated: Bool = false) -> UInt32 {
            var blob = Data()
            for part in parts {
                blob.append(contentsOf: Array(part.utf8))
                blob.append(0)
            }
            if terminated { blob.append(0) }
            if let offset = offsets[blob] { return offset }
            let offset = UInt32(bytes.count)
            offsets[blob] = offset
            bytes.append(blob)
            return offset
        }
    }
}

public enum GazetteerError: Error, Sendable, Hashable {
    /// The bundled resource isn't in the app.
    case resourceMissing
    case badMagic
    case unsupportedVersion(UInt16)
    case truncated
    case checksumMismatch
    case corrupt(String)
    /// The writer refused its input.
    case invalidSource(String)
}

/// CRC-32 (IEEE 802.3, as zlib).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension UnsafeRawBufferPointer {
    func le<T: FixedWidthInteger>(_ offset: Int, as type: T.Type = T.self) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
