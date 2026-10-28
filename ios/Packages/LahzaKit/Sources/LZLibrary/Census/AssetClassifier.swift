import Foundation

/// What kind of photo an asset is, from its facts alone: a screen capture, likely received from a
/// chat, or a camera photo. The census counts with these rules and the index stores their answers,
/// so both always agree. The constants are the design's placeholders (mvp-design §3), named so
/// reports can quote them.
public enum AssetClassifier {
    /// The long sides (pixels) messaging apps commonly resize photos to: WhatsApp 1600 (standard
    /// quality); Telegram 1280 and 2560 (high quality); Signal and Messenger 2048. A guess to
    /// calibrate: the census shows how the shape rule agrees with filename hints and lists the most
    /// common long sides among photos without GPS.
    public static let messagingLongSides: Set<Int> = [1280, 1600, 2048, 2560]
    /// "Creation ≈ added" (P0's likelyReceived): a received photo is saved as it arrives, so the
    /// library adds it within minutes of its creation date. PhotoKit's added date exists from iOS 26.
    public static let receivedAddedWithin: TimeInterval = 10 * 60

    /// A screenshot by PhotoKit's subtype, or a photo named like one.
    public static func isScreenCapture(_ facts: AssetFacts) -> Bool {
        facts.subtypes.contains(.screenshot) || facts.filenameHint == .screenshot
    }

    /// Whether the added date is within ``receivedAddedWithin`` of the creation date (nil when
    /// either is unknown).
    public static func addedNearCreation(_ facts: AssetFacts) -> Bool? {
        guard let created = facts.creationDate, let added = facts.addedDate else { return nil }
        return abs(added.timeIntervalSince(created)) <= receivedAddedWithin
    }

    /// The shape rule, P0's likelyReceived without filenames: a photo with no GPS that is not a
    /// screen capture, at a messaging app's size, added about when it was created (an unknown date
    /// doesn't rule it out).
    public static func matchesReceivedShape(_ facts: AssetFacts) -> Bool {
        facts.kind == .photo && !facts.isLocated && !isScreenCapture(facts)
            && messagingLongSides.contains(facts.longSide) && addedNearCreation(facts) != false
    }

    /// Named like a messaging app, or (photos) matching the shape rule.
    public static func isLikelyReceived(_ facts: AssetFacts) -> Bool {
        facts.filenameHint?.isMessaging == true || matchesReceivedShape(facts)
    }

    /// A photo that is neither a screen capture nor likely received: the place signal's target.
    public static func isCameraPhoto(_ facts: AssetFacts) -> Bool {
        facts.kind == .photo && !isScreenCapture(facts) && !isLikelyReceived(facts)
    }
}
