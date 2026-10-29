import Foundation
import CoreML
import CoreImage

public final class SkySegmenter {
    let model: MLModel
    public init(modelURL: URL) throws {
        let config=MLModelConfiguration();config.computeUnits = .cpuAndGPU
        model=try MLModel(contentsOf:modelURL,configuration:config)
        guard model.modelDescription.inputDescriptionsByName["modelInput"]?.multiArrayConstraint?.shape == [1,3,384,384] else {
            throw StackError("Expected Ceviche SkyRemoval Core ML model, NCHW 384×384")
        }
    }
    public func mask(_ frame: Frame, imaging: Imaging, conservative:Bool=true, normalizeForNight:Bool=true) throws -> [Float] {
        // Brightness normalization only for segmentation. Fusion always sees original linear samples.
        let values=frame.luminance.enumerated().filter{$0.offset%31==0}.map{Double(max(0,$0.element))}
        let level=max(1e-6,median(values)),ev=log2(0.12/level)
        let image=imaging.image(frame).applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:normalizeForNight ? min(5,max(-2,ev)) : 0])
        guard let cg=imaging.context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:Imaging.sRGB) else {
            throw StackError("Sky model color conversion failed")
        }
        let input=CIImage(cgImage:cg,options:[.colorSpace:NSNull()])
            .transformed(by:CGAffineTransform(scaleX:384/Double(frame.width),y:384/Double(frame.height)))
        var rgb=[Float](repeating:0,count:384*384*4)
        rgb.withUnsafeMutableBytes { imaging.context.render(input,toBitmap:$0.baseAddress!,rowBytes:384*16,
            bounds:CGRect(x:0,y:0,width:384,height:384),format:.RGBAf,colorSpace:nil) }
        var planes=[Float](repeating:0,count:384*384*3)
        for c in 0..<3 { for i in 0..<384*384 { planes[c*384*384+i]=max(0,min(1,rgb[4*i+c])) } }
        let array=MLMultiArray(MLShapedArray(scalars:planes,shape:[1,3,384,384]))
        let output=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["modelInput":array]))
        guard let values=output.featureValue(for:"modelOutput")?.multiArrayValue else { throw StackError("Sky model output missing") }
        let small=MLShapedArray<Float>(converting:values).scalars
        guard small.count==384*384 else { throw StackError("Invalid sky mask dimensions") }
        var mask=[Float](repeating:0,count:frame.width*frame.height)
        for y in 0..<frame.height { for x in 0..<frame.width {
            let sx=min(383,Double(x)*384/Double(frame.width)),sy=min(383,Double(y)*384/Double(frame.height))
            let ix=Int(sx),iy=Int(sy),fx=Float(sx-Double(ix)),fy=Float(sy-Double(iy)),jx=min(383,ix+1),jy=min(383,iy+1)
            mask[y*frame.width+x]=(small[iy*384+ix]*(1-fx)+small[iy*384+jx]*fx)*(1-fy)+(small[jy*384+ix]*(1-fx)+small[jy*384+jx]*fx)*fy
        } }
        // Network confidence is not optical transparency. A 0.98 threshold punches false
        // holes in real sky and makes confidence-grid edges resemble transient streaks.
        let binary=mask.map { Float($0>=0.5 ? 1 : 0) }
        // Static-camera maximum previews do not need the broad uncertainty band
        // required when stellar warps pull samples across the skyline.
        if !conservative { return mask }
        // The 384px model cannot resolve a lit skyline or thin trees. Retain the reference
        // in a scale-aware uncertainty band rather than warp possible ground into the sky.
        let radius=max(6,Int(Double(frame.width)*0.025))
        let support=boxBlur(binary,width:frame.width,height:frame.height,radius:radius)
        let interior=support.map { Float($0>0.9999 ? 1 : 0) }
        return boxBlur(interior,width:frame.width,height:frame.height,radius:max(2,radius/4))
    }
}

public func maskValue(_ mask: [Float], width: Int, height: Int, point: Point) -> Float {
    guard point.x>=0,point.y>=0,point.x<Double(width),point.y<Double(height) else { return 0 }
    return mask[Int(point.y)*width+Int(point.x)]
}
