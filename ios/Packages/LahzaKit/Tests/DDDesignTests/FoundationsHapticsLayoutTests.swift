import CoreHaptics
import Foundation
import SwiftUI
import Testing
@testable import DDDesign

@MainActor
@Suite("Foundations · haptics")
struct FoundationsHapticsTests {
    @Test("One vocabulary: five core feedbacks plus the firm beat and the step down")
    func vocabulary() {
        #expect(DDHaptic.allCases.count == 7)
        #expect(DDHaptic.selection.feedback == .selection)
        #expect(DDHaptic.success.feedback == .success)
        #expect(DDHaptic.alignment.feedback == .alignment)
        #expect(DDHaptic.increase.feedback == .increase)
        #expect(DDHaptic.softImpact.feedback == .impact(flexibility: .soft, intensity: 0.6))
    }

    @Test("Patterns are well formed: sorted, in range, and brief", arguments: DDHapticPattern.all)
    func patternsAreValid(_ pattern: DDHapticPattern) throws {
        for event in pattern.events {
            #expect(event.time >= 0)
            #expect((0...1).contains(event.intensity), "\(pattern.name) intensity")
            #expect((0...1).contains(event.sharpness), "\(pattern.name) sharpness")
            if case .continuous(let duration) = event.kind {
                #expect(duration > 0 && duration <= 30)
            }
        }
        for curve in pattern.curves {
            #expect(curve.points.map(\.time) == curve.points.map(\.time).sorted(), "\(pattern.name) curve out of order")
            for point in curve.points {
                let range: ClosedRange<Double> = curve.parameter == .intensity ? 0...1 : -1...1
                #expect(range.contains(point.value), "\(pattern.name) curve value \(point.value)")
            }
        }
        #expect(pattern.duration <= 1.6 + 1e-9, "\(pattern.name) lasts \(pattern.duration) s")
        // Core Haptics accepts it (validated on the host too).
        _ = try pattern.makeCHPattern()
    }

    @Test("Durations match their moments")
    func durations() {
        #expect(DDHapticPattern.tick.duration < 0.1)
        #expect(DDHapticPattern.milestone.duration < 0.4)
        #expect(abs(DDHapticPattern.holdRamp.duration - DDHoldRamp.defaultDuration) < 1e-9)
        #expect(DDHapticPattern.reveal.duration <= 1.2)
        #expect(DDHapticPattern.holdComplete.duration < 0.4)
    }

    @Test("The hold ramp pattern only grows, and ends in a clear release")
    func holdRampPattern() throws {
        let intensity = try #require(DDHapticPattern.holdRamp.curves.first { $0.parameter == .intensity })
        let values = intensity.points.map(\.value)
        #expect(values == values.sorted())
        #expect((values.first ?? 1) < 0.2 && (values.last ?? 0) > 0.85)
        let transients = DDHapticPattern.holdRamp.events.filter { $0.kind == .transient }
        #expect(transients.count == 1)
        #expect(transients.first?.time == DDHoldRamp.defaultDuration)
    }

    @Test("The live hold ramp is monotonic and bounded")
    func holdRamp() {
        var lastIntensity = -1.0, lastSharpness = -1.0
        for step in 0...100 {
            let p = Double(step) / 100
            let i = DDHoldRamp.intensity(progress: p), s = DDHoldRamp.sharpness(progress: p)
            #expect(i >= lastIntensity && s >= lastSharpness)
            #expect((0...1).contains(i) && (0...1).contains(s))
            lastIntensity = i
            lastSharpness = s
        }
        #expect(DDHoldRamp.intensity(progress: -5) == DDHoldRamp.intensity(progress: 0))
        #expect(DDHoldRamp.intensity(progress: 5) == DDHoldRamp.intensity(progress: 1))
    }

    @Test("The reveal has a rising rumble, a crisp pop, then fading sparkles")
    func reveal() {
        let transients = DDHapticPattern.reveal.events.filter { $0.kind == .transient }
        #expect(transients.count == 4)
        let pop = transients[0]
        #expect(pop.intensity == 1 && pop.sharpness >= 0.8)
        let sparkles = transients.dropFirst().map(\.intensity)
        #expect(sparkles == sparkles.sorted(by: >))
    }

    @Test("AHAP export has the Core Haptics shape")
    func ahap() throws {
        for pattern in DDHapticPattern.all {
            let data = try pattern.ahapData()
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["Version"] as? Double == 1.0)
            let entries = try #require(object["Pattern"] as? [[String: Any]])
            #expect(entries.count == pattern.events.count + pattern.curves.count)
            let events = entries.compactMap { $0["Event"] as? [String: Any] }
            #expect(events.allSatisfy { ["HapticTransient", "HapticContinuous"].contains($0["EventType"] as? String) })
            #expect(events.filter { $0["EventType"] as? String == "HapticContinuous" }.allSatisfy { $0["EventDuration"] is Double })
            // Core Haptics parses the dictionary.
            _ = try CHHapticPattern(dictionary: Dictionary(uniqueKeysWithValues: pattern.ahapDictionary().map { (CHHapticPattern.Key(rawValue: $0.key), $0.value) }))
        }
    }

    @Test("Without haptic hardware (or with haptics off) the engine is silent and never throws")
    func engineNoHardware() {
        let engine = DDHapticEngine(supportsHaptics: false)
        engine.prepare()
        engine.play(.tick)
        #expect(engine.beginHold() == false)
        engine.updateHold(progress: 0.5)
        engine.endHold(completed: true)
        engine.isEnabled = false
        engine.play(.reveal)
    }

    @Test("Sounds are opt-in and respect silent mode")
    func feedbackSettings() {
        #expect(DDFeedbackSettings.default.hapticsEnabled)
        #expect(!DDFeedbackSettings.default.soundsEnabled)
        #expect(!DDFeedbackSettings(soundsEnabled: true).allowsSound(silenced: true))
        #expect(DDFeedbackSettings(soundsEnabled: true).allowsSound(silenced: false))
        #expect(!DDFeedbackSettings().allowsSound(silenced: false))
    }
}

@MainActor
@Suite("Foundations · metrics and layout")
struct FoundationsLayoutTests {
    @Test("Spacing sits on a 2/4-pt rhythm and grows")
    func spacing() {
        #expect(DDSpace.scale == DDSpace.scale.sorted())
        #expect(Set(DDSpace.scale).count == DDSpace.scale.count)
        for value in DDSpace.scale { #expect(value.truncatingRemainder(dividingBy: 2) == 0) }
        #expect(DDLayout.gutter == 24 && DDLayout.readingMargin == 28 && DDLayout.maxContentWidth == 640)
    }

    @Test("Radii and concentric insets")
    func radii() {
        #expect([DDRadius.xs, DDRadius.sm, DDRadius.md, DDRadius.lg, DDRadius.xl] == [6, 10, 18, 24, 32])
        #expect(DDRadius.concentric(outer: 24, inset: 16) == 8)
        #expect(DDRadius.concentric(outer: 24, inset: 22) == DDRadius.xs)
        #expect(DDRadius.concentric(outer: 24, inset: -4) == 24)
        #expect(DDRadius.badge(size: 40) == 14)
    }

    @Test("Hit targets never fall below 44 pt")
    func hitTargets() {
        #expect(DDHitTarget.minimum == 44 && DDHitTarget.comfortable == 48)
        #expect(DDHitTarget.padding(for: 40) == 4)
        #expect(DDHitTarget.padding(for: 60) == 0)
        #expect(40 + 2 * DDHitTarget.padding(for: 40) >= DDHitTarget.minimum)
    }

    @Test("Elevation: two plum layers, stronger in the dark")
    func elevation() {
        for elevation in DDElevation.allCases {
            #expect(elevation.layers.count == 2)
            for layer in elevation.layers {
                #expect(elevation.color(layer, dark: true).alpha > elevation.color(layer, dark: false).alpha)
                #expect(elevation.color(layer, dark: true).alpha <= 1)
            }
        }
        #expect(DDElevation.float.layers[1].opacity > DDElevation.card.layers[1].opacity)
    }

    @Test("Layout metrics: gutters, columns and stacking adapt to width, size class and text size")
    func metrics() {
        let phone = DDLayoutMetrics(width: 402, isRegularWidth: false, isAccessibilitySize: false)
        #expect(phone.gutter == 24 && phone.columns == 1 && phone.contentWidth == 354 && !phone.stacksRows)
        let small = DDLayoutMetrics(width: 320, isRegularWidth: false, isAccessibilitySize: false)
        #expect(small.gutter == 20)
        let padPortrait = DDLayoutMetrics(width: 820, isRegularWidth: true, isAccessibilitySize: false)
        #expect(padPortrait.gutter == 40 && padPortrait.columns == 2 && padPortrait.contentWidth == 740)
        let padLandscape = DDLayoutMetrics(width: 1_180, isRegularWidth: true, isAccessibilitySize: false)
        #expect(padLandscape.columns == 3)
        let padLarge = DDLayoutMetrics(width: 1_180, isRegularWidth: true, isAccessibilitySize: true)
        #expect(padLarge.columns == 1 && padLarge.contentWidth == DDLayout.maxContentWidth && padLarge.stacksRows)
        let splitView = DDLayoutMetrics(width: 500, isRegularWidth: true, isAccessibilitySize: false)
        #expect(splitView.columns == 1 && splitView.gutter == 24)
    }

    @Test("Flow layout wraps and never overflows")
    func flow() {
        let sizes = [CGSize(width: 100, height: 40), CGSize(width: 120, height: 40), CGSize(width: 90, height: 44), CGSize(width: 500, height: 40)]
        let result = DDFlowMath.arrange(sizes: sizes, maxWidth: 240, spacing: 8, lineSpacing: 6)
        #expect(result.origins[0] == .zero)
        #expect(result.origins[1] == CGPoint(x: 108, y: 0))
        #expect(result.origins[2] == CGPoint(x: 0, y: 46))
        #expect(result.origins[3] == CGPoint(x: 0, y: 96))
        #expect(result.size.width <= 240)
        #expect(result.size.height == 136)
        #expect(DDFlowMath.arrange(sizes: [], maxWidth: 100, spacing: 8, lineSpacing: 8).size == .zero)
    }
}
