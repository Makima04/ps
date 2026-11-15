import XCTest
import CoreImage
import Metal
@testable import ReferenceMatch

final class ReferenceMatchTests: XCTestCase {
    private func context() throws -> CIContext {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: ReferenceMatch.linearP3, .workingFormat: CIFormat.RGBAf
        ])
    }

    private func fixture(width: Int = 1024) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * 4)
        for x in 0..<width {
            let value = Float(x) / Float(width-1) * 1.15
            pixels[x*4] = value; pixels[x*4+1] = value; pixels[x*4+2] = value
        }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
                       size: CGSize(width: width, height: 1), format: .RGBAf,
                       colorSpace: ReferenceMatch.linearP3)
    }

    private func pixels(_ image: CIImage, context: CIContext) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width*height*4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width*16,
                           bounds: image.extent, format: .RGBAf, colorSpace: ReferenceMatch.linearP3)
        }
        return values
    }

    private func profile(_ l: Double) -> ReferenceMatch.Profile {
        ReferenceMatch.Profile(sampleCount: 1000, faceWidthPixels: 150,
            lightness: .init([l-12,l-6,l,l+6,l+12]),
            redGreen: .init([0,1,2,3,4]), yellowBlue: .init([0,1,2,3,4]))
    }

    func testIdenticalProfileAndZeroStrengthPreserveExtendedPixels() throws {
        let context = try context(), image = fixture()
        let white = CIImage(color: .white).cropped(to: image.extent)
        let before = pixels(image, context: context)
        for strength in [0.0, 1.0] {
            let recipe = ReferenceMatch.Recipe(source: profile(65), reference: profile(65), strength: strength)
            let result = pixels(try ReferenceMatch.transfer(image, mask: white, recipe: recipe), context: context)
            XCTAssertLessThan(zip(before, result).map { abs($0-$1) }.max()!, 0.00002)
            XCTAssertGreaterThan(result[result.count-4], 1, "Extended highlights must survive the transform")
        }
    }

    func testLargeLightnessLiftKeepsGradientMonotonic() throws {
        let context = try context(), image = fixture()
        let white = CIImage(color: .white).cropped(to: image.extent)
        for anchor in [30.0, 65.0, 83.0] {
            let recipe = ReferenceMatch.Recipe(source: profile(anchor), reference: profile(anchor+14), strength: 1)
            let result = pixels(try ReferenceMatch.transfer(image, mask: white, recipe: recipe), context: context)
            var previous = -Double.infinity
            for x in 0..<1024 {
                let index = x*4
                let l = ReferenceMatch.lab(Double(result[index]), Double(result[index+1]), Double(result[index+2])).0
                XCTAssertGreaterThan(l, previous, "A brightening curve must not reverse highlight gradients")
                previous = l
            }
        }
    }

    func testSkinMaskLeavesDistantBackgroundUnchanged() throws {
        let context = try context(), image = fixture()
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 1))
            .composited(over: CIImage(color: .black).cropped(to: image.extent))
        let recipe = ReferenceMatch.Recipe(source: profile(65), reference: profile(77), strength: 0.85)
        let before = pixels(image, context: context)
        let after = pixels(try ReferenceMatch.transfer(image, mask: mask, recipe: recipe), context: context)
        XCTAssertGreaterThan(after[256*4], before[256*4])
        for x in 800..<1024 {
            for channel in 0..<4 { XCTAssertEqual(after[x*4+channel], before[x*4+channel], accuracy: 0.000001) }
        }
    }
}
