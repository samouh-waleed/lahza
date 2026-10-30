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
        case .image(let cgImage)?, .reduced(let cgImage)?:
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

extension View {
    /// A grid tile's badges: a favourite's heart, a video's length and, for a search's nearby photo, a gold dot. They
    /// stop growing at the largest standard text size, so they never cover the photo (VoiceOver reads them).
    func assetTileBadges(isFavorite: Bool, videoDuration: Double?, isNearby: Bool = false) -> some View {
        overlay(alignment: .bottomLeading) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(LZSpace.xs + 1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let videoDuration {
                Text(MomentCopy.duration(videoDuration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(LZSpace.xs + 1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isNearby {
                Circle()
                    .fill(.lz(.gold))
                    .frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                    .shadow(radius: 1)
                    .padding(LZSpace.xs + 1)
            }
        }
    }
}

/// What VoiceOver says for a grid tile.
nonisolated enum AssetTileCopy {
    static let nearby = "nearby"

    /// "Video, 0:42, favourite, 5:20 PM", adding "nearby" for a search's photo just outside the place or dates.
    static func label(isVideo: Bool, duration: Double, isFavorite: Bool, wall: Int64?, isNearby: Bool = false,
                      locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [isVideo ? "Video, \(MomentCopy.duration(duration))" : "Photo"]
        if isFavorite { parts.append("favourite") }
        if isNearby { parts.append(nearby) }
        if let wall {
            parts.append(Date(timeIntervalSince1970: TimeInterval(wall))
                .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: .gmt)))
        }
        return parts.joined(separator: ", ")
    }
}
