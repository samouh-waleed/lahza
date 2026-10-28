import CoreHaptics
import Foundation

/// A Core Haptics pattern in AHAP terms: transient and continuous events plus parameter curves.
/// Patterns are values, so they are unit-tested on the host and exported as `.ahap` JSON.
nonisolated public struct LZHapticPattern: Sendable, Hashable {
    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case transient
            case continuous(duration: TimeInterval)
        }

        public var time: TimeInterval
        public var kind: Kind
        /// 0…1.
        public var intensity: Double
        /// 0…1 (0 = round and soft, 1 = crisp).
        public var sharpness: Double

        public init(time: TimeInterval, kind: Kind, intensity: Double, sharpness: Double) {
            self.time = time
            self.kind = kind
            self.intensity = intensity
            self.sharpness = sharpness
        }

        public static func transient(_ time: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(time: time, kind: .transient, intensity: intensity, sharpness: sharpness)
        }

        public static func continuous(_ time: TimeInterval, duration: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(time: time, kind: .continuous(duration: duration), intensity: intensity, sharpness: sharpness)
        }

        public var end: TimeInterval {
            if case .continuous(let duration) = kind { return time + duration }
            return time
        }
    }

    public struct Curve: Sendable, Hashable {
        public enum Parameter: String, Sendable, Hashable {
            case intensity = "HapticIntensityControl"
            case sharpness = "HapticSharpnessControl"
        }

        public struct Point: Sendable, Hashable {
            public var time: TimeInterval
            public var value: Double
            public init(_ time: TimeInterval, _ value: Double) {
                self.time = time
                self.value = value
            }
        }

        public var parameter: Parameter
        public var time: TimeInterval
        public var points: [Point]

        public init(_ parameter: Parameter, time: TimeInterval = 0, points: [Point]) {
            self.parameter = parameter
            self.time = time
            self.points = points
        }

        public var end: TimeInterval { time + (points.last?.time ?? 0) }
    }

    public var name: String
    public var events: [Event]
    public var curves: [Curve]

    public init(name: String, events: [Event], curves: [Curve] = []) {
        self.name = name
        self.events = events
        self.curves = curves
    }

    /// When the last event or curve ends.
    public var duration: TimeInterval {
        max(events.map(\.end).max() ?? 0, curves.map(\.end).max() ?? 0)
    }

    // MARK: The vocabulary

    /// A tick: a soft, round click with a whisper of body.
    public static let tick = LZHapticPattern(name: "tick", events: [
        .transient(0, intensity: 0.55, sharpness: 0.22),
        .continuous(0.004, duration: 0.05, intensity: 0.18, sharpness: 0.08),
    ], curves: [
        Curve(.intensity, time: 0.004, points: [.init(0, 1), .init(0.05, 0)]),
    ])

    /// A milestone: a firm beat, an echo and a warm swell that fades.
    public static let milestone = LZHapticPattern(name: "milestone", events: [
        .transient(0, intensity: 0.9, sharpness: 0.55),
        .transient(0.09, intensity: 0.5, sharpness: 0.3),
        .continuous(0.1, duration: 0.24, intensity: 0.4, sharpness: 0.15),
    ], curves: [
        Curve(.intensity, time: 0.1, points: [.init(0, 0.2), .init(0.06, 1), .init(0.24, 0)]),
    ])

    /// A press-and-hold played on a fixed clock (1.6 s): a continuous ramp that grows and
    /// sharpens, ending in a clear release. For a live press-and-hold use
    /// ``LZHapticEngine/beginHold()``, which follows the finger with ``LZHoldRamp``.
    public static let holdRamp = LZHapticPattern(name: "holdRamp", events: [
        .continuous(0, duration: LZHoldRamp.defaultDuration, intensity: 1, sharpness: 0.5),
        .transient(LZHoldRamp.defaultDuration, intensity: 1, sharpness: 0.6),
    ], curves: [
        Curve(.intensity, points: stride(from: 0.0, through: 1.0, by: 0.125).map { .init($0 * LZHoldRamp.defaultDuration, LZHoldRamp.intensity(progress: $0)) }),
        Curve(.sharpness, points: stride(from: 0.0, through: 1.0, by: 0.25).map { .init($0 * LZHoldRamp.defaultDuration, LZHoldRamp.sharpness(progress: $0) - 0.5) }),
    ])

    /// The release when a hold completes: a clear beat and a warm settle.
    public static let holdComplete = LZHapticPattern(name: "holdComplete", events: [
        .transient(0, intensity: 1, sharpness: 0.6),
        .continuous(0.02, duration: 0.32, intensity: 0.45, sharpness: 0.12),
    ], curves: [
        Curve(.intensity, time: 0.02, points: [.init(0, 1), .init(0.32, 0)]),
    ])

    /// A reveal (≤ 1.2 s): an anticipation rumble, a crisp pop, then three falling sparkles.
    public static let reveal = LZHapticPattern(name: "reveal", events: [
        .continuous(0, duration: 0.82, intensity: 1, sharpness: 0.3),
        .transient(0.86, intensity: 1, sharpness: 0.8),
        .transient(0.98, intensity: 0.42, sharpness: 0.9),
        .transient(1.07, intensity: 0.3, sharpness: 0.95),
        .transient(1.16, intensity: 0.2, sharpness: 1),
    ], curves: [
        Curve(.intensity, points: [.init(0, 0.15), .init(0.5, 0.45), .init(0.78, 0.8), .init(0.82, 0.3)]),
        Curve(.sharpness, points: [.init(0, -0.2), .init(0.82, 0.2)]),
    ])

    public static let all: [LZHapticPattern] = [tick, milestone, holdRamp, holdComplete, reveal]

    // MARK: AHAP

    /// The pattern as an AHAP dictionary (`Version`, `Pattern`).
    public func ahapDictionary() -> [String: Any] {
        var entries: [[String: Any]] = []
        for event in events {
            var body: [String: Any] = [
                "Time": event.time,
                "EventParameters": [
                    ["ParameterID": "HapticIntensity", "ParameterValue": event.intensity],
                    ["ParameterID": "HapticSharpness", "ParameterValue": event.sharpness],
                ],
            ]
            switch event.kind {
            case .transient:
                body["EventType"] = "HapticTransient"
            case .continuous(let duration):
                body["EventType"] = "HapticContinuous"
                body["EventDuration"] = duration
            }
            entries.append(["Event": body])
        }
        for curve in curves {
            entries.append(["ParameterCurve": [
                "ParameterID": curve.parameter.rawValue,
                "Time": curve.time,
                "ParameterCurveControlPoints": curve.points.map { ["Time": $0.time, "ParameterValue": $0.value] },
            ] as [String: Any]])
        }
        return ["Version": 1.0, "Pattern": entries]
    }

    /// `.ahap` file contents.
    public func ahapData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ahapDictionary(), options: [.prettyPrinted, .sortedKeys])
    }

    /// The Core Haptics pattern.
    public func makeCHPattern() throws -> CHHapticPattern {
        let chEvents = events.map { event -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
            ]
            switch event.kind {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: event.time)
            case .continuous(let duration):
                return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: event.time, duration: duration)
            }
        }
        let chCurves = curves.map { curve in
            CHHapticParameterCurve(parameterID: curve.parameter == .intensity ? .hapticIntensityControl : .hapticSharpnessControl,
                                   controlPoints: curve.points.map { .init(relativeTime: $0.time, value: Float($0.value)) },
                                   relativeTime: curve.time)
        }
        return try CHHapticPattern(events: chEvents, parameterCurves: chCurves)
    }
}

/// How a press-and-hold ramp maps the hold's progress (0…1) to haptic intensity and sharpness:
/// it starts as a faint hum and grows, eased so the last third feels like arriving.
nonisolated public enum LZHoldRamp {
    /// The default hold length (seconds).
    public static let defaultDuration: TimeInterval = 1.6

    public static func intensity(progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 0.14 + 0.76 * pow(p, 1.6)
    }

    public static func sharpness(progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 0.12 + 0.4 * p
    }
}

/// Plays the Core Haptics patterns. Haptics-only (it never makes a sound, so the
/// Ring/Silent switch has nothing to silence); silent when the user turns haptics off or the
/// hardware has none (the simulator). Engine failures are swallowed: haptics are never worth
/// an error.
@MainActor public final class LZHapticEngine {
    public static let shared = LZHapticEngine()

    /// Mirrors Settings › Haptics (``SwiftUICore/View/lzFeedback(_:)`` keeps it in step).
    public var isEnabled = true {
        didSet { if !isEnabled { stopAll() } }
    }

    /// The hardware plays Core Haptics.
    public let supportsHaptics: Bool

    private var engine: CHHapticEngine?
    private var holdPlayer: CHHapticAdvancedPatternPlayer?
    private var holdStarted: Date?

    init(supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics) {
        self.supportsHaptics = supportsHaptics
    }

    /// Starts the engine early (call when a haptic-heavy screen appears).
    public func prepare() {
        _ = runningEngine()
    }

    /// Plays a pattern once.
    public func play(_ pattern: LZHapticPattern) {
        guard isEnabled, let engine = runningEngine() else { return }
        do {
            let player = try engine.makePlayer(with: pattern.makeCHPattern())
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            self.engine = nil
        }
    }

    /// Starts a live press-and-hold ramp. Feed it ``updateHold(progress:)`` as the finger holds
    /// and finish with ``endHold(completed:)``.
    @discardableResult
    public func beginHold() -> Bool {
        guard isEnabled, let engine = runningEngine() else { return false }
        endHold(completed: false)
        let pattern = LZHapticPattern(name: "hold", events: [.continuous(0, duration: 30, intensity: 1, sharpness: 0.5)])
        do {
            let player = try engine.makeAdvancedPlayer(with: pattern.makeCHPattern())
            try player.start(atTime: CHHapticTimeImmediate)
            holdPlayer = player
            holdStarted = Date()
            updateHold(progress: 0)
            return true
        } catch {
            return false
        }
    }

    /// Moves the hold ramp to `progress` (0…1).
    public func updateHold(progress: Double) {
        guard let holdPlayer else { return }
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(LZHoldRamp.intensity(progress: progress)), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(LZHoldRamp.sharpness(progress: progress) - 0.5), relativeTime: 0),
        ]
        try? holdPlayer.sendParameters(parameters, atTime: CHHapticTimeImmediate)
    }

    /// Ends the hold: a completed hold releases with ``LZHapticPattern/holdComplete``; a
    /// cancelled one simply stops.
    public func endHold(completed: Bool) {
        guard let player = holdPlayer else { return }
        try? player.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
        holdStarted = nil
        if completed { play(.holdComplete) }
    }

    /// Stops everything (haptics turned off, app backgrounded).
    public func stopAll() {
        endHold(completed: false)
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    private func runningEngine() -> CHHapticEngine? {
        guard supportsHaptics else { return nil }
        if let engine { return engine }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            Self.installHandlers(on: engine, owner: self)
            try engine.start()
            self.engine = engine
            return engine
        } catch {
            return nil
        }
    }

    fileprivate func engineDidReset() {
        engine = nil
        holdPlayer = nil
    }

    /// Handlers run on a Core Haptics queue; build them outside the main actor and hop back.
    private nonisolated static func installHandlers(on engine: CHHapticEngine, owner: LZHapticEngine) {
        let ref = OwnerRef(owner)
        engine.resetHandler = {
            Task { @MainActor in ref.engine?.engineDidReset() }
        }
        engine.stoppedHandler = { _ in
            Task { @MainActor in ref.engine?.engineDidReset() }
        }
    }

    private nonisolated final class OwnerRef: Sendable {
        weak let engine: LZHapticEngine?
        init(_ engine: LZHapticEngine) { self.engine = engine }
    }
}
