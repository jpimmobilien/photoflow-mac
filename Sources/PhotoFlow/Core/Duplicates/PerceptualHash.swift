import Foundation
import CoreGraphics
import CryptoKit

/// Classic perceptual hashes (64 bit). Robust to resizing, recompression and mild colour/brightness changes.
/// - aHash: 8×8 mean threshold
/// - dHash: 9×8 horizontal gradient signs
/// - pHash: 32×32 DCT, 8×8 low-frequency block (excluding DC) against its median
enum PerceptualHash {
    struct Hashes: Sendable, Equatable { var a: UInt64; var d: UInt64; var p: UInt64 }

    static func compute(_ image: CGImage) -> Hashes? {
        guard let g32 = grayscale(image, 32, 32), let g9 = grayscale(image, 9, 8), let g8 = grayscale(image, 8, 8) else { return nil }
        // aHash
        let mean = g8.reduce(0, +) / Float(g8.count)
        var a: UInt64 = 0
        for (i, v) in g8.enumerated() where v > mean { a |= 1 << UInt64(i) }
        // dHash
        var d: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                if g9[y * 9 + x + 1] > g9[y * 9 + x] { d |= 1 << bit }
                bit += 1
            }
        }
        // pHash
        let dct = dct2D(g32, n: 32)
        var block: [Float] = []
        for y in 0 ..< 8 { for x in 0 ..< 8 where !(x == 0 && y == 0) { block.append(dct[y * 32 + x]) } }
        let median = block.sorted()[block.count / 2]
        var p: UInt64 = 0
        var b: UInt64 = 0
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                if !(x == 0 && y == 0) && dct[y * 32 + x] > median { p |= 1 << b }
                b += 1
            }
        }
        return Hashes(a: a, d: d, p: p)
    }

    @inline(__always) static func distance(_ x: UInt64, _ y: UInt64) -> Int { (x ^ y).nonzeroBitCount }

    /// Area-averaged grayscale resample via Core Graphics.
    static func grayscale(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf.map { Float($0) / 255 } : nil
    }

    /// Separable DCT-II.
    static func dct2D(_ input: [Float], n: Int) -> [Float] {
        var cosTable = [Float](repeating: 0, count: n * n)
        for k in 0 ..< n { for i in 0 ..< n { cosTable[k * n + i] = cosf(Float.pi * Float(k) * (2 * Float(i) + 1) / Float(2 * n)) } }
        var tmp = [Float](repeating: 0, count: n * n), out = tmp
        for y in 0 ..< n {
            for k in 0 ..< n {
                var s: Float = 0
                for i in 0 ..< n { s += input[y * n + i] * cosTable[k * n + i] }
                tmp[y * n + k] = s
            }
        }
        for x in 0 ..< n {
            for k in 0 ..< n {
                var s: Float = 0
                for i in 0 ..< n { s += tmp[i * n + x] * cosTable[k * n + i] }
                out[k * n + x] = s
            }
        }
        return out
    }
}

enum FileHasher {
    /// Streaming SHA-256 (1 MB chunks – constant memory for any file size).
    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 1 << 20) }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
