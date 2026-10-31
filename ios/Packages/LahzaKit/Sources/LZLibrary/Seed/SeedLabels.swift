#if DEBUG
import Foundation
import LZGeo

/// What the hero seed's pictures stand for, as Vision would tag them: the seed's pictures are drawn gradients, so the
/// seed's visual analyzer reports these instead, and HeroSuite's visual goldens expect them. A pure function of the
/// item, the same on every run: soccer at the pitches (a quarter of Al-Nakheel's photos tagged only `football`), a
/// beach, a sunset in Oia, a hike above Fira, a night at the desert camp, fireworks on New Year's Eve, receipts and a
/// passport among the screenshots. The photos without a place (`orphans`) are only in iCloud, so they are never checked.
public enum SeedLabels {
    /// Which of Vision's filters a tag passed: the high-recall one only, the 0.7-precision one, or the 0.9 one.
    public enum Strength: Int, Sendable, Hashable, Comparable {
        case candidate, likely, precise

        public var confidence: Float {
            switch self {
            case .candidate: 0.2
            case .likely: 0.6
            case .precise: 0.9
            }
        }

        public static func < (lhs: Strength, rhs: Strength) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Analysis: Sendable, Hashable {
        /// Tag → strength.
        public var labels: [String: Strength]
        public var faces: Int
        public var humans: Int
        public var isUtility: Bool
        /// No image on the iPhone: never checked.
        public var inCloud: Bool
    }

    public static func analysis(for item: SeedItem) -> Analysis {
        var labels: [String: Strength] = [:]
        var faces = 0, humans = 0
        let minute = item.wallSeconds.map { LocalTime.minuteOfDay(wallSeconds: $0) } ?? -1
        func tag(_ strength: Strength, _ names: String...) { for name in names { labels[name] = max(labels[name] ?? strength, strength) } }
        switch item.tag {
        case .nakheel:
            humans = 6
            tag(.precise, "grass")
            if item.number % 4 == 0 {
                tag(.likely, "football")
            } else {
                tag(item.number % 4 == 1 ? .precise : .likely, "soccer")
                tag(.candidate, "sport")
            }
        case .otherPitch:
            humans = 4
            tag(.likely, "soccer")
            tag(.precise, "grass")
        case .salam:
            humans = 2
            tag(.precise, "park")
            tag(.likely, "playground")
        case .kingdom:
            tag(.precise, "skyscraper")
            tag(.likely, "tower")
            tag(.candidate, "night_sky")
        case .sufra:
            faces = 2
            tag(.precise, "food", "restaurant")
            if item.number % 2 == 0 { tag(.likely, "kebab") }
            tag(.candidate, "grill")
        case .diriyah:
            tag(.precise, "ruins")
            tag(.candidate, "castle")
        case .desert:
            if minute < 4 * 60 {
                tag(.precise, "night_sky")
                tag(.likely, "camping")
                tag(.candidate, "fire")
            } else if minute < 12 * 60 {
                tag(.precise, "tent", "desert")
                tag(.candidate, "camping")
            } else {
                tag(.precise, "desert", "sand_dune")
                if item.number % 2 == 0 { tag(.likely, "atv") }
            }
        case .iftar:
            faces = 3
            tag(.precise, "food")
        case .eid:
            faces = item.isSelfie ? 1 : 4
            humans = faces
            tag(.precise, "people")
            if item.number % 3 == 0 { tag(.likely, "dessert") }
        case .dubai1, .dubai2:
            switch item.title {
            case SeedPlace.burjKhalifa.name: tag(.precise, "skyscraper", "tower")
            case SeedPlace.dubaiMall.name: tag(.likely, "interior_shop")
            case SeedPlace.jbrBeach.name:
                humans = 3
                tag(.precise, "beach", "ocean")
                if item.number % 3 == 0 { tag(.likely, "swimming") }
            case SeedPlace.dubaiMarina.name:
                tag(.precise, "skyscraper")
                tag(.likely, "boat")
            default: tag(.precise, "park", "grass")
            }
        case .greece:
            switch item.title {
            case SeedPlace.mykonos.name: tag(.precise, "beach", "ocean")
            case SeedPlace.oia.name:
                tag(.precise, "sunset_sunrise")
                tag(.likely, "cliff")
            case SeedPlace.fira.name:
                if minute < 4 * 60 {
                    tag(.precise, "night_sky")
                } else {
                    humans = 2
                    tag(.likely, "hiking")
                    tag(.precise, "cliff")
                    tag(.candidate, "trail")
                }
            default:
                tag(.precise, "ruins")
                tag(.likely, "monument")
            }
        case .london:
            if item.title == SeedPlace.towerBridge.name {
                // The New Year's Eve fireworks: 23:40 to 00:20.
                if minute >= 23 * 60 + 40 || minute < 21 { tag(.precise, "fireworks") }
                tag(.precise, "bridge")
                tag(.likely, "night_sky")
            } else {
                tag(.precise, "park", "tree")
            }
        case .sydney:
            if item.title == SeedPlace.bondiBeach.name {
                humans = 2
                tag(.precise, "beach", "ocean")
                tag(.likely, "surfing")
            } else {
                tag(.precise, "building")
            }
        case .home, .summer2026:
            tag(.likely, "interior_room")
        case .screens:
            switch item.number % 5 {
            case 0: tag(.precise, "receipt"); tag(.likely, "document")
            case 2: tag(.likely, "passport"); tag(.candidate, "document")
            default: tag(.candidate, "document")
            }
        case .received:
            humans = 5
            tag(.precise, "people")
            if item.number % 3 == 0 { tag(.likely, "soccer") }
        case .orphans:
            return Analysis(labels: [:], faces: 0, humans: 0, isUtility: false, inCloud: true)
        case .undated:
            tag(.precise, "cat")
        }
        return Analysis(labels: labels, faces: faces, humans: humans, isUtility: item.media == .screenshot, inCloud: false)
    }
}
#endif
