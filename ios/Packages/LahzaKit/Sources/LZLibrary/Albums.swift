import Foundation

/// One of the person's own albums: its title and its photos and videos.
public struct LibraryAlbum: Sendable, Hashable {
    public var title: String
    public var localIDs: [String]

    public init(title: String, localIDs: [String]) {
        self.title = title
        self.localIDs = localIDs
    }
}

/// The person's own albums, read by title on the iPhone (the DEBUG scoreboard's labels, content search 5a). It needs
/// photo access and never prompts.
public protocol AlbumSource: Sendable {
    /// The albums whose title passes `matching`, each with its items (the Hidden album's left out).
    func albums(matching: @escaping @Sendable (String) -> Bool) async -> [LibraryAlbum]
}

/// Scripted albums, for tests and the seed.
public struct FakeAlbumSource: AlbumSource {
    public var albums: [LibraryAlbum]

    public init(_ albums: [LibraryAlbum] = []) {
        self.albums = albums
    }

    public func albums(matching: @escaping @Sendable (String) -> Bool) async -> [LibraryAlbum] {
        albums.filter { matching($0.title) }
    }
}

#if canImport(Photos)
import Photos

/// The albums the person made in Photos, over PhotoKit.
public struct LiveAlbumSource: AlbumSource {
    public init() {}

    @concurrent public func albums(matching: @escaping @Sendable (String) -> Bool) async -> [LibraryAlbum] {
        guard PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)).canRead else { return [] }
        var albums: [LibraryAlbum] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, matching(title) else { return }
            var ids: [String] = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
            albums.append(LibraryAlbum(title: title, localIDs: ids))
        }
        return albums
    }
}
#endif
