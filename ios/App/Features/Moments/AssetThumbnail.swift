import LZDesign
import LZLibrary
import SwiftUI

/// A square thumbnail of one library item, from what the iPhone holds (network off). A sweep while it loads; a
/// cloud glyph when the photo is only in iCloud, a photo glyph when it can't be read.
struct AssetThumbnail: View {
    let localID: String
    /// A fixed square side in points, or nil to fill the space offered (a grid cell adds `.aspectRatio(1, ...)`).
    var side: CGFloat?
    var radius: CGFloat = LZRadius.xs
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: AssetImage?

    /// The short side asked of the library when filling, in points.
    private static let flexibleSide: CGFloat = 200

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear
            .frame(width: side, height: side)
            .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
            .overlay { content }
            .clipShape(shape)
            .accessibilityHidden(true)
            .task(id: localID) {
                image = await model.images.thumbnail(for: localID, side: Int(((side ?? Self.flexibleSide) * displayScale).rounded()))
            }
    }

    @ViewBuilder private var content: some View {
        switch image {
        case .image(let cgImage)?:
            Image(decorative: cgImage, scale: displayScale)
                .resizable()
                .scaledToFill()
        case .inCloud?:
            placeholder("icloud")
        case .missing?:
            placeholder("photo")
        case nil:
            SkeletonBlock(radius: radius)
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(.lz(.muted))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.lz(.surface2))
    }
}
