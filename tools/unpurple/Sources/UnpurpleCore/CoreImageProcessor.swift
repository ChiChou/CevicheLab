// Floating-point adaptation of Martin Jambon's Unpurple (Copyright (c) 2012).
// See LICENSE.upstream. New Ceviche integration follows the repository license.
import CoreImage
import Metal

/// Lazy GPU processing of premultiplied, extended-linear-sRGB pixels.
/// Use a Metal-backed CIContext; input/output and mask intermediates are 32-bit float.
public enum CoreImageProcessor {
    public static func apply(_ image: CIImage, parameters p: Parameters, scale: Double = 1) throws -> CIImage {
        try p.validate()
        guard scale.isFinite, scale > 0, scale <= 1 else { throw UnpurpleError("image scale must be in (0, 1]") }
        guard p.mode == .normal else { throw UnpurpleError("Core Image processing supports normal correction only") }
        guard p.intensity > 0 else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull else { throw UnpurpleError("Unpurple needs a finite image extent") }
        return try UnpurpleImageProcessor.apply(withExtent: extent, inputs: [image], arguments: [
            "extent": CIVector(cgRect: extent), "radius": p.boxRadius, "scale": scale,
            "controls": CIVector(x: p.intensity, y: p.minBrightness, z: p.minRed, w: p.maxRed)
        ])
    }
}

/// An opaque processor boundary avoids Core Image's constant-image specialization
/// of stitchable spatial kernels. All six passes stay on its supplied command buffer.
private final class UnpurpleImageProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let extent = arguments?["extent"] as? CIVector,
              let radius = arguments?["radius"] as? Int,
              let scale = arguments?["scale"] as? Double else { return outputRect }
        // Two box convolutions in each direction, including fractional-tap interpolation.
        let support = 2 * ceil(Double(radius) * scale) + 2
        return outputRect.insetBy(dx: -support, dy: -support).intersection(extent.cgRectValue).integral
    }

    private struct Pipelines {
        let mask: MTLComputePipelineState
        let blur: MTLComputePipelineState
        let correct: MTLComputePipelineState
    }
    private static let lock = NSLock()
    private static var pipelines: [UInt64: Pipelines] = [:]
    private static func shaders(for device: MTLDevice) throws -> Pipelines {
        lock.lock(); defer { lock.unlock() }
        if let cached = pipelines[device.registryID] { return cached }
        guard let url = Bundle.module.url(forResource: "UnpurpleFloat", withExtension: "metal") else {
            throw UnpurpleError("missing floating-point Metal shader resource")
        }
        let options = MTLCompileOptions()
        if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw UnpurpleError("missing shader: \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        let result = try Pipelines(mask: pipeline("floatMask"), blur: pipeline("floatBox"), correct: pipeline("floatCorrect"))
        pipelines[device.registryID] = result
        return result
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture, let destination = output.metalTexture,
              let command = output.metalCommandBuffer,
              let radius = arguments?["radius"] as? Int, let scale = arguments?["scale"] as? Double,
              let controls = arguments?["controls"] as? CIVector else {
            throw UnpurpleError("Unpurple requires a Metal-backed Core Image context")
        }
        let states = try shaders(for: command.device)
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: source.width, height: source.height, mipmapped: false)
        description.usage = [.shaderRead, .shaderWrite]; description.storageMode = .private
        guard let first = command.device.makeTexture(descriptor: description), let second = command.device.makeTexture(descriptor: description) else {
            throw UnpurpleError("could not allocate Unpurple mask textures")
        }
        func encode(_ state: MTLComputePipelineState, textures: [MTLTexture], values: SIMD4<Float>, width: Int, height: Int) throws {
            guard let encoder = command.makeComputeCommandEncoder() else { throw UnpurpleError("could not create Unpurple encoder") }
            encoder.setComputePipelineState(state)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            var values = values
            encoder.setBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            let w = state.threadExecutionWidth, h = min(8, state.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()
        }
        try encode(states.mask, textures: [source, first], values: SIMD4(Float(controls.x), Float(controls.y), 0, 0), width: source.width, height: source.height)
        var current = first, next = second
        for horizontal in [true, false, true, false] {
            try encode(states.blur, textures: [current, next], values: SIMD4(Float(radius), horizontal ? 1 : 0, horizontal ? 0 : 1, Float(scale)), width: source.width, height: source.height)
            swap(&current, &next)
        }
        // Metal texture rows run from top to bottom; Core Image regions use bottom-left coordinates.
        let dx = output.region.minX - input.region.minX, dy = input.region.maxY - output.region.maxY
        try encode(states.correct, textures: [source, current, destination], values: SIMD4(Float(controls.z), Float(controls.w), Float(dx), Float(dy)), width: destination.width, height: destination.height)
    }
}
