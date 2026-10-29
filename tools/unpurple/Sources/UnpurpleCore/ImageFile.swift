import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct ImageFile {
    public let pixels: PixelImage
    public let metadata: [String: Any]

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw UnpurpleError("cannot read image: \(url.path)")
        }
        // Decode at full resolution and apply EXIF orientation once.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw UnpurpleError("cannot decode image pixels")
        }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, w <= Int(UInt32.max) / h, w * h <= Int.max / 4 else {
            throw UnpurpleError("image is too large")
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw UnpurpleError("cannot create RGBA decode context") }
        // The algorithm expects straight RGB, not RGB multiplied by alpha.
        for j in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[j + 3])
            if alpha > 0, alpha < 255 {
                for c in 0..<3 { rgba[j + c] = UInt8(min(255, (Int(rgba[j + c]) * 255 + alpha / 2) / alpha)) }
            }
        }
        pixels = try PixelImage(width: w, height: h, rgba: rgba)
        metadata = properties
    }

    public static func write(_ pixels: PixelImage, to url: URL, metadata: [String: Any] = [:],
                             quality: Double = 0.95, overwrite: Bool = false) throws {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "tif", "tiff": type = .tiff
        default: throw UnpurpleError("output extension must be .png, .jpg, .jpeg, .tif, or .tiff")
        }
        guard quality.isFinite, (0...1).contains(quality) else { throw UnpurpleError("JPEG quality must be in [0, 1]") }
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw UnpurpleError("output already exists; use --force to replace it")
        }
        if type == .jpeg, stride(from: 3, to: pixels.rgba.count, by: 4).contains(where: { pixels.rgba[$0] != 255 }) {
            throw UnpurpleError("JPEG cannot preserve transparency; choose PNG or TIFF")
        }
        guard let provider = CGDataProvider(data: Data(pixels.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: pixels.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw UnpurpleError("cannot create output image")
        }
        // Only copy descriptive dictionaries, not source profiles, thumbnails, or format-specific encoding settings.
        var properties: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            if let value = metadata[key as String] { properties[key as String] = value }
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = pixels.width
            exif[kCGImagePropertyExifPixelYDimension as String] = pixels.height
            exif[kCGImagePropertyExifColorSpace as String] = 1 // sRGB
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = pixels.width
        properties[kCGImagePropertyPixelHeight as String] = pixels.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        // Use a retained data object so encoding completes before touching the output path.
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw UnpurpleError("cannot create image encoder")
        }
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw UnpurpleError("image encoding failed") }
        try (data as Data).write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
    }
}
