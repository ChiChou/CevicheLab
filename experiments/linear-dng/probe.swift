// Standalone research helper. Compile with: swiftc -O probe.swift -o probe
import Foundation
import CoreGraphics
import CoreImage
import ImageIO

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let context = CIContext(options: [.cacheIntermediates: false])
func read(_ url: URL) throws -> CGImage {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "ImageIO could not read \(url.path)"])
    }
    return image
}
func bitmap(_ image: CGImage, depth: Int = 8, space: CGColorSpace? = nil) -> CGContext {
    let flags = (depth == 16 ? CGBitmapInfo.byteOrder16Little : .byteOrder32Big).rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: depth,
                      bytesPerRow: image.width * 4 * depth / 8, space: space ?? srgb, bitmapInfo: flags)!
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return c
}
func write(_ image: CGImage, _ url: URL) {
    let type = url.pathExtension == "tiff" ? "public.tiff" : "public.png"
    let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil)
    precondition(CGImageDestinationFinalize(d))
}
func metrics(_ reference: CGImage, _ actual: CGImage) -> [String: Any] {
    guard reference.width == actual.width && reference.height == actual.height else {
        return ["dimensionMismatch": [reference.width, reference.height, actual.width, actual.height]]
    }
    let a = bitmap(reference), b = bitmap(actual)
    let ap = a.data!.assumingMemoryBound(to: UInt8.self), bp = b.data!.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, squared = 0.0, maxError = 0, over1 = 0
    var histogram = [Int](repeating: 0, count: 256)
    for i in 0..<(reference.width * reference.height) {
        for channel in 0..<3 {
            let d = abs(Int(ap[i * 4 + channel]) - Int(bp[i * 4 + channel]))
            sum += Double(d); squared += Double(d*d); maxError = max(maxError, d)
            if d > 1 { over1 += 1 }; histogram[d] += 1
        }
    }
    let count = reference.width * reference.height * 3
    var n = 0, p99 = 0
    for i in 0..<256 { n += histogram[i]; if Double(n) >= Double(count)*0.99 { p99 = i; break } }
    return ["mae8": sum/Double(count), "rmse8": sqrt(squared/Double(count)), "max8": maxError,
            "p99_8": p99, "percentChannelsOver1": Double(over1)/Double(count)*100]
}
let args = CommandLine.arguments
let mode = args[1], directory = URL(fileURLWithPath: args[2], isDirectory: true)
if mode == "prepare" {
    try (linear.copyICCData()! as Data).write(to: directory.appendingPathComponent("linear-srgb.icc"))
    // A smooth grayscale ramp plus low/mid/high-intensity RGB and CMY patches.
    let w = 768, h = 384
    var pixels = [UInt8](repeating: 255, count: w*h*4)
    let colors: [[Double]] = [[1,0,0], [0,1,0], [0,0,1], [0,1,1], [1,0,1], [1,1,0]]
    for y in 0..<h { for x in 0..<w { for c in 0..<3 {
        let v: Double
        if y < 128 { v = Double(x)/Double(w-1) }
        else { v = colors[x/128][c] * (y < 214 ? 0.25 : (y < 299 ? 0.5 : 1)) }
        pixels[(y*w+x)*4+c] = UInt8((v*255).rounded())
    } } }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let chart = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4, space: srgb,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)!
    write(chart, directory.appendingPathComponent("chart.tiff"))
    let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "tiff" && !$0.lastPathComponent.contains("linear") }
    for url in sources {
        let source = try read(url), converted = bitmap(source, depth: 16, space: linear)
        let p = converted.data!.assumingMemoryBound(to: UInt16.self)
        var rgb = [UInt16](); rgb.reserveCapacity(source.width*source.height*3)
        for i in 0..<(source.width*source.height) { for c in 0..<3 { rgb.append(p[i*4+c].littleEndian) } }
        let base = url.deletingPathExtension()
        try rgb.withUnsafeBytes { try Data($0).write(to: base.appendingPathExtension("rgb16")) }
        try JSONSerialization.data(withJSONObject: ["width": source.width, "height": source.height]).write(to: base.appendingPathExtension("json"))
        write(converted.makeImage()!, base.appendingPathExtension("linear.tiff"))
        print(url.lastPathComponent, "linear conversion", metrics(source, converted.makeImage()!))
    }
} else if mode == "decode" {
    var report = [[String: Any]]()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "dng" }.sorted { $0.path < $1.path }
    for url in files {
        let stem = url.deletingPathExtension().lastPathComponent
        let referenceName = String(stem.split(separator: "_")[0])
        let reference = try read(directory.appendingPathComponent(referenceName + ".tiff"))
        var entry: [String: Any] = ["file": url.lastPathComponent]
        do {
            let decoded = try read(url)
            entry["imageIO"] = metrics(reference, decoded)
            entry["imageIOSize"] = [decoded.width, decoded.height]
            write(decoded, directory.appendingPathComponent(stem + "-imageio.png"))
        } catch { entry["imageIOError"] = error.localizedDescription }
        for variant in ["rawDefault", "rawBoostOff", "rawGamutOff", "rawNeutral"] {
            guard let raw = CIRAWFilter(imageURL: url) else { entry["rawError"] = "CIRAWFilter rejected file"; continue }
            if variant == "rawDefault" {
                entry["rawDefaults"] = ["decoder": raw.decoderVersion.rawValue, "boost": raw.boostAmount,
                                        "exposure": raw.exposure, "baselineExposure": raw.baselineExposure,
                                        "localToneMap": raw.localToneMapAmount, "gamutMapping": raw.isGamutMappingEnabled]
            } else if variant == "rawBoostOff" {
                raw.boostAmount = 0
            } else if variant == "rawGamutOff" {
                raw.isGamutMappingEnabled = false
            } else {
                raw.boostAmount = 0; raw.baselineExposure = 0; raw.exposure = 0
                raw.localToneMapAmount = 0; raw.isGamutMappingEnabled = false
                raw.sharpnessAmount = 0; raw.contrastAmount = 0; raw.detailAmount = 0
                raw.luminanceNoiseReductionAmount = 0; raw.colorNoiseReductionAmount = 0
            }
            guard let ci = raw.outputImage, let image = context.createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: srgb) else {
                entry["rawError"] = "CIRAWFilter produced no image"; continue
            }
            let key = variant
            entry[key] = metrics(reference, image)
            write(image, directory.appendingPathComponent(stem + "-" + key + ".png"))
        }
        print(entry)
        report.append(entry)
    }
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("metrics.json"))
} else if mode == "screen" {
    var results = [[String: Any]]()
    for (name, width, height) in [("chart", 768, 384), ("edited", 720, 960)] {
        // Measured window geometry on this host: 2x backing scale, image starts at y=156.
        // Recheck these coordinates before using on another machine/window layout.
        let rect = CGRect(x: 0, y: 156, width: width*2, height: height*2)
        let a = try read(directory.appendingPathComponent("preview-\(name)-reference.png")).cropping(to: rect)!
        let b = try read(directory.appendingPathComponent("preview-\(name)-dng.png")).cropping(to: rect)!
        write(a, directory.appendingPathComponent("preview-\(name)-reference-content.png"))
        write(b, directory.appendingPathComponent("preview-\(name)-dng-content.png"))
        var result: [String: Any] = ["fixture": name, "screenComparison": metrics(a,b)]
        if name == "chart" {
            var patches = [[String: Any]]()
            let ac = bitmap(a), bc = bitmap(b)
            let ap = ac.data!.assumingMemoryBound(to: UInt8.self), bp = bc.data!.assumingMemoryBound(to: UInt8.self)
            for (n,x) in ["red", "green", "blue", "cyan", "magenta", "yellow"].enumerated() {
                let index = ((height*2-84)*width*2 + (n*128+64)*2)*4
                patches.append(["color":x, "reference":Array(UnsafeBufferPointer(start:ap+index,count:3)),
                                "dng":Array(UnsafeBufferPointer(start:bp+index,count:3))])
            }
            result["brightPatches"] = patches
        }
        results.append(result)
    }
    let data = try JSONSerialization.data(withJSONObject:results, options:[.prettyPrinted,.sortedKeys])
    try data.write(to:directory.appendingPathComponent("preview-metrics.json"))
    print(String(decoding:data,as:UTF8.self))
} else if mode == "read" {
    let url = URL(fileURLWithPath: args[3])
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    print("ImageIO image count:", CGImageSourceGetCount(source))
    for i in 0..<CGImageSourceGetCount(source) {
        print("Image", i, CGImageSourceCopyPropertiesAtIndex(source, i, nil) as Any)
    }
    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1700] as CFDictionary) {
        write(image, directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-imageio.png"))
    }
}
