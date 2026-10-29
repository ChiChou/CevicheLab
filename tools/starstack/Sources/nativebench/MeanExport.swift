import Foundation
import ImageIO
import StarStackCore

private struct MeanRecord:Encodable {
    let metadata:Metadata
    let cache:String
    let mask:String
    let stars:[Star]
    let alignment:Alignment?
}
private struct MeanManifest:Encodable {
    let width:Int,height:Int,analysisWidth:Int,analysisHeight:Int,referenceIndex:Int
    let focal35:Double,lensModel:String
    let frames:[MeanRecord]
}
func exportMean(input:URL,output:URL,model:URL)throws {
    let all=try Imaging.files(in:input).map(Imaging.metadata).sorted{($0.relativeClock ?? 0,$0.path)<($1.relativeClock ?? 0,$1.path)}
    var groups=[[Metadata]]()
    for m in all {
        if let last=groups.last?.last,last.camera==m.camera,last.exposure==m.exposure,last.iso==m.iso,last.aperture==m.aperture,
           last.focalLength==m.focalLength,abs((m.relativeClock ?? 0)-(last.relativeClock ?? 0))<1800 {
            groups[groups.count-1].append(m)
        } else {groups.append([m])}
    }
    guard groups.count==2,groups.allSatisfy({$0.count==5}) else{throw StackError("Expected two compatible five-frame groups; found \(groups.map(\.count))")}
    let imaging=Imaging(),segmenter=try SkySegmenter(modelURL:model)
    for (gi,metadata) in groups.enumerated() {
        try autoreleasepool {
            let dir=output.appendingPathComponent("group-\(gi+1)");try FileManager.default.createDirectory(at:dir.appendingPathComponent("frames"),withIntermediateDirectories:true)
            let ri=metadata.count/2,refURL=URL(fileURLWithPath:metadata[ri].path),wb=try imaging.whiteBalance(refURL)
            let reference=try imaging.decode(refURL,longEdge:max(metadata[ri].width,metadata[ri].height),whiteBalance:wb)
            let analysis=imaging.render(imaging.image(reference),longEdge:3200),mask=try segmenter.mask(analysis,imaging:imaging,conservative:false,normalizeForNight:false)
            let refStars=StarDetector.detect(analysis,mask:mask,limit:1200,sigma:6)
            guard let focal=metadata[ri].focal35,focal>0 else{throw StackError("Need EXIF 35mm-equivalent focal length for ray geometry")}
            let src=CGImageSourceCreateWithURL(refURL as CFURL,nil)!,props=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any]
            let exif=props?[kCGImagePropertyExifDictionary as String] as? [String:Any]
            let lens=exif?[kCGImagePropertyExifLensModel as String] as? String ?? "not recorded"
            var records=[MeanRecord]()
            for (i,m) in metadata.enumerated() {
                try autoreleasepool {
                    let start=seconds(),name=URL(fileURLWithPath:m.path).deletingPathExtension().lastPathComponent
                    let full=i==ri ? reference : try imaging.decode(URL(fileURLWithPath:m.path),longEdge:max(m.width,m.height),whiteBalance:wb)
                    guard full.width==reference.width,full.height==reference.height else{throw StackError("Native dimensions differ")}
                    let proxy=i==ri ? analysis : imaging.render(imaging.image(full),longEdge:3200)
                    let sky=i==ri ? mask : try segmenter.mask(proxy,imaging:imaging,conservative:false,normalizeForNight:false)
                    let stars=i==ri ? refStars : StarDetector.detect(proxy,mask:sky,limit:1200,sigma:6)
                    let alignment=i==ri ? nil : try Registration.align(source:stars,reference:refStars,width:proxy.width)
                    let cache="frames/\(name).rgba",maskName="frames/\(name).mask.f32"
                    try writeFloats(full.pixels,dir.appendingPathComponent(cache));try writeFloats(sky,dir.appendingPathComponent(maskName))
                    records.append(MeanRecord(metadata:m,cache:cache,mask:maskName,stars:stars,alignment:alignment))
                    log("Mean group \(gi+1), frame \(i+1)/5: \(name), full \(full.width)x\(full.height), \(stars.count) stars, matched \(alignment?.matches.count ?? refStars.count), \(String(format:"%.1f",seconds()-start))s")
                }
            }
            try saveJSON(MeanManifest(width:reference.width,height:reference.height,analysisWidth:analysis.width,analysisHeight:analysis.height,
                referenceIndex:ri,focal35:focal,lensModel:lens,frames:records),to:dir.appendingPathComponent("manifest.json"))
            log("Group \(gi+1) ready; EXIF lens \(lens), focal35 \(focal)")
        }
    }
}
