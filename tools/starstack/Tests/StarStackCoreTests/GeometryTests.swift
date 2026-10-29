import XCTest
@testable import StarStackCore

final class GeometryTests: XCTestCase {
    func testProjectiveFitAndInverse() throws {
        let h=Homography([1.002,-0.02,14,0.02,1.001,-9,0.00001,-0.00002,1])
        var points=[Point]()
        for y in 0..<8 {for x in 0..<10 {points.append(Point(Double(x*90+20),Double(y*80+30)))}}
        let pairs=points.map{Match(source:$0,reference:h.apply($0))}
        let fitted=try XCTUnwrap(Registration.fit(pairs,scale:1000))
        let inverse=try fitted.inverted()
        for p in points { XCTAssertLessThan(fitted.apply(p).distance(h.apply(p)),1e-7);XCTAssertLessThan(inverse.apply(fitted.apply(p)).distance(p),1e-7) }
    }
    func testPatternRegistrationWithMissingStarsAndOutliers() throws {
        var state:UInt64=42
        func random()->Double { state=state &* 6364136223846793005 &+ 1;return Double(state>>11)/Double(UInt64.max>>11) }
        let h=Homography([0.999,-0.025,19,0.025,0.999,-12,0.000003,-0.000004,1])
        var source=[Star](),reference=[Star]()
        for i in 0..<100 {
            let p=Point(50+900*random(),50+600*random()),q=h.apply(p),flux=Double(110-i)
            source.append(Star(point:p,flux:flux))
            if i%9 != 0 {reference.append(Star(point:q,flux:flux))}
        }
        for _ in 0..<20 {reference.append(Star(point:Point(1000*random(),700*random()),flux:1))}
        let fit=try Registration.align(source:source,reference:reference,width:1000)
        XCTAssertGreaterThan(fit.matches.count,80)
        XCTAssertLessThan(fit.validationP95Error,0.01)
        for p in source.prefix(20) {XCTAssertLessThan(fit.transform.apply(p.point).distance(h.apply(p.point)),0.01)}
    }
    func testStarDetectorRejectsHotPixel() {
        let w=128,h=96;var p=[Float](repeating:0.001,count:w*h*4)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            p[4*(y*w+x)+c]+=Float(0.05*exp(-Double((x-40)*(x-40)+(y-35)*(y-35))/3))
        };p[4*(y*w+x)+3]=1 } }
        for c in 0..<3 { p[4*(60*w+90)+c]=0.5 }
        let found=StarDetector.detect(Frame(width:w,height:h,pixels:p))
        XCTAssertTrue(found.contains{$0.point.distance(Point(40,35))<0.2})
        XCTAssertFalse(found.contains{$0.point.distance(Point(90,60))<2})
    }
}
