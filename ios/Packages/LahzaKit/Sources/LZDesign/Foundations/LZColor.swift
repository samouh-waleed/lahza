import Foundation

// MARK: - LZRGBA

/// An sRGB colour with straight (non-premultiplied) alpha: the value behind every colour
/// token. Pure maths lives here so it is testable on the Mac host (contrast, compositing, mixing).
nonisolated public struct LZRGBA: Sendable, Hashable, CustomStringConvertible {
    /// 0…1, sRGB-encoded.
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 0…1.
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    /// `#RRGGBB` or `RRGGBB` (anything else reads as black).
    public init(hexString: String, alpha: Double = 1) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        self.init(hex: UInt32(digits.prefix(6), radix: 16) ?? 0, alpha: alpha)
    }

    /// `#RRGGBB`, uppercase (alpha is not included).
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public var description: String { alpha >= 1 ? hex : "\(hex)@\(String(format: "%.2f", alpha))" }

    public var isOpaque: Bool { alpha >= 1 }

    /// The same colour at another opacity.
    public func opacity(_ value: Double) -> LZRGBA { LZRGBA(red: red, green: green, blue: blue, alpha: value) }

    /// This colour drawn "source over" an opaque background, returned opaque. This is what the
    /// eye sees, so contrast is always measured on composited colours.
    public func composited(over background: LZRGBA) -> LZRGBA {
        let base = background.isOpaque ? background : background.composited(over: LZRGBA(red: 1, green: 1, blue: 1))
        let a = alpha
        return LZRGBA(red: red * a + base.red * (1 - a), green: green * a + base.green * (1 - a),
                      blue: blue * a + base.blue * (1 - a), alpha: 1)
    }

    /// Linear interpolation in sRGB (what gradients draw by default); `t` 0 → self, 1 → other.
    public func mixed(with other: LZRGBA, amount t: Double) -> LZRGBA {
        let k = Self.clamp(t)
        return LZRGBA(red: red + (other.red - red) * k, green: green + (other.green - green) * k,
                      blue: blue + (other.blue - blue) * k, alpha: alpha + (other.alpha - alpha) * k)
    }

    /// WCAG 2.x relative luminance of the (opaque) colour.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio (1…21). Translucent colours are first composited: `self` over
    /// `other`, and `other` over white if it is itself translucent.
    public func contrast(with other: LZRGBA) -> Double {
        let back = other.isOpaque ? other : other.composited(over: LZRGBA(red: 1, green: 1, blue: 1))
        let front = isOpaque ? self : composited(over: back)
        let a = front.relativeLuminance, b = back.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
}

// MARK: - Tokens

/// Every semantic colour. Editorial ivory and charcoal keep reading quiet;
/// the `*Text` tones are contrast-checked variants for labels and status messages.
nonisolated public enum LZColorToken: String, CaseIterable, Sendable, Hashable {
    // Paper
    /// Page background (warm ivory / charcoal night).
    case bg
    /// Cards and sheets.
    case surface
    /// Recessed paper: tracks, wells, disabled fields.
    case surface2

    // Ink
    case ink
    /// Secondary text. ≥ 4.5:1 on every paper.
    case muted

    // Lines
    /// Hairline divider: ink at 10 % (12 % dark). Opaque under Reduce Transparency.
    case line
    /// Opaque divider / field border.
    case lineSolid

    // Brand
    case accent
    /// Text and glyphs drawn on `accent`.
    case accentInk
    case accentDeep
    case sage
    case gold
    case danger

    // Text-safe tones (≥ 4.5:1 on every paper and on their own soft fill)
    case sageText
    case goldText
    case dangerText

    // Pastel washes (content-layer tints)
    case apricot
    case lilac
    case butter
    case mint

    // Soft tone fills (translucent; opaque under Reduce Transparency)
    case accentSoft
    case sageSoft
    case goldSoft
    case dangerSoft

    /// Dim behind modal content: #1C1422 at 45 %.
    case scrim
}

/// The appearance a colour resolves for.
nonisolated public struct LZAppearance: Sendable, Hashable, CustomStringConvertible {
    public var isDark: Bool
    /// Settings › Accessibility › Increase Contrast.
    public var increasedContrast: Bool
    /// Settings › Accessibility › Reduce Transparency: every translucent token becomes opaque.
    public var reduceTransparency: Bool

    public init(isDark: Bool, increasedContrast: Bool = false, reduceTransparency: Bool = false) {
        self.isDark = isDark
        self.increasedContrast = increasedContrast
        self.reduceTransparency = reduceTransparency
    }

    public static let light = LZAppearance(isDark: false)
    public static let dark = LZAppearance(isDark: true)

    /// All eight combinations (used by tests and the gallery).
    public static let all: [LZAppearance] = [false, true].flatMap { dark in
        [false, true].flatMap { contrast in [false, true].map { LZAppearance(isDark: dark, increasedContrast: contrast, reduceTransparency: $0) } }
    }

    public var description: String {
        (isDark ? "dark" : "light") + (increasedContrast ? "+contrast" : "") + (reduceTransparency ? "+opaque" : "")
    }

    /// The minimum WCAG ratio text pairs must reach in this appearance: 4.5 (AA), or 7 (AAA)
    /// with Increase Contrast.
    public var minimumTextContrast: Double { increasedContrast ? 7 : 4.5 }
}

/// The palette: token → colour for an appearance.
nonisolated public enum LZPalette {
    /// The colour of `token` in `appearance`.
    public static func rgba(_ token: LZColorToken, _ appearance: LZAppearance) -> LZRGBA {
        let table = appearance.isDark ? (appearance.increasedContrast ? darkHigh : dark) : (appearance.increasedContrast ? lightHigh : light)
        if let value = table.base[token] { return value }
        // Translucent tokens: built from the base colours, opaque under Reduce Transparency.
        let tone: LZRGBA
        let alpha: Double
        switch token {
        case .line:
            tone = table.base[.ink] ?? .black
            alpha = appearance.increasedContrast ? 0.24 : (appearance.isDark ? 0.12 : 0.10)
        case .accentSoft:
            tone = table.base[.accent] ?? .black
            alpha = appearance.increasedContrast ? 0.05 : 0.10
        case .sageSoft:
            tone = table.base[.sage] ?? .black
            alpha = appearance.increasedContrast ? 0.05 : 0.16
        case .goldSoft:
            tone = table.base[.gold] ?? .black
            alpha = appearance.increasedContrast ? 0.05 : 0.18
        case .dangerSoft:
            tone = table.base[.danger] ?? .black
            alpha = appearance.increasedContrast ? 0.05 : 0.14
        case .scrim:
            tone = LZRGBA(hex: 0x1C1422)
            alpha = appearance.increasedContrast ? 0.6 : 0.45
        default:
            return .black
        }
        let translucent = tone.opacity(alpha)
        guard appearance.reduceTransparency else { return translucent }
        // A scrim stays a dim (it is a modal backdrop, not a surface); everything else is
        // pre-composited on the card surface it sits on.
        if token == .scrim { return tone.opacity(appearance.increasedContrast ? 0.75 : 0.62) }
        return translucent.composited(over: table.base[.surface] ?? .white)
    }

    /// The tokens that are translucent in the standard appearance.
    public static let translucentTokens: Set<LZColorToken> = [.line, .accentSoft, .sageSoft, .goldSoft, .dangerSoft, .scrim]

    struct Table { let base: [LZColorToken: LZRGBA] }

    // Editorial paper, bronze and charcoal. Semantic greens are reserved for status.
    static let light = Table(base: [
        .bg: LZRGBA(hex: 0xF8F6F0), .surface: LZRGBA(hex: 0xFFFDF8), .surface2: LZRGBA(hex: 0xEEEAE1),
        .ink: LZRGBA(hex: 0x282821), .muted: LZRGBA(hex: 0x69675F), .lineSolid: LZRGBA(hex: 0xD8D4C9),
        .accent: LZRGBA(hex: 0x6C5638), .accentInk: LZRGBA(hex: 0xFFFDF8), .accentDeep: LZRGBA(hex: 0x282821),
        .sage: LZRGBA(hex: 0x486353), .gold: LZRGBA(hex: 0x917040), .danger: LZRGBA(hex: 0xA1393D),
        // Text-safe tones: the brand gold is 4.46:1 on surface2 and 3.95:1 on its soft fill.
        .sageText: LZRGBA(hex: 0x416151), .goldText: LZRGBA(hex: 0x7B531F), .dangerText: LZRGBA(hex: 0xA1393D),
        .apricot: LZRGBA(hex: 0xF2EBE1), .lilac: LZRGBA(hex: 0xF0EDE6), .butter: LZRGBA(hex: 0xF3EDDE), .mint: LZRGBA(hex: 0xECEEE7),
    ])

    static let dark = Table(base: [
        .bg: LZRGBA(hex: 0x151614), .surface: LZRGBA(hex: 0x20211E), .surface2: LZRGBA(hex: 0x282925),
        .ink: LZRGBA(hex: 0xF4F0E6), .muted: LZRGBA(hex: 0xBAB7AD), .lineSolid: LZRGBA(hex: 0x42443D),
        .accent: LZRGBA(hex: 0xDEC392), .accentInk: LZRGBA(hex: 0x151614), .accentDeep: LZRGBA(hex: 0xF0D9AF),
        .sage: LZRGBA(hex: 0xB2D9C3), .gold: LZRGBA(hex: 0xF1D28A), .danger: LZRGBA(hex: 0xFFA7A4),
        .sageText: LZRGBA(hex: 0xB2D9C3), .goldText: LZRGBA(hex: 0xF1D28A), .dangerText: LZRGBA(hex: 0xFFA7A4),
        .apricot: LZRGBA(hex: 0x292620), .lilac: LZRGBA(hex: 0x272824), .butter: LZRGBA(hex: 0x2B271F), .mint: LZRGBA(hex: 0x242A24),
    ])

    // Increase Contrast: text reaches 7:1 (AAA) on every paper; lines and borders firm up; soft
    // fills get lighter so the tone text on them stays AAA (components add a tone border).
    static let lightHigh = Table(base: light.base.merging([
        .ink: LZRGBA(hex: 0x1E201C), .muted: LZRGBA(hex: 0x494A40), .lineSolid: LZRGBA(hex: 0x818176),
        .accent: LZRGBA(hex: 0x4A3B29), .sage: LZRGBA(hex: 0x374C45), .gold: LZRGBA(hex: 0x60411F), .danger: LZRGBA(hex: 0x7B2E35),
        .sageText: LZRGBA(hex: 0x374C45), .goldText: LZRGBA(hex: 0x60411F), .dangerText: LZRGBA(hex: 0x7B2E35),
    ]) { $1 })

    static let darkHigh = Table(base: dark.base.merging([
        .ink: LZRGBA(hex: 0xFFFBF6), .muted: LZRGBA(hex: 0xD6D3C8), .lineSolid: LZRGBA(hex: 0x858579),
        .accent: LZRGBA(hex: 0xF0D9AF), .accentDeep: LZRGBA(hex: 0xF8E8C9), .sage: LZRGBA(hex: 0xB5DBC5), .gold: LZRGBA(hex: 0xF1D28A),
        .danger: LZRGBA(hex: 0xFFC5C3), .sageText: LZRGBA(hex: 0xB5DBC5), .goldText: LZRGBA(hex: 0xF1D28A), .dangerText: LZRGBA(hex: 0xFFC5C3),
    ]) { $1 })
}

nonisolated extension LZRGBA {
    static let black = LZRGBA(red: 0, green: 0, blue: 0)
    static let white = LZRGBA(red: 1, green: 1, blue: 1)
}

// MARK: - Tones and washes

/// A semantic tone: the pairing of a soft fill with the text/glyph colour that reads on it.
/// Pills, icon badges and notices use tones.
nonisolated public enum LZTone: String, CaseIterable, Sendable, Hashable {
    case neutral, accent, sage, gold, danger

    /// Text and glyphs on the tone's fill.
    public var foreground: LZColorToken {
        switch self {
        case .neutral: .muted
        case .accent: .accent
        case .sage: .sageText
        case .gold: .goldText
        case .danger: .dangerText
        }
    }

    /// The soft fill (translucent; opaque under Reduce Transparency).
    public var fill: LZColorToken {
        switch self {
        case .neutral: .surface2
        case .accent: .accentSoft
        case .sage: .sageSoft
        case .gold: .goldSoft
        case .danger: .dangerSoft
        }
    }

    /// The saturated brand colour (glyph fills, strokes, borders under Increase Contrast).
    public var solid: LZColorToken {
        switch self {
        case .neutral: .muted
        case .accent: .accent
        case .sage: .sage
        case .gold: .gold
        case .danger: .danger
        }
    }
}

/// The four pastel washes that tint content surfaces (never text colours).
nonisolated public enum LZWash: String, CaseIterable, Sendable, Hashable {
    case apricot, lilac, butter, mint

    public var token: LZColorToken {
        switch self {
        case .apricot: .apricot
        case .lilac: .lilac
        case .butter: .butter
        case .mint: .mint
        }
    }
}

// MARK: - Contrast contract

/// The text-on-background pairs the app uses. Every pair is unit-tested at ≥ 4.5:1 (≥ 7:1 with
/// Increase Contrast) in every appearance. Add a pair here before using a new combination.
nonisolated public enum LZContrastPairs {
    public struct Pair: Sendable, Hashable, CustomStringConvertible {
        public var text: LZColorToken
        /// The background, drawn over `base` when it is translucent.
        public var background: LZColorToken
        public var base: LZColorToken?

        public var description: String { "\(text) on \(background)" + (base.map { " over \($0)" } ?? "") }

        public func contrast(in appearance: LZAppearance) -> Double {
            var back = LZPalette.rgba(background, appearance)
            if let base { back = back.composited(over: LZPalette.rgba(base, appearance)) }
            return LZPalette.rgba(text, appearance).contrast(with: back)
        }
    }

    /// Every paper a text colour may sit on.
    public static let papers: [LZColorToken] = [.bg, .surface, .surface2, .apricot, .lilac, .butter, .mint]
    /// Every text colour allowed directly on paper.
    public static let paperTexts: [LZColorToken] = [.ink, .muted, .accent, .sageText, .goldText, .dangerText]

    public static let all: [Pair] = {
        var pairs: [Pair] = []
        for text in paperTexts { for paper in papers { pairs.append(Pair(text: text, background: paper, base: nil)) } }
        // Buttons and toasts.
        pairs.append(Pair(text: .accentInk, background: .accent, base: nil))
        pairs.append(Pair(text: .bg, background: .ink, base: nil))
        pairs.append(Pair(text: .surface, background: .ink, base: nil))
        // Tone text on its own soft fill, over each paper; ink on every soft fill (notices).
        for tone in LZTone.allCases where LZPalette.translucentTokens.contains(tone.fill) {
            for paper in papers {
                pairs.append(Pair(text: tone.foreground, background: tone.fill, base: paper))
                pairs.append(Pair(text: .ink, background: tone.fill, base: paper))
            }
        }
        return pairs
    }()
}
