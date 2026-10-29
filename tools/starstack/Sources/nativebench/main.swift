import Foundation
import StarStackCore

func run() throws {
    let args=Array(CommandLine.arguments.dropFirst())
    if args.first=="mean-export",args.count==4 {try exportMean(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),model:URL(fileURLWithPath:args[3]));return}
    if args.first=="trail-mask",args.count==3 {try trailMask(output:URL(fileURLWithPath:args[1]),model:URL(fileURLWithPath:args[2]));return}
    if args.first=="trail-export",args.count==5 {try exportTrails(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),edge:Int(args[3]) ?? 0,model:URL(fileURLWithPath:args[4]));return}
    if args.first=="compare",args.count==2 {try compare(URL(fileURLWithPath:args[1],isDirectory:true));return}
    if args.first=="catalog",args.count==2 {try catalogSolve(URL(fileURLWithPath:args[1],isDirectory:true));return}
    if args.first=="selftest",args.count==2 {try selftest(URL(fileURLWithPath:args[1],isDirectory:true));return}
    guard args.count>=3 else {throw StackError("Usage: nativebench export REPORT_JSON OUTPUT [EDGE] | compare ROOT | catalog ROOT | selftest ROOT")}
    guard args[0]=="export" else {throw StackError("Unknown command")}
    let report=try JSONDecoder().decode(StackReport.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
    let output=URL(fileURLWithPath:args[2],isDirectory:true),edge=args.count>3 ? Int(args[3]) ?? 1600 : 1600
    guard edge>=128,edge<=8000 else {throw StackError("Invalid edge")}
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let imaging=Imaging(),wb=try imaging.whiteBalance(URL(fileURLWithPath:report.reference))
    var manifest=[[String:Any]]()
    for (i,record) in report.frames.enumerated() {
        try autoreleasepool {
            let source=URL(fileURLWithPath:record.metadata.path),name=String(format:"%04d",i)+"_"+source.deletingPathExtension().lastPathComponent
            let frame=try imaging.decode(source,longEdge:edge,whiteBalance:wb)
            try frame.pixels.withUnsafeBytes{try Data($0).write(to:output.appendingPathComponent(name+".rgba"))}
            try imaging.write(frame,to:output.appendingPathComponent(name+".tiff"))
            manifest.append(["source":source.path,"base":name,"width":frame.width,"height":frame.height,"reference":source.path==report.reference,
                "exposure":record.metadata.exposure ?? 0,"camera_clock":record.metadata.dateTimeOriginal ?? "","midpoint":record.metadata.midpoint ?? 0])
            log("Exported \(i+1)/\(report.frames.count) \(name)")
        }
    }
    try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("manifest.json"))
}
do {try run()} catch {fputs("error: \(error)\n",stderr);exit(1)}
