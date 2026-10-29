#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation

/// The clip of a seed video: its artwork with a playback bar, 10 frames a second over its length, H.264 in a QuickTime
/// file. `lz-seed` writes the Simulator's files with it (adding the date and position metadata) and
/// ``FakeVideoLoader`` the clips the viewer plays, so a video in the Simulator and its fake twin look the same.
public enum SeedVideo {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Writes `item`'s clip to `url` (which must not exist) with `metadata`.
    public static func write(_ item: SeedItem, to url: URL, metadata: [AVMetadataItem] = []) async throws {
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
}
#endif
