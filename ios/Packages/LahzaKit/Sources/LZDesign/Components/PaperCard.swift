import SwiftUI

/// The content surface: opaque warm paper. Content rests here, never on glass.
///
/// The card sets `.containerShape` to its rounded rectangle, so inner shapes can be
/// `ConcentricRectangle()` and stay concentric with the card's corners.
public struct PaperCard<Content: View>: View {
    public enum Style: Hashable, Sendable {
        /// Surface paper with a hairline (the default).
        case paper
        /// Paper that invites a tap: a hairline and a barely visible lift.
        case raised
        /// A pastel wash for gentle emphasis (onboarding tiles).
        case wash(LZWash)
        /// Recessed paper (surface2) for secondary groups.
        case recessed
        /// Paper floating over a backdrop: 94 % surface (opaque under Reduce Transparency) with
        /// a lift.
        case onSky
    }

    private let style: Style
    private let padding: CGFloat
    private let radius: CGFloat
    private let action: (() -> Void)?
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// - Parameter action: makes the whole card one button with subtle press feedback.
    public init(style: Style = .paper, padding: CGFloat = LZSpace.lg + 2, radius: CGFloat = LZRadius.card,
                action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.style = style
        self.padding = padding
        self.radius = radius
        self.action = action
        self.content = content()
    }

    public var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(LZPressStyle(scale: LZMotion.cardPressScale))
                .lzFocusRing(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            card
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(fill) }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.lz(.lineSolid), lineWidth: 1)
                } else if showsHairline {
                    shape.strokeBorder(.lz(.line), lineWidth: 0.5)
                }
            }
            .modifier(LZCardLift(elevation: elevation))
            .containerShape(shape)
    }

    private var elevation: LZElevation? {
        switch style {
        case .raised, .onSky: .soft
        default: nil
        }
    }

    private var showsHairline: Bool {
        switch style {
        case .raised, .onSky: true
        default: false
        }
    }

    private var fill: LZColorStyle {
        switch style {
        case .paper, .raised: .lz(.surface)
        case .wash(let wash): .lz(wash.token)
        case .recessed: .lz(.surface2)
        case .onSky: .lz(.surface, opacity: reduceTransparency ? 1 : 0.94)
        }
    }
}

/// The lift each paper style gets.
struct LZCardLift: ViewModifier {
    let elevation: LZElevation?
    @ViewBuilder func body(content: Content) -> some View {
        if let elevation { content.lzElevation(elevation) } else { content }
    }
}

/// A native section heading with an optional eyebrow, caption and trailing action.
public struct SectionHeader: View {
    private let title: String
    private let eyebrow: String?
    private let caption: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ title: String, eyebrow: String? = nil, caption: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.eyebrow = eyebrow
        self.caption = caption
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        LZAdaptiveStack(spacing: LZSpace.sm, verticalAlignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: LZSpace.xs) {
                if let eyebrow {
                    Text(eyebrow).lzText(.label).foregroundStyle(.lz(.muted))
                }
                Text(title)
                    .lzText(.displaySmall)
                    .foregroundStyle(.lz(.ink))
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    Text(caption).lzText(.caption).foregroundStyle(.lz(.muted))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                LZButton(actionTitle, role: .quiet, size: .small, action: action)
            }
        }
    }
}
