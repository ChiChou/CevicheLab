import Foundation

public struct Streak: Codable {
    public var frameIndex: Int
    public var start: Point
    public var end: Point
    public var width: Double
    public var pixels: Int
    public var peakResidual: Double
    public var label = "unclassified-linear-transient"
    public var persistentTrack: Bool? = nil
    public var selected: Bool? = nil
}
public enum TransientDetector {
    public static func groupTracks(_ input:[Streak])->[Streak] {
        var result=input,parent=Array(input.indices)
        func root(_ i:Int)->Int {var p=i;while parent[p] != p {p=parent[p]};return p}
        for i in input.indices {for j in input.indices where j>i {
            let a=input[i],b=input[j],gap=abs(a.frameIndex-b.frameIndex)
            guard gap>0,gap<=2 else{continue}
            let dx=a.end.x-a.start.x,dy=a.end.y-a.start.y,ex=b.end.x-b.start.x,ey=b.end.y-b.start.y
            let length=hypot(dx,dy),other=hypot(ex,ey)
            let angle=abs(dx*ey-dy*ex)/(length*other)
            let perpendicular=abs((b.start.x-a.start.x)*dy-(b.start.y-a.start.y)*dx)/length
            let separation=min(a.start.distance(b.start),a.start.distance(b.end),a.end.distance(b.start),a.end.distance(b.end))
            if angle<0.12,perpendicular<12,separation<max(30,max(length,other)*2) {parent[root(j)]=root(i)}
        }}
        var groups=[Int:Set<Int>]()
        for i in input.indices {groups[root(i),default:[]].insert(input[i].frameIndex)}
        for i in result.indices {
            result[i].persistentTrack=groups[root(i),default:[]].count>=3
            result[i].label=result[i].persistentTrack == true ? "persistent-track-aircraft-or-satellite-candidate" : "isolated-meteor-candidate"
        }
        return result
    }
    public static func detect(source: Frame, stack: Frame, mask: [Float], stars: [Star], frameIndex: Int) -> [Streak] {
        let w=source.width,h=source.height,a=source.luminance,b=stack.luminance
        let residual=zip(a,b).map(-),background=boxBlur(residual,width:w,height:h,radius:12)
        let high=zip(residual,background).map(-)
        let valid=mask.indices.map { mask[$0]>0.98 && source.pixels[4*$0+3]>0 ? Float(1) : Float(0) }
        let interior=boxBlur(valid,width:w,height:h,radius:15)
        let samples=high.enumerated().filter{$0.offset%7==0 && interior[$0.offset]>0.999}.map{Double($0.element)}
        let m=median(samples),sigma=max(1e-6,1.4826*median(samples.map{abs($0-m)}))
        var active=[UInt8](repeating:0,count:w*h)
        for y in 15..<h-15 {for x in 15..<w-15 {
            let i=y*w+x
            if interior[i]>0.999 && Double(high[i])>m+5*sigma {active[i]=1}
        }}
        for star in stars {
            let x=Int(star.point.x),y=Int(star.point.y)
            for dy in -4...4 {for dx in -4...4 where dx*dx+dy*dy<=16 {
                if x+dx>=0,x+dx<w,y+dy>=0,y+dy<h {active[(y+dy)*w+x+dx]=0}
            }}
        }
        var found=[Streak]()
        for seed in active.indices where active[seed]==1 {
            var queue=[seed],index=0;active[seed]=0
            while index<queue.count {
                let k=queue[index],x=k%w,y=k/w;index+=1
                // Bridge a one-pixel noise gap, without smearing the final measured source.
                for dy in -2...2 {for dx in -2...2 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<w,yy>=0,yy<h,active[yy*w+xx]==1 {active[yy*w+xx]=0;queue.append(yy*w+xx)}
                }}
            }
            guard queue.count>=12,queue.count<w*h/10 else {continue}
            let n=Double(queue.count),cx=queue.map{Double($0%w)}.reduce(0,+)/n,cy=queue.map{Double($0/w)}.reduce(0,+)/n
            var xx=0.0,yy=0.0,xy=0.0
            for k in queue {let x=Double(k%w)-cx,y=Double(k/w)-cy;xx+=x*x;yy+=y*y;xy+=x*y}
            let angle=0.5*atan2(2*xy,xx-yy),ux=cos(angle),uy=sin(angle)
            let along=queue.map{(Double($0%w)-cx)*ux+(Double($0/w)-cy)*uy}
            let across=queue.map{abs(-(Double($0%w)-cx)*uy+(Double($0/w)-cy)*ux)}
            let lo=along.min()!,hi=along.max()!,width=max(1,median(across)*2.96),length=hi-lo
            guard length>=18,length/width>=6,width<=6 else {continue}
            found.append(Streak(frameIndex:frameIndex,start:Point(cx+lo*ux,cy+lo*uy),end:Point(cx+hi*ux,cy+hi*uy),
                width:width,pixels:queue.count,peakResidual:Double(queue.map{high[$0]}.max()!)))
        }
        // Star exclusion can split one trail. Join only collinear, nearby segments in
        // the same exposure; compositing still uses the original measured pixels.
        var changed=true
        while changed {
            changed=false
            outer: for i in found.indices {for j in found.indices where j>i {
                let a=found[i],b=found[j],dx=a.end.x-a.start.x,dy=a.end.y-a.start.y,length=hypot(dx,dy)
                let ex=b.end.x-b.start.x,ey=b.end.y-b.start.y,other=hypot(ex,ey)
                let cross=abs(dx*ey-dy*ex)/(length*other)
                let gap=min(a.start.distance(b.start),a.start.distance(b.end),a.end.distance(b.start),a.end.distance(b.end))
                let distance=abs((b.start.x-a.start.x)*dy-(b.start.y-a.start.y)*dx)/length
                guard cross<0.035,gap<24,distance<max(3,a.width+b.width) else{continue}
                let points=[a.start,a.end,b.start,b.end],projection=points.map{($0.x-a.start.x)*dx/length+($0.y-a.start.y)*dy/length}
                let lo=projection.min()!,hi=projection.max()!
                found[i]=Streak(frameIndex:frameIndex,start:Point(a.start.x+lo*dx/length,a.start.y+lo*dy/length),
                    end:Point(a.start.x+hi*dx/length,a.start.y+hi*dy/length),width:max(a.width,b.width),pixels:a.pixels+b.pixels,peakResidual:max(a.peakResidual,b.peakResidual))
                found.remove(at:j);changed=true;break outer
            }}
        }
        return found
    }
    public static func footprint(_ streak: Streak, width w: Int, height h: Int) -> [Int] {
        let a=streak.start,b=streak.end,dx=b.x-a.x,dy=b.y-a.y,l2=dx*dx+dy*dy,r=max(2,streak.width*1.5)
        let x0=max(0,Int(min(a.x,b.x)-r-1)),x1=min(w-1,Int(max(a.x,b.x)+r+1))
        let y0=max(0,Int(min(a.y,b.y)-r-1)),y1=min(h-1,Int(max(a.y,b.y)+r+1))
        guard x1>=x0,y1>=y0,l2>0 else{return []}
        var indices=[Int]()
        for y in y0...y1 {for x in x0...x1 {
            let t=max(0,min(1,((Double(x)-a.x)*dx+(Double(y)-a.y)*dy)/l2))
            if hypot(Double(x)-a.x-t*dx,Double(y)-a.y-t*dy)<=r {indices.append(y*w+x)}
        }}
        return indices
    }
}
