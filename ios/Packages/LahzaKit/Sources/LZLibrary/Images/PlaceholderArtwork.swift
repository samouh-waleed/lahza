import CoreGraphics
import CoreText
import Foundation

/// A card drawn with CoreGraphics and CoreText: a two-colour gradient, a serif title, two lines of
/// detail and corner badges. Fake thumbnails and the seed library's files use it, so they look alike.
struct PlaceholderArtwork: Sendable {
    var title: String
    var lines: [String]
    var leadingBadge: String?
    var trailingBadges: [String] = []
    /// 0…1 around the colour wheel.
    var hue: Double
    /// 0 (daylight) … 1 (night).
    var darkness: Double = 0
    /// One flat colour instead of the gradient (a screenshot; it also keeps PNGs small).
    var flat = false

    /// The card as an image of `width` × `height` pixels.
    func image(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        draw(in: context, width: CGFloat(width), height: CGFloat(height))
        return context.makeImage()
    }

    /// Draws the card filling `width` × `height` of `context` (origin bottom left). `progress`
    /// (0…1) adds a playback bar along the bottom, for video frames.
    func draw(in context: CGContext, width: CGFloat, height: CGFloat, progress: Double? = nil) {
        let scale = min(width, height)
        let margin = scale * 0.06
        let dim = 1 - 0.6 * min(1, max(0, darkness))
        if flat {
            context.setFillColor(Self.color(hue, 0.35, 0.6 * dim))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [Self.color(hue, 0.5, 0.88 * dim), Self.color(hue + 0.09, 0.72, 0.5 * dim)] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        let soft = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78)
        let available = width - 2 * margin
        Self.text(title, font: Self.font("Georgia", scale * 0.115), color: white, at: CGPoint(x: margin, y: height * 0.52), width: available, in: context)
        for (index, line) in lines.enumerated() {
            Self.text(line, font: Self.font("Helvetica", scale * 0.048), color: soft,
                      at: CGPoint(x: margin, y: height * 0.52 - scale * (0.1 + 0.07 * CGFloat(index))), width: available, in: context)
        }
        let badgeFont = Self.font("Helvetica-Bold", scale * 0.036)
        let badgeY = height - margin - scale * 0.06
        if let leadingBadge { Self.badge(leadingBadge, font: badgeFont, x: margin, y: badgeY, alignRight: false, in: context) }
        var right = width - margin
        for badge in trailingBadges.reversed() {
            right = Self.badge(badge, font: badgeFont, x: right, y: badgeY, alignRight: true, in: context) - scale * 0.02
        }
        if let progress {
            let track = CGRect(x: margin, y: margin, width: available, height: scale * 0.015)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3))
            context.fill(track)
            context.setFillColor(white)
            context.fill(CGRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, progress)), height: track.height))
        }
    }

    /// A stable hue for `text` (FNV-1a, so it doesn't change between runs like `Hasher` does).
    static func hue(for text: String) -> Double {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return Double(hash % 360) / 360
    }

    // MARK: Drawing

    private static func font(_ name: String, _ size: CGFloat) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    /// One line of text whose baseline starts at `point`, shrunk to fit `width`.
    private static func text(_ string: String, font: CTFont, color: CGColor, at point: CGPoint, width: CGFloat, in context: CGContext) {
        var line = makeLine(string, font: font, color: color)
        let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if measured > width, measured > 0 {
            line = makeLine(string, font: CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * width / measured, nil, nil), color: color)
        }
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A rounded label; returns its far edge (left edge when right-aligned, right edge otherwise).
    @discardableResult
    private static func badge(_ string: String, font: CTFont, x: CGFloat, y: CGFloat, alignRight: Bool, in context: CGContext) -> CGFloat {
        let line = makeLine(string, font: font, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let size = CTFontGetSize(font)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + size
        let rect = CGRect(x: alignRight ? x - width : x, y: y, width: width, height: size * 1.6)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.5, cornerHeight: size * 0.5, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: rect.minX + size * 0.5, y: rect.minY + size * 0.45)
        CTLineDraw(line, context)
        return alignRight ? rect.minX : rect.maxX
    }

    private static func makeLine(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// An sRGB colour from hue, saturation and brightness (all 0…1; hue wraps).
    private static func color(_ hue: Double, _ saturation: Double, _ brightness: Double) -> CGColor {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f), t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
