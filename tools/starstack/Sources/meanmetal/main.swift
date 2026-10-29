import Foundation
import Metal
import StarStackCore
struct Source:Decodable {let source:String,map:String,groundShift:[Float],reference:Bool}
struct Recipe:Decodable {let width:Int,height:Int,frames:[Source],mask:String,table:String,reference:String}
struct Params {var w:UInt32,h:UInt32,dx:Float,dy:Float,reference:UInt32}
func run()throws {
    let args=Array(CommandLine.arguments.dropFirst());guard args.count==2 else{throw StackError("Usage: meanmetal render.json output.rgba")}
    let r=try JSONDecoder().decode(Recipe.self,from:Data(contentsOf:URL(fileURLWithPath:args[0])))
    guard let d=MTLCreateSystemDefaultDevice(),let queue=d.makeCommandQueue() else{throw StackError("Metal unavailable; no silent CPU fallback")}
    let options=MTLCompileOptions();options.mathMode = .safe
    let start=Date();let library=try d.makeLibrary(source:String(contentsOf:Bundle.module.url(forResource:"Mean",withExtension:"metal")!,encoding:.utf8),options:options)
    let accumulate=try d.makeComputePipelineState(function:library.makeFunction(name:"accumulate")!),finish=try d.makeComputePipelineState(function:library.makeFunction(name:"finish")!)
    let n=r.width*r.height,size=n*16
    func buffer(_ bytes:Int)throws->MTLBuffer {guard bytes<=d.maxBufferLength,let b=d.makeBuffer(length:bytes,options:.storageModeShared) else{throw StackError("Metal allocation failed")};return b}
    func read(_ path:String,_ expected:Int)throws->MTLBuffer {
        let data=try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
        guard data.count==expected else{throw StackError("Incorrect buffer size: \(path)")}
        let b=try buffer(expected);data.withUnsafeBytes{b.contents().copyMemory(from:$0.baseAddress!,byteCount:expected)};return b
    }
    let sky=try buffer(size),ground=try buffer(size),weights=try read(r.table,32*8*4)
    memset(sky.contents(),0,size);memset(ground.contents(),0,size)
    var gpuSeconds=0.0
    func dispatch(_ state:MTLComputePipelineState,_ buffers:[MTLBuffer],_ p:Params)throws {
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else{throw StackError("Metal command failed")}
        encoder.setComputePipelineState(state)
        for (i,b) in buffers.enumerated(){encoder.setBuffer(b,offset:0,index:i)}
        var p=p;encoder.setBytes(&p,length:MemoryLayout<Params>.stride,index:5)
        encoder.dispatchThreads(MTLSize(width:n,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(256,state.maxTotalThreadsPerThreadgroup),height:1,depth:1))
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else{throw StackError("Metal dispatch failed: \(String(describing:command.error))")}
        gpuSeconds+=command.gpuEndTime-command.gpuStartTime
    }
    for (index,f) in r.frames.enumerated() {
        try autoreleasepool {
            let source=try read(f.source,size),map=try read(f.map,size)
            try dispatch(accumulate,[source,map,sky,ground,weights],Params(w:UInt32(r.width),h:UInt32(r.height),dx:f.groundShift[0],dy:f.groundShift[1],reference:f.reference ? 1:0))
            log("Metal warp/mean \(index+1)/\(r.frames.count)")
        }
    }
    let reference=try read(r.reference,size),mask=try read(r.mask,n*4),out=try buffer(size)
    try dispatch(finish,[sky,ground,reference,mask,out],Params(w:UInt32(r.width),h:UInt32(r.height),dx:0,dy:0,reference:0))
    try Data(bytesNoCopy:out.contents(),count:size,deallocator:.none).write(to:URL(fileURLWithPath:args[1]))
    let report:[String:Any]=["device":d.name,"gpu_kernel_seconds":gpuSeconds,"elapsed_seconds":Date().timeIntervalSince(start),"width":r.width,"height":r.height,"frames":r.frames.count,"backend":"Metal Float32 Lanczos4 warp and arithmetic mean; shared host geometry/validity maps"]
    try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:URL(fileURLWithPath:args[1]+".json"))
    log("Metal complete: \(report)")
}
do {try run()} catch {fputs("error: \(error)\n",stderr);exit(1)}
