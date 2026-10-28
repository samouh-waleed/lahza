import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Environment → appearance

nonisolated extension LZAppearance {
    /// The appearance SwiftUI is rendering with: colour scheme, Increase Contrast and Reduce
    /// Transparency.
    public init(_ environment: EnvironmentValues) {
        self.init(isDark: environment.colorScheme == .dark,
                  increasedContrast: environment.colorSchemeContrast == .increased,
                  reduceTransparency: environment.accessibilityReduceTransparency)
    }
}

nonisolated extension LZRGBA {
    /// The SwiftUI colour (sRGB).
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

// MARK: - ShapeStyle (preferred in views)

/// A palette token as a `ShapeStyle`. It resolves against the view's environment, so it follows
/// light/dark, Increase Contrast **and** Reduce Transparency (translucent tokens turn opaque):
///
/// ```swift
/// Text("Hello").foregroundStyle(.lz(.ink))
/// RoundedRectangle(cornerRadius: LZRadius.card).fill(.lz(.surface))
/// ```
nonisolated public struct LZColorStyle: ShapeStyle, Hashable {
    public var token: LZColorToken
    public var opacity: Double

    public init(_ token: LZColorToken, opacity: Double = 1) {
        self.token = token
        self.opacity = opacity
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        let rgba = LZPalette.rgba(token, LZAppearance(environment))
        return opacity >= 1 ? rgba.color : rgba.opacity(rgba.alpha * opacity).color
    }
}

nonisolated extension ShapeStyle where Self == LZColorStyle {
    /// A palette colour: `.foregroundStyle(.lz(.muted))`.
    public static func lz(_ token: LZColorToken, opacity: Double = 1) -> LZColorStyle { LZColorStyle(token, opacity: opacity) }
}

// MARK: - Color (for APIs that need a `Color`)

nonisolated extension Color {
    /// A dynamic `Color` for APIs that take `Color` rather than a `ShapeStyle` (`.tint`, glass
    /// tints, shadows). It follows light/dark and Increase Contrast through the trait collection.
    /// Reduce Transparency cannot be read there: pass `opaque: true` (from
    /// `@Environment(\.accessibilityReduceTransparency)`) for translucent tokens, or prefer
    /// `.lz(token)` as a `ShapeStyle`, which handles it.
    public static func lz(_ token: LZColorToken, opaque: Bool = false) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: LZDynamicColor.uiColor(token, opaque: opaque))
        #elseif canImport(AppKit)
        return Color(nsColor: LZDynamicColor.nsColor(token, opaque: opaque))
        #else
        return LZPalette.rgba(token, .light).color
        #endif
    }
}

/// Builds platform dynamic colours outside the main actor: the providers are called by the
/// render system on whatever thread resolves the colour.
nonisolated enum LZDynamicColor {
    #if canImport(UIKit)
    static func uiColor(_ token: LZColorToken, opaque: Bool) -> UIColor {
        UIColor { traits in
            let appearance = LZAppearance(isDark: traits.userInterfaceStyle == .dark,
                                          increasedContrast: traits.accessibilityContrast == .high,
                                          reduceTransparency: opaque)
            let c = LZPalette.rgba(token, appearance)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }
    #elseif canImport(AppKit)
    static func nsColor(_ token: LZColorToken, opaque: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let resolved = LZAppearance(isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                                        increasedContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua,
                                        reduceTransparency: opaque)
            let c = LZPalette.rgba(token, resolved)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }
    #endif
}
