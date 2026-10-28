#if DEBUG
import CoreGraphics
import Foundation
import LZGeo

/// The picture of a seed item: a gradient coloured by its place and darkened at night, the place
/// name, "Sat 14 Jun 2025 · 17:20", "seed 0142 · 24.7590, 46.6440" and badges for its tag and kind.
/// `lz-seed` draws the files with it and ``FakeAssetImageProvider`` the thumbnails, so a photo in
/// the Simulator and its fake twin look the same.
public enum SeedArtwork {
    /// `item` drawn at `width` × `height` pixels (its own size by default).
    public static func image(for item: SeedItem, width: Int? = nil, height: Int? = nil) -> CGImage? {
        artwork(for: item).image(width: width ?? item.pixelWidth, height: height ?? item.pixelHeight)
    }

    /// Draws `item` filling `width` × `height` of `context`; `progress` (0…1) adds a playback bar (video frames).
    public static func draw(_ item: SeedItem, in context: CGContext, width: CGFloat, height: CGFloat, progress: Double? = nil) {
        artwork(for: item).draw(in: context, width: width, height: height, progress: progress)
    }

    static func artwork(for item: SeedItem) -> PlaceholderArtwork {
        var badges: [String] = []
        switch item.media {
        case .video: badges.append("VIDEO")
        case .screenshot: badges.append("SCREENSHOT")
        case .received: badges.append("RECEIVED")
        case .undated: badges.append("UNDATED")
        case .photo, .dateOnly: break
        }
        if item.isSelfie { badges.append("SELFIE") }
        if !item.isLocated { badges.append("NO GPS") }
        let position = item.coordinate.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "no GPS"
        return PlaceholderArtwork(title: item.title, lines: [dateLine(item), "seed \(SeedItem.padded(item.number)) · \(position)"],
                                  leadingBadge: item.tag.rawValue.uppercased(), trailingBadges: badges,
                                  hue: PlaceholderArtwork.hue(for: item.title), darkness: darkness(item), flat: item.media == .screenshot)
    }

    /// "Sat 14 Jun 2025 · 17:20" in the item's local time ("No date" when undated).
    static func dateLine(_ item: SeedItem) -> String {
        guard let wall = item.wallSeconds else { return "No date" }
        let day = SeedItem.days(wall)
        let (year, month, date) = LocalTime.civil(day: day)
        let minute = Int(wall - Int64(day) * 86_400) / 60
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@ %d %@ %d · %02d:%02d", weekdays[LocalTime.weekday(day: day) - 1], date, months[month - 1], year,
                      minute / 60, minute % 60)
    }

    /// Night pictures are darker: 1 from 20:00 to 05:00, 0.4 in the early evening, 0 by day.
    private static func darkness(_ item: SeedItem) -> Double {
        guard let wall = item.wallSeconds else { return 0.2 }
        let hour = Int(wall - Int64(SeedItem.days(wall)) * 86_400) / 3600
        switch hour {
        case 20..., ..<5: return 1
        case 17..<20: return 0.4
        default: return 0
        }
    }
}
#endif
