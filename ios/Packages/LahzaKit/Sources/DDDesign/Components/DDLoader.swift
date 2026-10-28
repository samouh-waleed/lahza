import SwiftUI

/// The loading indicator. There are no bare spinners: a small sun rises over a horizon
/// line and glints, or a star glints in place. It is a status loop, so it stops off screen and in
/// the background; under Reduce Motion it stays still and breathes by opacity alone.
public struct DDLoader: View {
    public enum Kind: String, CaseIterable, Sendable {
        /// A sun rising over a horizon line (default).
        case sun
        /// A four-point star glinting (for tight spots: buttons, chips).
        case star
    }

    private let kind: Kind
    private let size: CGFloat
    private let tint: DDColorStyle
    private let label: String
    @Environment(\.ddStatusMotionAllowed) private var allowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - tint: the glyph colour (gold on paper; pass `.dd(.accentInk)` on a primary button).
    ///   - label: what VoiceOver says.
    public init(_ kind: Kind = .sun, size: CGFloat = 28, tint: DDColorStyle = .dd(.gold), label: String = "Loading") {
        self.kind = kind
        self.size = size
        self.tint = tint
        self.label = label
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !allowed)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Group {
                switch kind {
                case .sun: sun(DDLoaderPhase.sun(at: t, reduceMotion: reduceMotion))
                case .star: star(DDLoaderPhase.star(at: t, reduceMotion: reduceMotion))
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func sun(_ phase: DDLoaderPhase.Sun) -> some View {
        DDRisingSun(rise: phase.rise, rays: phase.rays, tint: tint)
            .opacity(phase.opacity)
    }

    private func star(_ phase: DDLoaderPhase.Star) -> some View {
        DDSparkle()
            .fill(tint)
            .frame(width: size * 0.8, height: size * 0.8)
            .scaleEffect(phase.scale)
            .rotationEffect(.degrees(phase.rotation))
            .opacity(phase.opacity)
            .frame(width: size, height: size)
    }
}

/// A four-point sparkle.
nonisolated public struct DDSparkle: Shape {
    public var pinch: CGFloat

    public init(pinch: CGFloat = 0.22) { self.pinch = pinch }

    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let inner = r * pinch
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + inner, y: c.y - inner))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + inner, y: c.y + inner))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - inner, y: c.y + inner))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - inner, y: c.y - inner))
        path.closeSubpath()
        return path
    }
}

/// The loaders' timing (pure, host-tested).
nonisolated public enum DDLoaderPhase {
    public struct Sun: Sendable, Hashable {
        /// 0 = below the horizon, 1 = fully risen.
        public var rise: Double
        /// Ray visibility 0…1.
        public var rays: Double
        public var opacity: Double
    }

    public struct Star: Sendable, Hashable {
        public var scale: Double
        public var rotation: Double
        public var opacity: Double
    }

    /// One sunrise cycle: rise 1.1 s, glint 0.5 s, sink 0.7 s, rest 0.3 s. The sun never sets
    /// below ``lowestRise``, so there is always a sun on the horizon.
    public static let sunCycle: TimeInterval = 2.6
    public static let starCycle: TimeInterval = 1.8
    public static let lowestRise = 0.45
    /// Reduce Motion breathes slowly instead of moving.
    public static let breathCycle: TimeInterval = 2.4

    public static func sun(at time: TimeInterval, reduceMotion: Bool) -> Sun {
        if reduceMotion {
            return Sun(rise: 0.72, rays: 0.35 + 0.45 * breath(time), opacity: 1)
        }
        let t = time.truncatingRemainder(dividingBy: sunCycle)
        switch t {
        case ..<1.1:
            let p = ease(t / 1.1)
            return Sun(rise: lowestRise + (1 - lowestRise) * p, rays: max(0, (p - 0.7) / 0.3) * 0.6, opacity: 1)
        case ..<1.6:
            let p = (t - 1.1) / 0.5
            return Sun(rise: 1, rays: 0.6 + 0.4 * sin(.pi * p), opacity: 1)
        case ..<2.3:
            let p = ease((t - 1.6) / 0.7)
            return Sun(rise: 1 - (1 - lowestRise) * p, rays: 0.6 * max(0, 1 - p * 2.5), opacity: 1)
        default:
            return Sun(rise: lowestRise, rays: 0, opacity: 1)
        }
    }

    public static func star(at time: TimeInterval, reduceMotion: Bool) -> Star {
        if reduceMotion {
            return Star(scale: 0.9, rotation: 0, opacity: 0.45 + 0.55 * breath(time))
        }
        let p = time.truncatingRemainder(dividingBy: starCycle) / starCycle
        let pulse = sin(.pi * p)
        return Star(scale: 0.7 + 0.3 * pulse, rotation: 45 * ease(p), opacity: 0.6 + 0.4 * pulse)
    }

    /// 0…1…0 over ``breathCycle``.
    static func breath(_ time: TimeInterval) -> Double {
        let p = time.truncatingRemainder(dividingBy: breathCycle) / breathCycle
        return 0.5 - 0.5 * cos(2 * .pi * p)
    }

    /// Cubic ease-in-out.
    static func ease(_ x: Double) -> Double {
        let k = min(1, max(0, x))
        return k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
    }
}
