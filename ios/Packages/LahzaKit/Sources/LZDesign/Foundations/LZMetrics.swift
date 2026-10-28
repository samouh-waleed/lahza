import SwiftUI

/// The spacing scale (points). A 4-pt rhythm with generous rests.
nonisolated public enum LZSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
    /// Between the page's major sections.
    public static let section: CGFloat = 40

    /// The whole scale, in order (tests and the gallery).
    public static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl, xxl, xxxl]
}

/// Corner radii. Nested shapes are concentric: an inner radius is the outer radius minus the
/// inset (``concentric(outer:inset:)``), or use `ConcentricRectangle()` inside a view that set
/// `.containerShape(...)` (every ``PaperCard`` does).
nonisolated public enum LZRadius {
    public static let xs: CGFloat = 6
    public static let sm: CGFloat = 10
    public static let md: CGFloat = 18
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32

    /// Paper cards.
    public static let card: CGFloat = lg
    /// Fields, chips, notices, rows inside cards.
    public static let control: CGFloat = md
    /// Sheets' top corners and hero panels.
    public static let sheet: CGFloat = xl
    /// Icon badges: 0.34 × the badge size.
    public static func badge(size: CGFloat) -> CGFloat { (size * 0.34).rounded() }

    /// The radius of a shape inset by `inset` inside a shape of radius `outer`, never below
    /// `minimum` (so a tight inset still reads as rounded).
    public static func concentric(outer: CGFloat, inset: CGFloat, minimum: CGFloat = xs) -> CGFloat {
        max(minimum, outer - max(0, inset))
    }
}

/// Minimum hit targets. Apple's minimum is 44 pt; the comfortable default is 48.
nonisolated public enum LZHitTarget {
    public static let minimum: CGFloat = 44
    public static let comfortable: CGFloat = 48

    /// The padding that grows a `size` glyph to the target on one axis.
    public static func padding(for size: CGFloat, target: CGFloat = comfortable) -> CGFloat {
        max(0, (target - size) / 2)
    }
}

extension View {
    /// Grows the tappable area to at least `size` (48 pt by default) without changing the
    /// visual size.
    public func lzHitTarget(_ size: CGFloat = LZHitTarget.comfortable) -> some View {
        frame(minWidth: size, minHeight: size).contentShape(Rectangle())
    }
}

// MARK: - Elevation

/// Two-layer paper shadows tinted with plum (never grey). Dark mode multiplies the alphas by
/// 2.2 so the lift still reads on plum paper. Glass has its own depth; don't add these to glass.
nonisolated public enum LZElevation: String, CaseIterable, Sendable {
    /// Barely-there separation for resting cards.
    case soft
    /// Cards that invite a tap.
    case card
    /// Floating paper: toasts, popovers, dragged items.
    case float

    public struct Layer: Sendable, Hashable {
        public var y: CGFloat
        public var radius: CGFloat
        public var opacity: Double
    }

    /// The two shadow layers (y offset, blur radius, opacity) before the dark multiplier.
    public var layers: [Layer] {
        switch self {
        case .soft: [Layer(y: 1, radius: 3, opacity: 0.035), Layer(y: 4, radius: 12, opacity: 0.025)]
        case .card: [Layer(y: 2, radius: 5, opacity: 0.04), Layer(y: 8, radius: 24, opacity: 0.045)]
        case .float: [Layer(y: 6, radius: 14, opacity: 0.10), Layer(y: 18, radius: 44, opacity: 0.14)]
        }
    }

    public static let darkMultiplier = 2.2
    static let lightShadow = LZRGBA(hex: 0x3D2B46)
    static let darkShadow = LZRGBA(hex: 0x0D0813)

    /// The shadow colour for one layer in a scheme.
    public func color(_ layer: Layer, dark: Bool) -> LZRGBA {
        (dark ? Self.darkShadow : Self.lightShadow).opacity(min(1, layer.opacity * (dark ? Self.darkMultiplier : 1)))
    }
}

extension View {
    /// Lifts paper with a two-layer plum shadow. Under Increase Contrast the lift is replaced by
    /// a solid hairline in the caller's shape (see ``PaperCard``); shadows alone are not a
    /// boundary.
    public func lzElevation(_ elevation: LZElevation) -> some View {
        modifier(LZElevationModifier(elevation: elevation))
    }
}

struct LZElevationModifier: ViewModifier {
    var elevation: LZElevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let layers = elevation.layers
        content
            .shadow(color: elevation.color(layers[0], dark: dark).color, radius: layers[0].radius / 2, y: layers[0].y)
            .shadow(color: elevation.color(layers[1], dark: dark).color, radius: layers[1].radius / 2, y: layers[1].y)
    }
}
