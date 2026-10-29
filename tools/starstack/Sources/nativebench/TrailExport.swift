import Foundation
import StarStackCore

/// Scene-linear fixtures for the aurora maximum-stack/quality experiment.
/// Camera coordinates are deliberately retained: no stellar registration.
func exportTrails(input:URL,output:URL,edge:Int,model:URL)throws {
    guard edge>=256,edge<=3200 else{throw StackError("Trail preview edge must be 256…3200")}
    let metadata=try Imaging.files(in:input).map(Imaging.metadata).sorted{($0.relativeClock ?? 0,$0.path)<($1.relativeClock ?? 0,$1.path)}
    guard let first=metadata.first,metadata.count>=3 else{throw StackError("Need at least three inputs")}
    guard metadata.allSatisfy({$0.exposure==first.exposure && $0.iso==first.iso && $0.aperture==first.aperture && $0.focalLength==first.focalLength}) else{throw StackError("This fixed-exposure experiment requires constant exposure/ISO/aperture/focal length")}
    try FileManager.default.createDirectory(at:output.appendingPathComponent("frames"),withIntermediateDirectories:true)
    let imaging=Imaging(),refURL=URL(fileURLWithPath:first.path),wb=try imaging.whiteBalance(refURL)
    let reference=try imaging.decode(refURL,longEdge:edge,whiteBalance:wb),w=reference.width,h=reference.height
    let mask=try SkySegmenter(modelURL:model).mask(reference,imaging:imaging)
    try writeFloats(mask,output.appendingPathComponent("sky-mask.f32"))
    try imaging.writeMask(mask,width:w,height:h,to:output.appendingPathComponent("sky-mask.png"))
    try imaging.write(reference,to:output.appendingPathComponent("reference.png"))
    try saveJSON(metadata,to:output.appendingPathComponent("metadata.json"))
    var records=[[String:Any]]()
    for (i,m) in metadata.enumerated() {
        try autoreleasepool {
            let start=seconds(),name=URL(fileURLWithPath:m.path).deletingPathExtension().lastPathComponent
            let frame=i==0 ? reference : try imaging.decode(URL(fileURLWithPath:m.path),longEdge:edge,whiteBalance:wb)
            guard frame.width==w,frame.height==h else{throw StackError("Frame dimension mismatch: \(name)")}
            let cache="frames/\(name).rgba";try writeFloats(frame.pixels,output.appendingPathComponent(cache))
            records.append(["index":i,"file":m.path,"cache":cache,"width":w,"height":h,"seconds":seconds()-start])
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("manifest.json"),options:.atomic)
            log("Trail RAW \(i+1)/\(metadata.count): \(name), \(String(format:"%.2f",seconds()-start))s")
        }
    }
}

func trailMask(output:URL,model:URL)throws {
    let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("manifest.json"))) as! [[String:Any]]
    guard let row=rows.first,let w=row["width"] as? Int,let h=row["height"] as? Int,let cache=row["cache"] as? String else{throw StackError("Invalid trail manifest")}
    let frame=Frame(width:w,height:h,pixels:try readFloats(output.appendingPathComponent(cache),w*h*4)),imaging=Imaging()
    let mask=try SkySegmenter(modelURL:model).mask(frame,imaging:imaging,conservative:false,normalizeForNight:false)
    try writeFloats(mask,output.appendingPathComponent("sky-model-uneroded.f32"))
    try imaging.writeMask(mask,width:w,height:h,to:output.appendingPathComponent("sky-model-uneroded.png"))
}
