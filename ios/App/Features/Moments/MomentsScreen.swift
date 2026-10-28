import DDDesign
import SwiftUI

/// Moments: the moments and places the person saved. Empty until search can save them (E8).
struct MomentsScreen: View {
    var body: some View {
        EmptyState(MomentsCopy.emptyTitle, message: MomentsCopy.emptyBody, systemImage: "rectangle.stack")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.dd(.bg))
            .navigationTitle(MomentsCopy.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("moments")
    }
}

nonisolated enum MomentsCopy {
    static let navigationTitle = "Moments"
    static let emptyTitle = "No saved moments yet"
    static let emptyBody = "Moments you save from Ask appear here, along with the places you name, like “home” or “my pitch”."
}
