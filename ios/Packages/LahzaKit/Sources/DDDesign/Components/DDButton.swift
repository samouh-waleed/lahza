import SwiftUI

/// The four button voices.
nonisolated public enum DDButtonRole: String, CaseIterable, Sendable {
    /// The one primary action on a screen: tinted prominent glass.
    case primary
    /// Other actions: clear glass.
    case secondary
    /// Calm text actions ("Not now", "Continue free"). Never shaming, never glass.
    case quiet
    /// Irreversible actions (delete). Glass with the danger ink, and the destructive role.
    case destructive
}

nonisolated public enum DDButtonSize: String, CaseIterable, Sendable {
    /// 56 pt tall.
    case regular
    /// 48 pt tall.
    case small

    var minHeight: CGFloat { self == .regular ? 56 : 48 }
    /// The label's own minimum height inside the glass (the style adds its padding).
    var glassLabelHeight: CGFloat { self == .regular ? 27 : 34 }
    var horizontalPadding: CGFloat { self == .regular ? 20 : 14 }
}

/// The button. Glass lives only here, on controls:
/// - `.primary` is `.glassProminent` tinted with the accent (ivory on plum by day, plum on
///   apricot at night), for the single most important action on a screen;
/// - `.secondary` is `.glass`;
/// - `.quiet` is plain accent text;
/// - `.destructive` is glass with danger ink and the destructive role.
///
/// States: pressed (glass responds to touch; quiet dims), disabled (`.disabled(_:)`), loading
/// (`isLoading`: the label steps aside for a rising sun, taps are ignored, VoiceOver hears
/// "in progress"), and focus (the system focus effect for keyboards).
public struct DDButton: View {
    private let title: String
    private let systemImage: String?
    private let role: DDButtonRole
    private let size: DDButtonSize
    private let isLoading: Bool
    private let fullWidth: Bool
    private let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ title: String, systemImage: String? = nil, role: DDButtonRole = .primary, size: DDButtonSize = .regular,
                isLoading: Bool = false, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.size = size
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        styled(Button(role: role == .destructive ? .destructive : nil) {
            guard !isLoading else { return }
            action()
        } label: {
            label
        })
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "In progress" : "")
    }

    private var label: some View {
        HStack(spacing: DDSpace.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.center)
        }
        .font(.dd(size == .regular ? .callout : .subheadline).weight(.semibold))
        .foregroundStyle(foreground)
        .opacity(isLoading ? 0 : 1)
        .overlay {
            if isLoading {
                DDLoader(.sun, size: size == .regular ? 26 : 22, tint: foreground, label: "")
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(minHeight: role == .quiet ? size.minHeight : size.glassLabelHeight)
        .padding(.horizontal, role == .quiet ? DDSpace.sm : size.horizontalPadding - 12)
        .contentShape(Rectangle())
        .ddAnimation(.interface, value: isLoading)
    }

    private var foreground: DDColorStyle {
        switch role {
        case .primary: .dd(.accentInk)
        case .secondary: .dd(.ink)
        case .quiet: .dd(.accent)
        case .destructive: .dd(.dangerText)
        }
    }

    /// A capsule, or a rounded rectangle once labels may wrap onto several lines.
    private var borderShape: ButtonBorderShape {
        dynamicTypeSize.isAccessibilitySize ? .roundedRectangle(radius: DDRadius.lg) : .capsule
    }

    @ViewBuilder
    private func styled(_ button: Button<some View>) -> some View {
        switch role {
        case .primary:
            button
                .buttonStyle(.glassProminent)
                .buttonBorderShape(borderShape)
                .tint(Color.dd(.accent))
                .controlSize(size == .regular ? .large : .regular)
        case .secondary, .destructive:
            button
                .buttonStyle(.glass)
                .buttonBorderShape(borderShape)
                .controlSize(size == .regular ? .large : .regular)
        case .quiet:
            button
                .buttonStyle(DDPressStyle(scale: 1))
                .frame(minHeight: size.minHeight)
                .ddFocusRing(Capsule())
        }
    }
}

/// A round glass button with one glyph (close, share, more). Always carries a VoiceOver label.
public struct DDIconButton: View {
    public enum Style: String, CaseIterable, Sendable {
        /// Clear glass (toolbars, sheets, over imagery).
        case glass
        /// Tinted prominent glass (a floating primary action).
        case prominent
        /// No glass: a tone-tinted paper disc (inside cards).
        case paper
    }

    private let systemImage: String
    private let label: String
    private let style: Style
    private let size: CGFloat
    private let isLoading: Bool
    private let action: () -> Void

    /// - Parameters:
    ///   - label: what VoiceOver says ("Close", "Share this photo").
    ///   - size: the visual diameter (the hit area is never below 44 pt).
    public init(_ systemImage: String, label: String, style: Style = .glass, size: CGFloat = 44, isLoading: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        let glyph = Group {
            if isLoading {
                DDLoader(.star, size: size * 0.5, tint: style == .prominent ? .dd(.accentInk) : .dd(.gold), label: "")
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(style == .prominent ? .dd(.accentInk) : (style == .paper ? .dd(.accent) : .dd(.ink)))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())

        Group {
            switch style {
            case .glass:
                Button { if !isLoading { action() } } label: { glyph }
                    .buttonStyle(DDPressStyle(scale: 1))
                    .glassEffect(.regular.interactive(), in: .circle)
            case .prominent:
                Button { if !isLoading { action() } } label: { glyph }
                    .buttonStyle(DDPressStyle(scale: 1))
                    .glassEffect(.regular.tint(Color.dd(.accent)).interactive(), in: .circle)
            case .paper:
                Button { if !isLoading { action() } } label: {
                    glyph.background(.dd(.accentSoft), in: Circle())
                }
                .buttonStyle(DDPressStyle())
                .ddFocusRing(Circle())
            }
        }
        .frame(minWidth: DDHitTarget.minimum, minHeight: DDHitTarget.minimum)
        .contentShape(Circle())
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: systemImage)
        }
        .accessibilityLabel(label)
        .accessibilityValue(isLoading ? "In progress" : "")
    }
}
