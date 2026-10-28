import Foundation
import SwiftUI

/// How much decorative motion the person wants.
nonisolated public enum LZMotionMode: String, CaseIterable, Sendable, Hashable {
    /// Decorative loops (shimmer, glints, sweeps) run.
    case full
    /// Nothing decorative loops.
    case calm
    /// Fully still (forced by Reduce Motion).
    case still
}

/// Whether decorative motion (shimmer, skeleton sweeps, loader loops) may run. Loops run only while
/// the scene is active, the view is on screen, and neither Reduce Motion nor Low Power Mode is on;
/// the person's motion mode can turn them off too.
nonisolated public struct LZDecorativeMotionPolicy: Sendable, Hashable {
    public var sceneActive: Bool
    public var onscreen: Bool
    public var reduceMotion: Bool
    public var lowPower: Bool
    /// Something covers the view (a sheet, the privacy cover).
    public var covered: Bool
    public var mode: LZMotionMode

    public init(sceneActive: Bool = true, onscreen: Bool = true, reduceMotion: Bool = false, lowPower: Bool = false,
                covered: Bool = false, mode: LZMotionMode = .full) {
        self.sceneActive = sceneActive
        self.onscreen = onscreen
        self.reduceMotion = reduceMotion
        self.lowPower = lowPower
        self.covered = covered
        self.mode = mode
    }

    /// The mode in force: Reduce Motion forces Still; Low Power calms Full.
    public var effectiveMode: LZMotionMode {
        if reduceMotion { return .still }
        if lowPower && mode == .full { return .calm }
        return mode
    }

    /// Decorative loops (glints, sweeps) may run.
    public var allowsLoops: Bool { sceneActive && onscreen && !covered && effectiveMode == .full }

    /// Status loops that carry meaning (the loader while work is pending) may run: they ignore the
    /// motion mode and Low Power, but still stop off screen, in the background and under Reduce
    /// Motion (which gets a still, cross-fading loader instead).
    public var allowsStatusLoops: Bool { sceneActive && onscreen && !reduceMotion }
}

extension EnvironmentValues {
    /// Decorative loops may run here (see ``LZDecorativeMotionPolicy/allowsLoops``). Drive
    /// `TimelineView(.animation(minimumInterval:paused: !lzDecorativeMotionAllowed))` with it.
    @Entry public var lzDecorativeMotionAllowed: Bool = true
    /// Meaningful status loops may run here (see ``LZDecorativeMotionPolicy/allowsStatusLoops``).
    @Entry public var lzStatusMotionAllowed: Bool = true
    /// The effective motion mode.
    @Entry public var lzMotionMode: LZMotionMode = .full
}

extension View {
    /// Installs the motion policy at the root of a scene: scene phase, Reduce Motion, Low Power Mode
    /// and the person's motion mode. Apply once, at the top of each window.
    public func lzMotionRoot(mode: LZMotionMode = .full) -> some View {
        modifier(LZMotionRootModifier(mode: mode))
    }

    /// Marks a region whose decorative motion should pause when it scrolls off screen or
    /// disappears, or while `covered` (a sheet over it).
    public func lzDecorativeRegion(covered: Bool = false) -> some View {
        modifier(LZDecorativeRegionModifier(covered: covered))
    }
}

struct LZMotionRootModifier: ViewModifier {
    let mode: LZMotionMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    func body(content: Content) -> some View {
        let policy = LZDecorativeMotionPolicy(sceneActive: scenePhase == .active, reduceMotion: reduceMotion,
                                              lowPower: lowPower, mode: mode)
        content
            .environment(\.lzDecorativeMotionAllowed, policy.allowsLoops)
            .environment(\.lzStatusMotionAllowed, policy.allowsStatusLoops)
            .environment(\.lzMotionMode, policy.effectiveMode)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

struct LZDecorativeRegionModifier: ViewModifier {
    let covered: Bool
    @State private var onscreen = false
    @Environment(\.lzDecorativeMotionAllowed) private var inherited
    @Environment(\.lzStatusMotionAllowed) private var inheritedStatus

    func body(content: Content) -> some View {
        content
            .environment(\.lzDecorativeMotionAllowed, inherited && onscreen && !covered)
            .environment(\.lzStatusMotionAllowed, inheritedStatus && onscreen)
            .onAppear { onscreen = true }
            .onDisappear { onscreen = false }
            .onScrollVisibilityChange(threshold: 0.01) { onscreen = $0 }
    }
}
