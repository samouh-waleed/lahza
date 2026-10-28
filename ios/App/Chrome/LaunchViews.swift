import DDCore
import DDDesign
import SwiftUI

/// Holds the static launch screen's composition (the `LaunchBackground` colour and the wordmark)
/// until launch finishes, so the hand-off is a single dissolve.
struct LaunchHoldView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Text(verbatim: Brand.name)
                .font(.custom("InstrumentSerif-Regular", size: 52, relativeTo: .largeTitle))
                .foregroundStyle(.dd(.ink))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening \(Brand.name)")
    }
}
