import XCTest
import CoreImage
import Metal
@testable import ColorEngine

final class BlemishDetectionTests: XCTestCase {
    private func fixture(redX: Int = 92, spots: Bool = true) -> CIImage {
        let side = 256
        var values = [Float](repeating: 1, count: side*side*4)
        for y in 0..<side { for x in 0..<side {
            var r: Float = 0.55, g: Float = 0.35, b: Float = 0.25
            if spots {
                if hypot(Double(x-redX),Double(y-140)) <= 3 { r = 0.60; g = 0.20; b = 0.16 }
                if hypot(Double(x-170),Double(y-110)) <= 3 { r *= 0.3; g *= 0.3; b *= 0.3 }
                // A broad cheek tint and an off-mask red object must not become repair spots.
                if hypot(Double(x-70),Double(y-65)) <= 26 { g -= 0.05 }
                if hypot(Double(x-5),Double(y-5)) <= 3 { r = 0.6; g = 0.1; b = 0.1 }
            }
            let i = (y*side+x)*4
            values[i] = r; values[i+1] = g; values[i+2] = b
        } }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) },bytesPerRow:side*16,
            size:CGSize(width:side,height:side),format:.RGBAf,colorSpace:SkinColorMath.linearP3)
    }

    private func detect(_ image: CIImage, sensitivity: Double = 0.5) throws -> [BlemishCandidate] {
        let context = CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[
            .workingColorSpace:SkinColorMath.linearP3,.workingFormat:CIFormat.RGBAf])
        let mask = CIImage(color:.white).cropped(to:CGRect(x:12,y:12,width:232,height:232))
            .composited(over:CIImage(color:.black).cropped(to:image.extent))
        return try BlemishDetector.detect(image,permitted:mask,box:image.extent,faceIndex:0,
            sensitivity:sensitivity,context:context)
    }

    func testFindsLocalSpotsAndNeverRecommendsDarkMarksAutomatically() throws {
        let candidates = try detect(fixture())
        let red = try XCTUnwrap(candidates.first { $0.kind == .redSpot && abs($0.target.x-92.0/256) < 0.03 })
        let dark = try XCTUnwrap(candidates.first { $0.kind == .darkSpot && abs($0.target.x-170.0/256) < 0.03 })
        XCTAssertNotNil(red.repair)
        XCTAssertTrue(red.recommended)
        XCTAssertFalse(dark.recommended)
        XCTAssertTrue(candidates.allSatisfy { $0.target.x > 0.1 && $0.target.y > 0.1 })
        XCTAssertFalse(candidates.contains { hypot(($0.target.x-70.0/256)*256,($0.target.y-65.0/256)*256) < 20 })
        for candidate in candidates {
            if let repair = candidate.repair {
                XCTAssertTrue(repair.isValid(in:CGSize(width:256,height:256)))
                XCTAssertGreaterThan(hypot(repair.source.x-repair.target.x,repair.source.y-repair.target.y),repair.radius*2)
            }
        }
    }

    func testRecalculatesLocationsPerImageAndLeavesUniformSkinAlone() throws {
        XCTAssertTrue(try detect(fixture(spots:false)).isEmpty)
        let first = try detect(fixture(redX:92)).filter { $0.kind == .redSpot }
        let second = try detect(fixture(redX:128)).filter { $0.kind == .redSpot }
        let a = try XCTUnwrap(first.first), b = try XCTUnwrap(second.first)
        XCTAssertGreaterThan(b.target.x-a.target.x,0.1)
        XCTAssertThrowsError(try detect(fixture(),sensitivity:.nan))
        XCTAssertThrowsError(try detect(fixture(),sensitivity:1.5))
    }

    func testDetectedRepairCoordinatesLandOnTheActualSpotAfterCropAndTranslation() throws {
        let context = CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[
            .workingColorSpace:SkinColorMath.linearP3,.workingFormat:CIFormat.RGBAf])
        let image = fixture().transformed(by:CGAffineTransform(translationX:41,y:73))
        let allowed = CIImage(color:.white).cropped(to:image.extent)
        let candidates = try BlemishDetector.detect(image,permitted:allowed,
            box:CGRect(x:61,y:93,width:210,height:210),faceIndex:0,sensitivity:0.5,context:context)
        let spot = try XCTUnwrap(candidates.first { $0.kind == .redSpot })
        let repair = try XCTUnwrap(spot.repair)
        func lab(_ point: MaskPoint, image input: CIImage) -> (Double,Double,Double) {
            var value = [Float](repeating:0,count:4)
            let rect = CGRect(x:image.extent.minX+point.x*image.extent.width-0.5,
                y:image.extent.minY+point.y*image.extent.height-0.5,width:1,height:1)
            value.withUnsafeMutableBytes { context.render(input,toBitmap:$0.baseAddress!,rowBytes:16,
                bounds:rect,format:.RGBAf,colorSpace:SkinColorMath.linearP3) }
            return SkinColorMath.lab(Double(value[0]),Double(value[1]),Double(value[2]))
        }
        let before = lab(repair.target,image:image), source = lab(repair.source,image:image)
        XCTAssertGreaterThan(before.1,source.1+8,"检测点应落在红点，不能上下镜像到正常皮肤")
        let after = lab(repair.target,image:try SpotRepair.apply([repair],to:image))
        XCTAssertLessThan(after.1,before.1-5,"实际合成必须减轻目标红点")
        XCTAssertEqual(repair.target.y,1-140.5/256,accuracy:0.012)
    }
}
