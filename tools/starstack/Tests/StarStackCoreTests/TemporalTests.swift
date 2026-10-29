import XCTest
import simd
@testable import StarStackCore

final class TemporalTests:XCTestCase {
    func testIrregularCaptureTimesRecoverSiderealRotation() throws {
        let width=1600,height=1066,focal=Double(width)*16/36,rate=2*Double.pi/86164.0905
        let axis=simd_normalize(SIMD3(0.2,0.95,0.15))
        var frames=[FrameRecord]()
        let times=(0..<18).map{Double($0*17+($0>7 ? 92:0))}
        for (i,t) in times.enumerated() {
            let metadata=Metadata(path:"\(i).ARW",width:width,height:height,camera:"synthetic",dateTimeOriginal:nil,subsecond:nil,offset:nil,
                exposure:15,iso:2500,aperture:4,focalLength:16,focal35:16,relativeClock:t)
            var pairs=[Match]()
            for y in 0..<5 {for x in 0..<8 {
                let p=Point(100+Double(x)*175,80+Double(y)*130)
                let ray=SIMD3((p.x-800)/focal,(p.y-533)/focal,1.0),angle=rate*t
                let q=ray*cos(angle)+simd_cross(axis,ray)*sin(angle)+axis*simd_dot(axis,ray)*(1-cos(angle))
                let source=Point(focal*q.x/q.z+800,focal*q.y/q.z+533)
                pairs.append(Match(source:source,reference:p))
            }}
            let alignment=Alignment(transform:Homography(),matches:pairs,medianError:0,p95Error:0,validationMedianError:0,validationP95Error:0)
            frames.append(FrameRecord(metadata:metadata,stars:[],alignment:alignment,failure:nil,cache:nil))
        }
        let report=StackReport(width:width,height:height,reference:"0.ARW",referenceMidpoint:7.5,assumptions:[],frames:frames,streaks:[])
        let fit=try XCTUnwrap(TemporalSolver.estimate(report))
        XCTAssertEqual(fit.inferredArcsecondsPerSecond,15.0410686,accuracy:0.01)
        XCTAssertLessThan(fit.heldOutP95Pixels,0.01)
        XCTAssertEqual(fit.focalPixels,focal,accuracy:0.1)
    }
}
