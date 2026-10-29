import Foundation
import LZGeo
import LZLibrary

/// The `asset.flags` bits.
struct AssetFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let favorite = AssetFlags(rawValue: 1)
    static let selfie = AssetFlags(rawValue: 2)
    static let likelyReceived = AssetFlags(rawValue: 4)
    static let burstMember = AssetFlags(rawValue: 8)
    static let hasAdjustments = AssetFlags(rawValue: 16)
    /// No creation date, before 2000, or more than a day in the future.
    static let dateUnreliable = AssetFlags(rawValue: 32)
}

/// One photo or video's indexed facts as column values (P0), and their fingerprint.
///
/// Times are whole unix seconds (rounded down, like ``LocalTime/wallSeconds(_:in:)``). The position is kept
/// only when it is valid. The fingerprint covers every fact except the modification date, so a re-read whose
/// facts are unchanged writes nothing.
struct AssetRecord: Sendable, Hashable {
    var localID: String
    /// 0 photo, 1 video.
    var kind: Int
    var subtypes: Int
    var flags: AssetFlags
    var created: Int64?
    var added: Int64?
    var modified: Int64?
    var adjusted: Int64?
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    var duration: Double
    var width: Int
    var height: Int
    /// 0 user library, 1 cloud shared, 2 synced, 3 unknown (diagnostics only).
    var source: Int
    var fingerprint: Int64

    /// 2000-01-01T00:00:00Z.
    static let reliableSince: Int64 = 946_684_800

    /// Nil for anything but a photo or a video (PhotoKit's audio and unknown media are not indexed).
    init?(_ asset: LibraryAsset, now: Date) {
        let facts = asset.facts
        switch facts.kind {
        case .photo: kind = 0
        case .video: kind = 1
        case .other: return nil
        }
        localID = asset.id
        subtypes = facts.subtypes.rawValue
        created = facts.creationDate.map(Self.seconds)
        added = facts.addedDate.map(Self.seconds)
        modified = facts.modificationDate.map(Self.seconds)
        adjusted = asset.adjustedDate.map(Self.seconds)
        if let coordinate = facts.coordinate, coordinate.isValid {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            accuracy = facts.horizontalAccuracy.flatMap { $0 >= 0 ? $0 : nil }
        }
        duration = facts.duration
        width = facts.pixelWidth
        height = facts.pixelHeight
        switch facts.source {
        case .userLibrary: source = 0
        case .cloudShared: source = 1
        case .synced: source = 2
        case .unknown: source = 3
        }
        var flags: AssetFlags = []
        if facts.isFavorite { flags.insert(.favorite) }
        if asset.isSelfie { flags.insert(.selfie) }
        if AssetClassifier.isLikelyReceived(facts) { flags.insert(.likelyReceived) }
        if facts.hasBurstIdentifier { flags.insert(.burstMember) }
        if asset.hasAdjustments { flags.insert(.hasAdjustments) }
        let tomorrow = Self.seconds(now) + 86_400
        if created.map({ $0 < Self.reliableSince || $0 > tomorrow }) ?? true { flags.insert(.dateUnreliable) }
        self.flags = flags
        fingerprint = 0
        fingerprint = computeFingerprint()
    }

    var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// FNV-1a (64-bit) over every indexed fact except the modification date.
    private func computeFingerprint() -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            var value = value
            for _ in 0..<8 {
                hash ^= value & 0xff
                hash &*= 0x0000_0100_0000_01b3
                value >>= 8
            }
        }
        func mix(_ value: Int64?) {
            if let value { mix(UInt64(1)); mix(UInt64(bitPattern: value)) } else { mix(UInt64(0)) }
        }
        func mix(_ value: Double?) {
            if let value { mix(UInt64(1)); mix(value.bitPattern) } else { mix(UInt64(0)) }
        }
        mix(Int64(kind))
        mix(Int64(subtypes))
        mix(Int64(flags.rawValue))
        mix(created)
        mix(added)
        mix(adjusted)
        mix(latitude)
        mix(longitude)
        mix(accuracy)
        mix(duration)
        mix(Int64(width))
        mix(Int64(height))
        mix(Int64(source))
        return Int64(bitPattern: hash)
    }
}
