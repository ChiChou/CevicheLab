// Apple RAW preview timing at Ceviche's 2200px preview size. Not the entire editor graph.
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Metal
func now()->Double {Double(DispatchTime.now().uptimeNanoseconds)/1e9}
let args=CommandLine.arguments
let device=MTLCreateSystemDefaultDevice()!
let context=CIContext(mtlDevice:device,options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,
    .workingFormat:CIFormat.RGBAf,.cacheIntermediates:true])
let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
var results=[[String:Any]]()
for path in args.dropFirst(2) {
    autoreleasepool {
        let url=URL(fileURLWithPath:path),start=now()
        guard let raw=CIRAWFilter(imageURL:url) else {fatalError("Apple RAW open failed")}
        let opened=now()-start
        raw.scaleFactor=Float(2200/max(raw.nativeSize.width,raw.nativeSize.height))
        raw.boostAmount=1;raw.extendedDynamicRangeAmount=0
        if raw.isLuminanceNoiseReductionSupported {raw.luminanceNoiseReductionAmount=0}
        if raw.isColorNoiseReductionSupported {raw.colorNoiseReductionAmount=0}
        var timings=[Double](),sizes=[[Int]]()
        for ev:Float in [0,0.1,0.2,0.3] {
            let start=now();raw.exposure=ev
            let image=raw.outputImage!
            guard let cg=context.createCGImage(image,from:image.extent,format:.RGBA16,colorSpace:srgb) else {fatalError("Render failed")}
            // Force realization of the pixel data before stopping the timer.
            guard let data=cg.dataProvider?.data,CFDataGetLength(data)>0 else {fatalError("No pixels")}
            timings.append(now()-start);sizes.append([cg.width,cg.height])
        }
        let row:[String:Any]=["file":url.lastPathComponent,"openSeconds":opened,"rendersSeconds":timings,"dimensions":sizes,
            "scope":"CIRAWFilter + CIContext, 2200px, exposure changes. Excludes Ceviche masks/looks/histogram/UI."]
        results.append(row);print(row);fflush(stdout)
    }
}
try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[1]))
