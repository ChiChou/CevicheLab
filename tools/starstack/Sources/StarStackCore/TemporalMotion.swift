import Foundation
import simd

public struct TemporalMotion: Codable {
    public var radiansPerSecond: [Double]
    public var focalPixels: Double
    public var nominalFocalPixels: Double
    public var inferredArcsecondsPerSecond: Double
    public var siderealArcsecondsPerSecond = 360.0*3600/86164.0905
    public var heldOutMedianPixels: Double
    public var heldOutP95Pixels: Double
    public var observations: Int
    public var captureSpanSeconds: Double
    public var compatibleWithFixedTripod: Bool
    public var role = "diagnostic time-conditioned rotation; not substituted for measured distortion-corrected warps"
}

public enum TemporalSolver {
    struct Observation {let point:Point;let target:Point;let dt:Double}
    public static func estimate(_ report:StackReport)->TemporalMotion? {
        guard let epoch=report.referenceMidpoint,
              let ref=report.frames.first(where:{$0.metadata.path==report.reference}),
              let focal35=ref.metadata.focal35, focal35>0 else{return nil}
        let w=Double(report.width),h=Double(report.height),nominal=w*focal35/36
        var observations=[Observation](),times=[Double]()
        for frame in report.frames {
            guard let a=frame.alignment,let t=frame.metadata.midpoint,abs(t-epoch)>1 else{continue}
            times.append(t)
            for i in stride(from:0,to:a.matches.count,by:max(1,a.matches.count/40)) {
                let pair=a.matches[i]
                observations.append(Observation(point:pair.source,target:pair.reference,dt:(epoch-t)/1000))
            }
        }
        guard observations.count>=60 else{return nil}
        let train=observations.enumerated().filter{$0.offset%5 != 0}.map(\.element)
        let test=observations.enumerated().filter{$0.offset%5 == 0}.map(\.element)
        // A shared angular velocity plus one effective focal-length correction. Explicit EXIF
        // intervals drive every observation; no per-frame clock adjustments can absorb bad fits.
        func project(_ o:Observation,_ p:[Double])->Point {
            let f=nominal*exp(p[3]),ray=SIMD3((o.point.x-w/2)/f,(o.point.y-h/2)/f,1.0)
            let rotation=SIMD3(p[0],p[1],p[2])*o.dt,angle=simd_length(rotation)
            let q:SIMD3<Double>
            if angle<1e-10 {q=ray+simd_cross(rotation,ray)} else {
                let axis=rotation/angle
                q=ray*cos(angle)+simd_cross(axis,ray)*sin(angle)+axis*simd_dot(axis,ray)*(1-cos(angle))
            }
            return Point(f*q.x/q.z+w/2,f*q.y/q.z+h/2)
        }
        func cost(_ p:[Double])->Double {
            train.reduce(0){sum,o in let e=project(o,p).distance(o.target);return sum+(e<2 ? e*e : 4*e-4)}
        }
        var params=[0.0,0,0,0],lambda=0.01
        for _ in 0..<25 {
            var rows=[[Double]](),values=[Double]()
            for o in train {
                let q=project(o,params),ex=o.target.x-q.x,ey=o.target.y-q.y
                let weight=sqrt(min(1,2/max(1e-8,hypot(ex,ey))))
                var jx=[Double](),jy=[Double]()
                for j in 0..<4 {
                    var pp=params;let step=j==3 ? 1e-5 : 1e-6;pp[j]+=step
                    let qp=project(o,pp);jx.append((qp.x-q.x)/step*weight);jy.append((qp.y-q.y)/step*weight)
                }
                rows.append(jx);values.append(ex*weight);rows.append(jy);values.append(ey*weight)
            }
            for j in 0..<4 {var row=[Double](repeating:0,count:4);row[j]=sqrt(lambda);rows.append(row);values.append(0)}
            guard let delta=solve(rows,values,count:4) else{break}
            var candidate=zip(params,delta).map(+)
            candidate[3]=max(log(0.7),min(log(1.3),candidate[3]))
            if cost(candidate)<cost(params) {params=candidate;lambda=max(1e-8,lambda/3)} else {lambda*=10}
            if delta.map({$0*$0}).reduce(0,+)<1e-16 {break}
        }
        let errors=test.map{project($0,params).distance($0.target)}.sorted()
        let speed=sqrt(params[0]*params[0]+params[1]*params[1]+params[2]*params[2])/1000*180/Double.pi*3600
        let p95=errors[min(errors.count-1,Int(Double(errors.count)*0.95))]
        return TemporalMotion(radiansPerSecond:Array(params.prefix(3)).map{$0/1000},focalPixels:nominal*exp(params[3]),
            nominalFocalPixels:nominal,inferredArcsecondsPerSecond:speed,heldOutMedianPixels:median(errors),heldOutP95Pixels:p95,
            observations:observations.count,captureSpanSeconds:(times.max() ?? epoch)-(times.min() ?? epoch),
            compatibleWithFixedTripod:abs(speed-15.0411)<1.5 && p95<2)
    }
}
