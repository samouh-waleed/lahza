import Foundation
import SwiftUI
import Testing
@testable import LZDesign

@MainActor
@Suite("Foundations · component logic")
struct FoundationsComponentLogicTests {
    // MARK: Counter

    @Test("The counter measures like the server (UTF-16 code units)")
    func counterCountsUTF16() {
        #expect(LZCharacterCounter(text: "photos", limit: 10).count == 6)
        #expect(LZCharacterCounter(text: "📷", limit: 10).count == 2)
        #expect(LZCharacterCounter(text: "é", limit: 10).count == 1)
        #expect(LZCharacterCounter(text: "e\u{301}", limit: 10).count == 2)
        #expect(LZCharacterCounter(text: "لَحْظَة", limit: 10).count == 7)
    }

    @Test("Counter states: normal, near (last 10 % or 10), over")
    func counterStates() {
        #expect(LZCharacterCounter(count: 100, limit: 280).state == .normal)
        #expect(LZCharacterCounter(count: 252, limit: 280).state == .near)
        #expect(LZCharacterCounter(count: 280, limit: 280).state == .near)
        #expect(LZCharacterCounter(count: 281, limit: 280).state == .over)
        #expect(LZCharacterCounter(count: 30, limit: 40).state == .near)
        #expect(LZCharacterCounter(count: 29, limit: 40).state == .normal)
        #expect(LZCharacterCounter(count: 12, limit: 280).text == "12/280")
        #expect(LZCharacterCounter(count: 12, limit: 280).accessibilityText == "12 of 280 characters")
        #expect(LZCharacterCounter(count: 290, limit: 280).accessibilityText == "10 characters over the 280 limit")
        #expect(LZCharacterCounter(count: -4, limit: -1).remaining == 0)
    }

    // MARK: Toasts

    @Test("At most three toasts; a fourth retires the oldest")
    func toastQueue() {
        let center = LZToastCenter(lifetime: .seconds(60), announce: false)
        let a = center.show("One"), b = center.show("Two"), c = center.show("Three")
        #expect(center.toasts.map(\.id) == [a.id, b.id, c.id])
        let d = center.show("Four", systemImage: "bookmark.fill")
        #expect(center.toasts.map(\.id) == [b.id, c.id, d.id])
        #expect(center.toasts.last?.systemImage == "bookmark.fill")
        center.dismiss(c.id)
        #expect(center.toasts.map(\.id) == [b.id, d.id])
        center.dismissAll()
        #expect(center.toasts.isEmpty)
    }

    @Test("Toasts leave on their own after their lifetime")
    func toastExpiry() async throws {
        let center = LZToastCenter(lifetime: .milliseconds(40), announce: false)
        center.show("Saved")
        #expect(center.toasts.count == 1)
        for _ in 0..<100 where !center.toasts.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(center.toasts.isEmpty)
        #expect(LZToastCenter.lifetime == .milliseconds(2_500))
        #expect(LZToastCenter.maxVisible == 3)
    }

    @Test("Each toast keeps its own clock")
    func toastTimersAreIndependent() async throws {
        let center = LZToastCenter(lifetime: .milliseconds(400), announce: false)
        let first = center.show("First")
        try await Task.sleep(for: .milliseconds(250))
        let second = center.show("Second")
        try await Task.sleep(for: .milliseconds(250))
        #expect(!center.toasts.contains(first))
        #expect(center.toasts.contains(second))
        center.dismiss(second.id)
        #expect(center.toasts.isEmpty)
    }

    // MARK: Pull to refresh

    @Test("Pull to refresh: arm once past the threshold, refresh on release, finish to idle")
    func pullToRefresh() {
        var state = LZPullToRefreshState()
        #expect(state.phase == .idle)
        let r1 = state.update(pull: 20, interacting: true)
        #expect(!r1)
        #expect(state.phase == .pulling)
        #expect(abs(state.progress - 20 / 76) < 1e-9)
        let r2 = state.update(pull: 80, interacting: true)
        #expect(r2) // arms: haptic
        #expect(state.phase == .armed)
        let r3 = state.update(pull: 90, interacting: true)
        #expect(!r3) // no second haptic
        let r4 = state.release()
        #expect(r4)
        #expect(state.phase == .refreshing)
        let r5 = state.update(pull: 0, interacting: false)
        #expect(!r5)
        #expect(state.phase == .refreshing)
        state.finish()
        #expect(state.phase == .idle)
    }

    @Test("Pulling back before release disarms; a short pull never refreshes")
    func pullToRefreshDisarm() {
        var state = LZPullToRefreshState()
        _ = state.update(pull: 80, interacting: true)
        #expect(state.phase == .armed)
        _ = state.update(pull: 70, interacting: true)
        #expect(state.phase == .armed) // hysteresis
        _ = state.update(pull: 40, interacting: true)
        #expect(state.phase == .pulling)
        let r6 = state.release()
        #expect(!r6)
        _ = state.update(pull: 0, interacting: false)
        #expect(state.phase == .idle)

        var short = LZPullToRefreshState()
        _ = short.update(pull: 50, interacting: true)
        let r7 = short.release()
        #expect(!r7)
        // Bouncing past the threshold without a finger never arms.
        var bounce = LZPullToRefreshState()
        let r8 = bounce.update(pull: 120, interacting: false)
        #expect(!r8)
        #expect(bounce.phase != .armed)
        let r9 = bounce.update(pull: .nan, interacting: true)
        #expect(!r9)
    }

    // MARK: Loops

    @Test("Skeleton sweep: a 1.7 s pass across, then a rest")
    func skeletonSweep() throws {
        let start = try #require(LZSkeletonSweep.position(at: 0))
        #expect(abs(start - -0.35) < 1e-9)
        let end = try #require(LZSkeletonSweep.position(at: 1.699_999))
        #expect(end > 1.3)
        #expect(LZSkeletonSweep.position(at: 2.0) == nil)
        #expect(LZSkeletonSweep.position(at: LZSkeletonSweep.cycle + 0.85) != nil)
        var last = -1.0
        for step in 0..<170 {
            let position = try #require(LZSkeletonSweep.position(at: Double(step) / 100))
            #expect(position >= last)
            last = position
        }
    }

    @Test("Loader phases stay in range; Reduce Motion holds the sun still")
    func loaderPhases() {
        for step in 0..<520 {
            let t = Double(step) / 100
            let sun = LZLoaderPhase.sun(at: t, reduceMotion: false)
            #expect((LZLoaderPhase.lowestRise...1).contains(sun.rise) && (0...1).contains(sun.rays))
            let star = LZLoaderPhase.star(at: t, reduceMotion: false)
            #expect(star.scale > 0 && star.scale <= 1 && (0...1).contains(star.opacity))
            let still = LZLoaderPhase.sun(at: t, reduceMotion: true)
            #expect(still.rise == 0.72)
            #expect(LZLoaderPhase.star(at: t, reduceMotion: true).rotation == 0)
        }
        #expect(LZLoaderPhase.sun(at: 1.3, reduceMotion: false).rise == 1)
        #expect(LZLoaderPhase.sun(at: 2.4, reduceMotion: false).rise == LZLoaderPhase.lowestRise)
    }

    @Test("The sun hides under the horizon at rise 0 and clears it at rise 1")
    func sunGeometry() {
        let size = CGSize(width: 32, height: 32)
        let down = LZSunGeometry(size: size, rise: 0)
        #expect(down.discTop >= down.horizonY - 1)
        let up = LZSunGeometry(size: size, rise: 1)
        #expect(up.center.y + up.radius <= up.horizonY + up.radius * 0.1)
        #expect(up.discTop >= 0)
        #expect(LZSunGeometry(size: size, rise: 9).center == up.center)
    }
}
