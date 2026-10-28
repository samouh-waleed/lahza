import SwiftUI

/// The one haptic vocabulary. Haptics mark **real actions only** (a choice made, something
/// completed), never scrolling, never decoration.
nonisolated public enum DDHaptic: String, CaseIterable, Sendable, Hashable {
    /// A choice among options: chips, segments, tabs.
    case selection
    /// Something completed: a target reached, something saved.
    case success
    /// A gentle confirmation: a card opening, pull-to-refresh arming.
    case softImpact
    /// A firmer beat: milestones.
    case rigidImpact
    /// Snapping into place: a slider detent.
    case alignment
    /// A value stepped up (reader size, a stepper).
    case increase
    /// A value stepped down.
    case decrease

    /// The SwiftUI feedback.
    public var feedback: SensoryFeedback {
        switch self {
        case .selection: .selection
        case .success: .success
        case .softImpact: .impact(flexibility: .soft, intensity: 0.6)
        case .rigidImpact: .impact(flexibility: .rigid, intensity: 0.85)
        case .alignment: .alignment
        case .increase: .increase
        case .decrease: .decrease
        }
    }
}

/// The user's feedback preferences. The app owns persistence (settings) and injects them with
/// ``SwiftUICore/View/ddFeedback(_:)``; DDDesign only reads them.
nonisolated public struct DDFeedbackSettings: Sendable, Hashable {
    /// Settings › Haptics. Off silences every haptic (SwiftUI and Core Haptics).
    public var hapticsEnabled: Bool
    /// Optional sounds (off by default). Any sound the app plays must use the `.ambient` audio
    /// session category, which the Ring/Silent switch silences.
    public var soundsEnabled: Bool

    public init(hapticsEnabled: Bool = true, soundsEnabled: Bool = false) {
        self.hapticsEnabled = hapticsEnabled
        self.soundsEnabled = soundsEnabled
    }

    public static let `default` = DDFeedbackSettings()

    /// Whether a sound may play now. `silenced` is true when the Ring/Silent switch is on silent
    /// (with the `.ambient` category the system enforces this too).
    public func allowsSound(silenced: Bool) -> Bool { soundsEnabled && !silenced }
}

extension EnvironmentValues {
    @Entry public var ddFeedback: DDFeedbackSettings = .default
}

extension View {
    /// Injects the user's feedback settings and keeps the Core Haptics engine in step.
    public func ddFeedback(_ settings: DDFeedbackSettings) -> some View {
        environment(\.ddFeedback, settings)
            .onChange(of: settings.hapticsEnabled, initial: true) { _, enabled in
                DDHapticEngine.shared.isEnabled = enabled
            }
    }

    /// Plays a haptic when `trigger` changes, unless the user turned haptics off.
    public func ddHaptic<T: Equatable>(_ haptic: DDHaptic, trigger: T) -> some View {
        modifier(DDHapticModifier(haptic: haptic, trigger: trigger, condition: nil))
    }

    /// Plays a haptic when `trigger` changes and `condition(old, new)` holds.
    public func ddHaptic<T: Equatable>(_ haptic: DDHaptic, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
        modifier(DDHapticModifier(haptic: haptic, trigger: trigger, condition: condition))
    }
}

struct DDHapticModifier<T: Equatable>: ViewModifier {
    let haptic: DDHaptic
    let trigger: T
    let condition: ((T, T) -> Bool)?
    @Environment(\.ddFeedback) private var feedback

    func body(content: Content) -> some View {
        let enabled = feedback.hapticsEnabled
        let condition = condition
        content.sensoryFeedback(haptic.feedback, trigger: trigger) { old, new in
            enabled && (condition?(old, new) ?? true)
        }
    }
}
