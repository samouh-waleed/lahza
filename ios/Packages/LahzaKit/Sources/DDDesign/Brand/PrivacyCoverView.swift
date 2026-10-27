import DDCore
import SwiftUI

/// The opaque cover shown whenever the scene is not active (app switcher snapshots, Control
/// Centre, incoming calls), so photos never appear in a snapshot. A still composition: the paper
/// background, the wordmark and the tagline. It takes no parameters, so it cannot show personal data.
///
/// It never animates (it is captured in the app-switcher snapshot) and is fully opaque, so
/// Reduce Transparency needs no special case. Text scales with Dynamic Type.
public struct PrivacyCoverView: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(colors: [Color.dd(.bg, opaque: true), Color.dd(.surface, opaque: true)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Text(verbatim: Brand.name)
                    .font(.custom("InstrumentSerif-Regular", size: 52, relativeTo: .largeTitle))
                    .foregroundStyle(Color.dd(.ink, opaque: true))
                Text(verbatim: Brand.tagline)
                    .font(.custom("Newsreader-Regular", size: 19, relativeTo: .title3))
                    .foregroundStyle(Color.dd(.muted, opaque: true))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(Brand.name). \(Brand.tagline)"))
    }
}

#Preview("Privacy cover") {
    PrivacyCoverView()
}
