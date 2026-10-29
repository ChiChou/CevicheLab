// Full-resolution ImageIO decode; no embedded-thumbnail API and no LibRaw.
// swiftc -O decode.swift -o decode
import Foundation
import ImageIO
import CoreImage
import CoreGraphics

let args = CommandLine.arguments
let destination = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
func png(_ image: CGImage, _ url: URL) {
    let w = min(1600, image.width), h = Int(Double(image.height)*Double(w)/Double(image.width))
    let bitmap = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:srgb,
        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.interpolationQuality = .high
    bitmap.draw(image, in:CGRect(x:0,y:0,width:w,height:h))
    let cg = bitmap.makeImage()!
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, cg, nil)
    precondition(CGImageDestinationFinalize(writer))
}
for path in args.dropFirst(2) {
    try autoreleasepool {
        let url = URL(fileURLWithPath: path), stem = url.deletingPathExtension().lastPathComponent
        let start = Date()
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat:true, kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { fatalError("ImageIO failed: \(path)") }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
        let bounds = image.extent.integral, w = Int(bounds.width), h = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: w*h*4)
        context.render(image, toBitmap: &pixels, rowBytes:w*16, bounds:bounds, format:.RGBAf, colorSpace:linear)
        try pixels.withUnsafeBytes { try Data($0).write(to:destination.appendingPathComponent(stem + ".rgba32")) }
        png(cg, destination.appendingPathComponent(stem + "-overview.png"))
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary ?? [:]
        let report: [String:Any] = ["file":url.lastPathComponent,"width":w,"height":h,"orientation":orientation,
          "imageCount":CGImageSourceGetCount(source),"sourceBitsPerComponent":cg.bitsPerComponent,
          "sourceColorSpace":cg.colorSpace?.name as String? ?? "unknown", "outputColorSpace":"extended linear Rec.2020",
          "iso":exif[kCGImagePropertyExifISOSpeedRatings] ?? [],"exposureSeconds":exif[kCGImagePropertyExifExposureTime] ?? 0,
          "aperture":exif[kCGImagePropertyExifFNumber] ?? 0,"camera":tiff[kCGImagePropertyTIFFModel] ?? "unknown",
          "decodeAndWriteSeconds":Date().timeIntervalSince(start)]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:destination.appendingPathComponent(stem + ".json"))
        print(String(decoding:data,as:UTF8.self))
    }
}
