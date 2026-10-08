import CoreGraphics
import Foundation

/// Premultiplied sRGB RGBA8 pixels, backed by a CGContext so tools can paint into them directly.
///
/// Rows are stored top-down with no padding (`bytesPerRow == width * 4`). Treat a bitmap that
/// lives in a document as immutable: copy it before painting so undo snapshots keep the old pixels.
final class Bitmap: @unchecked Sendable {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let width: Int
    let height: Int
    let context: CGContext
    private var cachedImage: CGImage?

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        context = CGContext(
            data: nil, width: self.width, height: self.height, bitsPerComponent: 8,
            bytesPerRow: self.width * 4, space: Bitmap.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
    }

    convenience init(image: CGImage) {
        self.init(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var bytesPerRow: Int { width * 4 }
    var pixels: UnsafeMutablePointer<UInt8> { context.data!.assumingMemoryBound(to: UInt8.self) }

    var image: CGImage {
        if let cachedImage { return cachedImage }
        let made = context.makeImage()!
        cachedImage = made
        return made
    }

    /// Call after writing to `context` or `pixels`.
    func didChange() { cachedImage = nil }

    func copy() -> Bitmap {
        let copy = Bitmap(width: width, height: height)
        memcpy(copy.pixels, pixels, bytesPerRow * height)
        return copy
    }

    func fill(_ color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        didChange()
    }
}
