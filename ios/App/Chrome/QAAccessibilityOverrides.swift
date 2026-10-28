import SwiftUI

/// DEBUG: `-LZReduceMotion 1` and `-LZReduceTransparency 1` force those settings for screenshots
/// (the real Settings work too). A no-op in Release.
struct QAAccessibilityOverrides: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        let options = DebugLaunch.current
        content
            .transformEnvironment(\._accessibilityReduceMotion) { if options.reduceMotion { $0 = true } }
            .transformEnvironment(\._accessibilityReduceTransparency) { if options.reduceTransparency { $0 = true } }
        #else
        content
        #endif
    }
}
