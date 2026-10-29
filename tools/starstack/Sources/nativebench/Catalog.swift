import Foundation
import simd
import StarStackCore

// Experimental native subset of tetra3's edge-ratio database search.
// Hash/database conventions and pinhole/distortion equations adapted from
// esa/tetra3 f9fa2eb9a32a5efc529e2d86f0b59f35b1e9028d, Apache-2.0.
// Copyright 2019 the European Space Agency. Original Tetra: (c) 2016 brownj4.
// Modifications: Swift implementation, polar rotation fit, bounded heuristic
// search, verification-pool checks and separate Metal projection benchmark.
// See ThirdParty/tetra3-LICENSE.txt, including the original Tetra notice.
// Search/refinement below is simplified: no upstream probability calculation,
// automatic database generation, target coordinates, or uncertainty estimation.
struct CatalogInput:Decodable {
    let width:Int,height:Int,centroids:[[Double]],fov_estimate_degrees:Double,pattern_rows:Int,star_count:Int
    let timeout_seconds:Double?
}
func angular(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->Double {2*asin(min(1,simd_length(a-b)/2))}
func edges(_ v:[SIMD3<Double>])->[Double] {
    var e=[Double]();for i in 0..<3{for j in i+1..<4{e.append(angular(v[i],v[j]))}};return e.sorted()
}
func binomialTail(_ n:Int,_ minimum:Int,_ p:Double)->Double {
    guard minimum>0 else{return 1};guard minimum<=n,p>0,p<1 else{return 0}
    var term=pow(1-p,Double(n)),sum=0.0
    for k in 0...n {if k>=minimum{sum+=term};if k<n{term*=Double(n-k)/Double(k+1)*p/(1-p)}}
    return min(1,sum)
}
func rotation(_ a:[SIMD3<Double>],_ b:[SIMD3<Double>])->simd_double3x3? {
    var m=simd_double3x3(0)
    for (x,y) in zip(a,b){for c in 0..<3{m[c]+=y*x[c]}}
    guard simd_determinant(m)>1e-15 else{return nil}
    // Polar decomposition gives the least-squares proper rotation for this case.
    for _ in 0..<24{m=(m+simd_transpose(simd_inverse(m)))*0.5}
    guard abs(simd_determinant(m)-1)<1e-6 else{return nil};return m
}
func catalogSolve(_ root:URL)throws {
    let dir=root.appendingPathComponent("catalog-fixture"),out=root.appendingPathComponent("native-catalog")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let input=try JSONDecoder().decode(CatalogInput.self,from:Data(contentsOf:dir.appendingPathComponent("input.json")))
    let catalog=try readFloats(dir.appendingPathComponent("vectors.f32"),input.star_count*3)
    let world=(0..<input.star_count).map{SIMD3<Double>(Double(catalog[$0*3]),Double(catalog[$0*3+1]),Double(catalog[$0*3+2]))}
    let data=try Data(contentsOf:dir.appendingPathComponent("patterns.u16"),options:.mappedIfSafe)
    guard data.count==input.pattern_rows*8,input.centroids.count>=15 else{throw StackError("Catalog fixture mismatch")}
    let patterns=data.withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}
    let start=seconds(),fov0=input.fov_estimate_degrees * .pi/180,w=Double(input.width),h=Double(input.height)
    func vectors(_ fov:Double,_ k:Double)->[SIMD3<Double>] {
        input.centroids.map {p in
            let x=p[1]-w/2,y=p[0]-h/2,scale=(1-k*(x*x+y*y)*4/(w*w))/(1-k),f=2*tan(fov/2)/w
            return simd_normalize(SIMD3(1,-x*scale*f,-y*scale*f))
        }
    }
    var tested=0,bestCount=0
    var answer:[String:Any]=["solved":false]
    search: for distortion in [0.0,-0.05,0.05,-0.1,0.1,-0.15,0.15] {
        let observed=vectors(fov0,distortion)
        for a in 0..<12 {for b in a+1..<13 {for c in b+1..<14 {for d in c+1..<15 {
            if seconds()-start>(input.timeout_seconds ?? 45){break search}
            let ids=[a,b,c,d],ie=edges(ids.map{observed[$0]}),ratios=ie.prefix(5).map{$0/ie[5]}
            var keys:[[Int]]=[[]]
            for ratio in ratios {
                let lo=max(0,Int((ratio-0.006)*50)),hi=min(50,Int((ratio+0.006)*50))
                keys=keys.flatMap{key in (lo...hi).map{key+[$0]}}
            }
            var seen=Set<Int>()
            for key in keys {
                var value:UInt64=0,mult:UInt64=1
                for q in key.sorted(){value+=UInt64(q)*mult;mult*=50}
                let hash=Int((value &* 2654435761)%UInt64(input.pattern_rows))
                guard seen.insert(hash).inserted else{continue}
                var probe=0
                while probe<input.pattern_rows {
                    let row=(hash+probe*probe)%input.pattern_rows;probe+=1
                    let ci=(0..<4).map{Int(patterns[row*4+$0])}
                    if ci.allSatisfy({$0==0}){break}
                    let cv=ci.map{world[$0]},ce=edges(cv)
                    guard zip(ratios,ce.prefix(5)).allSatisfy({abs($0-$1/ce[5])<0.006}) else{continue}
                    let fov=fov0*ce[5]/ie[5]
                    guard abs(fov-fov0)<8 * .pi/180 else{continue}
                    let all=vectors(fov,distortion),iv=ids.map{all[$0]},center=iv.reduce(SIMD3<Double>(repeating:0),+)/4
                    let order=(0..<4).sorted{simd_distance(iv[$0],center)<simd_distance(iv[$1],center)}
                    guard let r=rotation(order.map{iv[$0]},cv) else{continue};tested+=1
                    let forward=r[0],f=w/(2*tan(fov/2))
                    // Database is magnitude sorted. Match the brightest in-field
                    // catalog stars, rather than allowing every faint neighbor.
                    let near=Array(world.indices.filter {
                        let v=world[$0];guard simd_dot(v,forward)>cos(fov*0.8) else{return false}
                        let q=simd_transpose(r)*v,x=w/2-f*q.y/q.x,y=h/2-f*q.z/q.x
                        return q.x>0 && x>0 && y>0 && x<w && y<h
                    }.prefix(all.count))
                    var used=Set<Int>(),matches=[(Int,Int,Double)]()
                    for (j,v) in all.enumerated() {
                        let predicted=r*v;var best=3.0*fov/w,idx:Int?
                        for q in near where !used.contains(q){let err=angular(predicted,world[q]);if err<best{best=err;idx=q}}
                        if let idx{matches.append((j,idx,best*w/fov));used.insert(idx)}
                    }
                    if matches.count>bestCount{bestCount=matches.count;log("Native catalog: \(bestCount) matches, \(tested) candidates")}
                    let heldout=matches.filter{$0.0>=15}.count
                    // tetra3's binomial mismatch approximation, corrected by its
                    // database pattern count. Not a calibrated real-world probability.
                    let mismatch=binomialTail(all.count,matches.count-2,Double(near.count)*pow(3/w,2))*Double(input.pattern_rows/2)
                    guard matches.count>=10,heldout>=6,mismatch<0.001,let refined=rotation(matches.map{all[$0.0]},matches.map{world[$0.1]}) else{continue}
                    let errors=matches.map{angular(refined*all[$0.0],world[$0.1])*w/fov}
                    guard median(errors)<1.5 else{continue}
                    let axis=refined[0],ra=(atan2(axis.y,axis.x)*180 / .pi+360).truncatingRemainder(dividingBy:360),dec=asin(axis.z)*180 / .pi
                    answer=["solved":true,"ra_degrees":ra,"dec_degrees":dec,"fov_degrees":fov*180 / .pi,"distortion_grid_value":distortion,
                        "matches":matches.count,"verification_matches_outside_pattern_pool":heldout,"approximate_corrected_mismatch":mismatch,"median_error_px":median(errors),"rms_error_px":sqrt(errors.map{$0*$0}.reduce(0,+)/Double(errors.count)),
                        "matched_centroids":matches.map{input.centroids[$0.0]},"catalog_indices":matches.map{$0.1},"rotation_columns":(0..<3).map{[refined[$0].x,refined[$0].y,refined[$0].z]}]
                    break search
                }
            }
        }}}}
    }
    answer["search_seconds"]=seconds()-start;answer["candidate_rotations_tested"]=tested;answer["best_match_count"]=bestCount
    if let columns=answer["rotation_columns"] as? [[Double]],let fov=answer["fov_degrees"] as? Double {
        answer["metal_projection"]=try catalogProjection(world,columns,w,h,fov)
    }
    answer["scope"]="Native blind pattern search from unsolved tetra3 centroids and its database. No solved attitude/IDs supplied; CPU search and polar rotation fit, fixed distortion grid, at least 10 matches, 6 outside search pool, database-corrected binomial mismatch approximation below .001. Simplified experimental solver; not full tetra3 refinement."
    try JSONSerialization.data(withJSONObject:answer,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
    log("Native catalog result: \(answer)")
}

func catalogProjection(_ world:[SIMD3<Double>],_ columns:[[Double]],_ w:Double,_ h:Double,_ fov:Double)throws->[String:Any] {
    let gpu=try MetalBench(),f=w/(2*tan(fov * .pi/360)),n=world.count
    let packed=world.flatMap{[Float($0.x),Float($0.y),Float($0.z),Float(0)]},src=try gpu.buffer(packed),dst=try gpu.buffer(n*8)
    let p=[Float(n),Float(w),Float(h),Float(f)]+columns.flatMap{$0.map(Float.init)}
    var times=[Double]();for _ in 0..<3{times.append(try gpu.dispatch("catalog_project",[src,dst],bytes(p),n))}
    let result=floats(dst,n*2),start=seconds()
    let axes=columns.map{SIMD3<Float>(Float($0[0]),Float($0[1]),Float($0[2]))}
    var expected=[Float](repeating:-1,count:n*2)
    for i in world.indices {
        let v=SIMD3<Float>(Float(world[i].x),Float(world[i].y),Float(world[i].z)),z=simd_dot(v,axes[0])
        if z<=0{continue};let x=Float(w/2)-Float(f)*simd_dot(v,axes[1])/z,y=Float(h/2)-Float(f)*simd_dot(v,axes[2])/z
        if x>=0,y>=0,x<Float(w),y<Float(h){expected[2*i]=x;expected[2*i+1]=y}
    }
    let cpuTime=seconds()-start,maxError=zip(expected,result).map{abs($0-$1)}.max()!
    guard maxError<0.001 else{throw StackError("Catalog projection parity: \(maxError)")}
    return ["stars":n,"max_pixel_error":maxError,"cpu_seconds":cpuTime,"metal_dispatch_wait_seconds":times,"scope":"Project full catalog into solved crop, without distortion; separate parity microbenchmark, search verification remains CPU"]
}
