import Foundation
import ChromaticCore

let help = """
Usage: chromatic [options] INPUT OUTPUT
Correct lateral and axial chromatic aberration (Chang et al. 2013, IPOL 2023/443) on Metal.

  --backend metal|cpu     Default: metal; cpu is the Double-precision reference
  -x, --horizontal N      Horizontal filter radius in pixels, 1...64 (default: 7)
  -y, --vertical N        Vertical filter radius in pixels, 1...64 (default: 4)
  -a, --amount N          Blend from the input (0) to the full correction (1, default)
  --tau N                 False-color achromatic threshold (default: 15/256)
  --crop X,Y,W,H          Process only this rectangle (top-left origin)
  --repeat N              Run the correction N times and report the fastest and median
  --verify                Compare Metal against the CPU reference before writing
  --force                 Replace an existing output
  -h, --help              Show this help
  --license               Print the upstream license

Output: 16-bit PNG or TIFF, or JPEG. Keep Chromatic_ChromaticCore.bundle beside the executable.
"""

func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    var p = Parameters()
    var backend = "metal", verify = false, overwrite = false, runs = 1
    var crop: (Int, Int, Int, Int)?
    var paths: [String] = []
    var index = 0
    func next(_ option: String) throws -> String {
        index += 1
        guard index < args.count else { throw ChromaticError("missing value for \(option)") }
        return args[index]
    }
    func number(_ option: String) throws -> Double {
        let value = try next(option)
        guard let result = Double(value), result.isFinite else { throw ChromaticError("invalid number for \(option): \(value)") }
        return result
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help": print(help); return
        case "--license": print(try UpstreamLicense.text()); return
        case "--backend": backend = try next(arg)
        case "-x", "--horizontal": p.horizontalRadius = Int(try number(arg))
        case "-y", "--vertical": p.verticalRadius = Int(try number(arg))
        case "-a", "--amount": p.amount = try number(arg)
        case "--tau": p.tau = try number(arg)
        case "--repeat": runs = max(1, Int(try number(arg)))
        case "--crop":
            let parts = try next(arg).split(separator: ",").map { Int($0) }
            guard parts.count == 4, !parts.contains(nil) else { throw ChromaticError("--crop takes X,Y,W,H") }
            crop = (parts[0]!, parts[1]!, parts[2]!, parts[3]!)
        case "--verify": verify = true
        case "--force": overwrite = true
        default:
            guard !arg.hasPrefix("-") else { throw ChromaticError("unknown option: \(arg)") }
            paths.append(arg)
        }
        index += 1
    }
    guard paths.count == 2 else { throw ChromaticError("expected INPUT and OUTPUT; run chromatic --help") }
    try p.validate()
    guard ["metal", "cpu"].contains(backend) else { throw ChromaticError("backend must be metal or cpu") }
    let input = URL(fileURLWithPath: paths[0]), output = URL(fileURLWithPath: paths[1])
    guard input.standardizedFileURL != output.standardizedFileURL else { throw ChromaticError("input and output must differ") }
    var image = try ImageFile(url: input).pixels
    if let (x, y, w, h) = crop {
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= image.width, y + h <= image.height else { throw ChromaticError("crop lies outside the image") }
        var rgba = [Float](); rgba.reserveCapacity(w * h * 4)
        for row in y..<(y + h) { rgba.append(contentsOf: image.rgba[((row * image.width + x) * 4)..<((row * image.width + x + w) * 4)]) }
        image = try FloatImage(width: w, height: h, rgba: rgba)
    }
    stderr("\(image.width)x\(image.height); radii \(p.horizontalRadius)x\(p.verticalRadius); amount \(p.amount)")
    let result: FloatImage
    var wall: [Double] = [], gpu: [Double] = []
    if backend == "metal" {
        let processor = try MetalProcessor()
        var last: FloatImage?
        for _ in 0..<runs {
            let start = Date()
            last = try processor.process(image, parameters: p)
            wall.append(Date().timeIntervalSince(start)); gpu.append(processor.lastGPUSeconds)
        }
        result = last!
        stderr(String(format: "%@: GPU %.1f ms fastest, %.1f ms median; processing %.1f ms fastest (%d runs)", processor.deviceName,
                      gpu.min()! * 1000, gpu.sorted()[gpu.count / 2] * 1000, wall.min()! * 1000, runs))
        if verify {
            let start = Date()
            let reference = try CPUProcessor.process(image, parameters: p)
            var maxError: Float = 0, over = 0
            for (a, b) in zip(result.rgba, reference.rgba) { let d = abs(a - b); maxError = max(maxError, d); if d > 1 / 255 { over += 1 } }
            stderr(String(format: "CPU reference %.1f ms; max difference %.5f (%.2f/255); %d values differ by more than 1/255", Date().timeIntervalSince(start) * 1000, maxError, maxError * 255, over))
            // Float and Double take different branches at the method's sign and threshold tests for a few pixels.
            guard over <= max(16, result.rgba.count / 10_000) else { throw ChromaticError("Metal and CPU disagree at too many values") }
        }
    } else {
        var last: FloatImage?
        for _ in 0..<runs {
            let start = Date()
            last = try CPUProcessor.process(image, parameters: p)
            wall.append(Date().timeIntervalSince(start))
        }
        result = last!
        stderr(String(format: "CPU: processing %.1f ms fastest (%d runs)", wall.min()! * 1000, runs))
    }
    try ImageFile.write(result, to: output, overwrite: overwrite)
    stderr("Wrote \(output.path)")
}

do { try run() } catch { stderr("chromatic: \(error)"); exit(1) }
