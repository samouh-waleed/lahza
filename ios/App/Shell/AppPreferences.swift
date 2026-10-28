import LZCore
import Foundation
import SwiftUI

/// Settings › Appearance.
nonisolated enum AppearanceMode: String, CaseIterable, Hashable, Sendable {
    /// Follow the iPhone (the default).
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "Match iPhone"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `preferredColorScheme`: nil follows the iPhone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Device-only choices the shell keeps. Lahza keeps everything on this device.
nonisolated struct AppPreferences: Sendable {
    static let onboardingKey = KVKey.device(KVSuffix.onboardingCompleted)
    static let appearanceKey = KVKey.device(KVSuffix.appearance)

    let kv: any KeyValueStore

    /// True once onboarding finished on this install.
    var onboardingCompleted: Bool { kv.string(forKey: Self.onboardingKey) != nil }

    func markOnboardingCompleted(at date: Date) {
        kv.setString(date.ISO8601Format(), forKey: Self.onboardingKey)
    }

    func resetOnboarding() { kv.removeValue(forKey: Self.onboardingKey) }

    var appearance: AppearanceMode {
        kv.string(forKey: Self.appearanceKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    func setAppearance(_ mode: AppearanceMode) {
        if mode == .system { kv.removeValue(forKey: Self.appearanceKey) } else { kv.setString(mode.rawValue, forKey: Self.appearanceKey) }
    }
}
