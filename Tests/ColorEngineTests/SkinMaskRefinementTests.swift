import XCTest
import CoreImage
import Metal
@testable import ColorEngine

final class SkinMaskRefinementTests: XCTestCase {
    private func context() throws -> CIContext {
        CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[
            .workingColorSpace:SkinColorMath.linearP3,.workingFormat:CIFormat.RGBAf])
    }
    private func value(_ image: CIImage, at point: CGPoint, context: CIContext) -> Float {
        var sample = [Float](repeating:0,count:4)
        sample.withUnsafeMutableBytes {
            context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,
                bounds:CGRect(x:point.x,y:point.y,width:1,height:1),format:.RGBAf,colorSpace:SkinColorMath.linearP3)
        }
        return sample[0]
    }
    func testHandToleranceWidensColourSelection() throws {
        let context = try context()
        let image = CIImage(color:CIColor(red:0.50,green:0.30,blue:0.20)).cropped(to:CGRect(x:0,y:0,width:20,height:20))
        let (_,a,b) = SkinColorMath.lab(0.50,0.30,0.20)
        let profile = SkinProfile(sampleCount:1000,faceWidthPixels:300,
            lightness:SkinDistribution([60,65,70]),redGreen:SkinDistribution([a-11,a-10,a-9]),
            yellowBlue:SkinDistribution([b-1,b,b+1]))
        let narrow = try SkinProcessing.bodyCandidate(image,profile:profile)
        let wide = try SkinProcessing.bodyCandidate(image,profile:profile,tolerance:2.2)
        XCTAssertGreaterThan(value(wide,at:CGPoint(x:10,y:10),context:context),
            value(narrow,at:CGPoint(x:10,y:10),context:context)+0.3)
    }
    func testComponentsPreserveSoftSkirtAndLocation() throws {
        let context = try context(), extent = CGRect(x:0,y:0,width:400,height:400)
        let core = CIImage(color:.white).cropped(to:CGRect(x:72,y:280,width:20,height:40))
        let black = CIImage(color:.black).cropped(to:extent)
        let mask = core.composited(over:black).applyingGaussianBlur(sigma:4).cropped(to:extent)
        let regions = try BodySkinComponents.regions(mask,context:context)
        let region = try XCTUnwrap(regions.first)
        XCTAssertEqual(regions.count,1)
        XCTAssertGreaterThan(value(region.mask,at:CGPoint(x:71,y:299),context:context),0.2)
        XCTAssertLessThan(value(region.mask,at:CGPoint(x:82,y:100),context:context),0.001)
        XCTAssertGreaterThan(region.bounds.minY,260)
    }
    func testRecoversConnectedNeckWithoutSelectingPaleHairOrDistantSkinColours() throws {
        let context = try context(), extent = CGRect(x:0,y:0,width:400,height:500)
        let black = CIImage(color:.black).cropped(to:extent)
        let faceBox = CGRect(x:150,y:270,width:100,height:120)
        let parsed = CIImage(color:.white).cropped(to:faceBox).composited(over:black)
        let skinColour = CIColor(red:0.50,green:0.30,blue:0.20)
        var image = CIImage(color:skinColour).cropped(to:CGRect(x:165,y:200,width:70,height:85))
            .composited(over:CIImage(color:skinColour).cropped(to:faceBox))
            .composited(over:CIImage(color:CIColor(red:0.8,green:0.8,blue:0.8)).cropped(to:extent))
        image = CIImage(color:skinColour).cropped(to:CGRect(x:110,y:220,width:15,height:20)).composited(over:image)
        let hair = parsed.applyingFilter("CIColorInvert")
        let face = SemanticFace(info:FaceRegionInfo(index:0,bounds:faceBox,hasLandmarks:false),
            regions:[.skin:parsed,.neck:black,.hair:hair])
        let refined = try SkinMaskRefinement.refine(face,image:image,clothing:black,context:context)
        let result = try XCTUnwrap(refined.regions[.skin])
        XCTAssertGreaterThan(value(result,at:CGPoint(x:200,y:266),context:context),0.9)
        XCTAssertLessThan(value(result,at:CGPoint(x:200,y:230),context:context),0.02,"远离语义边界的区域应渐弱，不能沿肤色一直扩到胸口")
        XCTAssertLessThan(value(result,at:CGPoint(x:145,y:230),context:context),0.01)
        XCTAssertLessThan(value(result,at:CGPoint(x:117,y:230),context:context),0.01,"孤立相似颜色不能被补选")
        XCTAssertGreaterThan(value(try XCTUnwrap(refined.regions[.neck]),at:CGPoint(x:200,y:260),context:context),0.25)
        let hand = CIImage(color:.white).cropped(to:CGRect(x:155,y:280,width:25,height:50)).composited(over:black)
        let withHand = try SkinMaskRefinement.refine(face,image:image,clothing:black,hands:hand,context:context)
        XCTAssertLessThan(value(try XCTUnwrap(withHand.regions[.skin]),at:CGPoint(x:166,y:300),context:context),0.01,
            "挡在头部前的手不能被当作脸颈再提亮一次")
    }
}
