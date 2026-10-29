import Foundation
import Metal

public final class MetalProcessor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let maskPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let correctionPipeline: MTLComputePipelineState
    public var deviceName: String { device.name }
    public private(set) var lastGPUSeconds: Double = 0

    // Matches Parameters in Unpurple.metal: 8 scalar fields, 32 bytes.
    private struct GPUParameters {
        var width, height, radius, mode: UInt32
        var intensity, minBrightness, minRed, maxRed: Float
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw UnpurpleError("Metal device unavailable; use --backend cpu explicitly to run the reference")
        }
        self.device = device
        self.queue = queue
        guard let url = Bundle.module.url(forResource: "Unpurple", withExtension: "metal") else {
            throw UnpurpleError("missing shader resource; keep the SwiftPM resource bundle beside the executable")
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: String(contentsOf: url), options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw UnpurpleError("missing Metal function \(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        maskPipeline = try pipeline("make_mask")
        blurPipeline = try pipeline("box_blur")
        correctionPipeline = try pipeline("correct")
    }

    public func process(_ image: PixelImage, parameters p: Parameters) throws -> PixelImage {
        try p.validate()
        let count = image.width * image.height
        let bytes = count * 4
        guard bytes <= device.maxBufferLength else { throw UnpurpleError("image exceeds Metal buffer limit") }
        guard let input = image.rgba.withUnsafeBytes({ raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: bytes, options: .storageModeShared)
        }),
              let maskA = device.makeBuffer(length: bytes, options: .storageModePrivate),
              let maskB = device.makeBuffer(length: bytes, options: .storageModePrivate),
              let output = device.makeBuffer(length: bytes, options: .storageModeShared),
              let command = queue.makeCommandBuffer() else {
            throw UnpurpleError("could not allocate Metal buffers or command buffer")
        }
        var params = GPUParameters(width: UInt32(image.width), height: UInt32(image.height),
                                   radius: UInt32(p.boxRadius), mode: p.mode.rawValue,
                                   intensity: Float(p.intensity), minBrightness: Float(p.minBrightness),
                                   minRed: Float(p.minRed), maxRed: Float(p.maxRed))
        func encode(_ pipeline: MTLComputePipelineState, buffers: [MTLBuffer],
                    axis: UInt32? = nil) throws {
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw UnpurpleError("could not create Metal compute encoder")
            }
            encoder.setComputePipelineState(pipeline)
            for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
            encoder.setBytes(&params, length: MemoryLayout<GPUParameters>.stride, index: buffers.count)
            if var axis {
                encoder.setBytes(&axis, length: MemoryLayout<UInt32>.size, index: buffers.count + 1)
            }
            let group = min(256, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1))
            encoder.endEncoding()
        }
        try encode(maskPipeline, buffers: [input, maskA])
        for _ in 0..<2 {
            try encode(blurPipeline, buffers: [maskA, maskB], axis: 1)
            try encode(blurPipeline, buffers: [maskB, maskA], axis: 0)
        }
        try encode(correctionPipeline, buffers: [input, maskA, output])
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw UnpurpleError("Metal processing failed: \(command.error?.localizedDescription ?? "unknown error")")
        }
        lastGPUSeconds = max(0, command.gpuEndTime - command.gpuStartTime)
        let rgba = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self), count: bytes))
        return try PixelImage(width: image.width, height: image.height, rgba: rgba)
    }
}
