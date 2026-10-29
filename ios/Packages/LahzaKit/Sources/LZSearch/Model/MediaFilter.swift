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

    /// A screenshot or screen-recording filter lifts the ranking penalty those get otherwise.
    public var asksForScreenCaptures: Bool { !flags.isDisjoint(with: [.screenshot, .screenRecording]) }
}

public enum MediaKind: String, Sendable, Hashable, Codable, CaseIterable {
    case photo, video
}

public enum MediaFlag: String, Sendable, Hashable, Codable, CaseIterable {
    case screenshot, screenRecording, selfie, favorite, livePhoto, portrait, panorama, sloMo, timeLapse, burst
}
