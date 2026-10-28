#if canImport(Photos)
import Foundation
import LZGeo
import Photos
import UniformTypeIdentifiers

extension AssetFacts {
    /// The facts PhotoKit holds for `asset` (metadata only; no image data is read).
    init(_ asset: PHAsset) {
        let kind: Kind = switch asset.mediaType {
        case .image: .photo
        case .video: .video
        default: .other
        }
        let types = asset.mediaSubtypes
        var subtypes: Subtypes = []
        if types.contains(.photoScreenshot) { subtypes.insert(.screenshot) }
        if types.contains(.photoLive) { subtypes.insert(.livePhoto) }
        if types.contains(.photoPanorama) { subtypes.insert(.panorama) }
        if types.contains(.photoHDR) { subtypes.insert(.hdr) }
        if types.contains(.photoDepthEffect) { subtypes.insert(.depthEffect) }
        if types.contains(.videoScreenRecording) { subtypes.insert(.screenRecording) }
        if types.contains(.videoHighFrameRate) { subtypes.insert(.sloMo) }
        if types.contains(.videoTimelapse) { subtypes.insert(.timeLapse) }
        let source: Source = switch asset.sourceType {
        case .typeUserLibrary: .userLibrary
        case .typeCloudShared: .cloudShared
        case .typeiTunesSynced: .synced
        default: .unknown
        }
        let location = asset.location
        self.init(
            kind: kind,
            subtypes: subtypes,
            format: kind == .photo ? ImageFormat(asset.contentType) : nil,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            addedDate: asset.addedDate,
            coordinate: location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            horizontalAccuracy: location?.horizontalAccuracy,
            isFavorite: asset.isFavorite,
            hasBurstIdentifier: asset.burstIdentifier != nil,
            representsBurst: asset.representsBurst,
            duration: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            source: source
        )
    }
}

extension AssetFacts.ImageFormat {
    init(_ type: UTType) {
        if type.conforms(to: .heif) || type.conforms(to: .heic) {
            self = .heif
        } else if type.conforms(to: .jpeg) {
            self = .jpeg
        } else if type.conforms(to: .png) {
            self = .png
        } else if type.conforms(to: .gif) {
            self = .gif
        } else if type.conforms(to: .rawImage) {
            self = .raw
        } else {
            self = .other
        }
    }
}
#endif
