import Foundation

/// A photo-type filter, applied only when the query states one (a bare "photos" never is). Kinds combine with OR,
/// flags with AND.
public struct MediaFilter: Sendable, Hashable, Codable {
    /// Empty means photos and videos.
    public var kinds: Set<MediaKind>
    public var flags: Set<MediaFlag>

    public init(kinds: Set<MediaKind> = [], flags: Set<MediaFlag> = []) {
        self.kinds = kinds
        self.flags = flags
    }

    public static let videos = MediaFilter(kinds: [.video])
    public static let photos = MediaFilter(kinds: [.photo])

    public var isEmpty: Bool { kinds.isEmpty && flags.isEmpty }

    /// Only "selfies" (photos, front camera): with the image model the word describes the photo instead.
    var isSelfiesOnly: Bool { flags == [.selfie] && kinds.subtracting([.photo]).isEmpty }

    /// The filter without the selfie flag; nil when nothing is left.
    var withoutSelfies: MediaFilter? {
        var filter = self
        filter.flags.remove(.selfie)
        if filter.flags.isEmpty, filter.kinds.subtracting([.photo]).isEmpty, flags.contains(.selfie) { return nil }
        return filter.isEmpty ? nil : filter
    }

    /// A screenshot or screen-recording filter lifts the ranking penalty those get otherwise.
    public var asksForScreenCaptures: Bool { !flags.isDisjoint(with: [.screenshot, .screenRecording]) }
}

public enum MediaKind: String, Sendable, Hashable, Codable, CaseIterable {
    case photo, video
}

public enum MediaFlag: String, Sendable, Hashable, Codable, CaseIterable {
    case screenshot, screenRecording, selfie, favorite, livePhoto, portrait, panorama, sloMo, timeLapse, burst
}
