import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Motion vocabulary. Every animation reports a change of state, then rests. Under Reduce Motion
/// every token becomes a short cross-fade (or nothing), never a slide, scale or bounce.
nonisolated public enum DDMotion {
    /// Press feedback: 100–160 ms.
    public static let touch: TimeInterval = 0.14
    /// Interface state changes (toggles, chips, segments, rows): 220–320 ms.
    public static let interface: TimeInterval = 0.24
    /// Feature moments (reveals, hero changes, sheets of content): 450–700 ms.
    public static let feature: TimeInterval = 0.48
    /// Delay between staggered siblings.
    public static let staggerStep: TimeInterval = 0.04
    /// Siblings beyond this index share the last delay, so long lists never crawl in.
    public static let staggerCap = 8
    /// The cross-fade that replaces motion under Reduce Motion.
    public static let reducedFade: TimeInterval = 0.12
    /// How far entering content rises (points).
    public static let riseDistance: CGFloat = 6
    /// Press scale for buttons and chips; cards press less.
    public static let pressScale: CGFloat = 0.99
    public static let cardPressScale: CGFloat = 0.995

    /// The ranges each duration family must stay inside (asserted by tests).
    public static let touchRange: ClosedRange<TimeInterval> = 0.10...0.16
    public static let interfaceRange: ClosedRange<TimeInterval> = 0.22...0.32
    public static let featureRange: ClosedRange<TimeInterval> = 0.45...0.70

    /// The delay for the `index`th staggered sibling.
    public static func staggerDelay(index: Int) -> TimeInterval {
        Double(min(max(0, index), staggerCap)) * staggerStep
    }

    /// Reduce Motion, read from the system (for `withDDAnimation` outside a view body).
    @MainActor public static var systemReduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }
}

/// Named animations.
nonisolated public enum DDMotionToken: String, CaseIterable, Sendable {
    /// Press and release (≈140 ms, no bounce).
    case touch
    /// Interface state changes (≈240 ms, smooth).
    case interface
    /// Feature reveals (≈480 ms, settling without bounce).
    case feature
    /// Content entering: an ease-out curve `cubic-bezier(.2,.8,.2,1)`, 480 ms.
    case enter
    /// Sheet-like travel that settles without bounce.
    case sheet
    /// Celebrations (bouncier, still under 700 ms).
    case celebrate
    /// Slow colour shifts: backgrounds re-keying, ink crossing over (1.2 s).
    case ambient

    /// The nominal duration (seconds).
    public var duration: TimeInterval {
        switch self {
        case .touch: DDMotion.touch
        case .interface: DDMotion.interface
        case .feature, .enter: DDMotion.feature
        case .sheet: 0.5
        case .celebrate: 0.62
        case .ambient: 1.2
        }
    }

    /// The full-motion animation.
    public var animation: Animation {
        switch self {
        case .touch: .spring(duration: DDMotion.touch, bounce: 0)
        case .interface: .spring(duration: DDMotion.interface, bounce: 0)
        case .feature: .spring(duration: DDMotion.feature, bounce: 0)
        case .enter: .timingCurve(0.2, 0.8, 0.2, 1, duration: DDMotion.feature)
        case .sheet: .spring(duration: 0.5, bounce: 0)
        case .celebrate: .spring(duration: 0.62, bounce: 0.3)
        case .ambient: .easeInOut(duration: 1.2)
        }
    }

    /// The Reduce Motion replacement: a short cross-fade (colour shifts keep a gentle fade).
    public var reducedAnimation: Animation {
        switch self {
        case .ambient: .easeInOut(duration: 0.6)
        default: .easeInOut(duration: DDMotion.reducedFade)
        }
    }

    public func animation(reduceMotion: Bool) -> Animation { reduceMotion ? reducedAnimation : animation }
}

/// Runs `body` with a motion token's animation, honouring the system's Reduce Motion.
@MainActor @discardableResult
public func withDDAnimation<Result>(_ token: DDMotionToken, reduceMotion: Bool? = nil, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(token.animation(reduceMotion: reduceMotion ?? DDMotion.systemReduceMotion), body)
}

extension View {
    /// Animates changes to `value` with a motion token, as a cross-fade under Reduce Motion.
    public func ddAnimation<V: Equatable>(_ token: DDMotionToken, value: V) -> some View {
        modifier(DDAnimationModifier(token: token, value: value))
    }

    /// Inserts and removes this view with a ``DDTransition`` (opacity-only under Reduce Motion).
    public func ddTransition(_ transition: DDTransition) -> some View {
        modifier(DDTransitionModifier(transition: transition))
    }

    /// Fades this view in (rising 6 pt) the first time it appears, `index` steps after its
    /// siblings. Under Reduce Motion it fades only. VoiceOver sees it immediately.
    public func ddAppear(index: Int = 0) -> some View {
        modifier(DDAppearModifier(index: index))
    }
}

struct DDAnimationModifier<V: Equatable>: ViewModifier {
    let token: DDMotionToken
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(token.animation(reduceMotion: reduceMotion), value: value)
    }
}

/// Insertion/removal transitions.
nonisolated public enum DDTransition: String, CaseIterable, Sendable {
    /// Rise from below and fade (cards, rows entering).
    case rise
    /// Drop from above and fade (toasts).
    case drop
    /// Scale from 96 % and fade (popovers, badges).
    case scale
    /// Fade only.
    case fade

    @MainActor public func anyTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch self {
        case .rise: return .opacity.combined(with: .offset(y: DDMotion.riseDistance))
        case .drop: return .opacity.combined(with: .offset(y: -DDMotion.riseDistance))
        case .scale: return .opacity.combined(with: .scale(scale: 0.96))
        case .fade: return .opacity
        }
    }
}

struct DDTransitionModifier: ViewModifier {
    let transition: DDTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(transition.anyTransition(reduceMotion: reduceMotion))
    }
}

struct DDAppearModifier: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : DDMotion.riseDistance)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion
                    ? Animation.easeInOut(duration: 0.26)
                    : DDMotionToken.enter.animation
                withAnimation(animation.delay(DDMotion.staggerDelay(index: index))) { shown = true }
            }
    }
}

// MARK: - Press feedback

/// A shared press style for paper controls (rows, cards, chips drawn on paper): scales to
/// 99 % on the touch spring, or dims slightly under Reduce Motion. Disabled controls dim.
public struct DDPressStyle: ButtonStyle {
    var scale: CGFloat

    public init(scale: CGFloat = DDMotion.pressScale) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        DDPressBody(configuration: configuration, scale: scale)
    }
}

struct DDPressBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.5)
            .animation(DDMotionToken.touch.animation(reduceMotion: reduceMotion), value: pressed)
    }
}
