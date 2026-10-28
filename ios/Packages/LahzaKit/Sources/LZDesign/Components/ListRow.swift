import SwiftUI

/// What sits at a row's trailing edge.
nonisolated public enum LZRowAccessory: Sendable, Hashable {
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
    private let tone: LZTone
    private let value: String?
    private let accessory: LZRowAccessory
    private let isLoading: Bool
    private let action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: LZTone = .accent, value: String? = nil,
                accessory: LZRowAccessory = .none, isLoading: Bool = false, action: (() -> Void)? = nil) {
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
            .buttonStyle(LZRowPressStyle())
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
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LZSpace.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: LZSpace.md + 2))
        return layout {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.lz(tone.foreground))
                    .frame(width: 26, height: 32)
                    .accessibilityHidden(true)
                    .padding(.top, LZSpace.md - 2)
                    .padding(.bottom, stacked ? 0 : LZSpace.md - 2)
            }
            HStack(alignment: stacked ? .top : .center, spacing: LZSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lzText(.body)
                        .foregroundStyle(.lz(.ink))
                    if let subtitle {
                        Text(subtitle)
                            .lzText(.caption)
                            .foregroundStyle(.lz(.muted))
                    }
                    if stacked, let value {
                        Text(value)
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.muted))
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked, let value {
                    Text(value)
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.muted))
                        .multilineTextAlignment(.trailing)
                }
                trailing
            }
            .padding(.top, stacked && systemImage != nil ? 0 : LZSpace.md - 2)
            .padding(.bottom, LZSpace.md - 2)
            .frame(minHeight: stacked ? nil : 56)
            .lzRowSeparator()
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var trailing: some View {
        if isLoading {
            LZLoader(.star, size: 18, label: "")
        } else {
            switch accessory {
            case .none: EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.lz(.muted))
                    .accessibilityHidden(true)
            case .external:
                Image(systemName: "arrow.up.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.lz(.muted))
                    .accessibilityHidden(true)
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(.lz(.accent))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Row press: a soft recessed highlight behind the row (no scale), concentric with the card.
struct LZRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LZRowPressBody(configuration: configuration)
    }
}

private struct LZRowPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background {
                // Reaches the card's edges in a row group; its corners follow the card's where
                // they meet it (concentric) and stay softly rounded elsewhere.
                ConcentricRectangle(corners: .concentric(minimum: .fixed(LZRadius.sm)), isUniform: false)
                    .fill(.lz(.surface2))
                    .padding(.horizontal, -LZSpace.lg)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(LZMotionToken.touch.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
            .lzFocusRing(RoundedRectangle(cornerRadius: LZRadius.sm, style: .continuous))
    }
}

/// Open rows separated by fine rules. Use one clear section heading above each group.
/// Put ``ListRow`` and ``LZToggleRow`` inside.
public struct LZRowGroup<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Group {
            VStack(spacing: 0) { content }
                .padding(.vertical, LZSpace.xs)
                .overlayPreferenceValue(LZRowTextAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        let increased = contrast == .increased
                        ForEach(Array(anchors.dropLast().enumerated()), id: \.offset) { _, anchor in
                            let rect = proxy[anchor]
                            let width = max(0, proxy.size.width - rect.minX)
                            Rectangle()
                                .fill(increased ? .lz(.lineSolid) : .lz(.line))
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

/// Each row's text column (leading edge and bottom), for ``LZRowGroup``'s separators.
struct LZRowTextAnchorKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publishes this row's text column (from `leadingInset` to the trailing edge, full row
    /// height) so a ``LZRowGroup`` can draw the separator under it.
    func lzRowSeparator(leadingInset: CGFloat = 0) -> some View {
        background {
            Color.clear
                .padding(.leading, leadingInset)
                .anchorPreference(key: LZRowTextAnchorKey.self, value: .bounds) { [$0] }
        }
    }
}

/// A row with a switch. The whole row toggles; the switch track is the accent when on.
public struct LZToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tone: LZTone
    @Binding private var isOn: Bool
    @ScaledMetric private var badgeScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var badgeSide: CGFloat { 26 }

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: LZTone = .accent, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        _isOn = isOn
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LZSpace.sm))
            : AnyLayout(HStackLayout(spacing: LZSpace.md + 2))
        return Toggle(isOn: $isOn) {
            layout {
                if let systemImage {
                    Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.lz(tone.foreground))
                    .frame(width: 26, height: 32)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lzText(.body).foregroundStyle(.lz(.ink))
                    if let subtitle {
                        Text(subtitle).lzText(.caption).foregroundStyle(.lz(.muted))
                    }
                }
            }
        }
        .tint(Color.lz(.accent))
        .padding(.vertical, LZSpace.md - 2)
        .frame(minHeight: 56)
        .lzRowSeparator(leadingInset: systemImage == nil || stacked ? 0 : badgeSide + LZSpace.md + 2)
    }
}
