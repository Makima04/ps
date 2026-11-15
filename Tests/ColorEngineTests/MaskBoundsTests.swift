import XCTest
import CoreImage
@testable import ColorEngine

final class MaskBoundsTests: XCTestCase {
    func testBrightCropEdgesCannotExtendAcrossTheFrame() throws {
        let extent=CGRect(x:0,y:0,width:100,height:80)
        let crop=CGRect(x:30,y:20,width:18,height:24)
        let local=CIImage(color:.white).cropped(to:crop)
        let padded=try MaskBounds.pad(local,to:extent)
        let context=CIContext(options:[.workingFormat:CIFormat.RGBAf])
        var values=[Float](repeating:0,count:100*80*4)
        values.withUnsafeMutableBytes {
            context.render(padded,toBitmap:$0.baseAddress!,rowBytes:100*16,bounds:extent,
                           format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)!)
        }
        let white=stride(from:0,to:values.count,by:4).filter {values[$0]>0.9}.count
        XCTAssertEqual(white,18*24,"Only the local crop may contribute to the mask")
        XCTAssertEqual(values[0],0)
        XCTAssertEqual(values[values.count-4],0)
    }
}
