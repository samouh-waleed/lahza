#if DEBUG
import Foundation
import LZEmbedding

/// DEBUG: where the SigLIP 2 model is on this iPhone or Simulator until step 11 delivers it with Background Assets. In
/// order: `-LZModelDir <path>`, the `LZ_MODEL_DIR` environment variable, then `Application Support/Models/siglip2-b16-256`
/// in the app's container, which `make device-model` (iPhone) and `make sim-model` (Simulator) copy from the Mac's
/// converted model. The model is never in the app bundle or in git, and its folder is left out of backups.
enum ModelLocator {
    static let folderName = "siglip2-b16-256"

    /// The folder `make device-model` and `make sim-model` fill.
    static var containerFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Models", isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    /// The first folder holding a model manifest, or nil.
    static func folder(override: String?) -> URL? {
        var candidates: [URL] = []
        if let override { candidates.append(URL(fileURLWithPath: override, isDirectory: true)) }
        if let path = ProcessInfo.processInfo.environment["LZ_MODEL_DIR"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path, isDirectory: true)) }
        if let containerFolder { candidates.append(containerFolder) }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(EmbeddingModel.manifestName).path) })
        else { return nil }
        if found == containerFolder {
            var models = found.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? models.setResourceValues(values)
        }
        return found
    }
}
#endif
