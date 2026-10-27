import SwiftUI

/// A small rounded label: "Now", "Next", "Plus", "Saved". Tone-tinted paper, never glass.
public struct Pill: View {
    private let title: String
    private let systemImage: String?
    private let tone: DDTone
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String, systemImage: String? = nil, tone: DDTone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: DDSpace.xs) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.dd(.caption).weight(.semibold))
        .foregroundStyle(.dd(tone.foreground))
        .padding(.horizontal, DDSpace.md - 2)
        .padding(.vertical, DDSpace.xs + 1)
        .background(.dd(tone.fill), in: Capsule(style: .continuous))
        .overlay {
            if contrast == .increased {
                Capsule(style: .continuous).strokeBorder(.dd(tone.solid), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A count badge (unread, new items). Hidden from VoiceOver unless given a label.
public struct DDBadge: View {
    private let count: Int
    private let label: String?

    public init(count: Int, accessibilityLabel: String? = nil) {
        self.count = count
        label = accessibilityLabel
    }

    public var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.dd(.caption).weight(.bold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.dd(.accentInk))
            .padding(.horizontal, DDSpace.sm - 2)
            .frame(minWidth: 20, minHeight: 20)
            .background(.dd(.accent), in: Capsule(style: .continuous))
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
    }
}

/// A rounded square holding a glyph in a tone: the leading icon of rows, empty states and
/// feature tiles.
public struct IconBadge: View {
    private let systemImage: String
    private let tone: DDTone
    private let size: CGFloat
    @ScaledMetric private var scale: CGFloat = 1

    public init(_ systemImage: String, tone: DDTone = .accent, size: CGFloat = 40) {
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        let side = size * min(scale, 1.6)
        Image(systemName: systemImage)
            .font(.system(size: side * 0.46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.dd(tone.foreground))
            .frame(width: side, height: side)
            .background(.dd(tone.fill), in: RoundedRectangle(cornerRadius: DDRadius.badge(size: side), style: .continuous))
            .accessibilityHidden(true)
    }
}
