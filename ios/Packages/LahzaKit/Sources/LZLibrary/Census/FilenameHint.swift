import Foundation

/// What a photo's original filename suggests about where it came from.
///
/// The census reads each name, keeps only this hint and drops the name: filenames are never
/// stored, logged or reported. Hints are clues, not facts. iOS gives images that apps save to the
/// library camera-style names ("IMG_1234.JPG"), so many received photos read as ``camera``; the
/// census reports how often the names and the shape rule agree.
public enum FilenameHint: String, Sendable, Codable, CaseIterable {
    /// "IMG-20231005-WA0003.jpg", "VID-20231005-WA0012.mp4", "WhatsApp Image 2023-10-05 at 14.32.11.jpeg".
    case whatsapp
    /// "photo_2023-10-05_14-32-11.jpg", "video_2023-10-05_14-32-11.mp4", or a name containing "telegram".
    case telegram
    /// Signal ("signal-2023-10-05-143211.jpg"), Messenger ("received_…"), Facebook ("FB_IMG_…"),
    /// Snapchat, Viber, WeChat ("mmexport…") and LINE.
    case otherMessaging
    /// A camera's own naming with a camera file type: "IMG_1234.HEIC", "IMG_E1234.JPG" (edited),
    /// "DSC_0042.JPG", "PXL_20231005_143211.jpg", "IMG_20231005_143211.jpg".
    case camera
    /// Screen captures: "Screenshot 2023-10-05 at 14.32.11.png", "RPReplay_Final1696500000.MP4", and
    /// "IMG_1234.PNG" (how iOS names screenshots; a camera never writes PNG).
    case screenshot
    /// Anything else, or no name.
    case unknown

    public init(filename: String?) {
        guard let filename, !filename.isEmpty else {
            self = .unknown
            return
        }
        let name = (filename.split(separator: "/").last.map(String.init) ?? filename).lowercased()
        let (stem, ext) = Self.split(name)
        if Self.isWhatsApp(stem) {
            self = .whatsapp
        } else if Self.isTelegram(stem) {
            self = .telegram
        } else if Self.isOtherMessaging(stem) {
            self = .otherMessaging
        } else if Self.isScreenCapture(stem, ext) {
            self = .screenshot
        } else if Self.isCamera(stem, ext) {
            self = .camera
        } else {
            self = .unknown
        }
    }

    /// A messaging app's naming.
    public var isMessaging: Bool { self == .whatsapp || self == .telegram || self == .otherMessaging }

    // MARK: Rules (plain string checks: fast enough for 100k names, no regex objects)

    private static let cameraExtensions: Set<Substring> = [
        "heic", "heif", "jpg", "jpeg", "dng", "mov", "mp4", "m4v", "hevc", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]

    private static func split(_ name: String) -> (stem: Substring, ext: Substring) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (Substring(name), "") }
        return (name[..<dot], name[name.index(after: dot)...])
    }

    private static func isWhatsApp(_ stem: Substring) -> Bool {
        if stem.contains("whatsapp") { return true }
        // IMG-20231005-WA0003 (and VID-, AUD-, PTT-, STK-, DOC-).
        let prefixes = ["img-", "vid-", "aud-", "ptt-", "stk-", "doc-"]
        guard let prefix = prefixes.first(where: { stem.hasPrefix($0) }) else { return false }
        var rest = stem.dropFirst(prefix.count)
        guard rest.count >= 12, rest.prefix(8).allSatisfy(\.isASCIIDigit) else { return false }
        rest = rest.dropFirst(8)
        guard rest.hasPrefix("-wa") else { return false }
        let digits = rest.dropFirst(3)
        return digits.first?.isASCIIDigit == true
    }

    private static func isTelegram(_ stem: Substring) -> Bool {
        if stem.contains("telegram") { return true }
        // photo_2023-10-05_14-32-11 (also video_, file_, animation_, sticker_, voice_), with "_" or " "
        // before the time and "-" or "." inside it.
        let prefixes = ["photo_", "video_", "file_", "animation_", "sticker_", "voice_"]
        guard let prefix = prefixes.first(where: { stem.hasPrefix($0) }) else { return false }
        return matches(stem.dropFirst(prefix.count), pattern: "dddd-dd-dd?dd?dd?dd", separators: ["_", " ", "-", "."])
    }

    private static func isOtherMessaging(_ stem: Substring) -> Bool {
        if stem.hasPrefix("signal-"), stem.dropFirst(7).first?.isASCIIDigit == true { return true }
        let prefixes = ["received_", "fb_img_", "snapchat-", "mmexport", "line_", "viber_"]
        if prefixes.contains(where: { stem.hasPrefix($0) }) { return true }
        return stem.contains("viber") || stem.contains("messenger")
    }

    private static func isScreenCapture(_ stem: Substring, _ ext: Substring) -> Bool {
        let words = ["screenshot", "screen shot", "screen_shot", "screen recording", "screenrecording", "simulator screen"]
        if words.contains(where: { stem.contains($0) }) || stem.hasPrefix("rpreplay") { return true }
        // iOS names its screenshots IMG_1234.PNG.
        return ext == "png" && stem.hasPrefix("img_") && stem.dropFirst(4).allSatisfy(\.isASCIIDigit) && stem.count > 4
    }

    private static func isCamera(_ stem: Substring, _ ext: Substring) -> Bool {
        guard cameraExtensions.contains(ext) else { return false }
        // IMG_1234 / IMG_E1234 (iPhone), IMG_20231005_143211 and VID_… (Android), and common camera prefixes.
        if stem.hasPrefix("img_") || stem.hasPrefix("vid_") {
            var rest = stem.dropFirst(4)
            if rest.first == "e" { rest = rest.dropFirst() }
            return rest.first?.isASCIIDigit == true
        }
        let prefixes = ["dsc_", "dscn", "dscf", "dsc0", "pxl_", "mvimg_", "gopr", "dji_", "_mg_"]
        guard let prefix = prefixes.first(where: { stem.hasPrefix($0) }) else { return false }
        return stem.dropFirst(prefix.count).first?.isASCIIDigit == true
    }

    /// `text` starts with `pattern`, where `d` is a digit, `?` is any of `separators` and every
    /// other character matches itself.
    private static func matches(_ text: Substring, pattern: String, separators: Set<Character>) -> Bool {
        guard text.count >= pattern.count else { return false }
        for (character, rule) in zip(text, pattern) {
            switch rule {
            case "d": guard character.isASCIIDigit else { return false }
            case "?": guard separators.contains(character) else { return false }
            default: guard character == rule else { return false }
            }
        }
        return true
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
