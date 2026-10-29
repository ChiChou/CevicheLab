// Double-precision port of the paper's method, structured as the Metal kernels are: one directional pass that
// yields the transient-improvement and false-color chroma of each pixel, then a merge and arbitration.
// See LICENSE.upstream.
import Foundation

public enum CPUProcessor {
    /// Per pixel and direction: the TI chroma at the pixel, the FC-filtered chroma, and the local extrema the
    /// arbitration scales by (the paper's Equations 5, 7 and 2e).
    struct Directional { var kTI = 0.0, kFC = 0.0, xMax = 0.0, xMin = 0.0 }

    /// One channel's 1D pass along `step` from `at`. `x`, `g` and `y` are the channel, the green guide and the luma.
    static func directional(x: (Int) -> Double, g: (Int) -> Double, y: (Int) -> Double, radius L: Int,
                            rho: (Double, Double, Double), alpha: Double, tau: Double) -> Directional {
        // Half-window extrema either side of the pixel, keeping the pair with the larger contrast (Equation 2).
        let center = x(0)
        var eMax = center, eMin = center, wMax = center, wMin = center
        for l in 1...L {
            let e = x(l), w = x(-l)
            eMax = max(eMax, e); eMin = min(eMin, e); wMax = max(wMax, w); wMin = min(wMin, w)
        }
        let xMax: Double, xMin: Double
        if eMax - wMin >= wMax - eMin { xMax = eMax; xMin = wMin } else { xMax = wMax; xMin = eMin }
        let above = center > g(0)
        // The TI chroma at the pixel itself is the centre of the slice (Equation 5).
        func ti(_ l: Int) -> Double {
            let xl = x(l), gl = g(l)
            let pf = above ? rho.0 * xMax + rho.1 * xl + rho.2 * xMin : rho.0 * xMin + rho.1 * xl + rho.2 * xMax
            let hi = above ? xl : min(xMax, gl), lo = above ? max(xMin, gl) : xl
            // Ceiling before floor, as the reference does; a plain clamp differs where the floor lies above the ceiling.
            return (pf > hi ? hi : pf < lo ? lo : pf) - gl
        }
        let k0 = ti(0)
        let y0 = y(0)
        var numerator = 0.0, denominator = 0.0
        var previousX = x(-L - 1), previousG = g(-L - 1)
        for l in -L...L {
            let xl = x(l), gl = g(l), kl = ti(l)
            let gradX = xl - previousX, gradG = gl - previousG
            previousX = xl; previousG = gl
            // Neighbours of the other chroma sign are left out unless nearly achromatic (Equation 10).
            let accepted = sign(kl) == sign(k0) || abs(kl) < tau
            guard accepted else { continue }
            let weight = 1 / (abs(gradG) + max(abs(gradX), alpha * abs(kl)) + abs(y0 - y(l)) + 1e-8)
            let clipped = k0 > 0 ? min(kl, k0) : k0 < 0 ? max(kl, k0) : k0
            numerator += weight * clipped; denominator += weight
        }
        return Directional(kTI: k0, kFC: numerator / (denominator + 1e-8), xMax: xMax, xMin: xMin)
    }
    private static func sign(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }

    /// The arbitration's directional contrast, with the chroma penalty (Equation 17).
    static func contrast(x: (Int) -> Double, g: (Int) -> Double, radius L: Int, beta: Double) -> Double {
        let center = x(0)
        var eMax = center, eMin = center, wMax = center, wMin = center
        for l in 0..<L {
            let e = x(l), ge = g(l), w = x(l - L + 1), gw = g(l - L + 1)
            eMax = max(eMax, e - beta * abs(e - ge)); eMin = min(eMin, e + beta * abs(e - ge))
            wMax = max(wMax, w - beta * abs(w - gw)); wMin = min(wMin, w + beta * abs(w - gw))
        }
        return eMax - wMin >= wMax - eMin ? eMax - wMin : wMax - eMin
    }

    /// Merges the two directions (the more achromatic estimate wins) and blends TI and FC by the local contrast.
    static func arbitrate(h: Directional, v: Directional, contrastH: Double, contrastV: Double, gamma1: Double, gamma2: Double) -> Double {
        let kFC = abs(h.kFC) < abs(v.kFC) ? h.kFC : v.kFC
        let ti = abs(h.kTI) < abs(v.kTI) ? h : v
        let contrast = max(contrastH, contrastV)
        let alpha = min(max(contrast, 0) / min(max(ti.xMax - ti.xMin, gamma2), gamma1), 1)
        return (1 - alpha) * ti.kTI + alpha * kFC
    }

    public static func process(_ image: FloatImage, parameters p: Parameters) throws -> FloatImage {
        try p.validate()
        let w = image.width, h = image.height
        let source = image.rgba.map(Double.init)
        func sample(_ x: Int, _ y: Int, _ c: Int) -> Double { source[(min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))) * 4 + c] }
        func luma(_ x: Int, _ y: Int) -> Double { 0.299 * sample(x, y, 0) + 0.587 * sample(x, y, 1) + 0.114 * sample(x, y, 2) }
        var result = image.rgba
        for y in 0..<h {
            for x in 0..<w {
                let green = sample(x, y, 1)
                for (channel, alpha, beta) in [(0, p.alphaRed, p.betaRed), (2, p.alphaBlue, p.betaBlue)] {
                    let hPass = directional(x: { sample(x + $0, y, channel) }, g: { sample(x + $0, y, 1) }, y: { luma(x + $0, y) },
                                            radius: p.horizontalRadius, rho: p.rho, alpha: alpha, tau: p.tau)
                    let vPass = directional(x: { sample(x, y + $0, channel) }, g: { sample(x, y + $0, 1) }, y: { luma(x, y + $0) },
                                            radius: p.verticalRadius, rho: p.rho, alpha: alpha, tau: p.tau)
                    let cH = contrast(x: { sample(x + $0, y, channel) }, g: { sample(x + $0, y, 1) }, radius: p.horizontalRadius, beta: beta)
                    let cV = contrast(x: { sample(x, y + $0, channel) }, g: { sample(x, y + $0, 1) }, radius: p.verticalRadius, beta: beta)
                    let corrected = arbitrate(h: hPass, v: vPass, contrastH: cH, contrastV: cV, gamma1: p.gamma1, gamma2: p.gamma2) + green
                    let original = sample(x, y, channel)
                    result[(y * w + x) * 4 + channel] = Float(original + p.amount * (corrected - original))
                }
            }
        }
        return try FloatImage(width: w, height: h, rgba: result)
    }
}
