import XCTest
import CoreImage
import Metal
@testable import ColorEngine

final class LipAndDetailTests: XCTestCase {
    private func profile(_ l: Double, _ a: Double, _ b: Double) -> SkinProfile {
        SkinProfile(sampleCount: 1200, faceWidthPixels: 400,
            lightness: SkinDistribution([l-6,l-3,l,l+3,l+6]),
            redGreen: SkinDistribution([a-2,a-1,a,a+1,a+2]),
            yellowBlue: SkinDistribution([b-2,b-1,b,b+1,b+2]))
    }

    func testIndependentLipControlsAndLegacyDefaults() throws {
        let legacy = try JSONDecoder().decode(ColorAdjustments.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.lipStyle, .manual)
        let context = try context()
        let input = stripes(width: 128, height: 32, base: (0.12,0.035,0.025), amplitude: 0.004)
        let before = pixels(input, context)
        XCTAssertEqual(pixels(try LipProcessing.apply(input, recipe: LipRecipe(), smoothing: 0), context), before)
        let bright = pixels(try LipProcessing.apply(input, recipe: LipRecipe(lightness: 4), smoothing: 0), context)
        let color = pixels(try LipProcessing.apply(input, recipe: LipRecipe(hue: -0.15, chroma: 1.1), smoothing: 0), context)
        let b = meanLab(before, width: 128, x: 12..<116, y: 6..<26)
        let l = meanLab(bright, width: 128, x: 12..<116, y: 6..<26)
        let c = meanLab(color, width: 128, x: 12..<116, y: 6..<26)
        XCTAssertGreaterThan(l.lightness, b.lightness + 2)
        XCTAssertEqual(l.redGreen, b.redGreen, accuracy: 0.15)
        XCTAssertEqual(l.yellowBlue, b.yellowBlue, accuracy: 0.15)
        XCTAssertEqual(c.lightness, b.lightness, accuracy: 0.1)
        XCTAssertNotEqual(c.redGreen, b.redGreen)
    }

    func testAdaptiveLipsPreserveOriginalHueAndUseFinalSkin() throws {
        var settings = ColorAdjustments()
        settings.lipStyle = .original
        settings.lipAdaptation = 1
        let lips = profile(42,24,9)
        let beforeLift = try LipProcessing.recipe(skin: profile(60,14,12), lips: lips, settings: settings, reference: nil)
        let afterLift = try LipProcessing.recipe(skin: profile(74,14,12), lips: lips, settings: settings, reference: nil)
        XCTAssertEqual(beforeLift.hue, 0)
        XCTAssertEqual(beforeLift.lightness, 0)
        XCTAssertEqual(afterLift.lightness, 6, "肤色提亮后重新计算，且限制唇部变化量")
        XCTAssertEqual(afterLift.hue, 0, "保留原色模式不得统一染成玫瑰色")
        settings.lipStyle = .reference
        XCTAssertThrowsError(try LipProcessing.recipe(skin: profile(70,14,12), lips: lips, settings: settings, reference: nil))
        let target = LipReferenceTarget(skin: profile(74,12,10), lips: profile(53,30,10))
        let result = try LipProcessing.recipe(skin: profile(70,14,12), lips: lips, settings: settings, reference: target)
        XCTAssertLessThanOrEqual(abs(result.hue), .pi/10)
        XCTAssertLessThanOrEqual(result.chroma, 1.2)
        XCTAssertEqual(result.lightness, 8)
        var legacy = target
        legacy.appearance = nil
        XCTAssertEqual(try LipProcessing.recipe(skin: profile(70,14,12), lips: lips, settings: settings, reference: legacy).lightness, 6)
        settings.lipBrightness = .nan
        XCTAssertThrowsError(try LipProcessing.recipe(skin: profile(70,14,12), lips: lips, settings: settings, reference: target))
    }

    func testLipTargetsAndIndependentControlsRoundTrip() throws {
        var template = SkinStyleTemplate(name: "相对唇色", reference: profile(74,12,10))
        template.lips = LipReferenceTarget(skin: template.reference, lips: profile(53,30,10))
        try template.validate()
        XCTAssertEqual(try JSONDecoder().decode(SkinStyleTemplate.self, from: JSONEncoder().encode(template)), template)
        var value = Adjustments()
        value.global.lipStyle = .coral
        value.global.lipBrightness = 0.2; value.global.lipHue = -0.1
        value.global.lipChroma = 0.3; value.global.lipSmoothing = 0.15
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(value)), value)
        template.lips?.reliability = -1
        XCTAssertThrowsError(try template.validate())
    }

    func testAbsoluteLipReferenceDoesNotAmplifyChromaWithSkinChroma() throws {
        var settings = ColorAdjustments()
        settings.lipStyle = .reference; settings.lipAdaptation = 1
        let target = LipReferenceTarget(skin: profile(74,10,8), lips: profile(56,23,11))
        let lips = profile(49,34,12)
        let a = try LipProcessing.recipe(skin: profile(70,10,8), lips: lips, settings: settings, reference: target)
        let b = try LipProcessing.recipe(skin: profile(70,22,18), lips: lips, settings: settings, reference: target)
        XCTAssertEqual(a.chroma, b.chroma)
        XCTAssertEqual(a.hue, b.hue)
        XCTAssertLessThan(a.chroma, 1)
        var value = Adjustments()
        var layer = AdjustmentLayer(mask: .lips)
        var template = SkinStyleTemplate(name: "独立唇色", reference: profile(74,10,8))
        template.lips = target; layer.lipReference = template; value.layers = [layer]
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(value)), value)
    }

    func testRealAdaptiveLipColorStaysInsideMask() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for the adaptive lips integration check")
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("DSC00681.JPG")
        let engine = ColorEngine()
        var layer = AdjustmentLayer(mask: .lips)
        layer.adjustments.lipStyle = .rose
        layer.adjustments.lipBrightness = 0.25
        layer.adjustments.lipChroma = -0.3
        var settings = Adjustments()
        settings.layers = [layer]
        let baseline = try await engine.preview(url, adjustments: Adjustments(), maxEdge: 1200, profile: .sRGB)
        let result = try await engine.preview(url, adjustments: settings, maxEdge: 1200, profile: .sRGB)
        let mask = try await engine.preview(url, adjustments: settings, maxEdge: 1200,
                                            maskLayerID: layer.id, profile: .sRGB)
        let context = try context()
        let before = pixels(CIImage(cgImage: baseline), context)
        let after = pixels(CIImage(cgImage: result), context)
        let weights = pixels(CIImage(cgImage: mask), context)
        var changed = 0, outside = 0, maxOutside = 0.0
        for i in stride(from: 0, to: before.count, by: 4) {
            let difference = (0..<3).map { abs(Double(before[i+$0] - after[i+$0])) }.max()!
            if weights[i] > 0.8 && difference > 0.002 { changed += 1 }
            if weights[i] < 0.0001 {
                outside += 1
                maxOutside = max(maxOutside, difference)
            }
        }
        XCTAssertGreaterThan(changed, 10, "正常混合必须保留唇色变化，不能误走明度混合")
        XCTAssertGreaterThan(outside, baseline.width * baseline.height / 2)
        XCTAssertLessThan(maxOutside, 0.008, "唇部调整不得污染背景与服装")
        var template = SkinStyleTemplate(name: "参考报告阶段", reference: profile(72,14,12))
        template.lips = LipReferenceTarget(skin: template.reference, lips: profile(51,28,10))
        settings.skinReference = SkinReferenceApplication(template: template)
        settings.skinReference?.bodyHarmonization = 0
        settings.layers[0].adjustments.lipStyle = .reference
        let reports = try await engine.skinReferenceReports(url, adjustments: settings)
        XCTAssertFalse(reports.isEmpty, "肤色报告不应提前执行依赖模板的唇部阶段")
    }
    private func context() throws -> CIContext {
        CIContext(mtlDevice: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: [
            .workingColorSpace: SkinColorMath.linearP3, .workingFormat: CIFormat.RGBAf
        ])
    }

    /// Alternating one-pixel columns give a measurable fine-detail band without
    /// introducing a strong edge that the halo guard would suppress.
    private func stripes(width: Int, height: Int, base: (Float, Float, Float), amplitude: Float) -> CIImage {
        var values = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let delta: Float = x.isMultiple(of: 2) ? amplitude : -amplitude
                let i = (y * width + x) * 4
                values[i] = base.0 + delta
                values[i + 1] = base.1 + delta
                values[i + 2] = base.2 + delta
                values[i + 3] = 1
            }
        }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: SkinColorMath.linearP3)
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

    private func mean(_ values: [Float], width: Int, channel: Int, x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0.0, count = 0
        for row in y {
            for column in x {
                sum += Double(values[(row * width + column) * 4 + channel])
                count += 1
            }
        }
        return sum / Double(count)
    }

    private func stripeContrast(_ values: [Float], width: Int, channel: Int, x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0.0, count = 0
        for row in y {
            for column in x {
                let a = values[(row * width + column) * 4 + channel]
                let b = values[(row * width + column + 1) * 4 + channel]
                sum += Double(abs(a - b))
                count += 1
            }
        }
        return sum / Double(count)
    }

    private func meanLab(_ values: [Float], width: Int, x: Range<Int>, y: Range<Int>) -> (lightness: Double, redGreen: Double, yellowBlue: Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for row in y {
            for column in x {
                let i = (row * width + column) * 4
                r += Double(values[i]); g += Double(values[i + 1]); b += Double(values[i + 2])
            }
        }
        let count = Double(x.count * y.count)
        r /= count; g /= count; b /= count
        func f(_ t: Double) -> Double { t > 0.0088564517 ? pow(t, 1.0 / 3.0) : (903.296296 * t + 16.0) / 116.0 }
        let fx = f((0.4865709486 * r + 0.2656676932 * g + 0.1982172852 * b) / 0.9504559271)
        let fy = f(0.2289745641 * r + 0.6917385218 * g + 0.0792869141 * b)
        let fz = f((0.0451133819 * g + 1.0439443689 * b) / 1.0890577508)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    func testLipPolishLiftsRoseTintAndSoftensLipLines() throws {
        let context = try context()
        let width = 256, height = 64
        let input = stripes(width: width, height: height, base: (0.09, 0.015, 0.012), amplitude: 0.01)
        let polished = try SelectiveColor.polishLips(input, amount: 1)

        let before = pixels(input, context)
        let after = pixels(polished, context)
        let x = 20..<(width - 20), y = 8..<(height - 8)

        let redBefore = mean(before, width: width, channel: 0, x: x, y: y)
        let redAfter = mean(after, width: width, channel: 0, x: x, y: y)
        XCTAssertGreaterThan(redAfter, redBefore)
        let labBefore = meanLab(before, width: width, x: x, y: y)
        let labAfter = meanLab(after, width: width, x: x, y: y)
        XCTAssertGreaterThan(labAfter.lightness, labBefore.lightness, "唇部优化应提亮暗唇")
        XCTAssertGreaterThan(labAfter.redGreen, labBefore.redGreen, "唇部优化应增加红润")
        XCTAssertLessThan(labAfter.yellowBlue, labBefore.yellowBlue, "唇部优化应减少黄感")

        let linesBefore = stripeContrast(before, width: width, channel: 0, x: x, y: y)
        let linesAfter = stripeContrast(after, width: width, channel: 0, x: x, y: y)
        XCTAssertLessThan(linesAfter, linesBefore * 0.9, "唇部优化应淡化细唇纹")
    }

    func testSkinDetailRestoresFineTextureWithoutChangingFlatSkin() throws {
        let context = try context()
        let width = 256, height = 64
        let input = stripes(width: width, height: height, base: (0.35, 0.22, 0.16), amplitude: 0.01)
        var settings = ColorAdjustments()
        settings.skinDetail = 1
        let detailed = try SkinProcessing.apply(input, settings: settings, cheeks: nil)

        let before = pixels(input, context)
        let after = pixels(detailed, context)
        let x = 20..<(width - 20), y = 8..<(height - 8)
        XCTAssertGreaterThan(stripeContrast(after, width: width, channel: 0, x: x, y: y),
                             stripeContrast(before, width: width, channel: 0, x: x, y: y) * 1.2)

        var disabled = ColorAdjustments()
        disabled.skinDetail = 0
        let unchanged = try SkinProcessing.apply(input, settings: disabled, cheeks: nil)
        XCTAssertEqual(pixels(unchanged, context), before)
    }

    func testChromaCompensationIsOnForNewApplicationsButOffForLegacyJSON() throws {
        let profile = SkinProfile(sampleCount: 1000, faceWidthPixels: 300,
                                  lightness: SkinDistribution([58, 60, 62, 64, 66]),
                                  redGreen: SkinDistribution([12, 14, 16, 18, 20]),
                                  yellowBlue: SkinDistribution([10, 12, 14, 16, 18]))
        let template = SkinStyleTemplate(name: "参考", reference: profile)
        let application = SkinReferenceApplication(template: template)
        XCTAssertEqual(application.chromaCompensation, 0.8)
        XCTAssertEqual(try JSONDecoder().decode(SkinReferenceApplication.self,
                                                from: JSONEncoder().encode(application)), application)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(application)) as? [String: Any])
        json.removeValue(forKey: "chromaCompensation")
        let legacy = try JSONDecoder().decode(SkinReferenceApplication.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.chromaCompensation, "旧项目缺少字段时必须保持关闭")
    }
}
