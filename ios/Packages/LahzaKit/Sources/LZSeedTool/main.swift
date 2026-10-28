// lz-seed: renders a seed scenario into files for the Simulator's Photos library (`make seed-photos`).
//
//     swift run --package-path Packages/LahzaKit lz-seed render --scenario hero --out .build/seed/hero
//
// Writes <out>/media/seed-NNNN.{jpg,png,mov} and <out>/manifest.json. Everything is drawn locally with
// CoreGraphics, CoreText, ImageIO and AVFoundation; nothing is downloaded. Photos carry EXIF dates with
// their zone's offset, Apple make and model and GPS; videos carry QuickTime creation date and ISO 6709
// position. The seed scenario exists only in debug builds, so this tool is always run in debug.
#if os(macOS)
import Foundation

#if DEBUG
import AVFoundation
import CoreGraphics
import ImageIO
import LZGeo
import LZLibrary
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible {
    var description: String
}

/// One manifest row: what a file is meant to be.
struct ManifestEntry: Codable {
    var file: String
    var id: String
    var tag: String
    var kind: String
    var local: String
    var zone: String
    var utc: Int64?
    var latitude: Double?
    var longitude: Double?
    var flags: [String]
}

let usage = "usage: lz-seed render --scenario hero --out <folder>"

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

// MARK: Metadata

/// "2025:06:14 17:20:00" (EXIF's local date-time) from a manifest local time.
func exifDateTime(_ item: SeedItem) -> String {
    item.localDateTime.replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "T", with: " ")
}

/// "+03:00".
func offsetString(_ seconds: Int, colon: Bool = true) -> String {
    let sign = seconds < 0 ? "-" : "+"
    let minutes = abs(seconds) / 60
    return String(format: colon ? "%@%02d:%02d" : "%@%02d%02d", sign, minutes / 60, minutes % 60)
}

func imageProperties(_ item: SeedItem) -> [CFString: Any] {
    var exif: [CFString: Any] = [:]
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.5]
    if let utc = item.utc, let offset = item.offsetSeconds {
        let local = exifDateTime(item)
        exif[kCGImagePropertyExifDateTimeOriginal] = local
        exif[kCGImagePropertyExifDateTimeDigitized] = local
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offsetString(offset)
        exif[kCGImagePropertyExifOffsetTimeDigitized] = offsetString(offset)
        exif[kCGImagePropertyExifSubsecTimeOriginal] = "000"
        if let coordinate = item.coordinate {
            let stamp = Date(timeIntervalSince1970: TimeInterval(utc))
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = .gmt
            let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: stamp)
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: coordinate.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: coordinate.longitude < 0 ? "W" : "E",
                kCGImagePropertyGPSHPositioningError: SeedScenario.horizontalAccuracy,
                kCGImagePropertyGPSDateStamp: String(format: "%04d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                kCGImagePropertyGPSTimeStamp: String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0),
            ] as [CFString: Any]
        }
    }
    switch item.media {
    case .photo:
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                                                      kCGImagePropertyTIFFDateTime: exifDateTime(item)] as [CFString: Any]
        exif[kCGImagePropertyExifLensMake] = "Apple"
        exif[kCGImagePropertyExifLensModel] = item.isSelfie ? "iPhone 15 Pro front camera 2.69mm f/1.9"
            : "iPhone 15 Pro back triple camera 6.765mm f/1.78"
    case .screenshot:
        exif[kCGImagePropertyExifUserComment] = "Screenshot"
    case .video, .received, .dateOnly, .undated:
        break
    }
    if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
    return properties
}

// MARK: Writers

func writeImage(_ item: SeedItem, to url: URL) throws {
    guard let image = SeedArtwork.image(for: item) else { throw Failure(description: "could not draw \(item.id)") }
    let type = item.media == .screenshot ? UTType.png : UTType.jpeg
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw Failure(description: "could not create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, imageProperties(item) as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "could not write \(url.lastPathComponent)") }
}

func writeVideo(_ item: SeedItem, to url: URL) async throws {
    let width = item.pixelWidth, height = item.pixelHeight
    let framesPerSecond: Int32 = 10
    let frames = Int(item.duration) * Int(framesPerSecond)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure(description: "no sRGB colour space") }
    var metadata: [AVMetadataItem] = []
    if let offset = item.offsetSeconds {
        let created = AVMutableMetadataItem()
        created.identifier = .quickTimeMetadataCreationDate
        created.dataType = kCMMetadataBaseDataType_UTF8 as String
        created.value = (item.localDateTime + offsetString(offset, colon: false)) as NSString
        metadata.append(created)
    }
    if let coordinate = item.coordinate {
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.dataType = kCMMetadataBaseDataType_UTF8 as String
        location.value = String(format: "%+010.6f%+011.6f/", coordinate.latitude, coordinate.longitude) as NSString
        metadata.append(location)
    }
    writer.metadata = metadata
    guard writer.startWriting() else { throw Failure(description: "could not start \(url.lastPathComponent): \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw Failure(description: "no pixel buffer for \(url.lastPathComponent)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            SeedArtwork.draw(item, in: context, width: CGFloat(width), height: CGFloat(height), progress: Double(frame) / Double(max(1, frames - 1)))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
            throw Failure(description: "could not append a frame to \(url.lastPathComponent)")
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: framesPerSecond))
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure(description: "could not finish \(url.lastPathComponent): \(String(describing: writer.error))") }
}

// MARK: Render

func render(scenario: SeedScenario, into folder: URL) async throws {
    let media = folder.appendingPathComponent("media", isDirectory: true)
    let files = FileManager.default
    if files.fileExists(atPath: media.path) { throw Failure(description: "\(media.path) exists; remove it first") }
    try files.createDirectory(at: media, withIntermediateDirectories: true)
    var manifest: [ManifestEntry] = []
    let items = scenario.photoKitItems
    for (index, item) in items.enumerated() {
        let url = media.appendingPathComponent(item.fileName)
        if item.isVideo { try await writeVideo(item, to: url) } else { try writeImage(item, to: url) }
        var flags: [String] = []
        if item.isSelfie { flags.append("selfie") }
        if !item.isLocated { flags.append("noGPS") }
        if item.borrowing != .none { flags.append("borrow:" + item.borrowing.rawValue) }
        manifest.append(ManifestEntry(file: item.fileName, id: item.id, tag: item.tag.rawValue, kind: item.media.rawValue, local: item.localDateTime,
                                      zone: item.zone, utc: item.utc, latitude: item.coordinate?.latitude,
                                      longitude: item.coordinate?.longitude, flags: flags))
        if (index + 1) % 100 == 0 || index + 1 == items.count { print("rendered \(index + 1)/\(items.count)") }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    let bytes = try files.contentsOfDirectory(at: media, includingPropertiesForKeys: [.fileSizeKey])
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    print("\(items.count) files (\(items.filter(\.isVideo).count) videos), \(bytes / 1_000_000) MB in \(media.path)")
    print("\(scenario.items.count - items.count) undated items are fake-reader only and have no file")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "render", let out = option("--out", in: arguments) else {
    print(usage)
    exit(2)
}
guard let name = SeedScenario.Name(rawValue: option("--scenario", in: arguments) ?? "hero") else {
    print("unknown scenario; known: \(SeedScenario.Name.allCases.map(\.rawValue).joined(separator: ", "))")
    exit(2)
}
do {
    try await render(scenario: SeedScenario.named(name), into: URL(fileURLWithPath: out, isDirectory: true))
} catch {
    print("lz-seed: \(error)")
    exit(1)
}
#else
print("lz-seed needs a debug build: the seed scenario exists only in DEBUG (run it with plain `swift run`).")
exit(1)
#endif
#endif
