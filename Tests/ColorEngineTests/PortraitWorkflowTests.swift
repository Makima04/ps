import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import UniformTypeIdentifiers
import ImageIO
@testable import ColorEngine

final class PortraitWorkflowTests: XCTestCase {
    private func context() throws -> CIContext {
        CIContext(mtlDevice: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: [
            .workingColorSpace: SkinColorMath.linearP3, .workingFormat: CIFormat.RGBAf
        ])
    }
    private func pixels(_ image: CIImage, _ context: CIContext) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        }
        return values
    }
    private func fixture() -> CIImage {
        let width = 1024, height = 32
        var values = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let l = Float(x) / Float(width - 1) * 1.2
                let i = (y * width + x) * 4
                values[i] = l; values[i+1] = l * 0.75; values[i+2] = l * 0.6
            }
        }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: SkinColorMath.linearP3)
    }
    private func profile(_ l: Double = 65) -> SkinProfile {
        SkinProfile(sampleCount: 1200, faceWidthPixels: 320, lightness: SkinDistribution([l-12,l-6,l,l+6,l+12]),
                    redGreen: SkinDistribution([10,12,14,16,18]), yellowBlue: SkinDistribution([12,14,16,18,20]))
    }

    func testLegacyDefaultsAndNewSettingsRoundTrip() throws {
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{\"exposure\":0.4}".utf8))
        XCTAssertEqual(old.global.texturePreservation, 0.75)
        XCTAssertEqual(old.global.skinWhitening, 0)
        XCTAssertEqual(old.global.lipPolish, 0)
        XCTAssertEqual(old.global.skinDetail, 0)
        XCTAssertEqual(old.global.skinEdgeGuard, 0)
        XCTAssertNil(old.skinReference)
        var new = old
        var layer = AdjustmentLayer(mask: .leftCheek)
        layer.faceIndex = 1
        layer.adjustments.skinUniformity = 0.6
        layer.adjustments.skinSmoothing = 0.5
        layer.adjustments.lipPolish = 0.4
        layer.adjustments.skinDetail = 0.3
        layer.adjustments.skinEdgeGuard = 0.8
        new.layers = [layer]
        new.skinReference = SkinReferenceApplication(template: SkinStyleTemplate(name: "自然", reference: profile()))
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(new)), new)
    }

    func testAdaptationRecalculatesPerSourceAndRejectsInvalidTemplates() throws {
        var template = SkinStyleTemplate(name: "自然白皙", reference: profile(75))
        template.maxLightnessChange = 8
        let application = SkinReferenceApplication(template: template)
        let dark = try SkinAdaptation(source: profile(50), application: application)
        let bright = try SkinAdaptation(source: profile(78), application: application)
        XCTAssertEqual(dark.deltaL, 8)
        XCTAssertEqual(bright.deltaL, -3)
        XCTAssertEqual(dark.lightnessScale, 1)
        var invalid = application
        invalid.template.targetLightness = .nan
        XCTAssertThrowsError(try SkinAdaptation(source: profile(), application: invalid))
        invalid = application; invalid.template.version = 999
        XCTAssertThrowsError(try invalid.template.validate())
        invalid = application; invalid.strength = 2
        XCTAssertThrowsError(try SkinAdaptation(source: profile(), application: invalid))
    }

    func testWhiteningPreservesMonotonicLightAndExtendedHighlights() throws {
        let context = try context(), image = fixture()
        var settings = ColorAdjustments()
        settings.skinWhitening = 1
        let after = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: nil), context)
        var previous = -Double.infinity
        for x in 0..<1024 {
            let i = x * 4
            let l = SkinColorMath.lab(Double(after[i]), Double(after[i+1]), Double(after[i+2])).0
            XCTAssertGreaterThan(l, previous)
            previous = l
        }
        XCTAssertGreaterThan(after[1023*4], 1)
        XCTAssertGreaterThan(after[400*4], pixels(image, context)[400*4])
    }

    func testReferenceZeroStrengthIsIdentityAndColorOnlyPreservesLuma() throws {
        let context = try context(), image = fixture()
        var application = SkinReferenceApplication(template: SkinStyleTemplate(name: "参考", reference: profile(78)))
        application.strength = 0
        let original = pixels(image, context)
        XCTAssertEqual(pixels(try SkinColorMath.transfer(image, recipe: SkinAdaptation(source: profile(), application: application)), context), original)
        application.strength = 0.8
        application.lightnessAmount = 0
        application.template.preserveContrast = false
        application.template.reference.lightness = SkinDistribution([30,50,78,85,95])
        application.template.targetRed += 5
        application.template.targetYellow -= 5
        let recipe = try SkinAdaptation(source: profile(), application: application)
        let result = pixels(try SkinColorMath.transfer(image, recipe: recipe), context)
        for x in 100..<900 {
            let i = x*4
            let beforeL = SkinColorMath.lab(Double(original[i]), Double(original[i+1]), Double(original[i+2])).0
            let afterL = SkinColorMath.lab(Double(result[i]), Double(result[i+1]), Double(result[i+2])).0
            XCTAssertEqual(beforeL, afterL, accuracy: 0.0001)
        }
    }

    func testCheekBlushUsesOnlyCheekGuideAndTextureKernelsRender() throws {
        let context = try context(), image = fixture()
        let black = CIImage(color: .black).cropped(to: image.extent)
        let white = CIImage(color: .white).cropped(to: image.extent)
        var settings = ColorAdjustments(); settings.cheekBlush = 0.8
        let original = pixels(image, context)
        let noCheek = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: black), context)
        XCTAssertLessThan(zip(original, noCheek).map { abs($0-$1) }.max()!, 0.00002)
        let blush = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: white), context)
        XCTAssertGreaterThan(abs(blush[400*4] - original[400*4]), 0.001)
        settings.skinUniformity = 0.5; settings.skinSmoothing = 0.5
        let softened = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: black), context)
        XCTAssertTrue(softened.allSatisfy(\.isFinite))
        XCTAssertNotEqual(softened, original)
        XCTAssertTrue(pixels(try SkinProcessing.teethCandidate(image), context).allSatisfy(\.isFinite))
        XCTAssertTrue(pixels(try SkinProcessing.bodyCandidate(image, profile: profile()), context).allSatisfy(\.isFinite))
    }

    func testLandmarkGuidesAreLocalizedAndRespectRoll() throws {
        let context = try context()
        let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
        let guide = FaceRegionGeometry(box: extent, eyeA: CGPoint(x: 0.3, y: 0.65), eyeB: CGPoint(x: 0.7, y: 0.7))
        let left = pixels(guide.mask(.leftCheek, extent: extent), context)
        let right = pixels(guide.mask(.rightCheek, extent: extent), context)
        var leftX = 0.0, rightX = 0.0, leftW = 0.0, rightW = 0.0
        for y in 0..<400 { for x in 0..<400 {
            let i = (y*400+x)*4
            leftX += Double(left[i]) * Double(x); leftW += Double(left[i])
            rightX += Double(right[i]) * Double(x); rightW += Double(right[i])
        } }
        XCTAssertGreaterThan(leftW, 100)
        XCTAssertLessThan(leftX / leftW, rightX / rightW)
        XCTAssertEqual(left[0], 0)
        XCTAssertEqual(right[(400*400-1)*4], 0)
    }

    func testManualRepairRemovesSmallSpotAndKeepsDistantPixelsAndTexture() throws {
        let context = try context(), width = 256
        var values = [Float](repeating: 1, count: width * width * 4)
        for y in 0..<width { for x in 0..<width {
            let i = (y*width+x)*4
            let detail = Float(sin(Double(x) * .pi / 2)) * 0.015
            let blemish: Float = hypot(Double(x-160), Double(y-128)) <= 3 ? 0.20 : 0
            values[i] = 0.55 + detail - blemish
            values[i+1] = 0.35 + detail - blemish
            values[i+2] = 0.25 + detail - blemish
        } }
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
                            size: CGSize(width: width, height: width), format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        let permitted = RepairSpot(source: MaskPoint(x: 64.5/256, y: 128.5/256),
                                   target: MaskPoint(x: 160.5/256, y: 128.5/256), radius: 0.03)
        let result = pixels(try SpotRepair.apply([permitted], to: image), context)
        let before = pixels(image, context)
        let center = (128*width+160)*4
        XCTAssertGreaterThan(result[center], before[center] + 0.10)
        XCTAssertGreaterThan(abs(result[center+4] - result[center+8]), 0.005, "Source texture must remain visible")
        for y in 0..<width { for x in 0..<100 {
            let i = (y*width+x)*4
            for channel in 0..<4 { XCTAssertEqual(result[i+channel], before[i+channel], accuracy: 0.000001) }
        } }
        var invalid = permitted; invalid.source.x = 0
        XCTAssertThrowsError(try SpotRepair.apply([invalid], to: image))
    }

    func testMultiPersonOwnershipCannotSelectNeighbour() throws {
        let context = try context()
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let white = CIImage(color: .white).cropped(to: extent)
        let boxes = [CGRect(x: 20, y: 20, width: 60, height: 60), CGRect(x: 120, y: 20, width: 60, height: 60)]
        let a = pixels(try FaceMaskOwnership.restrict(white, index: 0, boxes: boxes), context)
        let b = pixels(try FaceMaskOwnership.restrict(white, index: 1, boxes: boxes), context)
        for i in stride(from: 0, to: a.count, by: 4) { XCTAssertEqual(a[i] + b[i], 1, accuracy: 0.000001) }
        XCTAssertEqual(a[50*4], 1, accuracy: 0.000001); XCTAssertEqual(a[150*4], 0, accuracy: 0.000001)
        XCTAssertEqual(b[50*4], 0, accuracy: 0.000001); XCTAssertEqual(b[150*4], 1, accuracy: 0.000001)
    }

    func testTexturePreservationKeepsFineDetailAtSameSofteningStrength() throws {
        let context = try context(), width = 1024
        var values = [Float](repeating: 1, count: width*32*4)
        for y in 0..<32 { for x in 0..<width {
            let i = (y*width+x)*4
            let detail = Float(sin(Double(x) * .pi / 2))*0.02
            values[i] = 0.5+detail; values[i+1] = 0.35+detail; values[i+2] = 0.25+detail
        } }
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
                            size: CGSize(width: width, height: 32), format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        var settings = ColorAdjustments(); settings.skinSmoothing = 1
        settings.texturePreservation = 1
        let kept = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: nil), context)
        settings.texturePreservation = 0
        let soft = pixels(try SkinProcessing.apply(image, settings: settings, cheeks: nil), context)
        let i = 501*4
        XCTAssertGreaterThan(abs(kept[i] - kept[i+4]), abs(soft[i] - soft[i+4]))
    }

    func testRealPhotoWorkflowAndQA() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for the portrait workflow acceptance check")
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("DSC00681.JPG")
        let engine = ColorEngine()
        let faces = try await engine.faceRegions(url)
        XCTAssertFalse(faces.isEmpty)
        XCTAssertTrue(faces[0].hasLandmarks)
        var settings = Adjustments()
        for kind in [MaskKind.leftCheek, .rightCheek, .underEyes, .noseSides, .forehead, .eyes, .eyebrows, .hair, .neck, .teeth, .bodySkin] {
            var layer = AdjustmentLayer(mask: kind)
            layer.feather = 0
            settings.layers = [layer]
            let cg = try await engine.preview(url, adjustments: settings, maxEdge: 800, maskLayerID: layer.id)
            let bytes = Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
            let area = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 128 }.count
            print("New region ", kind.rawValue, " area=", area)
            if [.leftCheek, .rightCheek, .underEyes, .eyes, .hair].contains(kind) { XCTAssertGreaterThan(area, 5) }
            if let output = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
                let target = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(target.appendingPathComponent("region-" + kind.rawValue + ".png") as CFURL,
                                                                               UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, cg, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
        let referenceURL = ProcessInfo.processInfo.environment["PS_REFERENCE_PHOTO"].map { URL(fileURLWithPath: $0) } ?? url
        let template = try await engine.makeSkinTemplate(referenceURL, name: "自然白皙")
        if referenceURL.pathExtension.lowercased() == "png" {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let selected = scratch.appendingPathComponent("reference.png")
            try FileManager.default.copyItem(at: referenceURL, to: selected)
            let flat = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            try CIContext().writeJPEGRepresentation(of: flat, to: scratch.appendingPathComponent("reference.jpg"),
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let selectedTemplate = try await engine.makeSkinTemplate(selected, name: "必须读取所选 PNG")
            XCTAssertEqual(selectedTemplate.reference.lightness.median, template.reference.lightness.median, accuracy: 0.01)
        }
        var skin = AdjustmentLayer(mask: .skin)
        skin.adjustments.skinWhitening = 0.3
        skin.adjustments.skinYellowReduction = 0.2
        skin.adjustments.skinUniformity = 0.25
        skin.adjustments.skinVitality = 0.2
        skin.adjustments.cheekBlush = 0.15
        skin.adjustments.skinSmoothing = 0.3
        settings.layers = [skin]
        settings.skinReference = SkinReferenceApplication(template: template)
        let reports = try await engine.skinReferenceReports(url, adjustments: settings)
        XCTAssertEqual(reports.count, faces.count)
        for report in reports {
            XCTAssertLessThanOrEqual(report.after.clippedFraction, report.before.clippedFraction + 0.005)
            print("Adaptation L*", report.before.lightness.median, "→", report.after.lightness.median)
        }
        // Reference strokes must affect the actual mask used for compositing.
        let automaticMask = try await engine.preview(url, adjustments: settings, maxEdge: 800, referenceMask: true)
        let info = try PhotoInfo.read(PhotoSource.resolve(url).imageURL)
        let face = faces[0].bounds
        let erase = MaskStroke(points: [MaskPoint(x: face.midX / Double(info.width), y: face.midY / Double(info.height))],
                               radius: 0.2, erase: true)
        settings.skinReference?.brushStrokes = [erase]
        let referenceMask = try await engine.preview(url, adjustments: settings, maxEdge: 800, referenceMask: true)
        let autoBytes = Array(try XCTUnwrap(automaticMask.dataProvider?.data) as Data)
        let editedBytes = Array(try XCTUnwrap(referenceMask.dataProvider?.data) as Data)
        let autoArea = stride(from: 0, to: autoBytes.count, by: 4).reduce(0) { $0 + Int(autoBytes[$1]) }
        let editedArea = stride(from: 0, to: editedBytes.count, by: 4).reduce(0) { $0 + Int(editedBytes[$1]) }
        XCTAssertGreaterThan(autoArea, 100)
        XCTAssertLessThan(Double(editedArea), Double(autoArea) * 0.01)
        settings.skinReference?.brushStrokes = nil
        let result = try await engine.preview(url, adjustments: settings, maxEdge: 1200)
        if let output = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
            let target = URL(fileURLWithPath: output)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(target.appendingPathComponent("workflow-preview.png") as CFURL,
                                                                           UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, result, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try JSONEncoder().encode(template).write(to: target.appendingPathComponent("skin-template.json"))
            try await engine.export(url, to: target.appendingPathComponent(UUID().uuidString + ".tiff"), adjustments: settings, format: .tiff, profile: .source)
        }
    }
}
