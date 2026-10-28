#if DEBUG
import Foundation
import LZGeo

/// One synthetic photo or video of a ``SeedScenario``: what `lz-seed` writes into a file's metadata
/// and what ``FakeLibraryReader`` serves as a ``LibraryAsset``.
public struct SeedItem: Sendable, Hashable {
    /// What kind of file it is, and so which metadata it carries.
    public enum Media: String, Sendable, Hashable, Codable, CaseIterable {
        /// A camera JPEG: EXIF date and offset, Apple make and model, GPS when located.
        case photo
        /// A 3 s H.264 QuickTime movie: creation date with offset, ISO 6709 position when located.
        case video
        /// A PNG screenshot: EXIF UserComment "Screenshot" and a date; no GPS.
        case screenshot
        /// Saved from a chat: a 1600×1200 JPEG with a date, no make and no GPS.
        case received
        /// A JPEG with an EXIF date and nothing else.
        case dateOnly
        /// No date at all. Fake reader only: PhotoKit dates every import.
        case undated
    }

    /// What the index is meant to do for an item without GPS; the scenario's invariants hold to it.
    public enum Borrowing: String, Sendable, Hashable, Codable {
        /// Nothing (it is located, or nothing is intended).
        case none
        /// Within 10 minutes of a located item on the same moment day: takes that position.
        case moment
        /// More than 2 hours from any located item: too far to borrow from its moment.
        case beyondMoment
        /// More than 90 minutes after every located item of its moment day, and before none.
        case sameDay
        /// At least 12 hours from any located item: no time zone to borrow either.
        case noZone
    }

    /// 1… in capture order (undated items last); shown on the artwork.
    public var number: Int
    public var tag: SeedScenario.Tag
    public var media: Media
    /// The artwork's title: the place name, or what the item is ("Screenshot").
    public var title: String
    /// Capture time in UTC seconds; nil for undated items.
    public var utc: Int64?
    /// IANA zone of the capture's local time.
    public var zone: String
    public var coordinate: Coordinate?
    /// Taken with the front camera (EXIF lens model); meant for the Selfies album.
    public var isSelfie: Bool
    public var borrowing: Borrowing
    /// The local weekday the scenario says it falls on (1 = Sunday … 7 = Saturday), where it says one.
    public var weekday: Int?

    /// The fake reader's local identifier ("seed/0142").
    public var id: String { "seed/" + Self.padded(number) }
    /// The file `lz-seed` writes ("seed-0142.jpg").
    public var fileName: String {
        let ext = switch media {
        case .video: "mov"
        case .screenshot: "png"
        default: "jpg"
        }
        return "seed-\(Self.padded(number)).\(ext)"
    }

    /// Imported through PhotoKit (every item but the undated ones).
    public var isInPhotoKit: Bool { media != .undated }
    public var isVideo: Bool { media == .video }
    public var isLocated: Bool { coordinate != nil }
    public var date: Date? { utc.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var timeZone: TimeZone { TimeZone(identifier: zone) ?? .gmt }
    /// UTC seconds plus the zone's offset then.
    public var wallSeconds: Int64? { date.map { LocalTime.wallSeconds($0, in: timeZone) } }
    /// The 04:00-to-04:00 local day.
    public var momentDay: Int32? { wallSeconds.map { LocalTime.momentDay(wallSeconds: $0) } }
    /// The local calendar day (midnight to midnight).
    public var civilDay: Int32? { wallSeconds.map { Self.days($0) } }
    /// The zone's offset at capture, in seconds.
    public var offsetSeconds: Int? { date.map { timeZone.secondsFromGMT(for: $0) } }

    public var pixelWidth: Int {
        switch media {
        case .video: 960
        case .screenshot: 1290
        case .received: 1600
        case .photo, .dateOnly, .undated: 2016
        }
    }

    public var pixelHeight: Int {
        switch media {
        case .video: 540
        case .screenshot: 2796
        case .received: 1200
        case .photo, .dateOnly, .undated: 1512
        }
    }

    /// Seconds (videos).
    public var duration: TimeInterval { isVideo ? 3 : 0 }

    /// The asset ``FakeLibraryReader`` serves. Added dates follow the camera (a couple of seconds after
    /// capture, so received photos pass the shape rule); PhotoKit import resets them to the import time.
    public var asset: LibraryAsset {
        let added = date.map { $0.addingTimeInterval(duration + 2) } ?? SeedScenario.undatedAddedDate
        let format: AssetFacts.ImageFormat? = switch media {
        case .video: nil
        case .screenshot: .png
        default: .jpeg
        }
        let facts = AssetFacts(kind: isVideo ? .video : .photo, subtypes: media == .screenshot ? .screenshot : [], format: format,
                               creationDate: date, modificationDate: added, addedDate: added, coordinate: coordinate,
                               horizontalAccuracy: coordinate == nil ? nil : SeedScenario.horizontalAccuracy, duration: duration,
                               pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return LibraryAsset(id: id, facts: facts, isSelfie: isSelfie)
    }

    /// Local wall time as "2025-06-14T17:20:00" (empty when undated).
    public var localDateTime: String {
        guard let wall = wallSeconds else { return "" }
        let (year, month, day) = LocalTime.civil(day: Self.days(wall))
        let second = Int(wall - Int64(Self.days(wall)) * 86_400)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, second / 3600, second / 60 % 60, second % 60)
    }

    static func padded(_ number: Int) -> String { String(format: "%04d", number) }

    /// Whole days since 1970-01-01 at a wall time (floored).
    static func days(_ wall: Int64) -> Int32 { Int32((wall >= 0 ? wall : wall - 86_399) / 86_400) }
}
#endif
