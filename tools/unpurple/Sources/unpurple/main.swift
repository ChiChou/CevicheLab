import Foundation
import UnpurpleCore

let help = """
Usage: unpurple [options] INPUT OUTPUT
Remove purple fringes using Martin Jambon's Unpurple algorithm on Metal.

  --backend metal|cpu    Default: metal; cpu is the reference implementation
  -r, --radius N         Blur radius in pixels, 0 < N <= 256 (default: 5)
  -i, --intensity N      Correction strength, 0...100 (default: 1)
  -m, --min-brightness N Blue brightness threshold, 0 <= N < 1 (default: 0)
  -minred N             Minimum removed red:blue ratio (default: 0)
  -maxred N             Maximum removed red:blue ratio (default: 0.33)
  -gentle, --gentle     Set -m 0.8 -minred 0.15
  -diff, --diff         Output removed color, instead of corrected image
  -blur, --blur         Output the blurred mask
  --quality N           JPEG quality, 0...1 (default: 0.95)
  --verify              Compare Metal against CPU before writing (max error: 1/255)
  --force               Replace an existing output; never replace the input
  --strip-metadata      Omit copied EXIF/GPS/IPTC/TIFF metadata
  --                    End options (for filenames beginning with '-')
  -h, --help            Show this help
  --license             Print upstream copyright, license, and image credits

Output: PNG, JPEG, or TIFF; processing is 8-bit sRGB. PNG/TIFF preserve alpha.
EXIF orientation is applied. Supported metadata is copied unless stripped.
Keep the generated Unpurple_UnpurpleCore.bundle beside the executable.
"""

func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    var p = Parameters()
    var backend = "metal", quality = 0.95
    var verify = false, overwrite = false, stripMetadata = false, positional = false
    var paths: [String] = []
    var index = 0
    func next(_ option: String) throws -> String {
        index += 1
        guard index < args.count else { throw UnpurpleError("missing value for \(option)") }
        return args[index]
    }
    func number(_ option: String) throws -> Double {
        let value = try next(option)
        guard let result = Double(value), result.isFinite else { throw UnpurpleError("invalid number for \(option): \(value)") }
        return result
    }
    while index < args.count {
        let arg = args[index]
        if positional { paths.append(arg); index += 1; continue }
        switch arg {
        case "-h", "--help": print(help); return
        case "--license": print(try UpstreamLicense.text()); return
        case "--": positional = true
        case "--backend": backend = try next(arg)
        case "-r", "--radius": p.radius = try number(arg)
        case "-i", "--intensity": p.intensity = try number(arg)
        case "-m", "--min-brightness": p.minBrightness = try number(arg)
        case "-minred", "--min-red": p.minRed = try number(arg)
        case "-maxred", "--max-red": p.maxRed = try number(arg)
        case "-gentle", "--gentle": p.minBrightness = 0.8; p.minRed = 0.15
        case "-diff", "--diff": p.mode = .diff
        case "-blur", "--blur": p.mode = .blur
        case "--quality": quality = try number(arg)
        case "--verify": verify = true
        case "--force": overwrite = true
        case "--strip-metadata": stripMetadata = true
        default:
            guard !arg.hasPrefix("-") else { throw UnpurpleError("unknown option: \(arg)") }
            paths.append(arg)
        }
        index += 1
    }
    guard paths.count == 2 else { throw UnpurpleError("expected INPUT and OUTPUT; run unpurple --help") }
    try p.validate()
    guard ["metal", "cpu"].contains(backend) else { throw UnpurpleError("backend must be metal or cpu") }
    guard !verify || backend == "metal" else { throw UnpurpleError("--verify requires --backend metal") }
    guard (0...1).contains(quality) else { throw UnpurpleError("quality must be in [0, 1]") }
    let input = URL(fileURLWithPath: paths[0]).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: paths[1]).standardizedFileURL.resolvingSymlinksInPath()
    guard input != output else { throw UnpurpleError("input and output must be different files") }
    guard ["png", "jpg", "jpeg", "tif", "tiff"].contains(output.pathExtension.lowercased()) else {
        throw UnpurpleError("output extension must be PNG, JPEG, or TIFF")
    }
    if !overwrite, FileManager.default.fileExists(atPath: output.path) {
        throw UnpurpleError("output already exists; use --force to replace it")
    }
    let start = Date()
    let file = try ImageFile(url: input)
    let result: PixelImage
    if backend == "metal" {
        let gpu = try MetalProcessor()
        let processingStart = Date()
        result = try gpu.process(file.pixels, parameters: p)
        stderr(String(format: "%@; %dx%d; GPU %.2f ms; processing %.2f ms",
                      gpu.deviceName, result.width, result.height, gpu.lastGPUSeconds * 1000,
                      Date().timeIntervalSince(processingStart) * 1000))
        if verify {
            let reference = try CPUProcessor.process(file.pixels, parameters: p)
            var maxError = 0, different = 0
            for (a, b) in zip(result.rgba, reference.rgba) {
                let delta = abs(Int(a) - Int(b))
                maxError = max(maxError, delta)
                if delta > 0 { different += 1 }
            }
            guard maxError <= 1 else { throw UnpurpleError("CPU verification failed: maximum channel error \(maxError)/255") }
            stderr("CPU verification passed: max channel error \(maxError)/255; \(different) differing bytes")
        }
    } else {
        let processingStart = Date()
        result = try CPUProcessor.process(file.pixels, parameters: p)
        stderr(String(format: "CPU; %dx%d; processing %.2f ms", result.width, result.height,
                      Date().timeIntervalSince(processingStart) * 1000))
    }
    try ImageFile.write(result, to: output, metadata: stripMetadata ? [:] : file.metadata,
                        quality: quality, overwrite: overwrite)
    stderr(String(format: "Wrote %@; total %.2f ms", output.path, Date().timeIntervalSince(start) * 1000))
}

do { try run() }
catch { stderr("unpurple: \(error)"); exit(1) }
