import Foundation
import Testing
@testable import LZGeo

/// The LZGZ writer and reader on a small fixture: round trip, determinism, damage, and the lookup rule
/// on hand-made places.
@Suite struct GazetteerFormatTests {
    // MARK: Fixture (20 places)

    static let admin1s: [GazetteerFormat.Admin1Source] = [
        .init(countryCode: "SA", code: "10", geonameID: 108411, name: "Ar Riyāḑ"),
        .init(countryCode: "AE", code: "03", geonameID: 292224, name: "Dubai"),
        .init(countryCode: "AE", code: "06", geonameID: 292673, name: "Sharjah"),
        .init(countryCode: "GR", code: "ESYE31", geonameID: 6692632, name: "Attica"),
        .init(countryCode: "FJ", code: "01", geonameID: 2205272, name: "Central"),
        .init(countryCode: "FJ", code: "03", geonameID: 2205274, name: "Northern"),
        .init(countryCode: "XX", code: "99", geonameID: 999, name: "Unused"),
    ]

    static let cities: [GazetteerFormat.CitySource] = [
        city(108410, ["Riyadh", "Ar Riyadh"], 24.68773, 46.72185, 4_205_961, .capital, "SA", "10", "Asia/Riyadh"),
        city(110312, ["Ad Dir‘īyah", "Diriyah"], 24.75187, 46.53874, 61_609, .city, "SA", "10", "Asia/Riyadh"),
        city(7_000_001, ["‘Irqah"], 24.69100, 46.58000, 42_179, .section, "SA", "10", "Asia/Riyadh"),
        city(7_000_002, ["Ad Diriyah Camp"], 24.75187, 46.53874, 15_000, .city, "SA", "10", "Asia/Riyadh"),   // same spot as Ad Dir‘īyah
        city(7_000_003, ["Rumāḩ", "Rumah"], 25.57000, 47.15000, 20_000, .city, "SA", nil, "Asia/Riyadh"),
        city(292223, ["Dubai", "Dubayy"], 25.07725, 55.30927, 3_790_000, .seat, "AE", "03", "Asia/Dubai"),
        city(8469788, ["Dubai Marina"], 25.08000, 55.14000, 30_000, .section, "AE", "03", "Asia/Dubai"),
        city(292672, ["Sharjah"], 25.33420, 55.41221, 1_800_000, .seat, "AE", "06", "Asia/Dubai"),
        city(8476509, ["Al Majaz"], 25.32800, 55.38700, 25_000, .section, "AE", "06", "Asia/Dubai"),
        city(7_000_004, ["Hatta"], 24.80000, 56.12000, 16_000, .city, "AE", "77", "Asia/Dubai"),           // unknown region code
        city(264371, ["Athens", "Athina"], 37.98376, 23.72784, 664_046, .capital, "GR", "ESYE31", "Europe/Athens"),
        city(263312, ["Dhafní", "Dhafni"], 37.95000, 23.73000, 22_000, .city, "GR", "ESYE31", "Europe/Athens"),
        city(2198148, ["Suva"], -18.13683, 178.42531, 77_366, .capital, "FJ", "01", "Pacific/Fiji"),
        city(2204582, ["Labasa"], -16.43320, 179.36451, 27_949, .seat, "FJ", "03", "Pacific/Fiji"),
        city(7_000_005, ["Eastern Edge"], -17.20000, 180.00000, 15_000, .city, "FJ", "03", "Pacific/Fiji"),
        city(7_000_006, ["Western Edge"], -16.50000, -179.99000, 15_000, .city, "FJ", "03", "Pacific/Fiji"),
        city(7_000_007, ["North Pole Station"], 90.00000, 0.00000, 15_000, .city, "NO", nil, "Arctic/Longyearbyen"),
        city(7_000_008, ["South Point"], -90.00000, 45.00000, 15_000, .city, "AQ", nil, "Antarctica/South_Pole"),
        city(7_000_009, ["Null Village"], 0.00001, 0.00001, 15_000, .city, "GH", nil, "Africa/Accra"),
        city(7_000_010, ["Big Number"], 10.00000, 10.00000, 300_000_000, .city, "NG", nil, "Africa/Lagos"),     // clamps to 28 bits
    ]

    static func city(_ id: Int32, _ names: [String], _ latitude: Double, _ longitude: Double, _ population: Int, _ kind: GazetteerCity.Kind,
                     _ country: String, _ admin1: String?, _ zone: String) -> GazetteerFormat.CitySource {
        .init(geonameID: id, names: names, coordinate: Coordinate(latitude: latitude, longitude: longitude), population: population, kind: kind,
              countryCode: country, admin1Code: admin1, timeZone: zone)
    }

    private func fixture() throws -> Data {
        try GazetteerFormat.encode(cities: Self.cities, admin1s: Self.admin1s, sourceDate: 20261028)
    }

    // MARK: Round trip

    @Test func everyFieldRoundTrips() throws {
        let gazetteer = try Gazetteer(data: fixture(), verifyChecksum: true)
        #expect(gazetteer.sourceDate == 20261028)
        let read = Dictionary(uniqueKeysWithValues: gazetteer.allCities().map { ($0.geonameID, $0) })
        #expect(read.count == 20)
        let regions = Dictionary(uniqueKeysWithValues: Self.admin1s.map { ("\($0.countryCode).\($0.code)", $0) })
        for source in Self.cities {
            let city = try #require(read[source.geonameID])
            #expect([city.name] + city.alternateNames == source.names)
            #expect(abs(city.coordinate.latitude - source.coordinate.latitude) < 1e-9)
            #expect(abs(city.coordinate.longitude - source.coordinate.longitude) < 1e-9)
            #expect(city.population == min(source.population, 0x0FFF_FFFF))
            #expect(city.kind == source.kind && city.countryCode == source.countryCode && city.timeZone == source.timeZone)
            let region = source.admin1Code.flatMap { regions["\(source.countryCode).\($0)"] }
            #expect(city.admin1?.geonameID == region?.geonameID && city.admin1?.name == region?.name)
            #expect(gazetteer.city(geonameID: source.geonameID) == city)
        }
        #expect(read[7_000_004]?.admin1 == nil)            // a code with no admin1 row becomes "no region"
        #expect(gazetteer.city(geonameID: 1) == nil)
        // Only regions some place refers to are written.
        #expect(gazetteer.admin1s(named: "unused", limit: 5).isEmpty)
        #expect(gazetteer.admin1s(named: "sharjah", limit: 5).map(\.geonameID) == [292673])
    }

    @Test func rebuildsAreByteIdenticalWhateverTheInputOrder() throws {
        let first = try fixture()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3 {
            let shuffled = try GazetteerFormat.encode(cities: Self.cities.shuffled(using: &generator), admin1s: Self.admin1s.shuffled(using: &generator),
                                                      sourceDate: 20261028)
            #expect(shuffled == first)
        }
        let other = try GazetteerFormat.encode(cities: Self.cities, admin1s: Self.admin1s, sourceDate: 20261029)
        #expect(other != first)
        #expect(try Gazetteer(data: other).dataVersion == Gazetteer(data: first).dataVersion)   // only the header changed
    }

    @Test func damagedFilesAreRejected() throws {
        let data = try fixture()
        var badMagic = data
        badMagic[0] = UInt8(ascii: "X")
        #expect(throws: GazetteerError.badMagic) { try Gazetteer(data: badMagic) }
        #expect(throws: GazetteerError.badMagic) { try Gazetteer(data: Data()) }
        #expect(throws: GazetteerError.truncated) { try Gazetteer(data: data.prefix(40)) }
        #expect(throws: GazetteerError.truncated) { try Gazetteer(data: data.prefix(data.count - 1)) }
        var newer = data
        newer[4] = 2
        #expect(throws: GazetteerError.unsupportedVersion(2)) { try Gazetteer(data: newer) }
        // A flipped population byte: caught by the checksum, invisible to the structural checks.
        var flipped = data
        let firstCity = Int(data.withUnsafeBytes { $0.le(32, as: UInt32.self) })
        flipped[firstCity + 12] ^= 0x01
        #expect(throws: GazetteerError.checksumMismatch) { try Gazetteer(data: flipped, verifyChecksum: true) }
        #expect(throws: Never.self) { try Gazetteer(data: flipped, verifyChecksum: false) }
        // A zone index past the table.
        var badZone = data
        badZone[firstCity + 22] = 0xFF
        badZone[firstCity + 23] = 0xFF
        #expect(throws: GazetteerError.corrupt("city 0 region or zone")) { try Gazetteer(data: badZone, verifyChecksum: false) }
    }

    @Test func theWriterRefusesBadInput() {
        var duplicate = Self.cities
        duplicate.append(Self.cities[0])
        #expect(throws: GazetteerError.self) { try GazetteerFormat.encode(cities: duplicate, admin1s: [], sourceDate: 20261028) }
        var unnamed = Self.cities[0]
        unnamed.names = []
        #expect(throws: GazetteerError.self) { try GazetteerFormat.encode(cities: [unnamed], admin1s: [], sourceDate: 20261028) }
        var lowercase = Self.cities[0]
        lowercase.countryCode = "sa"
        #expect(throws: GazetteerError.self) { try GazetteerFormat.encode(cities: [lowercase], admin1s: [], sourceDate: 20261028) }
        var offEarth = Self.cities[0]
        offEarth.coordinate = Coordinate(latitude: 95, longitude: 0)
        #expect(throws: GazetteerError.self) { try GazetteerFormat.encode(cities: [offEarth], admin1s: [], sourceDate: 20261028) }
        #expect(throws: GazetteerError.self) { try GazetteerFormat.encode(cities: Self.cities, admin1s: [], sourceDate: 2026) }
    }

    @Test func anEmptyGazetteerAnswersNothing() throws {
        let gazetteer = try Gazetteer(data: GazetteerFormat.encode(cities: [], admin1s: [], sourceDate: 20261028))
        #expect(gazetteer.locate(Coordinate(latitude: 24.7, longitude: 46.7)) == GeoPlacement())
        #expect(gazetteer.cities(named: "riyadh", limit: 5).isEmpty)
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 24.7, longitude: 46.7)) == "Etc/GMT-3")
    }

    @Test func theChecksumIsCRC32() {
        #expect(Array("123456789".utf8).withUnsafeBytes { CRC32.checksum($0) } == 0xCBF4_3926)
        #expect([UInt8]().withUnsafeBytes { CRC32.checksum($0) } == 0)
    }

    @Test func cellKeysClampAtTheEdges() {
        #expect(GazetteerFormat.cellKey(latitude: 0, longitude: 0) == 90 * 360 + 180)
        #expect(GazetteerFormat.cellKey(latitude: -90, longitude: -180) == 0)
        #expect(GazetteerFormat.cellKey(latitude: 90, longitude: 180) == 179 * 360 + 359)
        #expect(GazetteerFormat.cellKey(latitude: -0.5, longitude: -0.5) == 89 * 360 + 179)
    }

    // MARK: Lookup on the fixture

    @Test func theGuardKeepsCitiesInTheNearestPlacesRegion() throws {
        let gazetteer = try Gazetteer(data: fixture())
        // Next to Al Majaz (Sharjah): Dubai is within its 36.9 km reach but in another region.
        let majaz = gazetteer.locate(Coordinate(latitude: 25.3260, longitude: 55.3850))
        #expect(majaz.city?.name == "Sharjah" && majaz.metro?.name == "Sharjah" && majaz.locality?.name == "Al Majaz")
        #expect(majaz.admin1?.geonameID == 292673 && majaz.countryCode == "AE" && majaz.timeZone == "Asia/Dubai")
        // Near ‘Irqah (a section, never a label): Riyadh by reach, Ad Dir‘īyah's 4.7 km reach doesn't cover it.
        let irqah = gazetteer.locate(Coordinate(latitude: 24.7000, longitude: 46.5850))
        #expect(irqah.city?.name == "Riyadh" && irqah.locality?.name == "‘Irqah")
        // At Ad Dir‘īyah itself: its own small reach wins on distance / reach.
        let diriyah = gazetteer.locate(Coordinate(latitude: 24.7520, longitude: 46.5390))
        #expect(diriyah.city?.geonameID == 110312 && diriyah.metro?.name == "Riyadh")
        #expect(diriyah.locality?.geonameID == 7_000_002)
        // Hatta has no known region, so any city of the country passes the guard; none reaches it.
        let hatta = gazetteer.locate(Coordinate(latitude: 24.8100, longitude: 56.1300))
        #expect(hatta.city?.name == "Hatta" && hatta.admin1 == nil && hatta.countryCode == "AE")
    }

    @Test func farFromAnyPlaceOnlyCountryAndZoneRemain() throws {
        let gazetteer = try Gazetteer(data: fixture())
        // 57 km from Rumāḩ: no city, but within 150 km for the country and 1,000 km for the zone.
        let desert = gazetteer.locate(Coordinate(latitude: 25.47, longitude: 46.60))
        #expect(desert.city == nil && desert.metro == nil && desert.locality == nil && desert.admin1 == nil)
        #expect(desert.countryCode == "SA" && desert.timeZone == "Asia/Riyadh")
        #expect(desert.nearestKm > 50 && desert.nearestKm < 60)
        #expect(desert.countryConfident)                     // the 3 nearest within 150 km are Saudi
        // Across the antimeridian the window wraps.
        let west = gazetteer.locate(Coordinate(latitude: -16.5, longitude: 179.995))
        #expect(west.city?.name == "Western Edge" && west.timeZone == "Pacific/Fiji" && west.countryCode == "FJ")
        #expect(gazetteer.locate(Coordinate(latitude: -17.2, longitude: -179.999)).city?.name == "Eastern Edge")
        // Mid-ocean: nothing within 1,000 km.
        let ocean = gazetteer.locate(Coordinate(latitude: 30, longitude: -40))
        #expect(ocean.city == nil && ocean.countryCode == nil && ocean.timeZone == nil && ocean.nearestKm > 1_000)
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 30, longitude: -40)) == "Etc/GMT+3")
        // (0, 0) is not a position.
        #expect(gazetteer.locate(Coordinate(latitude: 0, longitude: 0)) == GeoPlacement())
        // Places at the poles are found.
        #expect(gazetteer.locate(Coordinate(latitude: 89.98, longitude: 120)).city?.name == "North Pole Station")
        #expect(gazetteer.locate(Coordinate(latitude: -89.98, longitude: -60)).city?.name == "South Point")
    }

    @Test func namesMatchExactlyThenByPrefixByPopulation() throws {
        let gazetteer = try Gazetteer(data: fixture())
        #expect(gazetteer.cities(named: "diriyah", limit: 5).map(\.geonameID) == [110312, 7_000_002])
        #expect(gazetteer.cities(named: "ad diriyah", limit: 5).map(\.geonameID) == [110312, 7_000_002])
        #expect(gazetteer.cities(named: "Dubayy", limit: 5).map(\.geonameID) == [292223])
        #expect(gazetteer.cities(named: "dubai", limit: 5).map(\.geonameID) == [292223, 8469788])   // exact, then "dubai marina"
        #expect(gazetteer.cities(named: "dubai", limit: 1).map(\.geonameID) == [292223])
        #expect(gazetteer.cities(named: "irqah", limit: 5).map(\.geonameID) == [7_000_001])
        #expect(gazetteer.cities(named: "nowhere", limit: 5).isEmpty)
        #expect(gazetteer.admin1s(named: "ar riyad", limit: 5).map(\.geonameID) == [108411])
        gazetteer.releaseNameIndex()
        #expect(gazetteer.cities(named: "athina", limit: 5).map(\.geonameID) == [264371])
    }
}
