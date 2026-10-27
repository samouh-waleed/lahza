import SwiftUI

/// One choice in a chip group.
public struct DDChipOption<ID: Hashable & Sendable>: Identifiable, Sendable {
    public var id: ID
    public var title: String
    public var systemImage: String?

    public init(_ id: ID, title: String, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// A glass chip. Selected chips take the accent tint and show a check; the glass shape morphs
/// between the two (inside a ``DDChipGroup``'s `GlassEffectContainer`).
public struct DDChip: View {
    private let title: String
    private let systemImage: String?
    private let isSelected: Bool
    private let isLoading: Bool
    private let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ title: String, systemImage: String? = nil, isSelected: Bool, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button {
            if !isLoading { action() }
        } label: {
            HStack(spacing: DDSpace.xs + 2) {
                if isLoading {
                    DDLoader(.star, size: 16, tint: isSelected ? .dd(.accentInk) : .dd(.gold), label: "")
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .fontWeight(.bold)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                        .transition(.opacity)
                }
                Text(title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
            }
            .font(.dd(.subheadline).weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .dd(.accentInk) : .dd(.ink))
            .padding(.horizontal, DDSpace.lg)
            .padding(.vertical, DDSpace.sm + 2)
            .frame(minHeight: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(DDPressStyle(scale: 0.96))
        .glassEffect(isSelected ? .regular.tint(Color.dd(.accent)).interactive() : .regular.interactive(), in: .capsule)
        .padding(.vertical, DDHitTarget.padding(for: 40, target: DDHitTarget.comfortable))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isLoading ? "In progress" : "")
    }
}

/// A wrapping group of glass chips in one `GlassEffectContainer`, so they sample the backdrop
/// together and morph as selection changes. Multi-select behaves like checkboxes, single-select
/// like radio buttons. Selection plays the `.selection` haptic.
public struct DDChipGroup<ID: Hashable & Sendable>: View {
    private let options: [DDChipOption<ID>]
    private let label: String
    private let isSelected: (ID) -> Bool
    private let toggle: (ID) -> Void
    private let selectionKey: [ID]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Multi-select.
    public init(_ label: String, options: [DDChipOption<ID>], selection: Binding<Set<ID>>) {
        self.label = label
        self.options = options
        isSelected = { selection.wrappedValue.contains($0) }
        toggle = { id in
            if selection.wrappedValue.contains(id) { selection.wrappedValue.remove(id) } else { selection.wrappedValue.insert(id) }
        }
        selectionKey = options.map(\.id).filter { selection.wrappedValue.contains($0) }
    }

    /// Single-select.
    public init(_ label: String, options: [DDChipOption<ID>], selection: Binding<ID>) {
        self.label = label
        self.options = options
        isSelected = { selection.wrappedValue == $0 }
        toggle = { selection.wrappedValue = $0 }
        selectionKey = [selection.wrappedValue]
    }

    public var body: some View {
        GlassEffectContainer(spacing: DDSpace.sm) {
            DDFlowLayout(spacing: DDSpace.sm, lineSpacing: 0) {
                ForEach(options) { option in
                    DDChip(option.title, systemImage: option.systemImage, isSelected: isSelected(option.id)) {
                        withAnimation(DDMotionToken.interface.animation(reduceMotion: reduceMotion)) { toggle(option.id) }
                    }
                    .glassEffectID(option.id, in: namespace)
                }
            }
        }
        .ddHaptic(.selection, trigger: selectionKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
