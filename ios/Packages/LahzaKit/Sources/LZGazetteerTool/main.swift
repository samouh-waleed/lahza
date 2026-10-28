// lz-gazetteer: builds LZGeo's offline place list (cities15000.lzgz) from a GeoNames dump.
//
//   swift run --package-path Packages/LahzaKit lz-gazetteer --cities <cities15000.txt> --admin1 <admin1CodesASCII.txt> \
//       --aliases Tools/gazetteer/aliases-en.tsv --source-date 20261028 --out <file.lzgz>
//
// The output depends only on the inputs: the same files give the same bytes (the SHA-256 is printed).
// See ios/Tools/gazetteer/README.md for the source and licence.
import CryptoKit
import Foundation
import LZGeo

struct Failure: Error, CustomStringConvertible {
    var description: String
}

/// GeoNames ids, names and the curated alias file, read into ``GazetteerFormat`` sources.
enum GeoNames {
    /// Historical, abandoned and destroyed places.
    static let droppedFeatureCodes: Set<Substring> = ["PPLH", "PPLQ", "PPLW"]
    /// Zone ids an older dump may use that this Mac's zone database doesn't know.
    static let zoneRenames = ["Europe/Kiev": "Europe/Kyiv"]
    static let maxAutomaticAliases = 8

    static func kind(_ featureCode: Substring) -> GazetteerCity.Kind {
        switch featureCode {
        case "PPLC": .capital
        case "PPLA", "PPLA2", "PPLA3", "PPLA4", "PPLA5": .seat
        case "PPLX": .section
        default: .city
        }
    }

    static func lines(_ path: String) throws -> [Substring] {
        guard let data = FileManager.default.contents(atPath: path) else { throw Failure(description: "can't read \(path)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// admin1CodesASCII.txt: `CC.code ⇥ name ⇥ ascii name ⇥ geonameid`.
    static func admin1s(_ path: String) throws -> [GazetteerFormat.Admin1Source] {
        try lines(path).compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 4, let dot = columns[0].firstIndex(of: "."), let id = Int32(columns[3]) else { return nil }
            return GazetteerFormat.Admin1Source(countryCode: String(columns[0][..<dot]), code: String(columns[0][columns[0].index(after: dot)...]),
                                                geonameID: id, name: String(columns[1]))
        }
    }

    /// aliases-en.tsv: `geonameid ⇥ alias|alias ⇥ display name`; `#` starts a comment line.
    static func curatedAliases(_ path: String) throws -> [Int32: (aliases: [String], name: String?)] {
        var aliases: [Int32: (aliases: [String], name: String?)] = [:]
        for line in try lines(path) where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2, let id = Int32(columns[0]), aliases[id] == nil else { throw Failure(description: "bad alias row: \(line)") }
            aliases[id] = (columns[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                           columns.count >= 3 ? String(columns[2]) : nil)
        }
        return aliases
    }

    /// An alternate name worth answering to: ASCII, 3–30 characters, starting upper-case, not all
    /// capitals, and only letters, spaces, hyphens, apostrophes and full stops.
    static func isUsableAlternate(_ name: Substring) -> Bool {
        let bytes = Array(name.utf8)
        guard (3...30).contains(bytes.count), let first = bytes.first, (65...90).contains(first),
              bytes.contains(where: { (97...122).contains($0) }) else { return false }
        return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || $0 == 32 || $0 == 45 || $0 == 39 || $0 == 46 }
    }

    struct Parsed {
        var cities: [GazetteerFormat.CitySource] = []
        var skipped = 0
        var dropped = 0
        var automaticAliases = 0
        var curatedAliases = 0
        var citiesWithAliases = 0
        var renamedZones = 0
    }

    /// cities15000.txt: GeoNames' 19 tab-separated columns.
    static func cities(_ path: String, curated: [Int32: (aliases: [String], name: String?)]) throws -> Parsed {
        var parsed = Parsed()
        var knownZones: [String: String] = [:]
        for line in try lines(path) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 19, let id = Int32(columns[0]), let latitude = Double(columns[4]), let longitude = Double(columns[5]),
                  let population = Int(columns[14].isEmpty ? "0" : columns[14]), !columns[1].isEmpty, columns[8].utf8.count == 2,
                  !columns[17].isEmpty else {
                parsed.skipped += 1
                continue
            }
            if droppedFeatureCodes.contains(columns[7]) {
                parsed.dropped += 1
                continue
            }
            let rawZone = String(columns[17])
            let zone: String
            if let known = knownZones[rawZone] {
                zone = known
            } else if TimeZone(identifier: rawZone) != nil {
                zone = rawZone
            } else if let renamed = zoneRenames[rawZone], TimeZone(identifier: renamed) != nil {
                zone = renamed
            } else {
                throw Failure(description: "unknown time zone \(rawZone) for \(id)")
            }
            knownZones[rawZone] = zone
            if zone != rawZone { parsed.renamedZones += 1 }

            let kind = kind(columns[7])
            let name = String(columns[1]), ascii = String(columns[2])
            var names = [name]
            var folded: Set<String> = [PlaceNames.fold(name)]
            func add(_ candidate: String) -> Bool {
                let key = PlaceNames.fold(candidate)
                guard !key.isEmpty, folded.insert(key).inserted else { return false }
                names.append(candidate)
                return true
            }
            _ = add(ascii)
            var aliasCount = 0
            if population >= 100_000 || kind == .capital {
                var automatic = 0
                for alternate in columns[3].split(separator: ",") where automatic < maxAutomaticAliases && isUsableAlternate(alternate) {
                    if add(String(alternate)) { automatic += 1 }
                }
                parsed.automaticAliases += automatic
                aliasCount += automatic
            }
            if let entry = curated[id] {
                if let expected = entry.name, expected != name, expected != ascii {
                    throw Failure(description: "aliases-en.tsv: \(id) is \(name), not \(expected)")
                }
                let added = entry.aliases.filter { add($0) }.count
                parsed.curatedAliases += added
                aliasCount += added
            }
            if aliasCount > 0 { parsed.citiesWithAliases += 1 }
            parsed.cities.append(GazetteerFormat.CitySource(
                geonameID: id, names: names, coordinate: Coordinate(latitude: latitude, longitude: longitude), population: population,
                kind: kind, countryCode: String(columns[8]), admin1Code: columns[10].isEmpty ? nil : String(columns[10]), timeZone: zone))
        }
        let ids = Set(parsed.cities.map(\.geonameID))
        if let missing = curated.keys.sorted().first(where: { !ids.contains($0) }) {
            throw Failure(description: "aliases-en.tsv: \(missing) is not in the dump")
        }
        return parsed
    }
}

/// SplitMix64, so the round-trip sample is the same on every run.
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

/// Re-reads the file and compares `count` random cities with their sources.
func checkRoundTrip(_ data: Data, sources: [GazetteerFormat.CitySource], admin1s: [GazetteerFormat.Admin1Source], count: Int) throws {
    let gazetteer = try Gazetteer(data: data, verifyChecksum: true)
    let regions = Dictionary(admin1s.map { ("\($0.countryCode).\($0.code)", $0.geonameID) }, uniquingKeysWith: { first, _ in first })
    var generator = SeededGenerator(state: 15_000)
    for _ in 0..<min(count, sources.count) {
        let source = sources[Int.random(in: 0..<sources.count, using: &generator)]
        guard let city = gazetteer.city(geonameID: source.geonameID) else { throw Failure(description: "round trip: \(source.geonameID) missing") }
        let expectedRegion = source.admin1Code.flatMap { regions["\(source.countryCode).\($0)"] }
        let matches = [city.name] + city.alternateNames == source.names
            && abs(city.coordinate.latitude - source.coordinate.latitude) <= 0.000_005
            && abs(city.coordinate.longitude - source.coordinate.longitude) <= 0.000_005
            && city.population == source.population && city.kind == source.kind && city.countryCode == source.countryCode
            && city.admin1?.geonameID == expectedRegion && city.timeZone == source.timeZone
        guard matches else { throw Failure(description: "round trip: \(source.geonameID) differs") }
    }
}

func run(_ arguments: [String]) throws {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--"), index + 1 < arguments.count else { throw Failure(description: "unexpected argument \(key)") }
        options[String(key.dropFirst(2))] = arguments[index + 1]
        index += 2
    }
    guard let citiesPath = options["cities"], let admin1Path = options["admin1"], let aliasesPath = options["aliases"],
          let outPath = options["out"], let sourceDate = options["source-date"].flatMap({ Int($0) }) else {
        throw Failure(description: "usage: lz-gazetteer --cities <file> --admin1 <file> --aliases <file> --source-date yyyymmdd --out <file>")
    }

    let admin1s = try GeoNames.admin1s(admin1Path)
    let parsed = try GeoNames.cities(citiesPath, curated: try GeoNames.curatedAliases(aliasesPath))
    let data: Data
    do {
        data = try GazetteerFormat.encode(cities: parsed.cities, admin1s: admin1s, sourceDate: sourceDate)
    } catch {
        throw Failure(description: "encode: \(error)")
    }
    if data.count > 2_000_000 { throw Failure(description: "\(data.count) B is over the 2,000,000 B limit") }
    try checkRoundTrip(data, sources: parsed.cities, admin1s: admin1s, count: 1_000)

    print("cities \(parsed.cities.count) (skipped \(parsed.skipped) malformed, dropped \(parsed.dropped) historical); "
        + "zones renamed \(parsed.renamedZones)")
    print("aliases \(parsed.automaticAliases) automatic + \(parsed.curatedAliases) curated on \(parsed.citiesWithAliases) cities")
    let names = ["header", "cells", "cities", "admin1", "countries", "zones", "strings"]
    let offsets = [0] + (0..<6).map { offset in data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 28 + offset * 4, as: UInt32.self))) } }
    for (position, name) in names.enumerated() {
        let end = position + 1 < offsets.count ? offsets[position + 1] : data.count
        print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(end - offsets[position]) B")
    }
    print("total \(data.count) B")
    if data.count > 1_800_000 { print("warning: over the 1,800,000 B budget") }
    print("sha256 \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
    try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    print("wrote \(outPath)")
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("lz-gazetteer: \(error)\n".utf8))
    exit(1)
}
