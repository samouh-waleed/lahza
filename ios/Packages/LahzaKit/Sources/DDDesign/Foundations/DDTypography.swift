import SwiftUI

/// Bundled font PostScript names (registered by the app's `UIAppFonts`).
nonisolated public enum DDFontName {
    public static let instrumentSerif = "InstrumentSerif-Regular"
    public static let instrumentSerifItalic = "InstrumentSerif-Italic"
    public static let newsreader = "Newsreader-Regular"
    public static let newsreaderMedium = "Newsreader-Medium"

    /// Every face DDDesign draws with.
    public static let all = [instrumentSerif, instrumentSerifItalic, newsreader, newsreaderMedium]
}

/// The type roles. SF Pro for all UI; Instrument Serif for display and countdown numerals;
/// Newsreader for reading.
///
/// Every role scales with Dynamic Type (`relativeTo:`), including its line height and tracking.
nonisolated public enum DDTextRole: String, CaseIterable, Sendable, Hashable {
    // Display: Instrument Serif, regular only (never synthesised bold).
    /// 48 pt: onboarding and welcome headlines.
    case displayXL
    /// 38 pt: paywall and hero headlines.
    case displayLarge
    /// 32 pt: screen titles.
    case display
    /// 26 pt: sheet titles, empty states.
    case displaySmall
    /// 24 pt: section titles.
    case section

    // UI: SF Pro.
    /// 22 pt semibold.
    case title
    /// 17 pt semibold.
    case headline
    /// 17 pt.
    case body
    /// 16 pt: button labels and emphasised rows.
    case callout
    /// 15 pt: secondary lines.
    case subheadline
    /// 13 pt.
    case caption
    /// 12 pt semibold, uppercase, tracked 0.14 em: eyebrows and small section labels. It stops
    /// growing at `.accessibility1`, and at accessibility sizes drops the caps and tracking.
    case label

    // Numerals.
    /// 64 pt Instrument Serif: hero countdowns.
    case numeralHero
    /// 44 pt Instrument Serif.
    case numeral
    /// SF Pro 20 pt semibold, tabular: counts in UI.
    case numeralUI

    // Reading.
    /// 21 pt Newsreader at 1.65: long-form reading.
    case reading
    /// 29 pt Newsreader Medium: reader titles.
    case readingTitle
}

/// What a role is made of.
nonisolated public struct DDTypeSpec: Sendable, Hashable {
    /// PostScript name; nil means SF Pro (the system font).
    public var fontName: String?
    /// Base size at the default Dynamic Type size.
    public var size: CGFloat
    /// SF weight (ignored for bundled faces: they ship only the weights they need).
    public var weight: Font.Weight?
    /// The Dynamic Type curve the role follows.
    public var textStyle: Font.TextStyle
    /// Line height as a multiple of the (scaled) point size; nil keeps the font's natural leading.
    public var lineHeight: CGFloat?
    /// Tracking in em.
    public var tracking: CGFloat
    public var uppercase: Bool
    /// Tabular figures (SF) or fixed-width digit cells (Instrument Serif has no `tnum`).
    public var tabular: Bool
    /// Display roles carry the header trait and must never be bolded.
    public var isDisplay: Bool
    /// The largest Dynamic Type size the role follows (nil: every size). Small tracked caps stop
    /// growing at `.accessibility1` so an eyebrow never outweighs the title it introduces.
    public var maximumTypeSize: DynamicTypeSize? = nil
}

nonisolated extension DDTextRole {
    public var spec: DDTypeSpec {
        func serif(_ size: CGFloat, _ style: Font.TextStyle, lineHeight: CGFloat = 1.12, tabular: Bool = false, display: Bool = true) -> DDTypeSpec {
            DDTypeSpec(fontName: DDFontName.instrumentSerif, size: size, weight: nil, textStyle: style, lineHeight: lineHeight,
                       tracking: -0.01, uppercase: false, tabular: tabular, isDisplay: display)
        }
        func sf(_ size: CGFloat, _ style: Font.TextStyle, _ weight: Font.Weight? = nil, lineHeight: CGFloat? = nil,
                tracking: CGFloat = 0, uppercase: Bool = false, tabular: Bool = false) -> DDTypeSpec {
            DDTypeSpec(fontName: nil, size: size, weight: weight, textStyle: style, lineHeight: lineHeight, tracking: tracking,
                       uppercase: uppercase, tabular: tabular, isDisplay: false)
        }
        return switch self {
        case .displayXL: serif(48, .largeTitle)
        case .displayLarge: serif(38, .largeTitle)
        case .display: serif(32, .title)
        case .displaySmall: serif(26, .title2)
        case .section: serif(24, .title2, lineHeight: 1.2)
        case .title: sf(22, .title2, .semibold)
        case .headline: sf(17, .headline, .semibold)
        case .body: sf(17, .body, lineHeight: 1.38)
        case .callout: sf(16, .callout, lineHeight: 1.36)
        case .subheadline: sf(15, .subheadline, lineHeight: 1.36)
        case .caption: sf(13, .footnote, lineHeight: 1.36)
        case .label:
            {
                var spec = sf(12, .caption, .semibold, tracking: 0.14, uppercase: true)
                spec.maximumTypeSize = .accessibility1
                return spec
            }()
        case .numeralHero: serif(64, .largeTitle, lineHeight: 1.05, tabular: true, display: false)
        case .numeral: serif(44, .largeTitle, lineHeight: 1.05, tabular: true, display: false)
        case .numeralUI: sf(20, .title3, .semibold, tabular: true)
        case .reading:
            DDTypeSpec(fontName: DDFontName.newsreader, size: 21, weight: nil, textStyle: .body, lineHeight: 1.65, tracking: 0,
                       uppercase: false, tabular: false, isDisplay: false)
        case .readingTitle:
            DDTypeSpec(fontName: DDFontName.newsreaderMedium, size: 29, weight: nil, textStyle: .title, lineHeight: 1.2, tracking: -0.005,
                       uppercase: false, tabular: false, isDisplay: true)
        }
    }

    /// The role's font. `scale` multiplies the base size (reader size steps, 0.9…1.6).
    public func font(scale: CGFloat = 1) -> Font {
        let spec = spec
        if let name = spec.fontName {
            return Font.custom(name, size: spec.size * scale, relativeTo: spec.textStyle)
        }
        // SF follows its text style; `ddText(_:scale:)` handles scaled SF sizes.
        var font: Font = .system(spec.textStyle)
        if let weight = spec.weight { font = font.weight(weight) }
        if spec.tabular { font = font.monospacedDigit() }
        return font
    }

    /// Instrument Serif's widest digit ("0") is 0.46 em; digit cells use it for steady countdowns.
    public static let serifDigitCellEm: CGFloat = 0.46
}

nonisolated extension DDTypeSpec {
    /// The exact line height for a Dynamic Type-scaled size, or nil for the face's natural
    /// leading. Display roles wrap at accessibility sizes, where a line box tighter than the face
    /// clips the last line's descenders: they keep the natural leading there.
    public func lineHeightPoints(scaledSize: CGFloat, accessibilitySize: Bool) -> CGFloat? {
        guard let lineHeight, !(isDisplay && accessibilitySize) else { return nil }
        return (scaledSize * lineHeight).rounded()
    }
}

nonisolated extension Font {
    /// A role font: `.font(.dd(.headline))`. Prefer ``SwiftUICore/View/ddText(_:scale:)``,
    /// which also applies line height, tracking and case.
    public static func dd(_ role: DDTextRole, scale: CGFloat = 1) -> Font { role.font(scale: scale) }
}

extension View {
    /// Styles text with a type role: font, Dynamic Type-scaled line height and tracking, case,
    /// tabular figures, and the header trait for display roles.
    public func ddText(_ role: DDTextRole, scale: CGFloat = 1) -> some View {
        modifier(DDTextModifier(role: role, scale: scale))
    }
}

struct DDTextModifier: ViewModifier {
    let role: DDTextRole
    let scale: CGFloat
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    init(role: DDTextRole, scale: CGFloat) {
        self.role = role
        self.scale = scale
        _scaledSize = ScaledMetric(wrappedValue: role.spec.size * scale, relativeTo: role.spec.textStyle)
    }

    func body(content: Content) -> some View {
        let spec = role.spec
        let font: Font = spec.fontName == nil && scale != 1
            ? .system(size: scaledSize).weight(spec.weight ?? .regular)
            : role.font(scale: scale)
        // Tracked caps read as shouting at accessibility sizes: they become plain text there.
        let plainCaps = spec.uppercase && typeSize.isAccessibilitySize
        content
            .font(spec.tabular && spec.fontName == nil ? font.monospacedDigit() : font)
            .modifier(DDBundledWeightLock(locked: spec.fontName != nil))
            .tracking(plainCaps ? 0 : spec.tracking * scaledSize)
            .textCase(spec.uppercase && !plainCaps ? .uppercase : nil)
            .lineHeight(spec.lineHeightPoints(scaledSize: scaledSize, accessibilitySize: typeSize.isAccessibilitySize).map { .exact(points: $0) })
            .accessibilityAddTraits(spec.isDisplay ? .isHeader : [])
            .modifier(DDTypeSizeCap(maximum: spec.maximumTypeSize))
    }
}

/// Caps a role's Dynamic Type growth (`DDTypeSpec.maximumTypeSize`).
struct DDTypeSizeCap: ViewModifier {
    let maximum: DynamicTypeSize?
    @ViewBuilder func body(content: Content) -> some View {
        if let maximum { content.dynamicTypeSize(...maximum) } else { content }
    }
}

/// Bundled faces ship only the weights they need: pin them to regular so an inherited
/// `.fontWeight` / `.bold()` never synthesises a fake bold. SF roles keep the caller's weight.
struct DDBundledWeightLock: ViewModifier {
    let locked: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if locked { content.fontWeight(.regular) } else { content }
    }
}

// MARK: - Serif numerals with steady digits

/// A numeral in Instrument Serif whose digits sit in fixed-width cells, so a countdown never
/// jitters (the face has no tabular figures). Changed digits roll with `.numericText`, or
/// cross-fade under Reduce Motion. VoiceOver reads `accessibilityLabel` (or the text).
/// `scale` multiplies the role's size (a regular-width hero, a calmer compact one).
public struct DDNumeral: View {
    private let text: String
    private let role: DDTextRole
    private let scale: CGFloat
    private let countsDown: Bool
    private let label: String?
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String, role: DDTextRole = .numeralHero, scale: CGFloat = 1, countsDown: Bool = true,
                accessibilityLabel: String? = nil) {
        self.text = text
        self.role = role
        self.scale = scale
        self.countsDown = countsDown
        label = accessibilityLabel
        _scaledSize = ScaledMetric(wrappedValue: role.spec.size * scale, relativeTo: role.spec.textStyle)
    }

    public var body: some View {
        let cells = DDNumeralCells.split(text)
        HStack(spacing: 0) {
            ForEach(cells) { cell in
                Text(String(cell.character))
                    .font(role.font(scale: scale))
                    .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: countsDown))
                    .frame(width: cell.isDigit && role.spec.fontName != nil ? scaledSize * DDTextRole.serifDigitCellEm : nil)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? text)
    }
}

/// Splits a numeral string into stable cells (index-keyed so digits animate in place).
nonisolated enum DDNumeralCells {
    struct Cell: Identifiable, Hashable {
        let id: Int
        let character: Character
        var isDigit: Bool { character.isASCII && character.isNumber }
    }

    /// Cells are keyed from the right so "9:59" → "10:00" keeps the minutes' cells in place.
    static func split(_ text: String) -> [Cell] {
        let characters = Array(text)
        return characters.enumerated().map { index, character in Cell(id: characters.count - index, character: character) }
    }
}
