//
//  SamplerImageTools.swift
//  RallyLab
//
//  Stateless image helpers for the Sampler: finding stills on disk, decoding
//  and writing them, and the near-duplicate test the ingest uses to drop
//  burst frames where nothing moved.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SamplerImageTools {

    static func imageFiles(in folder: URL) -> [URL] {
        let types: Set<String> = ["jpg", "jpeg", "png"]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where types.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Decode a still from disk, capped to `maxPixelSize` on its longer side,
    /// orientation applied so a phone JPEG comes up upright.
    static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func downscale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Difference hash: 9×8 grayscale, each bit = "left pixel brighter than
    /// its right neighbour". Two frames of the same moment differ in a
    /// handful of bits; a ball moving across the frame flips many.
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                hash <<= 1
                if pixels[row * w + col] > pixels[row * w + col + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Two frames are the same moment when the ball(s) haven't moved: every
    /// detection in one sits within 1% of the frame of one in the other.
    /// A frame with a ball and one without are always different; two frames
    /// with no ball at all fall back to the picture hash.
    static func isSameMoment(
        _ a: (hash: UInt64, centers: [CGPoint]), _ b: (hash: UInt64, centers: [CGPoint]), hashThreshold: Int
    ) -> Bool {
        if a.centers.isEmpty && b.centers.isEmpty {
            return hamming(a.hash, b.hash) <= hashThreshold
        }
        guard a.centers.count == b.centers.count else { return false }
        let tolerance: CGFloat = 0.01
        return b.centers.allSatisfy { c in
            a.centers.contains { abs($0.x - c.x) <= tolerance && abs($0.y - c.y) <= tolerance }
        }
    }
}
