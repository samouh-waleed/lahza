import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Environment → appearance

nonisolated extension DDAppearance {
    /// The appearance SwiftUI is rendering with: colour scheme, Increase Contrast and Reduce
    /// Transparency.
    public init(_ environment: EnvironmentValues) {
        self.init(isDark: environment.colorScheme == .dark,
                  increasedContrast: environment.colorSchemeContrast == .increased,
                  reduceTransparency: environment.accessibilityReduceTransparency)
    }
}

nonisolated extension DDRGBA {
    /// The SwiftUI colour (sRGB).
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

// MARK: - ShapeStyle (preferred in views)

/// A palette token as a `ShapeStyle`. It resolves against the view's environment, so it follows
/// light/dark, Increase Contrast **and** Reduce Transparency (translucent tokens turn opaque):
///
/// ```swift
/// Text("Hello").foregroundStyle(.dd(.ink))
/// RoundedRectangle(cornerRadius: DDRadius.card).fill(.dd(.surface))
/// ```
nonisolated public struct DDColorStyle: ShapeStyle, Hashable {
    public var token: DDColorToken
    public var opacity: Double

    public init(_ token: DDColorToken, opacity: Double = 1) {
        self.token = token
        self.opacity = opacity
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        let rgba = DDPalette.rgba(token, DDAppearance(environment))
        return opacity >= 1 ? rgba.color : rgba.opacity(rgba.alpha * opacity).color
    }
}

nonisolated extension ShapeStyle where Self == DDColorStyle {
    /// A palette colour: `.foregroundStyle(.dd(.muted))`.
    public static func dd(_ token: DDColorToken, opacity: Double = 1) -> DDColorStyle { DDColorStyle(token, opacity: opacity) }
}

// MARK: - Color (for APIs that need a `Color`)

nonisolated extension Color {
    /// A dynamic `Color` for APIs that take `Color` rather than a `ShapeStyle` (`.tint`, glass
    /// tints, shadows). It follows light/dark and Increase Contrast through the trait collection.
    /// Reduce Transparency cannot be read there: pass `opaque: true` (from
    /// `@Environment(\.accessibilityReduceTransparency)`) for translucent tokens, or prefer
    /// `.dd(token)` as a `ShapeStyle`, which handles it.
    public static func dd(_ token: DDColorToken, opaque: Bool = false) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: DDDynamicColor.uiColor(token, opaque: opaque))
        #elseif canImport(AppKit)
        return Color(nsColor: DDDynamicColor.nsColor(token, opaque: opaque))
        #else
        return DDPalette.rgba(token, .light).color
        #endif
    }
}

/// Builds platform dynamic colours outside the main actor: the providers are called by the
/// render system on whatever thread resolves the colour.
nonisolated enum DDDynamicColor {
    #if canImport(UIKit)
    static func uiColor(_ token: DDColorToken, opaque: Bool) -> UIColor {
        UIColor { traits in
            let appearance = DDAppearance(isDark: traits.userInterfaceStyle == .dark,
                                          increasedContrast: traits.accessibilityContrast == .high,
                                          reduceTransparency: opaque)
            let c = DDPalette.rgba(token, appearance)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }
    #elseif canImport(AppKit)
    static func nsColor(_ token: DDColorToken, opaque: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let resolved = DDAppearance(isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                                        increasedContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua,
                                        reduceTransparency: opaque)
            let c = DDPalette.rgba(token, resolved)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }
    #endif
}
