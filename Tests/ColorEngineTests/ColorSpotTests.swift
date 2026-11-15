import XCTest
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
@testable import ColorEngine

final class ColorSpotTests: XCTestCase {
    private func context() throws -> CIContext {
        CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[
            .workingColorSpace:SkinColorMath.linearP3,.workingFormat:CIFormat.RGBAf])
    }

    private func fixture(spots: Bool = true, warm: Bool = false) -> CIImage {
        let side = 256
        var values = [Float](repeating:1,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            // Smooth lighting and small texture must survive local repair.
            let light = Float(x) * 0.0001 + (x.isMultiple(of:2) ? Float(0.001) : -0.001)
            var rgb: [Float] = warm ? [0.55,0.32,0.13] : [0.55,0.35,0.25]
            if spots {
                if hypot(Double(x-80),Double(y-150)) <= 3 || hypot(Double(x-5),Double(y-5)) <= 3 {
                    rgb = [0.55,0.32,0.13]
                }
                if hypot(Double(x-160),Double(y-65)) <= 28 { rgb = [0.55,0.32,0.13] }
                if (184...187).contains(x) && (130...190).contains(y) { rgb = [0.50,0.30,0.12] }
            }
            let i = (y*side+x)*4
            for c in 0..<3 { values[i+c] = rgb[c]+light }
        } }
        return CIImage(bitmapData:values.withUnsafeBytes { Data($0) },bytesPerRow:side*16,
            size:CGSize(width:side,height:side),format:.RGBAf,colorSpace:SkinColorMath.linearP3)
    }

    private func pixels(_ image: CIImage, _ context: CIContext) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating:0,count:width*height*4)
        values.withUnsafeMutableBytes {
            context.render(image,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:image.extent,
                format:.RGBAf,colorSpace:SkinColorMath.linearP3)
        }
        return values
    }

    func testYellowCandidateRejectsBroadTintLinesAndProtectedPixels() throws {
        let context = try context(), image = fixture()
        let allowed = CIImage(color:.white).cropped(to:CGRect(x:12,y:12,width:232,height:232))
            .composited(over:CIImage(color:.black).cropped(to:image.extent))
        let candidates = try BlemishDetector.detect(image,permitted:allowed,box:image.extent,
            faceIndex:2,sensitivity:0.5,context:context)
        let yellow = try XCTUnwrap(candidates.first { $0.kind == .yellowSpot })
        XCTAssertEqual(yellow.faceIndex,2)
        XCTAssertEqual(yellow.target.x,80.5/256,accuracy:0.01)
        XCTAssertEqual(yellow.target.y,1-150.5/256,accuracy:0.01)
        XCTAssertFalse(yellow.recommended,"黄褐色点即使高分也需要确认")
        XCTAssertEqual(yellow.repair?.mode,.sampledSkin)
        XCTAssertEqual(candidates.count,1,"宽色区、条纹和蒙版外色点均不能进入候选")
        let protected = CIImage(color:.black).cropped(to:CGRect(x:70,y:95,width:22,height:22))
            .composited(over:allowed)
        XCTAssertTrue(try BlemishDetector.detect(image,permitted:protected,box:image.extent,
            faceIndex:2,sensitivity:0.5,context:context).isEmpty)
        for warm in [false,true] {
            XCTAssertTrue(try BlemishDetector.detect(fixture(spots:false,warm:warm),permitted:allowed,
                box:image.extent,faceIndex:0,sensitivity:1,context:context).isEmpty,
                "暖肤色和缓慢光照变化本身不能视作色斑")
        }
    }

    func testConfirmedColourRepairReducesResidualAndPreservesOutsidePixels() throws {
        let context = try context()
        let translation = CGAffineTransform(translationX:41,y:73)
        let image = fixture().transformed(by:translation)
        let clean = fixture(spots:false).transformed(by:translation)
        let allowed = CIImage(color:.white).cropped(to:image.extent)
        let candidates = try BlemishDetector.detect(image,permitted:allowed,
            box:CGRect(x:61,y:93,width:210,height:210),faceIndex:0,sensitivity:0.5,context:context)
        let repair = try XCTUnwrap(candidates.first { $0.kind == .yellowSpot && $0.target.x < 0.4 }?.repair)
        let before = pixels(image,context), expected = pixels(clean,context)
        let after = pixels(try SpotRepair.apply([repair],to:image),context)
        func lab(_ values: [Float], _ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (y*256+x)*4
            let (l,a,b) = SkinColorMath.lab(Double(values[i]),Double(values[i+1]),Double(values[i+2]))
            return SIMD3(l,a,b)
        }
        let initial = lab(before,80,150)-lab(expected,80,150)
        let residual = lab(after,80,150)-lab(expected,80,150)
        XCTAssertLessThan(abs(residual.z),abs(initial.z)*0.3,"色斑低频不能被原样保留")
        XCTAssertLessThan(abs(residual.x),abs(initial.x)*0.5)
        let radius = repair.radius*256
        for y in 0..<256 { for x in 0..<256 {
            let distance = hypot(Double(x)+0.5-repair.target.x*256,
                256-Double(y)-0.5-repair.target.y*256)
            if distance > radius+1 {
                for c in 0..<4 { XCTAssertEqual(after[(y*256+x)*4+c],before[(y*256+x)*4+c],accuracy:0.000002) }
            }
        } }
        let texture = abs(lab(after,80,150).x-lab(after,81,150).x)
        XCTAssertGreaterThan(texture,0.01,"修复不能只是涂一块平色")
    }

    func testRepairModeKeepsLegacyJSONAndRoundTripsColourRepairs() throws {
        let legacy = Data("{\"source\":{\"x\":0.2,\"y\":0.3},\"target\":{\"x\":0.5,\"y\":0.6},\"radius\":0.01}".utf8)
        var spot = try JSONDecoder().decode(RepairSpot.self,from:legacy)
        XCTAssertEqual(spot.mode,.texture)
        let encoded = try JSONEncoder().encode(spot)
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("mode"))
        spot.mode = .sampledSkin
        var settings = Adjustments(); settings.repairSpots = [spot]
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self,from:JSONEncoder().encode(settings)),settings)
    }

    func testColourRepairPreviewAndSixteenBitExportAgree() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source = folder.appendingPathComponent("source.png"), target = folder.appendingPathComponent("result.tiff")
        let context = try context(), input = fixture()
        let cg = try XCTUnwrap(context.createCGImage(input,from:input.extent,format:.RGBA16,
            colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,cg,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf:source)
        var settings = Adjustments()
        settings.repairSpots = [RepairSpot(source:MaskPoint(x:64.5/256,y:1-150.5/256),
            target:MaskPoint(x:80.5/256,y:1-150.5/256),radius:0.02,mode:.sampledSkin)]
        let engine = ColorEngine()
        let preview = try await engine.preview(source,adjustments:settings,maxEdge:nil,profile:.sRGB)
        try await engine.export(source,to:target,adjustments:settings,format:.tiff,profile:.sRGB)
        let exported = try await engine.preview(target,adjustments:Adjustments(),maxEdge:nil,profile:.sRGB)
        func bytes(_ image: CGImage) -> [UInt8] {
            var output = [UInt8](repeating:0,count:256*256*4)
            output.withUnsafeMutableBytes {
                context.render(CIImage(cgImage:image),toBitmap:$0.baseAddress!,rowBytes:256*4,
                    bounds:input.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            }
            return output
        }
        XCTAssertLessThanOrEqual(zip(bytes(preview),bytes(exported)).map { abs(Int($0)-Int($1)) }.max() ?? 0,1)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int,16)
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
}
