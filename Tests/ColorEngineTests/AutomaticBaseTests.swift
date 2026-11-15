import XCTest
import CoreImage
import Metal
@testable import ColorEngine

final class AutomaticBaseTests: XCTestCase {
    private func context() throws -> CIContext {
        CIContext(mtlDevice: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: [
            .workingColorSpace: SkinColorMath.linearP3, .workingFormat: CIFormat.RGBAf
        ])
    }
    private func values(_ image: CIImage, context: CIContext, rect: CGRect? = nil) -> [Float] {
        let rect = rect ?? image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var data = [Float](repeating: 0, count: w*h*4)
        data.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: rect,
                           format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        }
        return data
    }
    func testAutomaticExposureIsAdaptiveAndBounded() throws {
        let scene = SceneToneProfile(median: 34, highlights: 85, neutralA: 2, neutralB: 3, neutralCount: 1000, sampleCount: 10000)
        let settings = AutomaticBaseSettings()
        let dark = try AutomaticBase.recipe(scene: scene, faceL: 27, settings: settings)
        let normal = try AutomaticBase.recipe(scene: scene, faceL: 55, settings: settings)
        XCTAssertGreaterThan(dark.subjectEV, 1)
        XCTAssertLessThanOrEqual(dark.subjectEV, settings.maxSubjectEV)
        XCTAssertLessThanOrEqual(dark.globalEV, settings.maxGlobalEV)
        XCTAssertEqual(AutomaticBase.mappedLightness(27, ev: dark.globalEV+dark.subjectEV), 53, accuracy: 0.01)
        XCTAssertEqual(normal.globalEV, 0); XCTAssertEqual(normal.subjectEV, 0)
        var zero = settings; zero.strength = 0; zero.correctColorCast = true
        let off = try AutomaticBase.recipe(scene: scene, faceL: 27, settings: zero)
        XCTAssertEqual(off.globalEV, 0); XCTAssertEqual(off.subjectEV, 0)
        XCTAssertEqual(off.colorDeltaA, 0); XCTAssertEqual(off.colorDeltaB, 0)
        zero.strength = .nan
        XCTAssertThrowsError(try AutomaticBase.recipe(scene: scene, faceL: 27, settings: zero))
    }
    func testColorCastCorrectionRequiresEnoughNeutralSamples() throws {
        var settings = AutomaticBaseSettings(); settings.correctColorCast = true
        let scarce = SceneToneProfile(median: 40, highlights: 90, neutralA: 4, neutralB: 5, neutralCount: 10, sampleCount: 10000)
        let noCast = try AutomaticBase.recipe(scene: scarce, faceL: 55, settings: settings)
        XCTAssertEqual(noCast.colorDeltaA, 0); XCTAssertEqual(noCast.colorDeltaB, 0)
        XCTAssertFalse(noCast.warnings.isEmpty)
        let reliable = SceneToneProfile(median: 40, highlights: 90, neutralA: 4, neutralB: 5, neutralCount: 3000, sampleCount: 10000)
        let corrected = try AutomaticBase.recipe(scene: reliable, faceL: 55, settings: settings)
        XCTAssertEqual(corrected.colorDeltaA, -2); XCTAssertEqual(corrected.colorDeltaB, -3)
    }
    func testTonalLiftPreservesBlackWhiteAndMonotonicExtendedHighlights() throws {
        let context = try context(), w = 1024
        var pixels = [Float](repeating: 1, count: w*4)
        for x in 0..<w { for c in 0..<3 { pixels[x*4+c] = Float(x)/Float(w-1)*1.2 } }
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: w*16,
                            size: CGSize(width: w, height: 1), format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        let after = values(try AutomaticBase.tone(image, ev: 2.5), context: context)
        XCTAssertEqual(after[0], 0, accuracy: 0.000001)
        XCTAssertGreaterThan(after[(w-1)*4], 1)
        for x in 1..<w { XCTAssertGreaterThan(after[x*4], after[(x-1)*4]) }
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: SkinColorMath.linearP3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(values(try AutomaticBase.tone(white, ev: 2.5), context: context)[0], 1, accuracy: 0.00001)
    }
    func testTonalLiftPreservesChromaAndNeutralCastPreservesLightness() throws {
        let context = try context()
        let image = CIImage(color: CIColor(red: 0.45, green: 0.35, blue: 0.28, colorSpace: SkinColorMath.linearP3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        func lab(_ image: CIImage) -> (Double,Double,Double) {
            let p = values(image, context: context)
            return SkinColorMath.lab(Double(p[0]),Double(p[1]),Double(p[2]))
        }
        let before = lab(image)
        let lifted = lab(try AutomaticBase.tone(image, ev: 2))
        XCTAssertGreaterThan(lifted.0, before.0)
        XCTAssertEqual(lifted.1, before.1, accuracy: 0.0001)
        XCTAssertEqual(lifted.2, before.2, accuracy: 0.0001)
        let corrected = lab(try SkinProcessing.correctNeutralCast(image, deltaA: -2, deltaB: -3))
        XCTAssertEqual(corrected.0, before.0, accuracy: 0.0001)
        XCTAssertLessThan(corrected.1, before.1-1)
        XCTAssertLessThan(corrected.2, before.2-2)
    }

    func testConnectedBodyComponentsKeepBottomLeftCoordinatesAndRejectTinyFragments() throws {
        let context = try context(), extent = CGRect(x: 0, y: 0, width: 320, height: 240)
        let rects = [CGRect(x: 30, y: 25, width: 30, height: 22), CGRect(x: 220, y: 170, width: 24, height: 25)]
        var mask = CIImage(color: .black).cropped(to: extent)
        for rect in rects + [CGRect(x: 150, y: 50, width: 2, height: 2)] {
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }
        let components = try BodySkinComponents.regions(mask, context: context)
        XCTAssertEqual(components.count, 2)
        for (i, rect) in rects.enumerated() {
            XCTAssertTrue(components[i].bounds.contains(CGPoint(x: rect.midX, y: rect.midY)))
            let center = CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1)
            XCTAssertGreaterThan(values(components[i].mask, context: context, rect: center)[0], 0.9)
            let other = rects[1-i]
            XCTAssertLessThan(values(components[i].mask, context: context,
                                     rect: CGRect(x: other.midX, y: other.midY, width: 1, height: 1))[0], 0.01)
        }
    }
    func testNewOptionsRoundTripAndOldProjectsDoNotEnableAutomaticCorrections() throws {
        let data = Data("{\"layers\":[]}".utf8)
        let legacy = try JSONDecoder().decode(Adjustments.self, from: data)
        XCTAssertNil(legacy.automaticBase)
        var settings = legacy; settings.automaticBase = AutomaticBaseSettings()
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings)), settings)
        let profile = SkinProfile(sampleCount: 1000, faceWidthPixels: 300, lightness: SkinDistribution([50,60,70]),
                                  redGreen: SkinDistribution([10,15,20]), yellowBlue: SkinDistribution([12,16,20]))
        var application = SkinReferenceApplication(template: SkinStyleTemplate(name: "参考", reference: profile))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(application)) as? [String: Any])
        json.removeValue(forKey: "bodyHarmonization")
        application = try JSONDecoder().decode(SkinReferenceApplication.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(application.bodyHarmonization)
    }
    func testAutomaticCorrectionAndBodyCoordinationOnBothSamplePhotos() async throws {
        guard let path = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for adaptive portrait acceptance")
        }
        let engine = ColorEngine()
        let reference = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PS_REFERENCE_PHOTO"] ??
            "/Users/makima/program/Ps/PhotoLibrary/参考/单图追色/奶油肤色参考.png")
        let template = try await engine.makeSkinTemplate(reference, name: "测试参考")
        for stem in ["DSC00681", "DSC00753"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(stem+".JPG")
            var settings = Adjustments()
            settings.automaticBase = AutomaticBaseSettings()
            settings.skinReference = SkinReferenceApplication(template: template)
            let automatic = try await engine.automaticBaseReport(url, adjustments: settings)
            if stem == "DSC00681" { XCTAssertEqual(automatic.subjectEV, 0) }
            else {
                XCTAssertGreaterThan(automatic.subjectEV, 1)
                XCTAssertGreaterThan(try XCTUnwrap(automatic.faceLightnessAfter), 48)
            }
            let reports = try await engine.skinReferenceReports(url, adjustments: settings)
            let report = try XCTUnwrap(reports.first)
            XCTAssertEqual(report.bodyReports.count, 2, "Both hands should have reliable independent samples")
            for body in report.bodyReports {
                func distance(_ p: SkinProfile) -> Double {
                    pow(p.lightness.median-body.targetLightness,2) + pow(p.redGreen.median-body.targetRed,2) +
                    pow(p.yellowBlue.median-body.targetYellow,2)
                }
                XCTAssertLessThanOrEqual(distance(body.after), distance(body.before)+0.1)
                XCTAssertGreaterThanOrEqual(body.after.lightness.median, body.before.lightness.median-0.05,
                    "Body coordination must not darken naturally sunlit skin")
                XCTAssertLessThanOrEqual(body.after.clippedFraction, body.before.clippedFraction+0.005)
                print(stem,"body L*",body.before.lightness.median,"→",body.after.lightness.median,
                      "b*",body.before.yellowBlue.median,"→",body.after.yellowBlue.median)
            }
            // Zero reference strength disables its body coordination as well.
            settings.skinReference?.strength = 0
            let disabled = try await engine.skinReferenceReports(url, adjustments: settings)
            XCTAssertTrue(disabled.allSatisfy { $0.bodyReports.isEmpty })
            settings.skinReference?.strength = 0.75
            if let root = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
                let folder = URL(fileURLWithPath: root)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent(stem+"-adaptive-test.tiff")
                try? FileManager.default.removeItem(at: output)
                try await engine.export(url, to: output, adjustments: settings, format: .tiff, profile: .sRGB)
                let preview = try await engine.preview(url, adjustments: settings, maxEdge: nil, profile: .sRGB)
                let exported = try await engine.preview(output, adjustments: Adjustments(), maxEdge: nil,
                                                        profile: .sRGB, preferRAW: false)
                let a = try XCTUnwrap(preview.dataProvider?.data) as Data
                let b = try XCTUnwrap(exported.dataProvider?.data) as Data
                XCTAssertEqual(preview.width, exported.width)
                XCTAssertEqual(preview.height, exported.height)
                XCTAssertEqual(a.count, b.count)
                // Compare physical-resolution pixels across a staggered grid. Resize
                // after clipping is intentionally avoided: it has a different order
                // from clipping a floating-point image after resizing.
                var maxError = 0
                a.withUnsafeBytes { (aa: UnsafeRawBufferPointer) in
                    b.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                        for i in stride(from: 0, to: min(aa.count,bb.count)-3, by: 4*31) {
                            for channel in 0..<3 { maxError = max(maxError,abs(Int(aa[i+channel])-Int(bb[i+channel]))) }
                        }
                    }
                }
                XCTAssertLessThanOrEqual(maxError, 2)
            }
        }
    }

}
