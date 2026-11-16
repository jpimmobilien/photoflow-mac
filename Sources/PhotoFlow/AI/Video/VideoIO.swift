import Foundation
import AVFoundation
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// Local video pipeline: frames ⇄ movie files with AVFoundation (H.264, HEVC, ProRes), metadata that marks
/// AI-generated content, audio pass-through, optional visible "AI-generated" label.
enum VideoIO {
    enum Codec: String, CaseIterable, Identifiable, Codable {
        case h264, hevc, proRes422
        var id: String { rawValue }
        var title: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC (H.265)"
            case .proRes422: return "Apple ProRes 422"
            }
        }
        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .proRes422: return .proRes422
            }
        }
        var fileType: AVFileType { self == .proRes422 ? .mov : .mp4 }
        var fileExtension: String { self == .proRes422 ? "mov" : "mp4" }
    }

    struct AIMetadata {
        var generated: Bool          // true: fully generated; false: AI-edited real footage
        var model: String
        var prompt: String
        var operation: String
        var seed: UInt32?
    }

    enum IOError: LocalizedError {
        case noFrames, writerFailed(String), readFailed(String)
        var errorDescription: String? {
            switch self {
            case .noFrames: return String(localized: "The video has no frames.")
            case .writerFailed(let s): return String(localized: "The video file could not be written: \(s)")
            case .readFailed(let s): return String(localized: "The video could not be read: \(s)")
            }
        }
    }

    static func framePaths(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: Metadata

    static func metadataItems(_ m: AIMetadata) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value as NSString
            i.extendedLanguageTag = "und"
            return i
        }
        func custom(_ key: String, _ value: String) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.keySpace = .quickTimeMetadata
            i.key = key as NSString
            i.value = value as NSString
            return i
        }
        let source = m.generated ? "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
                                 : "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
        let label = m.generated ? String(localized: "AI-generated video") : String(localized: "Video edited with AI")
        var items = [
            item(.commonIdentifierSoftware, "PhotoFlow"),
            item(.quickTimeMetadataDescription, "\(label) · \(m.model)" + (m.prompt.isEmpty ? "" : " · \(m.prompt)")),
            custom("org.iptc.DigitalSourceType", source),
            custom("com.photoflow.ai.model", m.model),
            custom("com.photoflow.ai.operation", m.operation),
            custom("com.photoflow.ai.prompt", m.prompt)
        ]
        if let s = m.seed { items.append(custom("com.photoflow.ai.seed", String(s))) }
        return items
    }

    // MARK: Writing

    /// Writes PNG/JPEG frames as a movie. `label` burns a small visible "AI-generated" note into the frames.
    static func writeMovie(frames folder: URL, fps: Int, to dest: URL, codec: Codec = .h264, size: CGSize? = nil,
                           bitrate: Int? = nil, metadata: AIMetadata?, label: String? = nil, audioFrom: URL? = nil,
                           progress: ((Double) -> Void)? = nil) async throws {
        let paths = framePaths(in: folder)
        guard let first = paths.first.flatMap(loadCGImage) else { throw IOError.noFrames }
        let outSize = size ?? CGSize(width: first.width, height: first.height)
        let w = Int(outSize.width) / 2 * 2, h = Int(outSize.height) / 2 * 2
        try? FileManager.default.removeItem(at: dest)
        let writer = try AVAssetWriter(outputURL: dest, fileType: codec.fileType)
        var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if codec != .proRes422 {
            let rate = bitrate ?? Int(Double(w * h * max(fps, 1)) * (codec == .hevc ? 0.08 : 0.12))
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: rate,
                                                         AVVideoExpectedSourceFrameRateKey: fps]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        if let metadata { writer.metadata = metadataItems(metadata) }

        // Audio pass-through (original sound of the source video)
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioFrom {
            let asset = AVURLAsset(url: audioFrom)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                if r.canAdd(o) {
                    r.add(o)
                    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000, AVEncoderBitRateKey: 192_000])
                    ai.expectsMediaDataInRealTime = false
                    if writer.canAdd(ai) { writer.add(ai); audioReader = r; audioOutput = o; audioInput = ai }
                }
            }
        }

        guard writer.startWriting() else { throw IOError.writerFailed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        audioReader?.startReading()
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let timescale = CMTimeScale(max(fps, 1) * 100)
        for (i, p) in paths.enumerated() {
            guard let cg = loadCGImage(p) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw IOError.writerFailed("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw IOError.writerFailed("pixel buffer") }
            var img = CIImage(cgImage: cg)
            let sx = CGFloat(w) / img.extent.width, sy = CGFloat(h) / img.extent.height
            if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            }
            if let label { img = burnLabel(label, into: img, width: w, height: h) }
            ctx.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let t = CMTime(value: CMTimeValue(i * 100), timescale: timescale)
            if !adaptor.append(pb, withPresentationTime: t) { throw IOError.writerFailed(writer.error?.localizedDescription ?? "append") }
            progress?(Double(i + 1) / Double(paths.count))
        }
        input.markAsFinished()
        let duration = CMTime(value: CMTimeValue(paths.count * 100), timescale: timescale)
        if let ar = audioReader, let ao = audioOutput, let ai = audioInput {
            while let sample = ao.copyNextSampleBuffer() {
                if CMSampleBufferGetPresentationTimeStamp(sample) >= duration { break }
                while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                ai.append(sample)
            }
            ai.markAsFinished()
            ar.cancelReading()
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        if writer.status != .completed { throw IOError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
    }

    private static func burnLabel(_ text: String, into img: CIImage, width: Int, height: Int) -> CIImage {
        let fontSize = max(12, CGFloat(height) * 0.03)
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        let s = NSAttributedString(string: text, attributes: attr)
        let size = s.size()
        let pad = fontSize * 0.5
        let rect = CGRect(x: 0, y: 0, width: ceil(size.width + pad * 2), height: ceil(size.height + pad))
        let bmp = NSImage(size: rect.size)
        bmp.lockFocus()
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        s.draw(at: CGPoint(x: pad, y: pad / 2))
        bmp.unlockFocus()
        guard let tiff = bmp.tiffRepresentation, let badge = CIImage(data: tiff) else { return img }
        let margin = CGFloat(height) * 0.03
        let placed = badge.transformed(by: CGAffineTransform(translationX: CGFloat(width) - rect.width - margin, y: margin))
        return placed.composited(over: img)
    }

    // MARK: Reading

    struct SourceInfo: Equatable {
        var duration: Double
        var fps: Double
        var size: CGSize
        var hasAudio: Bool
        var codec: String
    }

    static func info(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw IOError.readFailed(String(localized: "no video track")) }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let size = natural.applying(transform)
        let duration = try await asset.load(.duration).seconds
        let audio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let fmt = try await track.load(.formatDescriptions).first
        let code = fmt.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let fourcc = String(bytes: [UInt8(code >> 24 & 255), UInt8(code >> 16 & 255), UInt8(code >> 8 & 255), UInt8(code & 255)], encoding: .ascii) ?? "?"
        return SourceInfo(duration: duration, fps: Double(rate), size: CGSize(width: abs(size.width), height: abs(size.height)), hasAudio: audio, codec: fourcc)
    }

    /// Extracts `count` frames evenly from `start` at `fps`, scaled and centre-cropped to `size`, as PNG files.
    static func extractFrames(from url: URL, start: Double = 0, fps: Double, count: Int, size: CGSize, to folder: URL,
                              cropRect: CGRect? = nil) async throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let ctx = CIContext()
        for i in 0..<count {
            let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
            let (cg, _) = try await gen.image(at: t)
            var img = CIImage(cgImage: cg)
            if let c = cropRect { img = img.cropped(to: c).transformed(by: CGAffineTransform(translationX: -c.minX, y: -c.minY)) }
            img = fill(img, to: size)
            guard let out = ctx.createCGImage(img, from: CGRect(origin: .zero, size: size)) else { continue }
            try writePNG(out, to: folder.appendingPathComponent(String(format: "f_%05d.png", i)))
        }
    }

    /// Scales to cover `size` and centre-crops.
    static func fill(_ img: CIImage, to size: CGSize) -> CIImage {
        let s = max(size.width / img.extent.width, size.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (scaled.extent.width - size.width) / 2 - scaled.extent.minX
        let dy = (scaled.extent.height - size.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func writePNG(_ cg: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw IOError.writerFailed("png") }
        CGImageDestinationAddImage(d, cg, nil)
        guard CGImageDestinationFinalize(d) else { throw IOError.writerFailed("png") }
    }

    static func poster(_ url: URL, maxSize: CGFloat = 640) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        return try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }
}
