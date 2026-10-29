import XCTest
@testable import ChromaticCore

final class ChromaticTests: XCTestCase {
    /// A soft grey edge whose red and blue transitions are displaced from green's: a lateral fringe.
    private func fringed(width: Int = 96, height: Int = 64) throws -> FloatImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        func ramp(_ x: Double, center: Double, softness: Double) -> Float { Float(0.2 + 0.6 / (1 + exp(-(x - center) / softness))) }
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = ramp(Double(x), center: 44, softness: 2.5)
                rgba[i + 1] = ramp(Double(x), center: 48, softness: 1.5)
                rgba[i + 2] = ramp(Double(x), center: 52, softness: 3)
            }
        }
        return try FloatImage(width: width, height: height, rgba: rgba)
    }
    private func processor() throws -> MetalProcessor {
        do { return try MetalProcessor() } catch { throw XCTSkip("No Metal device: \(error)") }
    }
    func testFringeShrinksAndGreenAndAlphaAreUntouched() throws {
        let image = try fringed()
        let out = try CPUProcessor.process(image, parameters: Parameters())
        func chroma(_ img: FloatImage) -> Float {
            var total: Float = 0
            for i in stride(from: 0, to: img.rgba.count, by: 4) { total += abs(img.rgba[i] - img.rgba[i + 1]) + abs(img.rgba[i + 2] - img.rgba[i + 1]) }
            return total
        }
        XCTAssertLessThan(chroma(out), chroma(image) * 0.5)
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            XCTAssertEqual(out.rgba[i + 1], image.rgba[i + 1]); XCTAssertEqual(out.rgba[i + 3], image.rgba[i + 3])
        }
    }
    func testZeroAmountIsIdentityAndMetalMatchesCPU() throws {
        let image = try fringed()
        var zero = Parameters(); zero.amount = 0
        XCTAssertEqual(try CPUProcessor.process(image, parameters: zero), image)
        let gpu = try processor()
        XCTAssertEqual(try gpu.process(image, parameters: zero), image)
        for radii in [(7, 4), (1, 1), (20, 12)] {
            var p = Parameters(); p.horizontalRadius = radii.0; p.verticalRadius = radii.1
            let a = try gpu.process(image, parameters: p), b = try CPUProcessor.process(image, parameters: p)
            let maxError = zip(a.rgba, b.rgba).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(maxError, 1 / 255, "radii \(radii)")
        }
    }
    func testNoiseAndTinyImagesAgreeBetweenBackends() throws {
        let gpu = try processor()
        var generator = SystemRandomNumberGenerator()
        for (w, h) in [(1, 1), (3, 70), (70, 3), (40, 30)] {
            var rgba = (0..<(w * h * 4)).map { _ in Float.random(in: 0...1, using: &generator) }
            for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
            let image = try FloatImage(width: w, height: h, rgba: rgba)
            var p = Parameters(); p.horizontalRadius = 9; p.verticalRadius = 5
            let a = try gpu.process(image, parameters: p), b = try CPUProcessor.process(image, parameters: p)
            let maxError = zip(a.rgba, b.rgba).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(maxError, 2 / 255, "\(w)x\(h)")
        }
    }
    func testInvalidParametersAreRejected() {
        var p = Parameters(); p.horizontalRadius = 0
        XCTAssertThrowsError(try p.validate())
        p = Parameters(); p.amount = 1.5
        XCTAssertThrowsError(try p.validate())
        p = Parameters(); p.gamma2 = 0.9
        XCTAssertThrowsError(try p.validate())
        XCTAssertThrowsError(try FloatImage(width: 2, height: 2, rgba: [0, 0, 0]))
    }
}
