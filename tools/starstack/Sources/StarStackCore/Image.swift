import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public struct StackError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// RGBA Float32, row zero at the top. All geometry uses this convention.
public struct Frame {
    public let width: Int
    public let height: Int
    public var pixels: [Float]
    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4)
        self.width = width; self.height = height; self.pixels = pixels
    }
    public var luminance: [Float] {
        (0..<width * height).map { i in
            0.2126 * pixels[4*i] + 0.7152 * pixels[4*i+1] + 0.0722 * pixels[4*i+2]
        }
    }
    public func sample(_ x: Double, _ y: Double) -> SIMD4<Float>? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(width-1), y < Double(height-1) else { return nil }
        let ix = Int(x), iy = Int(y), fx = Float(x-Double(ix)), fy = Float(y-Double(iy))
        func p(_ xx: Int, _ yy: Int) -> SIMD4<Float> {
            let k = 4 * (yy * width + xx)
            return SIMD4(pixels[k],pixels[k+1],pixels[k+2],pixels[k+3])
        }
        return (p(ix,iy)*(1-fx)+p(ix+1,iy)*fx)*(1-fy) + (p(ix,iy+1)*(1-fx)+p(ix+1,iy+1)*fx)*fy
    }
}

public struct Metadata: Codable {
    public let path: String
    public let width: Int
    public let height: Int
    public let camera: String
    public let dateTimeOriginal: String?
    public let subsecond: String?
    public let offset: String?
    public let exposure: Double?
    public let iso: Double?
    public let aperture: Double?
    public let focalLength: Double?
    public let focal35: Double?
    public let relativeClock: Double?
    public var midpoint: Double? { relativeClock.map { $0 + (exposure ?? 0)/2 } }
}

public final class Imaging {
    public static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    public let context: CIContext
    public init() {
        context = CIContext(options: [.workingColorSpace: Self.linear, .workingFormat: CIFormat.RGBAf,
                                      .cacheIntermediates: false])
    }
    public static func files(in folder: URL) throws -> [URL] {
        let extensions: Set<String> = ["arw","dng","cr2","cr3","nef","raf","rw2","orf","tif","tiff"]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    public static func metadata(_ url: URL) throws -> Metadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let d = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { throw StackError("Cannot read metadata: \(url.path)") }
        let exif = d[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let tiff = d[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        func number(_ key: CFString) -> Double? { (exif[key as String] as? NSNumber)?.doubleValue }
        let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let sub = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String
        let offset = exif["OffsetTimeOriginal"] as? String
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        // Without an explicit offset this is a camera-local clock, NOT an assertion of UTC capture time.
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var clock = date.flatMap { formatter.date(from:$0)?.timeIntervalSince1970 }
        if let s = sub, let f = Double("0." + s), clock != nil { clock! += f }
        if let offset, offset.count == 6 {
            let parts = offset.dropFirst().split(separator:":")
            if parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]), clock != nil {
                clock! -= (offset.first == "-" ? -1 : 1) * (h*3600+m*60)
            }
        }
        let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        return Metadata(path:url.path, width:(d[kCGImagePropertyPixelWidth as String] as? Int ?? 0),
                        height:(d[kCGImagePropertyPixelHeight as String] as? Int ?? 0),
                        camera:tiff[kCGImagePropertyTIFFModel as String] as? String ?? "unknown",
                        dateTimeOriginal:date, subsecond:sub, offset:offset, exposure:number(kCGImagePropertyExifExposureTime),
                        iso:isos?.first?.doubleValue, aperture:number(kCGImagePropertyExifFNumber),
                        focalLength:number(kCGImagePropertyExifFocalLength), focal35:number(kCGImagePropertyExifFocalLenIn35mmFilm), relativeClock:clock)
    }
    public func whiteBalance(_ url: URL) throws -> (Float, Float) {
        guard let raw = CIRAWFilter(imageURL:url) else { throw StackError("Unsupported RAW: \(url.path)") }
        return (raw.neutralTemperature,raw.neutralTint)
    }
    public func decode(_ url: URL, longEdge: Int, whiteBalance: (Float,Float)? = nil) throws -> Frame {
        try autoreleasepool {
            guard let raw = CIRAWFilter(imageURL:url) else { throw StackError("RAW decoding failed: \(url.path)") }
            raw.scaleFactor = Float(min(1,Double(longEdge)/max(raw.nativeSize.width,raw.nativeSize.height)))
            if let wb = whiteBalance { raw.neutralTemperature=wb.0; raw.neutralTint=wb.1 }
            raw.exposure=0; raw.boostAmount=0; raw.boostShadowAmount=0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount=0 }
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount=0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount=0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount=0 }
            if raw.isDetailSupported { raw.detailAmount=0 }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled=true }
            guard let image = raw.outputImage else { throw StackError("Empty RAW: \(url.path)") }
            return render(image, longEdge:longEdge)
        }
    }
    public func render(_ input: CIImage, longEdge: Int) -> Frame {
        var image = input.transformed(by:CGAffineTransform(translationX:-input.extent.minX,y:-input.extent.minY))
        let scale = min(1,Double(longEdge)/max(image.extent.width,image.extent.height))
        if scale < 1 { image=image.applyingFilter("CILanczosScaleTransform",parameters:["inputScale":scale,"inputAspectRatio":1]) }
        let w=Int(image.extent.width.rounded(.down)), h=Int(image.extent.height.rounded(.down))
        var pixels=[Float](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { b in context.render(image,toBitmap:b.baseAddress!,rowBytes:w*16,
            bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:Self.linear) }
        for i in pixels.indices where !pixels[i].isFinite { pixels[i]=0 }
        return Frame(width:w,height:h,pixels:pixels)
    }
    public func thumbnail(_ url: URL, size: Int) throws -> CIImage {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),
              let cg=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:size] as CFDictionary)
        else { throw StackError("Thumbnail failed: \(url.path)") }
        return CIImage(cgImage:cg)
    }
    public func image(_ frame: Frame) -> CIImage {
        let data=frame.pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData:data,bytesPerRow:frame.width*16,size:CGSize(width:frame.width,height:frame.height),format:.RGBAf,colorSpace:Self.linear)
    }
    public func write(_ frame: Frame, to url: URL, ev: Float=0) throws {
        let im=image(frame)
        if url.pathExtension.lowercased()=="tiff" {
            try context.writeTIFFRepresentation(of:im,to:url,format:.RGBAf,colorSpace:Self.linear)
        } else {
            let preview=im.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
            try context.writePNGRepresentation(of:preview,to:url,format:.RGBA8,colorSpace:Self.sRGB)
        }
    }
    public func writeMask(_ mask: [Float], width: Int, height: Int, to url: URL) throws {
        var rgba=[Float](repeating:1,count:width*height*4)
        for i in mask.indices { for c in 0..<3 { rgba[4*i+c]=mask[i] } }
        try write(Frame(width:width,height:height,pixels:rgba),to:url)
    }
}

public func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys]
    try e.encode(value).write(to:url,options:.atomic)
}
