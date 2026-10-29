import Foundation

public enum StreakPolicy:String {case isolated,all,none}

public enum Composite {
    public static func render(report:inout StackReport,clean:Frame,mask:[Float],policy:StreakPolicy,keepFrames:Set<String>?=nil)throws->Frame {
        let w=clean.width,h=clean.height
        report.streaks=TransientDetector.groupTracks(report.streaks)
        for i in report.streaks.indices {
            let candidate=report.streaks[i],name=URL(fileURLWithPath:report.frames[candidate.frameIndex].metadata.path).lastPathComponent
            report.streaks[i].selected=keepFrames.map{$0.contains(name)} ?? (policy == .all || policy == .isolated && candidate.persistentTrack != true)
        }
        var result=clean,strongest=[Float](repeating:-Float.infinity,count:w*h)
        let selected=Dictionary(grouping:report.streaks.filter{$0.selected == true},by: \.frameIndex)
        for index in selected.keys.sorted() {
            guard let path=report.frames[index].cache else{throw StackError("Selected transient has no aligned source")}
            let data=try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
            guard data.count==w*h*16 else{throw StackError("Truncated aligned source")}
            let source=data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
            for streak in selected[index]! {for k in TransientDetector.footprint(streak,width:w,height:h) {
                guard source[4*k+3]>0,mask[k]>0.98 else{continue}
                let dx=streak.end.x-streak.start.x,dy=streak.end.y-streak.start.y,length=hypot(dx,dy)
                let distance=abs((Double(k%w)-streak.start.x)*dy-(Double(k/w)-streak.start.y)*dx)/length
                let radius=max(2,streak.width*1.5),alpha=Float(min(1,max(0,(radius-distance)/max(0.5,radius*0.35))))
                let delta=SIMD3(source[4*k]-clean.pixels[4*k],source[4*k+1]-clean.pixels[4*k+1],source[4*k+2]-clean.pixels[4*k+2])
                let score=alpha*(0.2126*delta.x+0.7152*delta.y+0.0722*delta.z)
                if score>strongest[k] {
                    strongest[k]=score
                    for c in 0..<3 {result.pixels[4*k+c]=clean.pixels[4*k+c]+alpha*delta[c]}
                }
            }}
        }
        return result
    }
    /// Re-review transients without decoding RAWs, changing alignment, or downloading a model.
    public static func recompose(input:URL,output:URL,policy:StreakPolicy,keepFrames:Set<String>?=nil)throws {
        var report=try JSONDecoder().decode(StackReport.self,from:Data(contentsOf:input.appendingPathComponent("report.json")))
        let w=report.width,h=report.height
        func floats(_ name:String,count:Int)throws->[Float] {
            let data=try Data(contentsOf:input.appendingPathComponent(name));guard data.count==count*4 else{throw StackError("Invalid \(name)")}
            return data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
        }
        let clean=Frame(width:w,height:h,pixels:try floats("stack-clean.rgba",count:w*h*4))
        let mask=try floats("sky-mask.f32",count:w*h)
        // Re-run detector to benefit from updated candidate logic while retaining cached geometry.
        guard let reference=report.frames.first(where:{$0.metadata.path==report.reference}) else {throw StackError("Missing reference")}
        report.streaks=[]
        for (i,f) in report.frames.enumerated() {
            guard let path=f.cache else{continue}
            let data=try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
            guard data.count==w*h*16 else{throw StackError("Truncated aligned frame")}
            let frame=Frame(width:w,height:h,pixels:data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))})
            report.streaks += TransientDetector.detect(source:frame,stack:clean,mask:mask,stars:reference.stars,frameIndex:i)
        }
        let result=try render(report:&report,clean:clean,mask:mask,policy:policy,keepFrames:keepFrames)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let imaging=Imaging()
        try imaging.write(result,to:output.appendingPathComponent("stack-meteors.tiff"))
        try imaging.write(result,to:output.appendingPathComponent("stack-meteors.png"))
        try result.pixels.withUnsafeBytes{try Data($0).write(to:output.appendingPathComponent("stack-meteors.rgba"))}
        for name in ["stack-clean.rgba","reference.rgba","sky-mask.f32"] where input.standardizedFileURL != output.standardizedFileURL {
            try Data(contentsOf:input.appendingPathComponent(name)).write(to:output.appendingPathComponent(name),options:.atomic)
        }
        try saveJSON(report,to:output.appendingPathComponent("report.json"))
        log("Selected \(report.streaks.filter{$0.selected == true}.count)/\(report.streaks.count) candidates; policy \(policy.rawValue)")
    }
}
