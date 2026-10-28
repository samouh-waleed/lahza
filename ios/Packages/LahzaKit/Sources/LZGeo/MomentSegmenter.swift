import Foundation

/// The moment rule (P0b): photos and videos in time order form one moment until a gap of more than
/// 90 minutes, the 04:00 local day break, or a jump of more than 1 km from the moment's last located
/// item. Items without GPS never split a moment.
///
/// Each item carries its own moment day, so a trip that crosses zones breaks each photo's day at
/// 04:00 in the zone it was taken in, while gaps are measured in UTC.
public enum MomentSegmenter {
    /// A new moment after more than this many seconds…
    public static let gap: Int64 = 90 * 60
    /// …or more than this many metres from the moment's last located item.
    public static let jump: Double = 1_000

    public struct Item: Sendable, Hashable {
        /// UTC seconds.
        public var utc: Int64
        /// The item's ``LocalTime/momentDay(wallSeconds:)`` in its own zone.
        public var day: Int32
        /// Nil when the item has no usable GPS position.
        public var coordinate: Coordinate?

        public init(utc: Int64, day: Int32, coordinate: Coordinate? = nil) {
            self.utc = utc
            self.day = day
            self.coordinate = coordinate
        }
    }

    /// Why a moment starts, checked in this order.
    public enum Split: Sendable, Hashable {
        case gap, dayBreak, jump
    }

    /// The start index of every moment after the first, with the reason. `items` must be sorted by `utc`.
    public static func boundaries(_ items: [Item]) -> [(index: Int, reason: Split)] {
        var boundaries: [(index: Int, reason: Split)] = []
        guard var previous = items.first else { return boundaries }
        var lastPlace = previous.coordinate
        for index in items.indices.dropFirst() {
            let item = items[index]
            var reason: Split?
            if item.utc - previous.utc > gap {
                reason = .gap
            } else if item.day != previous.day {
                reason = .dayBreak
            } else if let place = item.coordinate, let lastPlace, place.distance(to: lastPlace) > jump {
                reason = .jump
            }
            if let reason {
                boundaries.append((index, reason))
                lastPlace = nil
            }
            if let place = item.coordinate { lastPlace = place }
            previous = item
        }
        return boundaries
    }
}
