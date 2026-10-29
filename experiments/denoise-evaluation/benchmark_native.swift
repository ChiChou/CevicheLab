// Native LibRaw + Core ML timing. No Python tensors or intermediate files.
import Foundation
import CoreML
import CoreImage
import ImageIO
import Metal
import Darwin

@_silgen_name("speed_raw_open") func rawOpen(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("speed_raw_pixels") func rawPixels(_ f: UnsafeMutableRawPointer) -> UnsafePointer<UInt16>
@_silgen_name("speed_raw_info") func rawInfo(_ f: UnsafeMutableRawPointer, _ i: UnsafeMutablePointer<Int32>, _ t: UnsafeMutablePointer<Double>)
@_silgen_name("speed_raw_close") func rawClose(_ f: UnsafeMutableRawPointer)
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds)/1e9 }
let args=CommandLine.arguments
let root=URL(fileURLWithPath:args[1],isDirectory:true)
let modelURL=URL(fileURLWithPath:args[2])
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var report:[String:Any]=["purpose":"Native real-sample timing; no shipping integration", "runCount":3]
var t=now()
let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at:modelURL)
report["compileSeconds"]=now()-t
let config=MLModelConfiguration();config.computeUnits = .all
t=now();let model=try MLModel(contentsOf:compiled,configuration:config);report["loadSeconds"]=now()-t
print("Model ready",report["compileSeconds"]!,report["loadSeconds"]!);fflush(stdout)
let input=try MLMultiArray(shape:[1,4,256,256],dataType:.float32)
let values=input.dataPointer.assumingMemoryBound(to:Float.self)
let provider=try MLDictionaryFeatureProvider(dictionary:["packed_raw":MLFeatureValue(multiArray:input)])
let tile=256,halo=32,step=192,plane=256*256
@inline(__always) func mirror(_ x:Int,_ n:Int)->Int { let period=2*n-2;var v=x%period;if v<0 {v+=period};return v<n ? v:period-v }
let profiles: [String:([Float],[Float])] = [
    "DSC00396.ARW":([0.6864119768,0.6891442537,0.6891442537,0.6980829835],[-0.0020500186,-0.0020667859,-0.0020667859,-0.0020090961])]
var runs=[[String:Any]]()
for path in args.dropFirst(3) {
    let name=URL(fileURLWithPath:path).lastPathComponent
    let (scales,offsets)=profiles[name] ?? ([1,1,1,1],[0,0,0,0])
    for pass in 0..<3 {
        try autoreleasepool {
            let started=now()
            guard let frame=path.withCString({rawOpen($0)}) else { fatalError("LibRaw failed: \(path)") }
            defer {rawClose(frame)}
            var info=[Int32](repeating:0,count:15),rawTimes=[Double](repeating:0,count:2)
            rawInfo(frame,&info,&rawTimes)
            precondition(Array(info[7..<11]) == [0,1,3,2],"This harness expects RGGB")
            let w=Int(info[0]),h=Int(info[1]),pitch=Int(info[2]),top=Int(info[3]),left=Int(info[4])
            let pixels=rawPixels(frame),hh=h/2,ww=w/2
            var output=[Float](repeating:0,count:w*h)
            let allocationSeconds=now()-started-rawTimes.reduce(0,+)
            var prepare=0.0,predict=0.0,stitch=0.0,times=[Double](),finite=true
            let mapping=[0,1,3,2]
            for y in stride(from:0,to:hh,by:step) { for x in stride(from:0,to:ww,by:step) {
                var mark=now()
                let xs=(0..<tile).map {mirror(x+$0-halo,ww)*2+left}
                let ys=(0..<tile).map {(mirror(y+$0-halo,hh)*2+top)*pitch}
                for c in 0..<4 {
                    let black=Float(info[5]+info[11+mapping[c]]),range=Float(info[6])-black
                    for ty in 0..<tile {
                        let sy=ys[ty]+(c/2)*pitch
                        for tx in 0..<tile {
                            let sx=xs[tx]+c%2
                            let v=min(1,max(0,(Float(pixels[sy+sx])-black)/range))
                            values[c*plane+ty*tile+tx]=(v*scales[c]+offsets[c])*256
                        }
                    }
                }
                prepare+=now()-mark;mark=now()
                let result=try model.prediction(from:provider)
                guard let a=result.featureValue(for:"denoised_raw")?.multiArrayValue else {fatalError("No model output")}
                let elapsed=now()-mark;predict+=elapsed;times.append(elapsed);mark=now()
                let strides=a.strides.map(\.intValue),dy=min(step,hh-y),dx=min(step,ww-x)
                // Native Core ML may materialize FP16 even with the Python interface
                // returning float32. Handle both native representations and strides.
                if times.count==1 { print("Output dtype",a.dataType.rawValue,"shape",a.shape);fflush(stdout) }
                let p=a.dataPointer.assumingMemoryBound(to:Float.self)
                let ph=a.dataPointer.assumingMemoryBound(to:Float16.self)
                precondition(a.dataType == .float32 || a.dataType == .float16)
                let isHalf=a.dataType == .float16
                for c in 0..<4 { for yy in 0..<dy { for xx in 0..<dx {
                    let index=c*strides[1]+(yy+halo)*strides[2]+(xx+halo)*strides[3]
                    let predicted=isHalf ? Float(ph[index]) : p[index]
                    let v=(predicted/256-offsets[c])/scales[c]
                    finite = finite && v.isFinite
                    output[(2*(y+yy)+c/2)*w+2*(x+xx)+c%2]=v
                } } }
                stitch+=now()-mark
            } }
            let total=now()-started
            let sorted=times.sorted()
            let row:[String:Any]=["file":name,"pass":pass,"width":w,"height":h,"tiles":times.count,
                "profile":profiles[name] == nil ? "Timing only: identity normalization; no ISO640 quality claim":"Matching DNG source noise profile",
                "openSeconds":rawTimes[0],"unpackSeconds":rawTimes[1],"allocationAndOtherSeconds":allocationSeconds,
                "tilePreparationSeconds":prepare,"predictionSeconds":predict,"stitchSeconds":stitch,
                "totalRawToDenoisedMosaicSeconds":total,"firstPredictionSeconds":times[0],"medianPredictionSeconds":sorted[sorted.count/2],
                "finite":finite,"outputBytes":output.count*4,"outputSample":output[output.count/2]]
            runs.append(row)
            print(name,"pass",pass,"total",total,"predict",predict)
            fflush(stdout)
        }
    }
}
report["runs"]=runs
var usage=rusage();getrusage(RUSAGE_SELF,&usage);report["processPeakResidentBytes"]=usage.ru_maxrss
report["precision"]="FP16 graph, float32 input, float16 native output widened to float32 for stitching; compute units ALL"
report["excluded"]="DNG writing and Apple decode/render; model compile/load separately recorded. Filesystem cache not purged."
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("native-speed.json"))
