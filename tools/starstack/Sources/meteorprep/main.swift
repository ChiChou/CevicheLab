import Foundation
import StarStackCore

// Small RAW-to-detector adapter; all originals are opened read-only.
func run() throws {
    let args=Array(CommandLine.arguments.dropFirst())
    guard args.count==3,let edge=Int(args[2]),edge>=128,edge<=8000 else {
        throw StackError("Usage: meteorprep INPUT OUTPUT EDGE")
    }
    let input=URL(fileURLWithPath:args[0]),out=URL(fileURLWithPath:args[1])
    let metadata=try Imaging.files(in:input).map(Imaging.metadata).sorted {
        ($0.relativeClock ?? 0,$0.path)<($1.relativeClock ?? 0,$1.path)
    }
    guard metadata.count>=3,metadata.allSatisfy({$0.midpoint != nil}) else {
        throw StackError("Need at least three images with EXIF timestamps")
    }
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let imaging=Imaging(),reference=metadata[metadata.count/2]
    let wb=try imaging.whiteBalance(URL(fileURLWithPath:reference.path))
    var records=[[String:Any]]()
    for (index,m) in metadata.enumerated() {
        try autoreleasepool {
            let frame=try imaging.decode(URL(fileURLWithPath:m.path),longEdge:edge,whiteBalance:wb)
            let name=String(format:"%04d-",index)+URL(fileURLWithPath:m.path).deletingPathExtension().lastPathComponent+".png"
            try imaging.write(frame,to:out.appendingPathComponent(name))
            records.append(["index":index,"source":m.path,"proxy":name,"width":frame.width,"height":frame.height,
                            "midpoint":m.midpoint!,"exposure":m.exposure ?? 0,"focal_mm":m.focalLength ?? 0,
                            "reference":m.path==reference.path])
            log("Detector proxy \(index+1)/\(metadata.count): \(name)")
        }
    }
    try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("manifest.json"))
    try saveJSON(metadata,to:out.appendingPathComponent("metadata.json"))
}
do {try run()} catch {fputs("error: \(error)\n",stderr);exit(1)}
