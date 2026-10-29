import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads any ImageIO format into display-referred sRGB floats and writes 16-bit PNG or TIFF (8-bit JPEG).
public struct ImageFile {
    public let pixels: FloatImage

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw ChromaticError("cannot read image: \(url.path)")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ChromaticError("cannot decode image pixels")
        }
        let w = cgImage.width, h = cgImage.height
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { data -> Bool in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space, bitmapInfo: info) else { return false }
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ChromaticError("cannot create a float decode context") }
        for j in stride(from: 0, to: rgba.count, by: 4) where rgba[j + 3] > 0 && rgba[j + 3] < 1 {
            for c in 0..<3 { rgba[j + c] /= rgba[j + 3] }
        }
        pixels = try FloatImage(width: w, height: h, rgba: rgba)
    }

    public static func write(_ pixels: FloatImage, to url: URL, overwrite: Bool = false) throws {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "png": type = .png
        case "tif", "tiff": type = .tiff
        case "jpg", "jpeg": type = .jpeg
        default: throw ChromaticError("output extension must be .png, .tif, .tiff, .jpg or .jpeg")
        }
        if !overwrite, FileManager.default.fileExists(atPath: url.path) { throw ChromaticError("output already exists; use --force to replace it") }
        var words = [UInt16](repeating: 0, count: pixels.rgba.count)
        for (i, value) in pixels.rgba.enumerated() { words[i] = UInt16((min(1, max(0, value)) * 65535).rounded()) }
        let data = words.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: pixels.width * 8, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ChromaticError("cannot create the output image")
        }
        let encoded = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { throw ChromaticError("cannot create an image encoder") }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw ChromaticError("image encoding failed") }
        try (encoded as Data).write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
    }
}
