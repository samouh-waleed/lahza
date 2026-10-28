import Foundation
import Synchronization
import Testing
@testable import LZGeo

/// Loaded once for every test in the file.
private let bundled = Result { try Gazetteer.bundled() }

/// The committed GeoNames resource: invariants, exactness of the nearest search, the verified lookup
/// table (spec §5.4) and place names.
@Suite struct GazetteerTests {
    // MARK: Invariants

    @Test func theResourceIsTheExpectedDump() throws {
        let url = try #require(Gazetteer.bundledURL)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= 1_800_000)
        // Checksum, every offset, cell order and record field are validated on load.
        let gazetteer = try Gazetteer(data: Data(contentsOf: url), verifyChecksum: true)
        #expect(gazetteer.cityCount == 34_164)
        #expect(gazetteer.sourceDate == 20261028)
        let cities = gazetteer.allCities()
        #expect(Set(cities.map(\.geonameID)).count == cities.count)
        let zones = Set(cities.map(\.timeZone))
        #expect(zones.count == 356)
        #expect(zones.allSatisfy { TimeZone(identifier: $0) != nil })
        #expect(Set(cities.map(\.countryCode)).count == 244)
        #expect(cities.filter { $0.kind == .capital }.count >= 200)
        #expect(cities.allSatisfy { !$0.name.isEmpty && $0.population >= 0 })
    }

    @Test func theNearestPlaceMatchesBruteForce() throws {
        let gazetteer = try bundled.get()
        let cities = gazetteer.allCities()
        var generator = SeededGenerator(state: 0x1A2B_3C4D)
        var points: [Coordinate] = []
        for index in 0..<10_000 {
            if index.isMultiple(of: 2) {
                // Anywhere on Earth (uniform on the sphere), so ocean points exercise the widening search.
                let z = Double.random(in: -1...1, using: &generator)
                points.append(Coordinate(latitude: asin(z) * 180 / .pi, longitude: Double.random(in: -180..<180, using: &generator)))
            } else {
                // Near a random place, where cells are dense.
                let near = cities[Int.random(in: 0..<cities.count, using: &generator)].coordinate
                points.append(Coordinate(latitude: max(-90, min(90, near.latitude + Double.random(in: -0.5...0.5, using: &generator))),
                                         longitude: wrap(near.longitude + Double.random(in: -0.5...0.5, using: &generator))))
            }
        }
        // Brute force over unit vectors (the nearest by great circle has the largest dot product), split across cores.
        let vectors = cities.flatMap { city -> [Double] in
            let v = unitVector(city.coordinate)
            return [v.x, v.y, v.z]
        }
        let samples = points, chunks = 16, size = (samples.count + chunks - 1) / chunks
        let mismatches = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var local = 0
            vectors.withUnsafeBufferPointer { vectors in
                for point in samples[min(samples.count, chunk * size)..<min(samples.count, (chunk + 1) * size)] where point.isValid {
                    let p = unitVector(point)
                    var best = -2.0, bestIndex = 0, offset = 0
                    while offset < vectors.count {
                        let dot = p.x * vectors[offset] + p.y * vectors[offset + 1] + p.z * vectors[offset + 2]
                        if dot > best { best = dot; bestIndex = offset / 3 }
                        offset += 3
                    }
                    let expected = point.distance(to: cities[bestIndex].coordinate) / 1_000
                    if abs(gazetteer.locate(point).nearestKm - expected) > 1e-6 { local += 1 }
                }
            }
            mismatches.withLock { $0 += local }
        }
        #expect(mismatches.withLock { $0 } == 0)
    }

    @Test func everyPlaceIsItsOwnNearest() throws {
        let gazetteer = try bundled.get()
        let cities = gazetteer.allCities()
        let positions = Dictionary(grouping: cities, by: \.coordinate)
        for city in cities {
            let nearest = try #require(gazetteer.nearest(to: city.coordinate))
            #expect(nearest.km == 0)
            // Places at exactly the same position may answer for each other.
            if nearest.city.geonameID != city.geonameID { #expect((positions[city.coordinate]?.count ?? 0) > 1) }
        }
    }

    @Test func noCityOf300kIsLabelledAsAnother() throws {
        let gazetteer = try bundled.get()
        let large = gazetteer.allCities().filter { $0.population >= 300_000 && $0.kind != .section }
        #expect(large.count > 1_000)
        let absorbed = large.filter { gazetteer.locate($0.coordinate).city?.geonameID != $0.geonameID }.map(\.name)
        #expect(absorbed.isEmpty)
    }

    // MARK: The verified table

    struct Golden: Sendable, CustomTestStringConvertible {
        var label: String
        var latitude: Double
        var longitude: Double
        var city: Int32?
        var metro: Int32?
        var locality: Int32?
        var country: String?
        var zone: String?
        var testDescription: String { label }
    }

    static let riyadh: Int32 = 108410, dubai: Int32 = 292223, sharjah: Int32 = 292672, athens: Int32 = 264371
    static let london: Int32 = 2643743, sydney: Int32 = 2147714

    static let goldens: [Golden] = [
        Golden(label: "Al-Nakheel Park", latitude: 24.7590, longitude: 46.6440, city: riyadh, metro: riyadh, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "At-Turaif, Diriyah", latitude: 24.7339, longitude: 46.5753, city: riyadh, metro: riyadh, locality: 110312, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Riyadh airport", latitude: 24.9576, longitude: 46.6988, city: riyadh, metro: riyadh, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Kingdom Centre", latitude: 24.7114, longitude: 46.6744, city: riyadh, metro: riyadh, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Dubai Marina", latitude: 25.0805, longitude: 55.1403, city: dubai, metro: dubai, locality: 8469788, country: "AE", zone: "Asia/Dubai"),
        Golden(label: "Burj Khalifa", latitude: 25.1972, longitude: 55.2744, city: dubai, metro: dubai, locality: 13118432, country: "AE", zone: "Asia/Dubai"),
        Golden(label: "Al Majaz, Sharjah", latitude: 25.3260, longitude: 55.3850, city: sharjah, metro: sharjah, locality: 8476509, country: "AE", zone: "Asia/Dubai"),
        Golden(label: "Acropolis", latitude: 37.9715, longitude: 23.7257, city: athens, metro: athens, locality: 263312, country: "GR", zone: "Europe/Athens"),
        Golden(label: "Oia", latitude: 36.4618, longitude: 25.3753, city: nil, metro: nil, locality: nil, country: "GR", zone: "Europe/Athens"),
        Golden(label: "Fira", latitude: 36.4167, longitude: 25.4318, city: nil, metro: nil, locality: nil, country: "GR", zone: "Europe/Athens"),
        Golden(label: "Mykonos", latitude: 37.4467, longitude: 25.3289, city: nil, metro: nil, locality: nil, country: "GR", zone: "Europe/Athens"),
        Golden(label: "Hyde Park", latitude: 51.5073, longitude: -0.1657, city: london, metro: london, locality: 6545243, country: "GB", zone: "Europe/London"),
        Golden(label: "Tower Bridge", latitude: 51.5055, longitude: -0.0754, city: london, metro: london, locality: 6690595, country: "GB", zone: "Europe/London"),
        Golden(label: "Bondi", latitude: -33.8915, longitude: 151.2767, city: sydney, metro: sydney, locality: 2208285, country: "AU", zone: "Australia/Sydney"),
        Golden(label: "Opera House", latitude: -33.8568, longitude: 151.2153, city: sydney, metro: sydney, locality: 6619280, country: "AU", zone: "Australia/Sydney"),
        Golden(label: "Oakland", latitude: 37.8044, longitude: -122.2712, city: 5378538, metro: 5391959, locality: 5322737, country: "US", zone: "America/Los_Angeles"),
        Golden(label: "Desert camp", latitude: 25.47, longitude: 46.60, city: nil, metro: nil, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Jeddah", latitude: 21.5433, longitude: 39.1728, city: 105343, metro: 105343, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Makkah", latitude: 21.4225, longitude: 39.8262, city: 104515, metro: 104515, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "AlUla", latitude: 26.6084, longitude: 37.9232, city: 108841, metro: 108841, locality: nil, country: "SA", zone: "Asia/Riyadh"),
        Golden(label: "Heraklion", latitude: 35.3387, longitude: 25.1442, city: 261745, metro: 261745, locality: nil, country: "GR", zone: "Europe/Athens"),
        Golden(label: "Times Square", latitude: 40.7580, longitude: -73.9855, city: 5128581, metro: 5128581, locality: 6930378, country: "US", zone: "America/New_York"),
        Golden(label: "Jersey City (New York excluded by the guard)", latitude: 40.7178, longitude: -74.0431, city: 5099836, metro: 5099836,
               locality: 5099133, country: "US", zone: "America/New_York"),
        Golden(label: "Suva", latitude: -18.1416, longitude: 178.4419, city: 2198148, metro: 2198148, locality: 2204575, country: "FJ", zone: "Pacific/Fiji"),
        Golden(label: "Taveuni, east of 180° (nearest across it)", latitude: -16.80, longitude: -179.97, city: nil, metro: nil, locality: nil,
               country: "FJ", zone: "Pacific/Fiji"),
        Golden(label: "Mid-Atlantic", latitude: 30, longitude: -40, city: nil, metro: nil, locality: nil, country: nil, zone: nil),
    ]

    @Test(arguments: goldens)
    func theVerifiedTable(_ golden: Golden) throws {
        let placement = try bundled.get().locate(Coordinate(latitude: golden.latitude, longitude: golden.longitude))
        #expect(placement.city?.geonameID == golden.city)
        #expect(placement.metro?.geonameID == golden.metro)
        #expect(placement.locality?.geonameID == golden.locality)
        #expect(placement.countryCode == golden.country)
        #expect(placement.timeZone == golden.zone)
    }

    @Test func distancesRegionsAndConfidence() throws {
        let gazetteer = try bundled.get()
        let nakheel = gazetteer.locate(Coordinate(latitude: 24.7590, longitude: 46.6440))
        #expect(abs(nakheel.nearestKm - 9.36) < 0.01)                                          // ‘Irqah, a section
        #expect(nakheel.city?.name == "Riyadh" && nakheel.admin1?.geonameID == 108411 && nakheel.countryConfident)
        #expect(abs(gazetteer.locate(Coordinate(latitude: 24.9576, longitude: 46.6988)).nearestKm - 28.0) < 0.05)   // Ad Dir‘īyah
        let desert = gazetteer.locate(Coordinate(latitude: 25.47, longitude: 46.60))
        #expect(abs(desert.nearestKm - 57.56) < 0.01 && desert.admin1 == nil && desert.countryConfident)
        let mykonos = gazetteer.locate(Coordinate(latitude: 37.4467, longitude: 25.3289))
        #expect(abs(mykonos.nearestKm - 124.66) < 0.01 && !mykonos.countryConfident)          // Chios; Turkey is close too
        #expect(abs(gazetteer.locate(Coordinate(latitude: -16.80, longitude: -179.97)).nearestKm - 81.8) < 0.05)   // Labasa
        #expect(gazetteer.locate(Coordinate(latitude: 0, longitude: 0)) == GeoPlacement())
    }

    @Test func zonesComeFromTheNearestPlaceOrTheLongitude() throws {
        let gazetteer = try bundled.get()
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 24.7590, longitude: 46.6440)) == "Asia/Riyadh")
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 51.5073, longitude: -0.1657)) == "Europe/London")
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 36.4618, longitude: 25.3753)) == "Europe/Athens")
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: 30, longitude: -40)) == "Etc/GMT+3")
        #expect(gazetteer.timeZoneIdentifier(at: Coordinate(latitude: -48.88, longitude: -123.39)) == "Etc/GMT+8")   // Point Nemo
    }

    // MARK: Names

    @Test func placeNamesResolve() throws {
        let gazetteer = try bundled.get()
        func first(_ name: String) -> Int32? { gazetteer.cities(named: name, limit: 5).first?.geonameID }
        #expect(first("mecca") == 104515)
        #expect(first("Makkah") == 104515)
        #expect(first("heraklion") == 261745)
        #expect(first("diriyah") == 110312)
        #expect(first("ad diriyah") == 110312)
        #expect(first("Ad Dir'iyah") == 110312)
        #expect(first("riyadh") == Self.riyadh)
        #expect(first("athens") == Self.athens)
        #expect(gazetteer.cities(named: "athens", limit: 5).first?.countryCode == "GR")
        #expect(gazetteer.cities(named: "athens", limit: 5).count > 1)                       // Athens, Georgia follows
        #expect(first("alula") == 108841)
        #expect(first("medina") == 109223)
        #expect(first("dubai") == Self.dubai)
        #expect(first("riya") == Self.riyadh)                                                 // prefix
        #expect(gazetteer.cities(named: "zzzz qqqq", limit: 5).isEmpty)
        #expect(gazetteer.cities(named: "riyadh", limit: 0).isEmpty)
        #expect(gazetteer.admin1s(named: "riyadh region", limit: 3).first?.geonameID == 108411)
        #expect(gazetteer.admin1s(named: "eastern province", limit: 3).first?.countryCode == "SA")
        #expect(gazetteer.admin1s(named: "dubai", limit: 3).first?.countryCode == "AE")
        #expect(gazetteer.city(geonameID: Self.riyadh)?.name == "Riyadh")
        #expect(gazetteer.city(geonameID: Self.riyadh)?.admin1?.name == "Riyadh Region")
        #expect(gazetteer.city(geonameID: 1) == nil)
        gazetteer.releaseNameIndex()
        #expect(first("heraklion") == 261745)
    }

    // MARK: Helpers

    private nonisolated func unitVector(_ c: Coordinate) -> (x: Double, y: Double, z: Double) {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    private func wrap(_ longitude: Double) -> Double {
        longitude >= 180 ? longitude - 360 : longitude < -180 ? longitude + 360 : longitude
    }
}

/// SplitMix64, so the random points are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
