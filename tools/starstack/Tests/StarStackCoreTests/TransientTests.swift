import XCTest
@testable import StarStackCore

final class TransientTests:XCTestCase {
    func testMeasuredLineSurvivesAndMaskEdgeDoesNotBecomeMeteor() {
        let w=256,h=192
        var clean=[Float](repeating:0,count:w*h*4),source=clean,mask=[Float](repeating:0,count:w*h)
        for y in 0..<h {for x in 0..<w {
            let k=y*w+x
            let noise=Float(sin(Double(k)*1.345)*0.00005)
            for c in 0..<3 {clean[4*k+c]=0.02;source[4*k+c]=0.02+noise}
            clean[4*k+3]=1;source[4*k+3]=y<150 ? 1:0;mask[k]=y<150 ? 1:0
            // A diagonal transient and an extreme boundary discontinuity.
            if x>=40,x<=180 {let d=Double(y)-(105-Double(x-40)*0.4);for c in 0..<3 {source[4*k+c]+=Float(0.1*exp(-d*d/2))}}
            if y>=147,y<=149 {for c in 0..<3 {source[4*k+c]+=0.2}}
        }}
        let found=TransientDetector.detect(source:Frame(width:w,height:h,pixels:source),stack:Frame(width:w,height:h,pixels:clean),mask:mask,stars:[],frameIndex:7)
        XCTAssertEqual(found.count,1)
        guard let line=found.first else{return}
        XCTAssertGreaterThan(line.start.distance(line.end),140)
        XCTAssertEqual(line.frameIndex,7)
        XCTAssertLessThan(max(line.start.y,line.end.y),120)
    }
    func testSmoothResidualMorphInversion() throws {
        let morph=ResidualMorph(x:[0,0,0,5,2,-3,1,0,0,1],y:[0,0,0,-2,3,4,0,1,0,2],scale:1000)
        let h=Homography([1,-0.03,11,0.03,1,-9,0.00002,-0.00001,1]),inverse=try h.inverted()
        let alignment=Alignment(transform:h,matches:[],medianError:0,p95Error:0,validationMedianError:0,validationP95Error:0,morph:morph)
        for y in stride(from:20,to:650,by:70) {for x in stride(from:20,to:980,by:70) {
            let p=Point(Double(x),Double(y)),q=alignment.apply(p)
            XCTAssertLessThan(alignment.sourcePoint(q,inverse:inverse).distance(p),0.001)
            let scaled=alignment.resized(by:0.4),small=Point((p.x+0.5)*0.4-0.5,(p.y+0.5)*0.4-0.5)
            let target=Point((q.x+0.5)*0.4-0.5,(q.y+0.5)*0.4-0.5)
            XCTAssertLessThan(scaled.apply(small).distance(target),1e-7)
        }}
    }
    func testPersistentTrackIsSeparatedFromIsolatedMeteor() {
        var lines=[Streak]()
        for i in 0..<4 {lines.append(Streak(frameIndex:i,start:Point(Double(30+i*20),80),end:Point(Double(55+i*20),80),width:1,pixels:40,peakResidual:0.1))}
        lines.append(Streak(frameIndex:2,start:Point(100,20),end:Point(180,55),width:1,pixels:100,peakResidual:0.5))
        let grouped=TransientDetector.groupTracks(lines)
        XCTAssertTrue(grouped.prefix(4).allSatisfy{$0.persistentTrack == true})
        XCTAssertFalse(grouped[4].persistentTrack ?? true)
    }
}
