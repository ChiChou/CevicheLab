import Foundation

public struct StackOptions {
    public var input: URL
    public var output: URL
    public var model: URL
    public var from: String?
    public var count: Int = 24
    public var longEdge: Int = 1600
    public var referenceIndex: Int?
    public var analysisEdge: Int = 3200
    public var keepStreaks: Bool = true
    public var streakPolicy:StreakPolicy = .isolated
    public var keepFrames:Set<String>? = nil
    public init(input: URL, output: URL, model: URL) { self.input=input;self.output=output;self.model=model }
}
public struct FrameRecord: Codable {
    public var metadata: Metadata
    public var stars: [Star]
    public var alignment: Alignment?
    public var failure: String?
    public var cache: String?
}
public struct StackReport: Codable {
    public var version = 1
    public var algorithm: String? = "exif-seeded-projective-cubic-v6"
    public var analysisWidth: Int? = nil
    public var width: Int
    public var height: Int
    public var reference: String
    public var referenceMidpoint: Double?
    public var assumptions: [String]
    public var frames: [FrameRecord]
    public var streaks: [Streak]
    public var temporalMotion: TemporalMotion? = nil
}
public func log(_ message: String) { FileHandle.standardError.write(Data((message+"\n").utf8)) }

public enum Pipeline {
    public static func run(_ options: StackOptions) throws {
        guard options.count>=3,options.longEdge>=128,options.longEdge<=10000,
              options.analysisEdge>=128,options.analysisEdge<=10000 else { throw StackError("Use at least 3 frames and output/analysis edges 128…10000") }
        var metadata=try Imaging.files(in:options.input).map(Imaging.metadata).sorted {
            ($0.relativeClock ?? 0,$0.path)<($1.relativeClock ?? 0,$1.path)
        }
        if let from=options.from {
            guard let index=metadata.firstIndex(where:{URL(fileURLWithPath:$0.path).lastPathComponent==from}) else { throw StackError("Start filename not found: \(from)") }
            metadata=Array(metadata[index...])
        }
        metadata=Array(metadata.prefix(options.count))
        guard metadata.count>=3 else { throw StackError("Need at least 3 readable source files") }
        let ri=options.referenceIndex ?? metadata.count/2
        guard metadata.indices.contains(ri) else { throw StackError("Reference index out of range") }
        let refURL=URL(fileURLWithPath:metadata[ri].path),out=options.output
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let cache=out.appendingPathComponent("aligned",isDirectory:true)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let imaging=Imaging(),wb=try imaging.whiteBalance(refURL),segmenter=try SkySegmenter(modelURL:options.model)
        log("Decoding reference \(refURL.lastPathComponent)")
        let analysisEdge=max(options.longEdge,options.analysisEdge)
        let analysisReference=try imaging.decode(refURL,longEdge:analysisEdge,whiteBalance:wb)
        let reference=options.longEdge>=analysisEdge ? analysisReference : imaging.render(imaging.image(analysisReference),longEdge:options.longEdge)
        let w=reference.width,h=reference.height,mask=try segmenter.mask(reference,imaging:imaging)
        let analysisMask=try segmenter.mask(analysisReference,imaging:imaging)
        let analysisStars=StarDetector.detect(analysisReference,mask:analysisMask)
        let scale=Double(w)/Double(analysisReference.width)
        func resizeStar(_ star:Star)->Star {
            Star(point:Point((star.point.x+0.5)*scale-0.5,(star.point.y+0.5)*scale-0.5),flux:star.flux*scale*scale,
                 peak:star.peak,radius:star.radius*scale,elongation:star.elongation)
        }
        let refStars=analysisStars.map(resizeStar)
        guard refStars.count>=12 else { throw StackError("Reference contains only \(refStars.count) sky stars") }
        try imaging.write(reference,to:out.appendingPathComponent("reference.png"))
        try imaging.writeMask(mask,width:w,height:h,to:out.appendingPathComponent("sky-mask.png"))
        var report=StackReport(width:w,height:h,reference:refURL.path,referenceMidpoint:metadata[ri].midpoint,
            assumptions:["EXIF clock sorted, exposure midpoint assumes timestamp marks exposure start",
                         "Common reference white balance; Apple lens-corrected scene-linear RAW",
                         "Projective stellar warp plus cross-validated smooth distortion residual; no within-exposure deconvolution",
                         "Foreground retained from reference; source sky validity prevents ground leakage",
                         "Streak detections are candidates, not a meteor-versus-satellite classification"],
            frames:metadata.map{FrameRecord(metadata:$0,stars:[],alignment:nil,failure:"not processed",cache:nil)},streaks:[])
        report.analysisWidth=analysisReference.width
        var analysisAlignments=[Int:Alignment]()
        // Track outward from the reference. Adjacent exposures give much stronger initialization
        // than triangle similarity across an hour of distorted wide-angle celestial motion.
        let order=Array(stride(from:ri,through:0,by:-1))+Array((ri+1)..<metadata.count)
        for (progress,index) in order.enumerated() {
            let meta=metadata[index]
            try autoreleasepool {
                log("Decode/align \(progress+1)/\(metadata.count): \(URL(fileURLWithPath:meta.path).lastPathComponent)")
                var record=FrameRecord(metadata:meta,stars:[],alignment:nil,failure:nil,cache:nil)
                do {
                    let analysisFrame=index==ri ? analysisReference : try imaging.decode(URL(fileURLWithPath:meta.path),longEdge:analysisEdge,whiteBalance:wb)
                    let frame=options.longEdge>=analysisEdge ? analysisFrame : imaging.render(imaging.image(analysisFrame),longEdge:options.longEdge)
                    guard frame.width==w,frame.height==h else { throw StackError("Frame dimensions differ") }
                    let sky=index==ri ? mask : try segmenter.mask(frame,imaging:imaging)
                    let analysisSky=index==ri ? analysisMask : try segmenter.mask(analysisFrame,imaging:imaging)
                    let stars=index==ri ? analysisStars : StarDetector.detect(analysisFrame,mask:analysisSky)
                    record.stars=stars.map(resizeStar)
                    var prediction:Alignment?
                    if index != ri {
                        let direction=index<ri ? 1 : -1,neighbor=index+direction,previous=neighbor+direction
                        prediction=analysisAlignments[neighbor]
                        if metadata.indices.contains(previous),let p=prediction,let q=analysisAlignments[previous],
                           let now=meta.midpoint,let t1=metadata[neighbor].midpoint,let t0=metadata[previous].midpoint,abs(t1-t0)>0.1 {
                            prediction=p.extrapolate(from:q,factor:(now-t1)/(t1-t0))
                        }
                    }
                    let measured=index==ri ? Alignment(transform:Homography(),matches:stars.map{Match(source:$0.point,reference:$0.point)},medianError:0,p95Error:0,validationMedianError:0,validationP95Error:0)
                        : try Registration.align(source:stars,reference:analysisStars,width:analysisFrame.width,initial:prediction)
                    analysisAlignments[index]=measured
                    let alignment=measured.resized(by:scale)
                    record.alignment=alignment
                    let inverse=try alignment.transform.inverted()
                    var aligned=[Float](repeating:0,count:w*h*4)
                    for y in 0..<h { for x in 0..<w {
                        let p=alignment.sourcePoint(Point(Double(x),Double(y)),inverse:inverse),k=y*w+x
                        guard mask[k]>0.001,maskValue(sky,width:w,height:h,point:p)>0.98,let v=frame.sample(p.x,p.y) else { continue }
                        for c in 0..<3 { aligned[4*k+c]=v[c] };aligned[4*k+3]=1
                    } }
                    let url=cache.appendingPathComponent(String(format:"%04d.rgba",index))
                    try aligned.withUnsafeBytes { try Data($0).write(to:url,options:.atomic) };record.cache=url.path
                    log("  \(stars.count) stars; \(alignment.matches.count) matches; held-out p95 \(String(format:"%.3f",alignment.validationP95Error)) px; morph \(alignment.morph != nil)")
                } catch { record.failure=String(describing:error);log("  REJECTED: \(error)") }
                report.frames[index]=record
                try saveJSON(report,to:out.appendingPathComponent("report.json"))
            }
        }
        let accepted=report.frames.compactMap(\.cache)
        guard accepted.count>=3 else { throw StackError("Only \(accepted.count) aligned frames; see report.json") }
        report.temporalMotion=TemporalSolver.estimate(report)
        if let motion=report.temporalMotion {log("Time-conditioned rotation: \(String(format:"%.3f",motion.inferredArcsecondsPerSecond)) arcsec/s; held-out p95 \(String(format:"%.3f",motion.heldOutP95Pixels)) px")}
        try saveJSON(report,to:out.appendingPathComponent("report.json"))
        log("Robust fusion of \(accepted.count) accepted frames")
        let fused=try fuse(paths:accepted,reference:reference,mask:mask)
        try imaging.write(fused.frame,to:out.appendingPathComponent("stack-clean.tiff"))
        try imaging.write(fused.frame,to:out.appendingPathComponent("stack-clean.png"))
        try fused.frame.pixels.withUnsafeBytes{try Data($0).write(to:out.appendingPathComponent("stack-clean.rgba"))}
        try reference.pixels.withUnsafeBytes{try Data($0).write(to:out.appendingPathComponent("reference.rgba"))}
        try mask.withUnsafeBytes{try Data($0).write(to:out.appendingPathComponent("sky-mask.f32"))}
        try imaging.writeMask(fused.coverage.map{Float($0)/Float(accepted.count)},width:w,height:h,to:out.appendingPathComponent("coverage.png"))
        // Inspect every source's positive residual before adding any transient back into the clean stack.
        for (index,record) in report.frames.enumerated() {
            guard let path=record.cache else { continue }
            let data=try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
            let pixels=data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
            let source=Frame(width:w,height:h,pixels:pixels)
            let found=TransientDetector.detect(source:source,stack:fused.frame,mask:mask,stars:refStars,frameIndex:index)
            report.streaks.append(contentsOf:found)
            if !found.isEmpty { log("  \(URL(fileURLWithPath:record.metadata.path).lastPathComponent): \(found.count) streak candidate(s)") }
        }
        let result=try Composite.render(report:&report,clean:fused.frame,mask:mask,policy:options.keepStreaks ? options.streakPolicy : .none,keepFrames:options.keepFrames)
        try imaging.write(result,to:out.appendingPathComponent("stack-meteors.tiff"))
        try imaging.write(result,to:out.appendingPathComponent("stack-meteors.png"))
        try result.pixels.withUnsafeBytes{try Data($0).write(to:out.appendingPathComponent("stack-meteors.rgba"))}
        try saveJSON(report,to:out.appendingPathComponent("report.json"))
        log("Complete: \(accepted.count)/\(metadata.count) aligned; \(report.streaks.count) streak candidates. \(out.path)")
    }

    static func fuse(paths: [String], reference: Frame, mask: [Float]) throws -> (frame:Frame,coverage:[Int]) {
        let w=reference.width,h=reference.height
        let handles=try paths.map{try FileHandle(forReadingFrom:URL(fileURLWithPath:$0))}
        defer { for handle in handles { try? handle.close() } }
        var output=reference.pixels,coverage=[Int](repeating:0,count:w*h)
        // Bounded memory: one row strip per source, rather than N full-resolution RAW frames.
        let strip=max(1,min(16,2_000_000/max(1,w*paths.count)))
        for y in stride(from:0,to:h,by:strip) {
            let n=min(strip,h-y)*w,bytes=n*16
            let data=try handles.map { handle -> Data in
                guard let d=try handle.read(upToCount:bytes),d.count==bytes else { throw StackError("Truncated aligned cache") };return d
            }
            let arrays=data.map{$0.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}}
            for i in 0..<n {
                let k=y*w+i;guard mask[k]>0.001 else {continue}
                var values=[(Float,Int)]();values.reserveCapacity(arrays.count)
                for (j,a) in arrays.enumerated() where a[4*i+3]>0 {
                    values.append((0.2126*a[4*i]+0.7152*a[4*i+1]+0.0722*a[4*i+2],j))
                }
                coverage[k]=values.count;guard values.count>=3 else {continue}
                values.sort{$0.0<$1.0};let mid=values[values.count/2].0
                let mad=Float(median(values.map{Double(abs($0.0-mid))})),threshold=max(1e-5,4.5*1.4826*mad)
                var sums=SIMD3<Float>(repeating:0),count:Float=0
                for (v,j) in values where abs(v-mid)<=threshold {
                    sums += SIMD3(arrays[j][4*i],arrays[j][4*i+1],arrays[j][4*i+2]);count+=1
                }
                if count>0 { for c in 0..<3 { output[4*k+c]=mask[k]*sums[c]/count+(1-mask[k])*reference.pixels[4*k+c] } }
            }
        }
        return (Frame(width:w,height:h,pixels:output),coverage)
    }
}
