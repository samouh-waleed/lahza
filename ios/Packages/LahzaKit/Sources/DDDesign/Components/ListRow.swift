import SwiftUI

/// What sits at a row's trailing edge.
nonisolated public enum DDRowAccessory: Sendable, Hashable {
    case none
    /// Navigates deeper.
    case chevron
    /// Opens outside the app.
    case external
    /// The chosen option in a list of choices.
    case checkmark
}

/// A paper row: optional icon badge, title, subtitle, trailing value and accessory. Tappable
/// rows highlight on press and read as one element to VoiceOver. At accessibility text sizes the
/// value moves under the title so nothing truncates.
public struct ListRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tone: DDTone
    private let value: String?
    private let accessory: DDRowAccessory
    private let isLoading: Bool
    private let action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: DDTone = .accent, value: String? = nil,
                accessory: DDRowAccessory = .none, isLoading: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.value = value
        self.accessory = accessory
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        if let action {
            Button {
                if !isLoading { action() }
            } label: {
                content
            }
            .buttonStyle(DDRowPressStyle())
            .accessibilityAddTraits(accessory == .checkmark ? .isSelected : [])
            .accessibilityValue(isLoading ? "In progress" : (value ?? ""))
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DDSpace.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DDSpace.md + 2))
        return layout {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.dd(tone.foreground))
                    .frame(width: 26, height: 32)
                    .accessibilityHidden(true)
                    .padding(.top, DDSpace.md - 2)
                    .padding(.bottom, stacked ? 0 : DDSpace.md - 2)
            }
            HStack(alignment: stacked ? .top : .center, spacing: DDSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ddText(.body)
                        .foregroundStyle(.dd(.ink))
                    if let subtitle {
                        Text(subtitle)
                            .ddText(.caption)
                            .foregroundStyle(.dd(.muted))
                    }
                    if stacked, let value {
                        Text(value)
                            .ddText(.subheadline)
                            .foregroundStyle(.dd(.muted))
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked, let value {
                    Text(value)
                        .ddText(.subheadline)
                        .foregroundStyle(.dd(.muted))
                        .multilineTextAlignment(.trailing)
                }
                trailing
            }
            .padding(.top, stacked && systemImage != nil ? 0 : DDSpace.md - 2)
            .padding(.bottom, DDSpace.md - 2)
            .frame(minHeight: stacked ? nil : 56)
            .ddRowSeparator()
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var trailing: some View {
        if isLoading {
            DDLoader(.star, size: 18, label: "")
        } else {
            switch accessory {
            case .none: EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.dd(.muted))
                    .accessibilityHidden(true)
            case .external:
                Image(systemName: "arrow.up.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.dd(.muted))
                    .accessibilityHidden(true)
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(.dd(.accent))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Row press: a soft recessed highlight behind the row (no scale), concentric with the card.
struct DDRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DDRowPressBody(configuration: configuration)
    }
}

private struct DDRowPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background {
                // Reaches the card's edges in a row group; its corners follow the card's where
                // they meet it (concentric) and stay softly rounded elsewhere.
                ConcentricRectangle(corners: .concentric(minimum: .fixed(DDRadius.sm)), isUniform: false)
                    .fill(.dd(.surface2))
                    .padding(.horizontal, -DDSpace.lg)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(DDMotionToken.touch.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
            .ddFocusRing(RoundedRectangle(cornerRadius: DDRadius.sm, style: .continuous))
    }
}

/// Open rows separated by fine rules. Use one clear section heading above each group.
/// Put ``ListRow`` and ``DDToggleRow`` inside.
public struct DDRowGroup<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Group {
            VStack(spacing: 0) { content }
                .padding(.vertical, DDSpace.xs)
                .overlayPreferenceValue(DDRowTextAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        let increased = contrast == .increased
                        ForEach(Array(anchors.dropLast().enumerated()), id: \.offset) { _, anchor in
                            let rect = proxy[anchor]
                            let width = max(0, proxy.size.width - rect.minX)
                            Rectangle()
                                .fill(increased ? .dd(.lineSolid) : .dd(.line))
                                .frame(width: width, height: increased ? 1 : 0.5)
                                .position(x: rect.minX + width / 2, y: rect.maxY)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }
}

/// Each row's text column (leading edge and bottom), for ``DDRowGroup``'s separators.
struct DDRowTextAnchorKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publishes this row's text column (from `leadingInset` to the trailing edge, full row
    /// height) so a ``DDRowGroup`` can draw the separator under it.
    func ddRowSeparator(leadingInset: CGFloat = 0) -> some View {
        background {
            Color.clear
                .padding(.leading, leadingInset)
                .anchorPreference(key: DDRowTextAnchorKey.self, value: .bounds) { [$0] }
        }
    }
}

/// A row with a switch. The whole row toggles; the switch track is the accent when on.
public struct DDToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tone: DDTone
    @Binding private var isOn: Bool
    @ScaledMetric private var badgeScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var badgeSide: CGFloat { 26 }

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: DDTone = .accent, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        _isOn = isOn
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DDSpace.sm))
            : AnyLayout(HStackLayout(spacing: DDSpace.md + 2))
        return Toggle(isOn: $isOn) {
            layout {
                if let systemImage {
                    Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.dd(tone.foreground))
                    .frame(width: 26, height: 32)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).ddText(.body).foregroundStyle(.dd(.ink))
                    if let subtitle {
                        Text(subtitle).ddText(.caption).foregroundStyle(.dd(.muted))
                    }
                }
            }
        }
        .tint(Color.dd(.accent))
        .padding(.vertical, DDSpace.md - 2)
        .frame(minHeight: 56)
        .ddRowSeparator(leadingInset: systemImage == nil || stacked ? 0 : badgeSide + DDSpace.md + 2)
    }
}
