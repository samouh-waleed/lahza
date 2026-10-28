import Foundation

/// Base32 geohash cells: precision 6 is about 1.2 × 0.6 km and precision 7 about 153 × 153 m at the
/// equator. Used to cache gazetteer lookups and group photos into ~150 m place cells.
public enum GeoHash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz".utf8)
    private static let values: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    /// The cell holding `c`, `precision` characters long.
    public static func encode(_ c: Coordinate, precision: Int) -> String {
        var latitude = (-90.0, 90.0), longitude = (-180.0, 180.0)
        var output: [UInt8] = []
        output.reserveCapacity(precision)
        var bits = 0, value = 0, evenBit = true
        while output.count < precision {
            if evenBit {
                let mid = (longitude.0 + longitude.1) / 2
                if c.longitude >= mid { value = value << 1 | 1; longitude.0 = mid } else { value <<= 1; longitude.1 = mid }
            } else {
                let mid = (latitude.0 + latitude.1) / 2
                if c.latitude >= mid { value = value << 1 | 1; latitude.0 = mid } else { value <<= 1; latitude.1 = mid }
            }
            evenBit.toggle()
            bits += 1
            if bits == 5 {
                output.append(alphabet[value])
                bits = 0
                value = 0
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The cell's centre. Decoding stops at the first character outside the alphabet.
    public static func center(_ hash: String) -> Coordinate {
        let box = bounds(hash)
        return Coordinate(latitude: (box.latitude.lowerBound + box.latitude.upperBound) / 2,
                          longitude: (box.longitude.lowerBound + box.longitude.upperBound) / 2)
    }

    /// The 8 surrounding cells of the same precision, wrapping at ±180° (fewer at the poles, where
    /// there is no cell beyond).
    public static func neighbours(_ hash: String) -> [String] {
        let box = bounds(hash)
        let precision = hash.utf8.prefix { values[$0] != nil }.count
        let height = box.latitude.upperBound - box.latitude.lowerBound
        let width = box.longitude.upperBound - box.longitude.lowerBound
        let centre = center(hash)
        var result: [String] = []
        for dy in [1.0, 0, -1] {
            let latitude = centre.latitude + dy * height
            guard latitude > -90, latitude < 90 else { continue }
            for dx in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                var longitude = centre.longitude + dx * width
                if longitude >= 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
                let cell = encode(Coordinate(latitude: latitude, longitude: longitude), precision: precision)
                if cell != hash, !result.contains(cell) { result.append(cell) }
            }
        }
        return result
    }

    static func bounds(_ hash: String) -> (latitude: ClosedRange<Double>, longitude: ClosedRange<Double>) {
        var latitude = (-90.0, 90.0), longitude = (-180.0, 180.0)
        var evenBit = true
        for character in hash.utf8 {
            guard let value = values[character] else { break }
            for shift in stride(from: 4, through: 0, by: -1) {
                let bit = (value >> shift) & 1
                if evenBit {
                    let mid = (longitude.0 + longitude.1) / 2
                    if bit == 1 { longitude.0 = mid } else { longitude.1 = mid }
                } else {
                    let mid = (latitude.0 + latitude.1) / 2
                    if bit == 1 { latitude.0 = mid } else { latitude.1 = mid }
                }
                evenBit.toggle()
            }
        }
        return (latitude.0...latitude.1, longitude.0...longitude.1)
    }
}
