import Foundation
import Metal

public final class MetalProcessor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let horizontalPipeline: MTLComputePipelineState
    private let mergePipeline: MTLComputePipelineState
    public var deviceName: String { device.name }
    /// GPU execution time of the last `process`, from the command buffer's own timestamps.
    public private(set) var lastGPUSeconds: Double = 0

    // Matches Parameters in Chromatic.metal: 2 + 2 32-bit integers and 11 floats, 60 bytes.
    private struct GPUParameters {
        var width, height: UInt32
        var horizontalRadius, verticalRadius: Int32
        var rho0, rho1, rho2, tau: Float
        var alphaRed, alphaBlue, betaRed, betaBlue: Float
        var gamma1, gamma2, amount: Float
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ChromaticError("Metal device unavailable; use --backend cpu explicitly to run the reference")
        }
        self.device = device; self.queue = queue
        guard let url = Bundle.module.url(forResource: "Chromatic", withExtension: "metal") else {
            throw ChromaticError("missing shader resource; keep the SwiftPM resource bundle beside the executable")
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: String(contentsOf: url), options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw ChromaticError("missing Metal function \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        horizontalPipeline = try pipeline("horizontal")
        mergePipeline = try pipeline("vertical_and_merge")
    }

    public func process(_ image: FloatImage, parameters p: Parameters) throws -> FloatImage {
        try p.validate()
        let count = image.width * image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor) else { throw ChromaticError("could not allocate the source texture") }
        image.rgba.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: image.width * 16) }
        descriptor.usage = .shaderWrite
        guard let destination = device.makeTexture(descriptor: descriptor),
              let chroma = device.makeBuffer(length: count * 16, options: .storageModePrivate),
              let extrema = device.makeBuffer(length: count * 16, options: .storageModePrivate),
              let command = queue.makeCommandBuffer() else {
            throw ChromaticError("could not allocate Metal resources")
        }
        var params = GPUParameters(width: UInt32(image.width), height: UInt32(image.height),
                                   horizontalRadius: Int32(p.horizontalRadius), verticalRadius: Int32(p.verticalRadius),
                                   rho0: Float(p.rho.0), rho1: Float(p.rho.1), rho2: Float(p.rho.2), tau: Float(p.tau),
                                   alphaRed: Float(p.alphaRed), alphaBlue: Float(p.alphaBlue), betaRed: Float(p.betaRed), betaBlue: Float(p.betaBlue),
                                   gamma1: Float(p.gamma1), gamma2: Float(p.gamma2), amount: Float(p.amount))
        func encode(_ pipeline: MTLComputePipelineState, textures: [MTLTexture]) throws {
            guard let encoder = command.makeComputeCommandEncoder() else { throw ChromaticError("could not create a compute encoder") }
            encoder.setComputePipelineState(pipeline)
            for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
            encoder.setBuffer(chroma, offset: 0, index: 0); encoder.setBuffer(extrema, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<GPUParameters>.stride, index: 2)
            let width = pipeline.threadExecutionWidth, height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            encoder.dispatchThreads(MTLSize(width: image.width, height: image.height, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
            encoder.endEncoding()
        }
        try encode(horizontalPipeline, textures: [source])
        try encode(mergePipeline, textures: [source, destination])
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw ChromaticError("Metal processing failed: \(command.error?.localizedDescription ?? "unknown error")")
        }
        lastGPUSeconds = max(0, command.gpuEndTime - command.gpuStartTime)
        var rgba = [Float](repeating: 0, count: count * 4)
        rgba.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: image.width * 16, from: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0) }
        return try FloatImage(width: image.width, height: image.height, rgba: rgba)
    }
}
