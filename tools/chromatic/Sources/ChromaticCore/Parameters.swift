// Port of the chromatic aberration correction of Chang, Kang and Kang (IEEE TIP 2013), after Thomas Eboli's
// reference implementation (IPOL 2023/443). See LICENSE.upstream.
import Foundation

public struct ChromaticError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// The paper's parameters with its defaults. Radii are in pixels of the processed image; the thresholds `tau`,
/// `gamma1` and `gamma2` are fractions of the signal range, which the paper sets for 8-bit display-referred values.
public struct Parameters: Equatable {
    public var horizontalRadius = 7
    public var verticalRadius = 4
    /// Transient-improvement prefilter weights, summing to 1.
    public var rho: (Double, Double, Double) = (-0.25, 1.375, -0.125)
    /// Chroma magnitude under which a differently signed neighbour still counts in the false-color average.
    public var tau = 15.0 / 256
    /// Chroma weights of the false-color stage, red and blue.
    public var alphaRed = 0.5, alphaBlue = 1.0
    /// Chroma penalties of the arbitration contrast, red and blue.
    public var betaRed = 1.0, betaBlue = 0.25
    /// Arbitration contrast clipping.
    public var gamma1 = 128.0 / 256, gamma2 = 64.0 / 256
    /// Blend between the input (0) and the full correction (1).
    public var amount = 1.0

    public init() {}

    public func validate() throws {
        guard (1...64).contains(horizontalRadius), (1...64).contains(verticalRadius) else {
            throw ChromaticError("radii must be between 1 and 64 pixels")
        }
        for value in [rho.0, rho.1, rho.2, tau, alphaRed, alphaBlue, betaRed, betaBlue, gamma1, gamma2, amount] where !value.isFinite {
            throw ChromaticError("parameters must be finite")
        }
        guard tau >= 0, alphaRed >= 0, alphaBlue >= 0, betaRed >= 0, betaBlue >= 0 else {
            throw ChromaticError("tau, alpha and beta must not be negative")
        }
        guard gamma2 > 0, gamma1 >= gamma2 else { throw ChromaticError("gamma1 >= gamma2 > 0 is required") }
        guard (0...1).contains(amount) else { throw ChromaticError("amount must be between 0 and 1") }
    }
    public static func == (a: Parameters, b: Parameters) -> Bool {
        a.horizontalRadius == b.horizontalRadius && a.verticalRadius == b.verticalRadius && a.rho == b.rho && a.tau == b.tau
            && a.alphaRed == b.alphaRed && a.alphaBlue == b.alphaBlue && a.betaRed == b.betaRed && a.betaBlue == b.betaBlue
            && a.gamma1 == b.gamma1 && a.gamma2 == b.gamma2 && a.amount == b.amount
    }
}

/// Straight-alpha RGBA floating-point pixels, row-major. Values are display-referred in the paper's setting; the
/// algorithm itself only assumes the three channels share a range.
public struct FloatImage: Equatable {
    public let width: Int
    public let height: Int
    public var rgba: [Float]
    public init(width: Int, height: Int, rgba: [Float]) throws {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { throw ChromaticError("pixel buffer does not match image size") }
        self.width = width; self.height = height; self.rgba = rgba
    }
}

public enum UpstreamLicense {
    public static func text() throws -> String {
        guard let url = Bundle.module.url(forResource: "LICENSE", withExtension: "upstream") else { throw ChromaticError("missing LICENSE.upstream resource") }
        return try String(contentsOf: url)
    }
}
