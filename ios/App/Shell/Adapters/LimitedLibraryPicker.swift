import Photos
import PhotosUI
import UIKit

/// The system picker for the limited selection (PhotosUI, UIKit only), shown over the top-most view
/// controller. Only the live dependency presents it, and only with limited access; the change it makes
/// reaches ``PhotoAccessStore`` through the library's change stream as well.
enum LimitedLibraryPicker {
    static func present() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited, let controller = topViewController() else { return }
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    /// The active window's top-most presented controller (a sheet's, when one is up).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
