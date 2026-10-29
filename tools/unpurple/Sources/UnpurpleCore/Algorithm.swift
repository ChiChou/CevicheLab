// Port of Martin Jambon's Unpurple. Copyright (c) 2012 Martin Jambon.
// See ../../LICENSE.upstream for redistribution conditions and disclaimer.
import Foundation

public struct UnpurpleError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum OutputMode: UInt32, CaseIterable {
    case normal = 0, diff = 1, blur = 2
}

public struct Parameters {
    public var radius: Double = 5
    public var intensity: Double = 1
    public var minBrightness: Double = 0
    public var minRed: Double = 0
    public var maxRed: Double = 0.33
    public var mode: OutputMode = .normal

    public init() {}

    public func validate() throws {
        guard radius.isFinite, radius > 0, radius <= 256 else {
            throw UnpurpleError("radius must be greater than 0 and at most 256 pixels")
        }
        guard intensity.isFinite, (0...100).contains(intensity) else {
            throw UnpurpleError("intensity must be between 0 and 100")
        }
        guard minBrightness.isFinite, minBrightness >= 0, minBrightness < 1,
              Float(minBrightness) < 1 else {
            throw UnpurpleError("minimum brightness must be in [0, 1) and representable below 1 as Float")
        }
        guard minRed.isFinite, maxRed.isFinite, minRed >= 0,
              minRed <= maxRed, maxRed <= 100,
              minRed == 0 || Float(minRed) > 0 else {
            throw UnpurpleError("red ratios must satisfy 0 <= minred <= maxred <= 100")
        }
    }

    // Upstream's tent blur is two box blurs of ceil(ceil(radius) / 2).
    var boxRadius: Int { (Int(ceil(radius)) + 1) / 2 }
}

/// Straight (unpremultiplied), gamma-encoded sRGB RGBA8 pixels, row-major.
public struct PixelImage {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              width <= Int(UInt32.max) / height,
              width * height <= Int.max / 4, rgba.count == width * height * 4 else {
            throw UnpurpleError("invalid RGBA image dimensions or byte count")
        }
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Double-precision CPU reference following upstream's rolling-sum implementation.
public enum CPUProcessor {
    public static func process(_ image: PixelImage, parameters p: Parameters) throws -> PixelImage {
        try p.validate()
        let w = image.width, h = image.height
        var mask = (0..<(w * h)).map { i in
            p.intensity * max(0, Double(image.rgba[4 * i + 2]) / 255 - p.minBrightness)
                / (1 - p.minBrightness)
        }
        for _ in 0..<2 {
            mask = boxBlur(mask, width: w, height: h, radius: p.boxRadius, horizontal: true)
            mask = boxBlur(mask, width: w, height: h, radius: p.boxRadius, horizontal: false)
        }
        var out = image
        for i in 0..<(w * h) {
            let j = i * 4
            let r = Double(image.rgba[j]), g = Double(image.rgba[j + 1]), b = Double(image.rgba[j + 2])
            let blur = max(0, min(255, mask[i] * 255))
            let mb = min(blur, max(b - g, 0))
            let dr = min(max(r - g, 0), mb * p.maxRed)
            let db = p.minRed > 0 ? min(mb, dr / p.minRed) : mb
            switch p.mode {
            case .normal:
                out.rgba[j] -= UInt8(dr)
                out.rgba[j + 2] -= UInt8(db)
            case .diff:
                out.rgba[j] = UInt8(dr)
                out.rgba[j + 1] = 0
                out.rgba[j + 2] = UInt8(db)
            case .blur:
                out.rgba[j] = UInt8(blur)
                out.rgba[j + 1] = UInt8(blur)
                out.rgba[j + 2] = UInt8(blur)
            }
        }
        return out
    }

    private static func boxBlur(_ values: [Double], width: Int, height: Int,
                                radius: Int, horizontal: Bool) -> [Double] {
        var result = values
        let length = horizontal ? width : height
        let lines = horizontal ? height : width
        let step = horizontal ? 1 : width
        for line in 0..<lines {
            let base = horizontal ? line * width : line
            func value(_ position: Int) -> Double {
                values[base + min(length - 1, max(0, position)) * step]
            }
            var sum = Double(radius + 2) * value(0)
            if radius > 1 {
                for j in 1..<radius { sum += value(j) }
            }
            for j in 0..<length {
                sum -= value(j - 1 - radius)
                sum += value(j + radius)
                result[base + j * step] = sum / Double(2 * radius + 1)
            }
        }
        return result
    }
}
