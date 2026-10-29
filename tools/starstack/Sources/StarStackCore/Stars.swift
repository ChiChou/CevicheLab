import Foundation

public func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return 0 }
    let s=a.sorted(); return s.count%2 == 0 ? (s[s.count/2-1]+s[s.count/2])/2 : s[s.count/2]
}
public func boxBlur(_ a: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
    var integral=[Double](repeating:0,count:(w+1)*(h+1))
    for y in 0..<h {
        var sum=0.0
        for x in 0..<w { sum += Double(a[y*w+x]); integral[(y+1)*(w+1)+x+1]=integral[y*(w+1)+x+1]+sum }
    }
    var out=[Float](repeating:0,count:w*h)
    for y in 0..<h { for x in 0..<w {
        let x0=max(0,x-r), x1=min(w,x+r+1), y0=max(0,y-r), y1=min(h,y+r+1)
        let s=integral[y1*(w+1)+x1]-integral[y0*(w+1)+x1]-integral[y1*(w+1)+x0]+integral[y0*(w+1)+x0]
        out[y*w+x]=Float(s/Double((x1-x0)*(y1-y0)))
    } }
    return out
}
public struct Point: Codable, Equatable {
    public var x: Double; public var y: Double
    public init(_ x: Double,_ y: Double) { self.x=x; self.y=y }
    public func distance(_ b: Point) -> Double { hypot(x-b.x,y-b.y) }
}
public struct Star: Codable {
    public var point: Point
    public var flux: Double
    public var peak: Double
    public var radius: Double
    public var elongation: Double
    public init(point: Point, flux: Double, peak: Double=1, radius: Double=1, elongation: Double=1) {
        self.point=point; self.flux=flux; self.peak=peak; self.radius=radius; self.elongation=elongation
    }
}
public enum StarDetector {
    /// Local-background subtraction and local noise thresholds. No learned star replacement.
    public static func detect(_ frame: Frame, mask: [Float]?=nil, limit: Int=700, sigma: Double=6) -> [Star] {
        let w=frame.width,h=frame.height,l=frame.luminance
        guard w>16,h>16 else { return [] }
        let bg=boxBlur(l,width:w,height:h,radius:6)
        let high=zip(l,bg).map(-)
        let tw=(w+63)/64,th=(h+63)/64
        var noise=[Double](repeating:1e-6,count:tw*th)
        for ty in 0..<th { for tx in 0..<tw {
            var values=[Double]()
            for y in stride(from:ty*64,to:min(h,ty*64+64),by:2) {
                for x in stride(from:tx*64,to:min(w,tx*64+64),by:2) { values.append(Double(high[y*w+x])) }
            }
            let m=median(values); noise[ty*tw+tx]=max(1e-7,1.4826*median(values.map { abs($0-m) }))
        } }
        var stars=[Star]()
        for y in 7..<h-7 { for x in 7..<w-7 {
            let k=y*w+x
            if let mask, mask[k]<0.95 { continue }
            let n=noise[(y/64)*tw+x/64],v=Double(high[k])
            guard v>sigma*n else { continue }
            var isMax=true
            for dy in -2...2 { for dx in -2...2 where dx != 0 || dy != 0 {
                if high[(y+dy)*w+x+dx]>=high[k] { isMax=false }
            } }
            if !isMax { continue }
            var total=0.0,sx=0.0,sy=0.0
            for dy in -3...3 { for dx in -3...3 {
                let a=max(0,Double(high[(y+dy)*w+x+dx])-n)
                total+=a; sx+=a*Double(dx); sy+=a*Double(dy)
            } }
            guard total>0 else { continue }; sx/=total; sy/=total
            var xx=0.0,yy=0.0,xy=0.0
            for dy in -3...3 { for dx in -3...3 {
                let a=max(0,Double(high[(y+dy)*w+x+dx])-n),ux=Double(dx)-sx,uy=Double(dy)-sy
                xx+=a*ux*ux; yy+=a*uy*uy; xy+=a*ux*uy
            } }
            xx/=total; yy/=total; xy/=total
            let d=sqrt((xx-yy)*(xx-yy)+4*xy*xy),minor=max(0.01,(xx+yy-d)/2),major=(xx+yy+d)/2
            let radius=sqrt((xx+yy)/2),elongation=sqrt(max(minor,major)/minor)
            // Reject isolated hot pixels and elongated streaks; keep mildly trailed stars as measured.
            if radius<0.45 || radius>3 || elongation>3.5 { continue }
            stars.append(Star(point:Point(Double(x)+sx,Double(y)+sy),flux:total,peak:Double(l[k]),radius:radius,elongation:elongation))
        } }
        // Suppress dense clusters of features on one bright structure, retaining field coverage.
        var counts=[Int:Int](),selected=[Star]()
        for star in stars.sorted(by:{$0.flux>$1.flux}) {
            let key=Int(star.point.y)/48*((w+47)/48)+Int(star.point.x)/48
            if counts[key,default:0]>=5 { continue }
            counts[key,default:0]+=1; selected.append(star)
            if selected.count>=limit { break }
        }
        return selected
    }
}
