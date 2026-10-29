import XCTest
import CoreImage
import Metal
@testable import UnpurpleCore

final class CoreImageTests: XCTestCase {
    let space=CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    func context() throws -> CIContext {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice:device,options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
    }
    func image(_ pixels:[Float],width:Int,height:Int) -> CIImage {
        let data=pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
    }
    func read(_ image:CIImage,_ context:CIContext,bounds:CGRect?=nil) -> [Float] {
        let r=bounds ?? image.extent
        var out=[Float](repeating:0,count:Int(r.width*r.height)*4)
        out.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:Int(r.width)*16,bounds:r,format:.RGBAf,colorSpace:space) }
        return out
    }
    func assertClose(_ a:[Float],_ b:[Float],accuracy:Float=0.00005,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(a.count,b.count,file:file,line:line)
        let delta=zip(a,b).map { abs($0-$1) }.max() ?? 0
        XCTAssertLessThanOrEqual(delta,accuracy,file:file,line:line)
        XCTAssertTrue(a.allSatisfy(\.isFinite),file:file,line:line)
    }
    // Independent continuous Double-precision reference for the extended-sRGB algorithm.
    func reference(_ pixels:[Float],width:Int,height:Int,p:Parameters) -> [Float] {
        func encode(_ x:Double)->Double { x<=0.0031308 ? 12.92*x : 1.055*pow(x,1/2.4)-0.055 }
        func decode(_ x:Double)->Double { x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
        var mask=[Double](repeating:0,count:width*height)
        for i in mask.indices {
            let a=Double(pixels[4*i+3]); if a<=0 { continue }
            let c=(0..<3).map { Double(pixels[4*i+$0])/a }
            if c.min()!<0 { continue }
            mask[i]=p.intensity*max(0,encode(c[2])-p.minBrightness)/(1-p.minBrightness)*a
        }
        for horizontal in [true,false,true,false] {
            let previous=mask
            for y in 0..<height { for x in 0..<width {
                var sum=0.0
                for t in -p.boxRadius...p.boxRadius {
                    let xx=min(width-1,max(0,x+(horizontal ? t : 0)))
                    let yy=min(height-1,max(0,y+(horizontal ? 0 : t)))
                    sum+=previous[yy*width+xx]
                }
                mask[y*width+x]=sum/Double(2*p.boxRadius+1)
            } }
        }
        var result=pixels
        for i in mask.indices {
            let a=Double(pixels[4*i+3]); if a<=0 { continue }
            let c=(0..<3).map { Double(pixels[4*i+$0])/a }
            if c.min()!<0 { continue }
            let encoded=c.map(encode)
            let mb=min(mask[i],max(encoded[2]-encoded[1],0))
            let dr=min(max(encoded[0]-encoded[1],0),mb*p.maxRed)
            let db=p.minRed>0 ? min(mb,dr/p.minRed) : mb
            if dr>0 { result[4*i]=Float(decode(encoded[0]-dr)*a) }
            if db>0 { result[4*i+2]=Float(decode(encoded[2]-db)*a) }
        }
        return result
    }
    func testContinuousReferenceIncludingHDRAndAlpha() throws {
        let ctx=try context(),w=19,h=7
        let pixels=(0..<(w*h)).flatMap { i -> [Float] in
            let alpha:Float=i%7==0 ? 0 : i%5==0 ? 0.25 : 1
            return [Float(i%11)*0.27*alpha,Float(i%3)*0.113*alpha,Float(i%13)*0.41*alpha,alpha]
        }
        let source=image(pixels,width:w,height:h)
        let input=read(source,ctx)
        for threshold in [0.0,0.8] {
            var p=Parameters();p.minBrightness=threshold;p.minRed=0.15;p.radius=9
            let output=read(try CoreImageProcessor.apply(source,parameters:p),ctx)
            assertClose(output,reference(input,width:w,height:h,p:p))
            for i in stride(from:0,to:output.count,by:4) {
                XCTAssertEqual(output[i+1],input[i+1],accuracy:0.000001)
                XCTAssertEqual(output[i+3],input[i+3],accuracy:0.000001)
            }
        }
    }
    func testNoClippingQuantizationOrNegativeColorChanges() throws {
        let ctx=try context()
        let pixels:[Float]=[4,4,4,1, -0.1,0.2,0.8,1, 0.123456,0.2,0.1,1, 3,0.4,5,1]
        let source=image(pixels,width:4,height:1)
        var p=Parameters();p.minRed=0.15
        let output=read(try CoreImageProcessor.apply(source,parameters:p),ctx)
        assertClose(output,reference(read(source,ctx),width:4,height:1,p:p))
        assertClose(Array(output.prefix(12)),Array(pixels.prefix(12)),accuracy:0.000001)
        XCTAssertGreaterThan(output[12],1)
        XCTAssertLessThan(output[14],5)
        p.intensity=0
        XCTAssertTrue(try CoreImageProcessor.apply(source,parameters:p) === source)
    }
    func testCropROITranslationAndFractionalScale() throws {
        let ctx=try context(),w=73,h=41
        let pixels=(0..<(w*h)).flatMap { i -> [Float] in
            [Float(i%17)*0.07,Float(i%7)*0.03,Float(i%23)*0.08,1]
        }
        let source=image(pixels,width:w,height:h)
        let p=Parameters(),rect=CGRect(x:31,y:17,width:11,height:9)
        for scale in [1.0,0.275] {
            let output=try CoreImageProcessor.apply(source,parameters:p,scale:scale)
            let full=read(output,ctx)
            // Bitmap row zero is at the top; Core Image's y axis starts at the bottom.
            let expected=((h-26)..<(h-17)).flatMap { y in Array(full[(y*w+31)*4..<(y*w+42)*4]) }
            assertClose(read(output,ctx,bounds:rect),expected)
            let offset=CGAffineTransform(translationX:103,y:-29)
            let translated=try CoreImageProcessor.apply(source.transformed(by:offset),parameters:p,scale:scale)
            assertClose(read(translated,ctx,bounds:rect.applying(offset)),expected)
        }
    }
    func testPreviewScaleAndGentlePurpleProtection() throws {
        let ctx=try context(),w=128,h=64
        let pixels=(0..<(w*h)).flatMap { i -> [Float] in
            let x=Float(i%w)/Float(w-1)
            return [0.5+0.2*x,0.3+0.3*x,0.8+0.2*x,1]
        }
        let source=image(pixels,width:w,height:h)
        var p=Parameters();p.radius=12;p.minRed=0.15
        let scale=CGAffineTransform(scaleX:0.5,y:0.5)
        let full=try CoreImageProcessor.apply(source,parameters:p).transformed(by:scale)
        let preview=try CoreImageProcessor.apply(source.transformed(by:scale),parameters:p,scale:0.5)
        assertClose(read(full,ctx),read(preview,ctx),accuracy:0.003)
        p.minBrightness=0.8
        let purple=image([0.2,0.02,0.3,1],width:1,height:1)
        let result=read(try CoreImageProcessor.apply(purple,parameters:p),ctx)
        assertClose(result,read(purple,ctx),accuracy:0.000001)
    }
}
