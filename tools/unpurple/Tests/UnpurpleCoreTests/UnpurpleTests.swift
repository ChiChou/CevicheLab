import XCTest
import Metal
import ImageIO
import UniformTypeIdentifiers
@testable import UnpurpleCore

final class UnpurpleTests: XCTestCase {
    func fixture(width: Int, height: Int) throws -> PixelImage {
        var state: UInt32 = 42
        let bytes: [UInt8] = (0..<(width * height * 4)).map { _ in
            state = state &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        return try PixelImage(width: width, height: height, rgba: bytes)
    }

    func testKnownPixelAndTruncation() throws {
        let image = try PixelImage(width: 1, height: 1, rgba: [180, 60, 240, 128])
        var p = Parameters()
        // Blue excess = 180; red removal = truncate(180 * .33) = 59.
        XCTAssertEqual(try CPUProcessor.process(image, parameters: p).rgba, [121, 60, 60, 128])
        p.mode = .diff
        XCTAssertEqual(try CPUProcessor.process(image, parameters: p).rgba, [59, 0, 180, 128])
        p.mode = .blur
        XCTAssertEqual(try CPUProcessor.process(image, parameters: p).rgba, [240, 240, 240, 128])
    }

    func testCPUBlurMatchesIndependentDirectConvolution() throws {
        let image = try fixture(width: 7, height: 3)
        var p = Parameters()
        p.radius = 11 // Larger than either image dimension: exercises border replication.
        p.mode = .blur
        var mask = stride(from: 2, to: image.rgba.count, by: 4).map { Double(image.rgba[$0]) / 255 }
        for horizontal in [true, false, true, false] {
            let source = mask
            for y in 0..<image.height {
                for x in 0..<image.width {
                    var sum = 0.0
                    for offset in -p.boxRadius...p.boxRadius {
                        let xx = min(image.width - 1, max(0, x + (horizontal ? offset : 0)))
                        let yy = min(image.height - 1, max(0, y + (horizontal ? 0 : offset)))
                        sum += source[yy * image.width + xx]
                    }
                    mask[y * image.width + x] = sum / Double(2 * p.boxRadius + 1)
                }
            }
        }
        let out = try CPUProcessor.process(image, parameters: p)
        for i in mask.indices { XCTAssertLessThanOrEqual(abs(Int(out.rgba[4 * i]) - Int(mask[i] * 255)), 1) }
    }

    func testZeroIntensityAndNeutralPixelsAreUnchanged() throws {
        let image = try fixture(width: 23, height: 13)
        var p = Parameters()
        p.intensity = 0
        XCTAssertEqual(try CPUProcessor.process(image, parameters: p).rgba, image.rgba)
        let neutral = try PixelImage(width: 3, height: 1, rgba: [0, 0, 0, 255, 128, 128, 128, 255, 255, 255, 255, 255])
        XCTAssertEqual(try CPUProcessor.process(neutral, parameters: Parameters()).rgba, neutral.rgba)
    }

    func testInvalidParametersAndDimensions() throws {
        for radius in [0.0, -1, 257, .infinity, .nan] {
            var p = Parameters(); p.radius = radius
            XCTAssertThrowsError(try p.validate())
        }
        var p = Parameters(); p.minBrightness = 1
        XCTAssertThrowsError(try p.validate())
        p = Parameters(); p.minRed = 0.5
        XCTAssertThrowsError(try p.validate())
        p = Parameters(); p.intensity = -.infinity
        XCTAssertThrowsError(try p.validate())
        XCTAssertThrowsError(try PixelImage(width: 0, height: 1, rgba: []))
        XCTAssertThrowsError(try PixelImage(width: 2, height: 2, rgba: [0]))
    }

    func testMetalAgreesWithCPUAcrossModesAndBoundaries() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let gpu = try MetalProcessor()
        for (width, height) in [(1, 1), (1, 19), (23, 1), (37, 29), (257, 3)] {
            let image = try fixture(width: width, height: height)
            var gentle = Parameters(); gentle.minBrightness = 0.8; gentle.minRed = 0.15
            var broad = Parameters(); broad.radius = 51.5; broad.intensity = 2; broad.minRed = 0.2; broad.maxRed = 0.8
            var none = Parameters(); none.intensity = 0
            var small = Parameters(); small.radius = 0.1
            for var p in [Parameters(), gentle, broad, none, small] {
                for mode in OutputMode.allCases {
                    p.mode = mode
                    let cpu = try CPUProcessor.process(image, parameters: p)
                    let metal = try gpu.process(image, parameters: p)
                    let maxError = zip(cpu.rgba, metal.rgba).map { abs(Int($0) - Int($1)) }.max()!
                    XCTAssertLessThanOrEqual(maxError, 1, "\(width)x\(height), mode \(mode), radius \(p.radius)")
                    for j in stride(from: 0, to: image.rgba.count, by: 4) {
                        XCTAssertEqual(metal.rgba[j + 3], image.rgba[j + 3])
                        if mode == .normal {
                            XCTAssertEqual(metal.rgba[j + 1], image.rgba[j + 1])
                            XCTAssertLessThanOrEqual(metal.rgba[j], image.rgba[j])
                            XCTAssertLessThanOrEqual(metal.rgba[j + 2], image.rgba[j + 2])
                        }
                    }
                    if p.intensity == 0, mode == .normal { XCTAssertEqual(metal.rgba, image.rgba) }
                }
            }
        }
    }

    func testLosslessImageIOAndOverwriteProtection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var image = try fixture(width: 17, height: 9)
        for i in stride(from: 3, to: image.rgba.count, by: 4) { image.rgba[i] = 255 }
        for ext in ["png", "tiff"] {
            let url = dir.appendingPathComponent("output.\(ext)")
            try ImageFile.write(image, to: url)
            let decoded = try ImageFile(url: url)
            XCTAssertEqual(decoded.pixels.width, image.width)
            XCTAssertEqual(decoded.pixels.height, image.height)
            XCTAssertEqual(decoded.pixels.rgba, image.rgba)
            XCTAssertThrowsError(try ImageFile.write(image, to: url))
            try ImageFile.write(image, to: url, overwrite: true)
        }
        image.rgba[3] = 128
        let transparent = dir.appendingPathComponent("alpha.png")
        try ImageFile.write(image, to: transparent)
        XCTAssertEqual(try ImageFile(url: transparent).pixels.rgba[3], 128)
        XCTAssertThrowsError(try ImageFile.write(image, to: dir.appendingPathComponent("alpha.jpg")))
        XCTAssertThrowsError(try ImageFile.write(image, to: dir.appendingPathComponent("bad.gif")))
    }

    func testOrientationAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.tiff")
        let oriented = dir.appendingPathComponent("oriented.tiff")
        let result = dir.appendingPathComponent("result.tiff")
        let image = try PixelImage(width: 2, height: 3, rgba: [UInt8](repeating: 255, count: 24))
        try ImageFile.write(image, to: original)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(oriented as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(dest, source, 0, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Unpurple test", kCGImagePropertyTIFFOrientation: 6]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let loaded = try ImageFile(url: oriented)
        XCTAssertEqual(loaded.pixels.width, 3)
        XCTAssertEqual(loaded.pixels.height, 2)
        try ImageFile.write(loaded.pixels, to: result, metadata: loaded.metadata)
        let output = try ImageFile(url: result)
        XCTAssertEqual(output.pixels.width, 3)
        XCTAssertEqual(output.pixels.height, 2)
        let tiff = output.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFArtist as String] as? String, "Unpurple test")
    }
}
