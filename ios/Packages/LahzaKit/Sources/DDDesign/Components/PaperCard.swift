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
        case wash(DDWash)
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
    public init(style: Style = .paper, padding: CGFloat = DDSpace.lg + 2, radius: CGFloat = DDRadius.card,
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
                .buttonStyle(DDPressStyle(scale: DDMotion.cardPressScale))
                .ddFocusRing(RoundedRectangle(cornerRadius: radius, style: .continuous))
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
                    shape.strokeBorder(.dd(.lineSolid), lineWidth: 1)
                } else if showsHairline {
                    shape.strokeBorder(.dd(.line), lineWidth: 0.5)
                }
            }
            .modifier(DDCardLift(elevation: elevation))
            .containerShape(shape)
    }

    private var elevation: DDElevation? {
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

    private var fill: DDColorStyle {
        switch style {
        case .paper, .raised: .dd(.surface)
        case .wash(let wash): .dd(wash.token)
        case .recessed: .dd(.surface2)
        case .onSky: .dd(.surface, opacity: reduceTransparency ? 1 : 0.94)
        }
    }
}

/// The lift each paper style gets.
struct DDCardLift: ViewModifier {
    let elevation: DDElevation?
    @ViewBuilder func body(content: Content) -> some View {
        if let elevation { content.ddElevation(elevation) } else { content }
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
        DDAdaptiveStack(spacing: DDSpace.sm, verticalAlignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: DDSpace.xs) {
                if let eyebrow {
                    Text(eyebrow).ddText(.label).foregroundStyle(.dd(.muted))
                }
                Text(title)
                    .ddText(.displaySmall)
                    .foregroundStyle(.dd(.ink))
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    Text(caption).ddText(.caption).foregroundStyle(.dd(.muted))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                DDButton(actionTitle, role: .quiet, size: .small, action: action)
            }
        }
    }
}
