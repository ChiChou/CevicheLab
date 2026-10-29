import Foundation
import Metal
import StarStackCore

struct InputRecord: Decodable {let source:String;let base:String;let width:Int;let height:Int;let reference:Bool}
func readFloats(_ url:URL,_ count:Int) throws -> [Float] {
    let d=try Data(contentsOf:url);guard d.count==count*4 else{throw StackError("Wrong size: \(url.path)")}
    return d.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
}
func writeFloats(_ a:[Float],_ url:URL)throws {try a.withUnsafeBytes{try Data($0).write(to:url)}}
func seconds()->Double {ProcessInfo.processInfo.systemUptime}

final class MetalBench {
    let device:MTLDevice,queue:MTLCommandQueue,library:MTLLibrary
    var states=[String:MTLComputePipelineState]()
    init()throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else{throw StackError("Metal unavailable")}
        device=d;queue=q
        let options=MTLCompileOptions();options.mathMode = .safe
        library=try d.makeLibrary(source:String(contentsOf:Bundle.module.url(forResource:"Kernels",withExtension:"metal")!,encoding:.utf8),options:options)
        for name in ["warp","fuse","difference","morphology","catalog_project"] {
            guard let f=library.makeFunction(name:name) else{throw StackError("Missing Metal kernel")}
            states[name]=try d.makeComputePipelineState(function:f)
        }
    }
    func buffer(_ bytes:Int)throws->MTLBuffer {
        guard bytes>0,bytes<=device.maxBufferLength,let b=device.makeBuffer(length:bytes,options:.storageModeShared) else{throw StackError("Metal buffer allocation failed: \(bytes)")};return b
    }
    func buffer(_ a:[Float])throws->MTLBuffer {let b=try buffer(a.count*4);a.withUnsafeBytes{b.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count)};return b}
    @discardableResult func dispatch(_ name:String,_ buffers:[MTLBuffer],_ params:[UInt8],_ count:Int,_ offset:Int=0)throws->Double {
        let start=seconds()
        guard let c=queue.makeCommandBuffer(),let e=c.makeComputeCommandEncoder(),let state=states[name] else{throw StackError("Metal command allocation failed")}
        e.setComputePipelineState(state)
        for (i,b) in buffers.enumerated(){e.setBuffer(b,offset:i==1 ? offset : 0,index:i)}
        params.withUnsafeBytes{e.setBytes($0.baseAddress!,length:$0.count,index:buffers.count)}
        e.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(256,state.maxTotalThreadsPerThreadgroup),height:1,depth:1))
        e.endEncoding();c.commit();c.waitUntilCompleted()
        guard c.status == .completed else{throw StackError("Metal failed: \(String(describing:c.error))")};return seconds()-start
    }
}
func bytes<T>(_ a:[T])->[UInt8] {a.withUnsafeBytes{Array($0)}}
func floats(_ b:MTLBuffer,_ count:Int)->[Float] {Array(UnsafeBufferPointer(start:b.contents().assumingMemoryBound(to:Float.self),count:count))}

func compare(_ root:URL)throws {
    let input=root.appendingPathComponent("input1600"),out=root.appendingPathComponent("native-metal")
    try FileManager.default.createDirectory(at:out.appendingPathComponent("aligned"),withIntermediateDirectories:true)
    let records=try JSONDecoder().decode([InputRecord].self,from:Data(contentsOf:input.appendingPathComponent("manifest.json")))
    guard records.count>=3,records.count<=64,let ri=records.firstIndex(where:{$0.reference}),let first=records.first else{throw StackError("Requires 3…64 frames and a reference")}
    let w=first.width,h=first.height,n=w*h
    guard records.allSatisfy({$0.width==w && $0.height==h}) else{throw StackError("Mixed dimensions")}
    let mask=try readFloats(input.appendingPathComponent("mask.f32"),n)
    func read(_ i:Int)throws->Frame {Frame(width:w,height:h,pixels:try readFloats(input.appendingPathComponent(records[i].base+".rgba"),n*4))}
    let reference=try read(ri),imaging=Imaging()
    var report=try JSONDecoder().decode(StackReport.self,from:Data(contentsOf:root.deletingLastPathComponent().appendingPathComponent("pilot-final-3200/report.json")))
    guard report.frames.count==records.count,zip(report.frames,records).allSatisfy({$0.metadata.path==$1.source}) else{throw StackError("Manifest does not match seed report")}
    let seedWidth=report.width
    report.width=w;report.height=h;report.analysisWidth=w;report.streaks=[];report.temporalMotion=nil
    report.algorithm="nativebench-refit-1600-metal-v1"
    report.assumptions=["Shared-white-balance scene-linear Apple RAW inputs", "Native geometry refitted at input resolution, initialized from earlier native registration", "Shared conservative reference sky mask used for both target and source validity; no per-frame segmentation in this benchmark", "Metal Float32 inverse warp and robust fusion; no within-exposure deconvolution", "Reference foreground preserved; measured DSC00025 transient explicitly selected"]
    let compileStart=seconds(),gpu=try MetalBench(),compileSeconds=seconds()-compileStart
    let cube=try gpu.buffer(n*16*records.count),maskBuffer=try gpu.buffer(mask),refBuffer=try gpu.buffer(reference.pixels)
    let starStart=seconds(),refStars=StarDetector.detect(reference,mask:mask)
    var registrationSeconds=seconds()-starStart,warpGPU=0.0,warpCPU=0.0,warpSquared=0.0,warpSamples=0,warpMax:Float=0,validityMismatches=0
    var timings=[[String:Any]]()
    for i in records.indices {
        let source=try read(i),start=seconds(),stars=i==ri ? refStars : StarDetector.detect(source,mask:mask)
        // Refit from these pixels, using earlier geometry only as a correspondence initializer.
        let seed=report.frames[i].alignment?.resized(by:Double(w)/Double(seedWidth))
        let a:Alignment
        if i==ri {guard let seed else{throw StackError("Missing reference seed")};a=seed} else {a=try Registration.align(source:stars,reference:refStars,width:w,initial:seed)}
        let reg=seconds()-start;registrationSeconds+=reg
        report.frames[i].alignment=a;report.frames[i].stars=stars;report.frames[i].failure=nil
        let inv=try a.transform.inverted()
        var p=[Float(w),Float(h)]+inv.m.map(Float.init)
        p += [Float(a.morph?.scale ?? 0),Float(a.morph?.inputOffset ?? 0)]
        p += a.morph?.x.map(Float.init) ?? [Float](repeating:0,count:10)
        p += a.morph?.y.map(Float.init) ?? [Float](repeating:0,count:10)
        let uploadStart=seconds(),sourceBuffer=try gpu.buffer(source.pixels)
        let upload=seconds()-uploadStart
        let gt=try gpu.dispatch("warp",[sourceBuffer,cube,maskBuffer],bytes(p),n,i*n*16);warpGPU+=gt
        let warped=Array(UnsafeBufferPointer(start:cube.contents().advanced(by:i*n*16).assumingMemoryBound(to:Float.self),count:n*4))
        let cpuStart=seconds();var cpu=[Float](repeating:0,count:n*4)
        for y in 0..<h {for x in 0..<w {
            let k=y*w+x;guard mask[k]>0.001 else{continue}
            let q=a.sourcePoint(Point(Double(x),Double(y)),inverse:inv)
            guard q.x>=0,q.y>=0,q.x<Double(w-1),q.y<Double(h-1) else{continue}
            let ix=Int(q.x),iy=Int(q.y),fx=Float(q.x-Double(ix)),fy=Float(q.y-Double(iy)),j=iy*w+ix
            let m=(mask[j]*(1-fx)+mask[j+1]*fx)*(1-fy)+(mask[j+w]*(1-fx)+mask[j+w+1]*fx)*fy
            guard m>0.98,let c=source.sample(q.x,q.y) else{continue}
            cpu[4*k]=c.x;cpu[4*k+1]=c.y;cpu[4*k+2]=c.z;cpu[4*k+3]=1
        }}
        let ct=seconds()-cpuStart;warpCPU+=ct
        for k in 0..<n {
            if cpu[4*k+3] != warped[4*k+3]{validityMismatches+=1;continue}
            if cpu[4*k+3]>0 {for c in 0..<3 {let d=abs(cpu[4*k+c]-warped[4*k+c]);warpMax=max(warpMax,d);warpSquared+=Double(d)*Double(d);warpSamples+=1}}
        }
        let path=out.appendingPathComponent("aligned/\(String(format:"%04d",i)).rgba")
        try writeFloats(warped,path);report.frames[i].cache=path.path
        timings.append(["file":records[i].source,"stars":stars.count,"matches":a.matches.count,"validation_p95_px":a.validationP95Error,"cpu_registration_seconds":reg,"gpu_warp_seconds":gt,"upload_seconds":upload,"cpu_warp_seconds":ct])
        log("Native \(i+1)/\(records.count): \(a.matches.count) matches, p95 \(a.validationP95Error), warp CPU \(ct)s / Metal \(gt)s")
    }
    let dst=try gpu.buffer(n*16);var fuseTimes=[Double]()
    for _ in 0..<3 {fuseTimes.append(try gpu.dispatch("fuse",[cube,dst,maskBuffer,refBuffer],bytes([UInt32(n),UInt32(records.count)]),n))}
    let output=floats(dst,n*4),cpuStart=seconds(),ptr=cube.contents().assumingMemoryBound(to:Float.self)
    var cpu=reference.pixels
    for k in 0..<n where mask[k]>0.001 {
        var values=[(Float,Int)]()
        for i in records.indices {let j=(i*n+k)*4;if ptr[j+3]>0{values.append((ptr[j]*0.2126+ptr[j+1]*0.7152+ptr[j+2]*0.0722,j))}}
        values.sort{$0.0<$1.0};guard values.count>=3 else{continue}
        let mid=values[values.count/2].0,dev=values.map{abs($0.0-mid)}.sorted()
        let mad=dev.count%2==0 ? (dev[dev.count/2-1]+dev[dev.count/2])/2 : dev[dev.count/2],limit=max(1e-5,4.5*1.4826*mad)
        var sum=SIMD3<Float>(repeating:0),count:Float=0
        for (v,j) in values where abs(v-mid)<=limit {sum+=SIMD3(ptr[j],ptr[j+1],ptr[j+2]);count+=1}
        if count>0 {for c in 0..<3{cpu[4*k+c]=sum[c]/count*mask[k]+reference.pixels[4*k+c]*(1-mask[k])}}
    }
    let fuseCPU=seconds()-cpuStart
    var maxError:Float=0,squared=0.0,groundError:Float=0
    for k in 0..<n {for c in 0..<3{let d=abs(cpu[4*k+c]-output[4*k+c]);maxError=max(maxError,d);squared+=Double(d)*Double(d)
        if mask[k]==0{groundError=max(groundError,abs(output[4*k+c]-reference.pixels[4*k+c]))}}}
    guard maxError<1e-5,groundError==0,warpMax<0.001,validityMismatches<100 else{throw StackError("Parity failed: fusion \(maxError), warp \(warpMax), validity \(validityMismatches)")}
    let clean=Frame(width:w,height:h,pixels:output)
    try writeFloats(output,out.appendingPathComponent("stack-clean.rgba"));try writeFloats(reference.pixels,out.appendingPathComponent("reference.rgba"));try writeFloats(mask,out.appendingPathComponent("sky-mask.f32"))
    for i in records.indices {
        let source=Frame(width:w,height:h,pixels:try readFloats(URL(fileURLWithPath:report.frames[i].cache!),n*4))
        report.streaks += TransientDetector.detect(source:source,stack:clean,mask:mask,stars:refStars,frameIndex:i)
    }
    let result=try Composite.render(report:&report,clean:clean,mask:mask,policy:.isolated,keepFrames:["DSC00025.ARW"])
    try writeFloats(result.pixels,out.appendingPathComponent("stack-meteors.rgba"))
    try imaging.write(clean,to:out.appendingPathComponent("stack-clean.png"));try imaging.write(result,to:out.appendingPathComponent("stack-meteors.png"))
    try saveJSON(report,to:out.appendingPathComponent("report.json"))
    var summary:[String:Any]=["device":gpu.device.name,"width":w,"height":h,"frames":records.count,"metal_compile_seconds":compileSeconds,
        "registration_cpu_seconds":registrationSeconds,"warp_cpu_seconds":warpCPU,"warp_metal_dispatch_wait_seconds":warpGPU,
        "warp_rgb_max_error":warpMax,"warp_rgb_rms_error":sqrt(warpSquared/Double(warpSamples)),"warp_validity_mismatch_pixels":validityMismatches,
        "fusion_cpu_seconds":fuseCPU,"fusion_metal_seconds":fuseTimes,"fusion_max_error":maxError,"fusion_rms_error":sqrt(squared/Double(n*3)),"ground_max_error":groundError,
        "frames_detail":timings,"selected_streaks":report.streaks.filter{$0.selected==true}.count,
        "scope":"Independent Swift registration seeded from earlier native geometry; shared reference sky mask; Metal warp and robust fusion. CPU fusion uses identical GPU-warped inputs. RAW decode, segmentation, I/O and transient analysis excluded from timings."]
    summary["detector_preprocessing"]=try detectorBenchmark(root,gpu)
    try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("benchmark.json"))
    log("PASS. Metal results and parity measurements: \(out.path)")
}

func detectorBenchmark(_ root:URL,_ gpu:MetalBench)throws->[String:Any] {
    let dir=root.appendingPathComponent("detector-fixture"),w=4000,h=2660,n=w*h
    let a=try gpu.buffer(readFloats(dir.appendingPathComponent("a.f32"),n)),b=try gpu.buffer(readFloats(dir.appendingPathComponent("b.f32"),n))
    let binary=try gpu.buffer(n),eroded=try gpu.buffer(n),opened=try gpu.buffer(n)
    var times=[Double]()
    for _ in 0..<3 {
        let start=seconds()
        try gpu.dispatch("difference",[a,b,binary],bytes([Float(n),179]),n)
        try gpu.dispatch("morphology",[binary,eroded],bytes([UInt32(w),UInt32(h),0,0]),n)
        try gpu.dispatch("morphology",[eroded,opened],bytes([UInt32(w),UInt32(h),1,0]),n)
        times.append(seconds()-start)
    }
    let expected=try Data(contentsOf:dir.appendingPathComponent("opencv-opened.u8"))
    guard expected.count==n else{throw StackError("Detector fixture size")}
    let got=Data(bytes:opened.contents(),count:n);let mismatch=zip(expected,got).filter{$0 != $1}.count
    guard mismatch==0 else{throw StackError("Detector mask differs at \(mismatch) pixels")}
    try got.write(to:dir.appendingPathComponent("metal-opened.u8"))
    return ["width":w,"height":h,"threshold_adu":179,"mismatched_pixels":mismatch,"metal_dispatch_wait_seconds":times,
            "scope":"absdiff, strict threshold and 3x3 morphological opening only; not Hough voting or meteor classification"]
}
