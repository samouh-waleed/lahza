import SwiftUI

/// Pull-to-refresh as a state machine (pure, host-tested).
///
/// idle → pulling (finger down, pulled) → armed (past the threshold: one soft haptic) →
/// refreshing (released while armed) → idle (the action finished). Pulling back under 70 % of
/// the threshold before release disarms it.
nonisolated public struct LZPullToRefreshState: Sendable, Hashable {
    public enum Phase: Sendable, Hashable { case idle, pulling, armed, refreshing }

    /// Pull distance that arms a refresh.
    public static let threshold: CGFloat = 76
    /// Space held open above the content while refreshing.
    public static let refreshingInset: CGFloat = 56

    public private(set) var phase: Phase = .idle
    public private(set) var pull: CGFloat = 0

    public init() {}

    /// 0…1 toward the threshold.
    public var progress: Double { Double(min(1, pull / Self.threshold)) }

    /// The pull distance changed. Returns true exactly when the pull arms (play the haptic).
    public mutating func update(pull newPull: CGFloat, interacting: Bool) -> Bool {
        pull = max(0, newPull.isFinite ? newPull : 0)
        switch phase {
        case .refreshing:
            return false
        case .idle, .pulling:
            if pull <= 0.5 {
                phase = .idle
                return false
            }
            if interacting && pull >= Self.threshold {
                phase = .armed
                return true
            }
            phase = interacting || phase == .pulling ? .pulling : .idle
            return false
        case .armed:
            if interacting && pull < Self.threshold * 0.7 { phase = .pulling }
            return false
        }
    }

    /// The finger lifted. Returns true when a refresh should start.
    public mutating func release() -> Bool {
        switch phase {
        case .armed:
            phase = .refreshing
            return true
        case .pulling:
            phase = pull > 0.5 ? .pulling : .idle
            return false
        default:
            return false
        }
    }

    /// The refresh finished.
    public mutating func finish() {
        guard phase == .refreshing else { return }
        phase = .idle
    }
}

extension View {
    /// A rising-sun pull-to-refresh for a `ScrollView`: the sun rises over the horizon as
    /// you pull, arms with a soft haptic, and loops while `action` runs. VoiceOver gets a
    /// "Refresh" action instead of the gesture.
    public func lzRefreshable(label: String = "Refresh", action: @escaping @MainActor () async -> Void) -> some View {
        modifier(LZRefreshModifier(label: label, action: action))
    }
}

struct LZRefreshModifier: ViewModifier {
    let label: String
    let action: @MainActor () async -> Void
    @State private var state = LZPullToRefreshState()
    @State private var interacting = false
    @State private var arms = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, state.phase == .refreshing ? LZPullToRefreshState.refreshingInset : 0)
            .onScrollPhaseChange { old, new in
                interacting = new == .interacting
                if old == .interacting && new != .interacting, state.release() {
                    start()
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, pull in
                if state.update(pull: pull, interacting: interacting) { arms += 1 }
            }
            .overlay(alignment: .top) {
                let refreshing = state.phase == .refreshing
                LZRefreshIndicator(progress: state.progress, refreshing: refreshing)
                    .frame(height: refreshing ? LZPullToRefreshState.refreshingInset : max(0, min(state.pull, LZPullToRefreshState.threshold)))
                    .clipped()
                    .opacity(state.phase == .idle ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .lzHaptic(.softImpact, trigger: arms)
            .accessibilityAction(named: Text(label)) {
                guard state.phase != .refreshing else { return }
                start(fromAccessibility: true)
            }
    }

    private func start(fromAccessibility: Bool = false) {
        if fromAccessibility {
            // Enter the refreshing phase without a gesture.
            _ = state.update(pull: LZPullToRefreshState.threshold, interacting: true)
            _ = state.release()
        }
        Task { @MainActor in
            await action()
            withAnimation(LZMotionToken.interface.animation(reduceMotion: reduceMotion)) { state.finish() }
        }
    }
}

/// The pull-to-refresh glyph: a sun rising over a horizon line with the pull, then the loader
/// while refreshing. Usable on its own (e.g. a custom header).
public struct LZRefreshIndicator: View {
    private let progress: Double
    private let refreshing: Bool

    public init(progress: Double, refreshing: Bool) {
        self.progress = progress
        self.refreshing = refreshing
    }

    public var body: some View {
        ZStack {
            if refreshing {
                LZLoader(.sun, size: 32, label: "Refreshing")
            } else {
                LZRisingSun(rise: progress, rays: max(0, (progress - 0.85) / 0.15))
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A static sun at a given rise (0…1) with rays (0…1): the loader's frame, driven by a value.
struct LZRisingSun: View {
    let rise: Double
    let rays: Double
    var tint: LZColorStyle = .lz(.gold)

    var body: some View {
        Canvas { context, size in
            let geometry = LZSunGeometry(size: size, rise: rise)
            let shading = GraphicsContext.Shading.style(tint)
            var sky = context
            sky.clip(to: Path(geometry.skyRect))
            if rays > 0.01 {
                var glow = sky
                glow.opacity = min(1, rays)
                glow.stroke(geometry.rays, with: shading, style: StrokeStyle(lineWidth: geometry.rayWidth, lineCap: .round))
            }
            sky.fill(geometry.disc, with: shading)
            context.stroke(geometry.horizon, with: shading, style: StrokeStyle(lineWidth: geometry.horizonWidth, lineCap: .round))
        }
    }
}

/// The rising sun's geometry in a square of `size` (host-tested: the disc stays under the
/// horizon at rise 0 and clears it at rise 1).
nonisolated struct LZSunGeometry {
    let side: CGFloat
    let origin: CGPoint
    let radius: CGFloat
    let horizonY: CGFloat
    let center: CGPoint

    init(size: CGSize, rise: Double) {
        let side: CGFloat = min(size.width, size.height)
        let radius: CGFloat = side * 0.23
        let horizonY: CGFloat = side * 0.68
        let lift: CGFloat = CGFloat(min(1, max(0, rise))) * radius * 2
        self.side = side
        self.radius = radius
        self.horizonY = horizonY
        origin = CGPoint(x: (size.width - side) / 2, y: 0)
        center = CGPoint(x: size.width / 2, y: horizonY + radius * 1.05 - lift)
    }

    var skyRect: CGRect { CGRect(x: 0, y: 0, width: origin.x * 2 + side, height: horizonY - side * 0.02) }

    var disc: Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    var rays: Path {
        var path = Path()
        let inner: CGFloat = radius + side * 0.08
        for index in 0..<5 {
            let angle: Double = (-150.0 + Double(index) * 30) * .pi / 180
            let length: CGFloat = side * (index == 2 ? 0.14 : 0.1)
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            path.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
            path.addLine(to: CGPoint(x: center.x + dx * (inner + length), y: center.y + dy * (inner + length)))
        }
        return path
    }

    var rayWidth: CGFloat { max(1.2, side * 0.065) }
    var horizonWidth: CGFloat { max(1.5, side * 0.075) }

    var horizon: Path {
        var path = Path()
        path.move(to: CGPoint(x: origin.x + side * 0.1, y: horizonY))
        path.addLine(to: CGPoint(x: origin.x + side * 0.9, y: horizonY))
        return path
    }

    /// The disc's top edge (y grows downward).
    var discTop: CGFloat { center.y - radius }
}
