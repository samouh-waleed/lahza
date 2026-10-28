import LZDesign
import LZLibrary
import SwiftUI

/// A thumbnail of one library item, cropped to fill, from what the iPhone holds (network off). A sweep while it
/// loads; a cloud glyph when the photo is only in iCloud, a photo glyph when it can't be read. A filling one asks
/// for its laid-out size, so a small mosaic tile never decodes a large image.
struct AssetThumbnail: View {
    let localID: String
    /// A fixed square side in points, or nil to fill the space offered (a grid cell adds `.aspectRatio(1, ...)`).
    var side: CGFloat?
    var radius: CGFloat = LZRadius.xs
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: AssetImage?
    /// The laid-out size, when filling.
    @State private var filled: CGSize = .zero

    private struct Request: Hashable {
        var localID: String
        var pixels: Int
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear
            .frame(width: side, height: side)
            .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if side == nil { filled = $0 } }
            .overlay { content }
            .clipShape(shape)
            .accessibilityHidden(true)
            .task(id: request) {
                guard let request else { return }
                let loaded = await model.images.thumbnail(for: request.localID, side: request.pixels)
                // A cancelled request (the row scrolled away) leaves the sweep, not a missing-photo glyph.
                if !Task.isCancelled { image = loaded }
            }
    }

    /// The square, in pixels, that covers the thumbnail; nil until a filling one is laid out.
    private var request: Request? {
        let points = side ?? max(filled.width, filled.height)
        guard points > 0 else { return nil }
        return Request(localID: localID, pixels: Int((points * displayScale).rounded(.up)))
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
