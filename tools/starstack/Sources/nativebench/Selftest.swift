import Foundation
import StarStackCore

func selftest(_ root:URL)throws {
    let gpu=try MetalBench(),n=7,count=64
    var cube=[Float](repeating:0,count:n*count*4),ref=[Float](repeating:0.9,count:n*4)
    let mask:[Float]=[1,1,1,0,0.5,1,1],expected:[Float]=[0.2,0.2,0.9,0.9,0.55,0,-0.1]
    for k in 0..<n{ref[k*4+3]=1}
    for i in 0..<count {for k in 0..<n {
        let value:Float=k==1 && i==63 ? 10 : k==5 ? 0 : k==6 ? -0.1 : 0.2
        let j=(i*n+k)*4;for c in 0..<3{cube[j+c]=value};cube[j+3]=k==2 && i>=2 ? 0 : 1
    }}
    let output=try gpu.buffer(n*16)
    try gpu.dispatch("fuse",[try gpu.buffer(cube),output,try gpu.buffer(mask),try gpu.buffer(ref)],bytes([UInt32(n),UInt32(count)]),n)
    let result=floats(output,n*4)
    for k in 0..<n {for c in 0..<3{guard abs(result[k*4+c]-expected[k])<1e-6 else{throw StackError("Synthetic fusion case \(k) failed")}}}
    let w=64,h=48
    var pixels=[Float](repeating:1,count:w*h*4)
    for y in 0..<h{for x in 0..<w {let j=(y*w+x)*4;pixels[j]=Float(x)/64;pixels[j+1]=Float(y)/48;pixels[j+2]=Float((x*7+y*3)%11)/11}}
    let fixture:[String:Any]=["transform":["m":[1.0001,-0.006,0.8,0.004,0.999,-0.3,0.00003,-0.00001,1]],"matches":[],"medianError":0,"p95Error":0,"validationMedianError":0,"validationP95Error":0,
        "morph":["x":[0.4,0.3,0.2,0.6,0.1,0.3,0.2,0.1,0.05,0.1],"y":[-0.2,0.2,0.1,0.3,0.2,-0.1,0.1,0.2,0.1,0.2],"scale":64,"inputOffset":0.25]]
    let a=try JSONDecoder().decode(Alignment.self,from:JSONSerialization.data(withJSONObject:fixture)),inv=try a.transform.inverted()
    var p=[Float(w),Float(h)]+inv.m.map(Float.init);p += [64,0.25];p += a.morph!.x.map(Float.init);p += a.morph!.y.map(Float.init)
    let warped=try gpu.buffer(w*h*16)
    try gpu.dispatch("warp",[try gpu.buffer(pixels),warped,try gpu.buffer([Float](repeating:1,count:w*h))],bytes(p),w*h)
    let got=floats(warped,w*h*4),source=Frame(width:w,height:h,pixels:pixels)
    var maxError:Float=0
    for y in 0..<h {for x in 0..<w {
        let q=a.sourcePoint(Point(Double(x),Double(y)),inverse:inv),v=source.sample(q.x,q.y),k=y*w+x
        guard got[4*k+3]==(v==nil ? 0 : 1) else{throw StackError("Synthetic cubic validity failed")}
        if let v {for c in 0..<3{maxError=max(maxError,abs(got[4*k+c]-v[c]))}}
    }}
    guard maxError<0.00005 else{throw StackError("Synthetic cubic warp parity failed: \(maxError)")}
    let report:[String:Any]=["passed":true,"fusion_cases":7,"temporal_frames":64,"cubic_warp_max_error":maxError,"device":gpu.device.name]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("selftest.json"))
    log("Synthetic Metal tests passed: \(report)")
}
