import Foundation

/// Source-to-reference projective warp in pixel coordinates. Inverse sampling uses inverted().
public struct Homography: Codable {
    public var m: [Double]
    public init(_ m: [Double]=[1,0,0,0,1,0,0,0,1]) { precondition(m.count==9); self.m=m }
    public func apply(_ p: Point) -> Point {
        let z=m[6]*p.x+m[7]*p.y+m[8]
        return Point((m[0]*p.x+m[1]*p.y+m[2])/z,(m[3]*p.x+m[4]*p.y+m[5])/z)
    }
    public func inverted() throws -> Homography {
        let a=m[0],b=m[1],c=m[2],d=m[3],e=m[4],f=m[5],g=m[6],h=m[7],i=m[8]
        let co=[e*i-f*h,c*h-b*i,b*f-c*e,f*g-d*i,a*i-c*g,c*d-a*f,d*h-e*g,b*g-a*h,a*e-b*d]
        let det=a*co[0]+b*co[3]+c*co[6]
        guard abs(det)>1e-12,det.isFinite else { throw StackError("Singular sky warp") }
        return Homography(co.map{$0/det})
    }
    public func followed(by b: Homography) -> Homography {
        var c=[Double](repeating:0,count:9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { c[i*3+j]+=b.m[i*3+k]*m[k*3+j] } } }
        return Homography(c)
    }
}
public struct Match: Codable {
    public let source: Point
    public let reference: Point
}
public struct Alignment: Codable {
    public let transform: Homography
    public let matches: [Match]
    public let medianError: Double
    public let p95Error: Double
    public let validationMedianError: Double
    public let validationP95Error: Double
    public var morph: ResidualMorph? = nil
    public func apply(_ point: Point) -> Point {
        let p=transform.apply(point),d=morph?.displacement(point) ?? Point(0,0)
        return Point(p.x+d.x,p.y+d.y)
    }
    public func sourcePoint(_ target: Point, inverse: Homography) -> Point {
        var p=inverse.apply(target)
        guard let morph else {return p}
        // Invert the composed smooth field rather than negating the forward displacements.
        for _ in 0..<5 {
            let d=morph.displacement(p),next=inverse.apply(Point(target.x-d.x,target.y-d.y))
            if p.distance(next)<0.0001 {return next};p=next
        }
        return p
    }
    /// First-order short-interval prediction in EXIF time. Only initializes matching;
    /// the new image must independently pass correspondence and holdout checks.
    public func extrapolate(from previous: Alignment, factor: Double) -> Alignment {
        guard factor.isFinite,abs(factor)<=10 else{return self}
        var result=self
        let a=transform.m.map{$0/transform.m[8]},b=previous.transform.m.map{$0/previous.transform.m[8]}
        result=Alignment(transform:Homography(zip(a,b).map{$0+factor*($0-$1)}),matches:[],medianError:0,p95Error:0,validationMedianError:0,validationP95Error:0,morph:morph)
        if let p=morph,let q=previous.morph {
            result.morph=ResidualMorph(x:zip(p.x,q.x).map{$0+factor*($0-$1)},y:zip(p.y,q.y).map{$0+factor*($0-$1)},scale:p.scale)
        }
        return result
    }
    public func resized(by scale:Double)->Alignment {
        let shrink=Homography([scale,0,(scale-1)/2,0,scale,(scale-1)/2,0,0,1])
        let expand=try! shrink.inverted()
        let h=expand.followed(by:transform).followed(by:shrink)
        // The residual polynomial coordinates stay in analysis pixels; transform them
        // explicitly by retaining a small input coordinate offset in the field.
        var field=morph
        if let m=morph {field=ResidualMorph(x:m.x.map{$0*scale},y:m.y.map{$0*scale},scale:m.scale*scale,
            inputOffset:(m.inputOffset ?? 0)*scale+(1-scale)/2)}
        return Alignment(transform:h,matches:matches.map{Match(source:shrink.apply($0.source),reference:shrink.apply($0.reference))},
            medianError:medianError*scale,p95Error:p95Error*scale,validationMedianError:validationMedianError*scale,
            validationP95Error:validationP95Error*scale,morph:field)
    }
}

/// Low-degree residual field for lens distortion left after the projective sky warp.
/// Enabled only when withheld stars improve; never an independent warp around each star.
public struct ResidualMorph: Codable {
    public let x: [Double]
    public let y: [Double]
    public let scale: Double
    public var inputOffset:Double? = nil
    static func basis(_ p: Point,_ scale: Double)->[Double] {
        let x=p.x/scale-0.5,y=p.y/scale-0.35
        return [1,x,y,x*x,x*y,y*y,x*x*x,x*x*y,x*y*y,y*y*y]
    }
    public func displacement(_ p: Point)->Point {
        let u=(p.x+(inputOffset ?? 0))/scale-0.5,v=(p.y+(inputOffset ?? 0))/scale-0.35
        func polynomial(_ a:[Double])->Double {
            a[0]+u*(a[1]+u*(a[3]+u*a[6])+v*(a[4]+u*a[7]+v*a[8]))+v*(a[2]+v*(a[5]+v*a[9]))
        }
        return Point(polynomial(x),polynomial(y))
    }
    static func fit(_ pairs:[Match],base:Homography,scale:Double)->ResidualMorph? {
        guard pairs.count>=60 else{return nil}
        var rows=pairs.map{basis($0.source,scale)},vx=[Double](),vy=[Double]()
        for p in pairs {let q=base.apply(p.source);vx.append(p.reference.x-q.x);vy.append(p.reference.y-q.y)}
        // Ridge on high-order coefficients discourages excessive curvature outside observed stars.
        for i in 0..<10 {var row=[Double](repeating:0,count:10);row[i]=i>=6 ? 0.02 : 0.001;rows.append(row);vx.append(0);vy.append(0)}
        guard let x=solve(rows,vx,count:10),let y=solve(rows,vy,count:10) else{return nil}
        let m=ResidualMorph(x:x,y:y,scale:scale)
        for yy in 0...6 {for xx in 0...10 {
            if m.displacement(Point(Double(xx)*scale/10,Double(yy)*scale/10)).distance(Point(0,0))>scale*0.04 {return nil}
        }}
        return m
    }
}

/// Pivoted elimination for the small normalized least-squares systems used here.
func solve(_ rows: [[Double]], _ values: [Double], count n: Int) -> [Double]? {
    var a=Array(repeating:[Double](repeating:0,count:n+1),count:n)
    for (row,v) in zip(rows,values) { for i in 0..<n {
        for j in 0..<n { a[i][j]+=row[i]*row[j] }; a[i][n]+=row[i]*v
    } }
    for i in 0..<n {
        let pivot=(i..<n).max { abs(a[$0][i])<abs(a[$1][i]) }!
        guard abs(a[pivot][i])>1e-10 else { return nil }; a.swapAt(i,pivot)
        let div=a[i][i]; for j in i...n { a[i][j]/=div }
        for k in 0..<n where k != i { let f=a[k][i]; for j in i...n { a[k][j]-=f*a[i][j] } }
    }
    let result=a.map{$0[n]}; return result.allSatisfy(\.isFinite) ? result : nil
}
public enum Registration {
    public static func fit(_ pairs: [Match], scale: Double) -> Homography? {
        guard pairs.count>=4 else { return nil }
        var rows=[[Double]](),v=[Double]()
        for p in pairs {
            let x=p.source.x/scale,y=p.source.y/scale,u=p.reference.x/scale,w=p.reference.y/scale
            rows.append([x,y,1,0,0,0,-u*x,-u*y]); v.append(u)
            rows.append([0,0,0,x,y,1,-w*x,-w*y]); v.append(w)
        }
        guard let a=solve(rows,v,count:8) else { return nil }
        return Homography([a[0],a[1],a[2]*scale,a[3],a[4],a[5]*scale,a[6]/scale,a[7]/scale,1])
    }
    struct Triangle {
        let vertices: [Point]
        let r1: Double; let r2: Double
    }
    static func triangles(_ stars: [Star]) -> [Triangle] {
        let points=Array(stars.prefix(90)).map(\.point)
        var result=[Triangle](),seen=Set<String>()
        for i in points.indices {
            let near=points.indices.filter{$0 != i}.sorted{points[i].distance(points[$0])<points[i].distance(points[$1])}.prefix(7)
            let a=Array(near)
            for j in 0..<a.count { for k in j+1..<a.count {
                let ids=[i,a[j],a[k]].sorted(),key=ids.map(String.init).joined(separator:",")
                if !seen.insert(key).inserted { continue }
                let p=ids.map{points[$0]}
                let sides=[p[1].distance(p[2]),p[0].distance(p[2]),p[0].distance(p[1])]
                let order=[0,1,2].sorted{sides[$0]<sides[$1]},long=sides[order[2]]
                let area=abs((p[1].x-p[0].x)*(p[2].y-p[0].y)-(p[1].y-p[0].y)*(p[2].x-p[0].x))
                if long<15 || area/(long*long)<0.08 { continue }
                result.append(Triangle(vertices:order.map{p[$0]},r1:sides[order[0]]/long,r2:sides[order[1]]/long))
            } }
        }
        return result
    }
    static func similarity(_ a: [Point], _ b: [Point]) -> Homography? {
        var rows=[[Double]](),v=[Double]()
        for (p,q) in zip(a,b) { rows.append([p.x,-p.y,1,0]);v.append(q.x);rows.append([p.y,p.x,0,1]);v.append(q.y) }
        guard let s=solve(rows,v,count:4) else { return nil }
        let scale=hypot(s[0],s[1]); guard scale>0.8,scale<1.25 else { return nil }
        return Homography([s[0],-s[1],s[2],s[1],s[0],s[3],0,0,1])
    }
    static func matches(_ source: [Star], _ reference: [Star], _ warp: (Point)->Point, radius: Double) -> [Match] {
        var candidates=[(Int,Int,Double)]()
        for (i,s) in source.enumerated() {
            let p=warp(s.point); var best=radius,jbest: Int?
            for (j,r) in reference.enumerated() { let d=p.distance(r.point); if d<best { best=d; jbest=j } }
            if let j=jbest { candidates.append((i,j,best)) }
        }
        var used=Set<Int>(),pairs=[Match]()
        for c in candidates.sorted(by:{$0.2<$1.2}) where used.insert(c.1).inserted {
            pairs.append(Match(source:source[c.0].point,reference:reference[c.1].point))
        }
        return pairs
    }
    public static func align(source: [Star], reference: [Star], width: Int, initial: Alignment?=nil) throws -> Alignment {
        guard source.count>=12,reference.count>=12 else { throw StackError("Too few stars (\(source.count), \(reference.count))") }
        var best=Homography(),bestPairs=[Match]()
        if let initial { best=initial.transform; bestPairs=matches(source,reference,initial.apply,radius:5) }
        if bestPairs.count<max(25,min(source.count,reference.count)/3) {
            let rt=triangles(reference),st=triangles(source)
            var buckets=[Int:[Triangle]]()
            func key(_ x: Int,_ y: Int)->Int {x*200+y}
            for t in rt { buckets[key(Int(t.r1*100),Int(t.r2*100)),default:[]].append(t) }
            let ss=Array(source.prefix(120)),rr=Array(reference.prefix(200))
            outer: for t in st {
                let x=Int(t.r1*100),y=Int(t.r2*100)
                for dx in -1...1 { for dy in -1...1 {
                    for r in buckets[key(x+dx,y+dy),default:[]] {
                        guard abs(t.r1-r.r1)<0.008,abs(t.r2-r.r2)<0.008,
                              let h=similarity(t.vertices,r.vertices) else { continue }
                        let pairs=matches(ss,rr,h.apply,radius:3)
                        if pairs.count>bestPairs.count { bestPairs=pairs; best=h }
                        if bestPairs.count>=min(70,ss.count*2/3) { break outer }
                    }
                } }
            }
        }
        guard bestPairs.count>=12 else { throw StackError("No trustworthy star-pattern match (\(bestPairs.count) inliers)") }
        // Grow correspondences and robustly refit; initial similarity is only a bootstrap.
        var pairs=bestPairs.count>100 ? bestPairs : matches(source,reference,best.apply,radius:5)
        var residual:ResidualMorph?
        for _ in 0..<5 {
            let errors=pairs.map { pair -> Double in
                let p=best.apply(pair.source),d=residual?.displacement(pair.source) ?? Point(0,0)
                return Point(p.x+d.x,p.y+d.y).distance(pair.reference)
            },m=median(errors)
            let threshold=max(1.2,min(5,m*3))
            let filtered=zip(pairs,errors).filter{$0.1<threshold}.map(\.0)
            guard let fit=fit(filtered,scale:Double(width)) else { break }; best=fit
            residual=ResidualMorph.fit(filtered,base:best,scale:Double(width))
            pairs=matches(source,reference,{p in
                let q=best.apply(p),d=residual?.displacement(p) ?? Point(0,0);return Point(q.x+d.x,q.y+d.y)
            },radius:2.5)
        }
        // Do not reintroduce the last nearest-neighbour search's loose outliers into the
        // final fit. In particular faint noise peaks can fall within the search radius.
        let finalResiduals=pairs.map {pair -> Double in
            let q=best.apply(pair.source),d=residual?.displacement(pair.source) ?? Point(0,0)
            return Point(q.x+d.x,q.y+d.y).distance(pair.reference)
        }
        let center=median(finalResiduals),spread=1.4826*median(finalResiduals.map{abs($0-center)})
        let cutoff=max(0.6,min(1.5,center+3*spread))
        pairs=zip(pairs,finalResiduals).filter{$0.1<cutoff}.map(\.0)
        guard pairs.count>=12 else { throw StackError("Insufficient projective inliers") }
        // Deterministic spatially distributed holdout, excluded from the validation fit.
        pairs.sort { $0.source.y == $1.source.y ? $0.source.x<$1.source.x : $0.source.y<$1.source.y }
        let train=pairs.enumerated().filter{$0.offset%4 != 0}.map(\.element)
        let held=pairs.enumerated().filter{$0.offset%4 == 0}.map(\.element)
        guard let validation=fit(train,scale:Double(width)),let final=fit(pairs,scale:Double(width)) else { throw StackError("Degenerate star geometry") }
        var errors=pairs.map{final.apply($0.source).distance($0.reference)}.sorted()
        var validationErrors=held.map{validation.apply($0.source).distance($0.reference)}.sorted()
        func p95(_ x:[Double])->Double {x[min(x.count-1,Int(Double(x.count)*0.95))]}
        var selectedMorph:ResidualMorph?
        if let validationMorph=ResidualMorph.fit(train,base:validation,scale:Double(width)),
           let finalMorph=ResidualMorph.fit(pairs,base:final,scale:Double(width)) {
            let candidateErrors=held.map {pair -> Double in
                let p=validation.apply(pair.source),d=validationMorph.displacement(pair.source)
                return Point(p.x+d.x,p.y+d.y).distance(pair.reference)
            }.sorted()
            if p95(candidateErrors)<p95(validationErrors)*0.85 && median(candidateErrors)<median(validationErrors)*0.9 {
                selectedMorph=finalMorph;validationErrors=candidateErrors
                errors=pairs.map {pair in
                    let p=final.apply(pair.source),d=finalMorph.displacement(pair.source)
                    return Point(p.x+d.x,p.y+d.y).distance(pair.reference)
                }.sorted()
            }
        }
        guard p95(validationErrors)<2.5 else { throw StackError("Held-out star residual too high: \(p95(validationErrors)) pixels") }
        return Alignment(transform:final,matches:pairs,medianError:median(errors),p95Error:p95(errors),
                         validationMedianError:median(validationErrors),validationP95Error:p95(validationErrors),morph:selectedMorph)
    }
}
