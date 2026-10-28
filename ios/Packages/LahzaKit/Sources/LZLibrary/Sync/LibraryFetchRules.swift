#if canImport(Photos)
import Foundation
import Photos

/// **The** PhotoKit fetch options: every read of the library (the access client's count, the census
/// and the library reader) goes through here, so they all see the same assets.
///
/// - The Hidden album stays out (decision 14). The header default is already NO; it is set anyway.
/// - The user library only. It holds the iCloud Shared Library; Shared Albums are not the library.
/// - Burst stacks show their representative, as the library does.
/// - No incremental change details: Lahza never diffs fetch results (the default is YES).
public enum LibraryFetchRules {
    /// The options for a fetch. `sortedNewestFirst` sorts by creation date, newest first;
    /// `createdAtOrBefore` keeps only assets created at or before that instant (a resumed scan);
    /// `allBurstFrames` counts the frames inside burst stacks too (the census's stack count).
    public static func options(sortedNewestFirst: Bool = false, createdAtOrBefore frontier: Date? = nil,
                               allBurstFrames: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeAllBurstAssets = allBurstFrames
        options.wantsIncrementalChangeDetails = false
        if sortedNewestFirst {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        if let frontier {
            options.predicate = NSPredicate(format: "creationDate <= %@", frontier as NSDate)
        }
        return options
    }

    /// Whether a fetched asset is one Lahza may read. A by-id fetch includes hidden assets whatever
    /// the options say (`PHAsset.h`), so its results are checked again here; anything that is not a
    /// photo or a video is skipped too.
    public static func admits(_ asset: PHAsset) -> Bool {
        !asset.isHidden && asset.sourceType.contains(.typeUserLibrary)
            && (asset.mediaType == .image || asset.mediaType == .video)
    }
}
#endif
