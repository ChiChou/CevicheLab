import Foundation
import CoreImage
import StarStackCore

func run() throws {
    let args=Array(CommandLine.arguments.dropFirst())
    guard args.count >= 3 else {
        print("Usage: starstack survey INPUT OUTPUT\n       starstack stack INPUT OUTPUT --sky-model MODEL.mlmodelc [--from NAME --count 24 --edge 1600 --analysis-edge 3200 --reference INDEX --streak-policy isolated|all|none --keep-frames FILE,FILE]\n       starstack recompose EXISTING_RUN OUTPUT [--streak-policy isolated|all|none --keep-frames FILE,FILE]")
        return
    }
    if args[0]=="stack" || args[0]=="recompose" {
        var flags=[String:String](),i=3
        let allowed:Set<String> = args[0]=="recompose"
            ? ["--no-streaks","--streak-policy","--keep-frames"]
            : ["--sky-model","--from","--count","--edge","--analysis-edge","--reference","--no-streaks","--streak-policy","--keep-frames"]
        while i<args.count {
            guard allowed.contains(args[i]),flags[args[i]]==nil else {throw StackError("Unknown or repeated option: \(args[i])")}
            if args[i]=="--no-streaks" {flags[args[i]]="true";i+=1;continue}
            guard i+1<args.count else {throw StackError("Missing value for \(args[i])")}
            flags[args[i]]=args[i+1];i+=2
        }
        guard let policy=StreakPolicy(rawValue:flags["--streak-policy"] ?? "isolated") else{throw StackError("Invalid streak policy")}
        let keep=flags["--keep-frames"].map{Set($0.split(separator:",").map(String.init))}
        if args[0]=="recompose" {
            try Composite.recompose(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),policy:flags["--no-streaks"] == nil ? policy : .none,keepFrames:keep);return
        }
        guard let model=flags["--sky-model"] else {throw StackError("Provide --sky-model PATH to the existing licensed SkyRemoval.mlmodelc")}
        var options=StackOptions(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),model:URL(fileURLWithPath:model))
        func integer(_ key:String,_ fallback:Int)->Int {
            guard let value=flags[key] else {return fallback}
            return Int(value) ?? -1
        }
        options.from=flags["--from"];options.count=integer("--count",24)
        options.longEdge=integer("--edge",1600);options.referenceIndex=flags["--reference"].map{Int($0) ?? -1}
        options.analysisEdge=integer("--analysis-edge",3200);options.streakPolicy=policy;options.keepFrames=keep
        options.keepStreaks=flags["--no-streaks"] == nil
        try Pipeline.run(options);return
    }
    guard args[0]=="survey" else {throw StackError("Unknown command \(args[0])")}
    let metadata=try Imaging.files(in:URL(fileURLWithPath:args[1])).map(Imaging.metadata).sorted {
        ($0.relativeClock ?? 0,$0.path)<($1.relativeClock ?? 0,$1.path)
    }
    let files=metadata.map{URL(fileURLWithPath:$0.path)}
    let out=URL(fileURLWithPath:args[2],isDirectory:true)
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    try saveJSON(metadata,to:out.appendingPathComponent("metadata.json"))
    let imaging=Imaging()
    // Contact sheets use embedded JPEGs only for reconnaissance, never for numerical stacking.
    for start in stride(from:0,to:files.count,by:40) {
        let selected=Array(files[start..<min(files.count,start+40)])
        let w=1200,h=160*((selected.count+4)/5)
        var canvas=CIImage(color:CIColor.black).cropped(to:CGRect(x:0,y:0,width:w,height:h))
        for (i,url) in selected.enumerated() {
            let t=try imaging.thumbnail(url,size:230)
            let moved=t.transformed(by:CGAffineTransform(translationX:CGFloat(i%5*240),y:CGFloat(h-(i/5+1)*160)))
            canvas=moved.composited(over:canvas)
        }
        try imaging.context.writePNGRepresentation(of:canvas,to:out.appendingPathComponent(String(format:"contact-%04d.png",start+1)),format:.RGBA8,colorSpace:Imaging.sRGB)
        print("Surveyed \(min(files.count,start+40))/\(files.count)")
    }
}
do { try run() } catch { fputs("error: \(error)\n",stderr); exit(1) }
