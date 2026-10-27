import SwiftUI

extension View {
    /// Draws the keyboard-focus ring (2 pt accent, 3 pt outside the shape) when this
    /// focusable control has focus, replacing the system halo. Use on custom controls drawn on
    /// paper; glass button styles keep the system's focus effect.
    public func ddFocusRing<S: InsettableShape>(_ shape: S) -> some View {
        modifier(DDFocusRingModifier(shape: shape))
    }
}

struct DDFocusRingModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    shape.inset(by: -3).strokeBorder(.dd(.accent), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
