import CoreImage
import Foundation

public struct AutomaticBaseSettings: Codable, Equatable, Sendable {
    public var strength = 1.0
    public var targetFaceLightness = 53.0
    public var maxGlobalEV = 0.6
    public var maxSubjectEV = 2.5
    public var correctColorCast = false
    public init() {}
    func validate() throws {
        guard [strength, targetFaceLightness, maxGlobalEV, maxSubjectEV].allSatisfy(\.isFinite),
              (0...1).contains(strength), (35...65).contains(targetFaceLightness),
              (0...1).contains(maxGlobalEV), (0...3).contains(maxSubjectEV) else {
            throw ImageError.maskFailed("自动基础校正参数无效")
        }
    }
}

public struct AutomaticBaseReport: Codable, Sendable {
    public let sceneMedianLightness: Double
    public let faceLightnessBefore: Double?
    public let faceLightnessAfter: Double?
    /// Highlight-preserving tonal EV, not an unbounded linear exposure multiplier.
    public let globalEV: Double
    public let subjectEV: Double
    public let neutralSamples: Int
    public let colorDeltaA: Double
    public let colorDeltaB: Double
    public let warnings: [String]
}

struct SceneToneProfile {
    let median: Double
    let highlights: Double
    let neutralA: Double
    let neutralB: Double
    let neutralCount: Int
    let sampleCount: Int
    static func measure(_ image: CIImage, context: CIContext) -> Self {
        let scale = min(1, 360 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        var pixels = [Float](repeating: 0, count: w*h*4)
        pixels.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: rect,
                           format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        }
        var lights: [Double] = [], aa: [Double] = [], bb: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i+3] > 0.99 {
            let (l,a,b) = SkinColorMath.lab(Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2]))
            guard l.isFinite, a.isFinite, b.isFinite else { continue }
            lights.append(l)
            if l > 50 && l < 90 && hypot(a,b) < 12 { aa.append(a); bb.append(b) }
        }
        let light = SkinDistribution(lights)
        return Self(median: light.median, highlights: light.p90, neutralA: SkinDistribution(aa).median,
                    neutralB: SkinDistribution(bb).median, neutralCount: aa.count, sampleCount: lights.count)
    }
}

enum AutomaticBase {
    static func luminance(_ l: Double) -> Double {
        l > 8 ? pow((l + 16) / 116, 3) : l / 903.296296
    }
    static func lightness(_ y: Double) -> Double {
        y > 216.0/24389 ? 116*cbrt(y)-16 : 903.296296*y
    }
    static func neededEV(from l: Double, to target: Double) -> Double {
        let sourceY = min(0.99, max(0.0001, luminance(l)))
        let targetY = min(0.99, max(0.0001, luminance(target)))
        return log2(targetY/(1-targetY)) - log2(sourceY/(1-sourceY))
    }
    static func mappedLightness(_ l: Double, ev: Double) -> Double {
        let y = luminance(l), gain = exp2(ev)
        return lightness(y * gain / (1 + y * (gain - 1)))
    }
    static func recipe(scene: SceneToneProfile, faceL: Double?, settings: AutomaticBaseSettings) throws -> AutomaticBaseReport {
        try settings.validate()
        let target = settings.targetFaceLightness
        let needsLift = (faceL ?? scene.median) < target - 3
        let global = needsLift && scene.median < 38
            ? max(0, min(settings.maxGlobalEV, neededEV(from: scene.median, to: 40))) * settings.strength : 0
        let subject = faceL.map { max(0, min(settings.maxSubjectEV,
            neededEV(from: mappedLightness($0, ev: global), to: target))) * settings.strength } ?? 0
        let enoughNeutrals = scene.neutralCount >= max(150, scene.sampleCount / 100)
        let a = settings.correctColorCast && enoughNeutrals ? -max(-2, min(2, scene.neutralA)) * settings.strength : 0
        let b = settings.correctColorCast && enoughNeutrals ? -max(-3, min(3, scene.neutralB)) * settings.strength : 0
        var warnings: [String] = []
        if faceL == nil { warnings.append("没有可靠脸部采样，仅估计全图校正") }
        if settings.correctColorCast && !enoughNeutrals { warnings.append("可靠中性色不足，未调整偏色") }
        if subject >= settings.maxSubjectEV * settings.strength - 0.01 && subject > 0 {
            warnings.append("人物提亮已达上限，可继续手动微调")
        }
        return AutomaticBaseReport(sceneMedianLightness: scene.median, faceLightnessBefore: faceL,
                                   faceLightnessAfter: nil, globalEV: global, subjectEV: subject,
                                   neutralSamples: scene.neutralCount, colorDeltaA: a, colorDeltaB: b, warnings: warnings)
    }
    private static let kernel: Result<CIColorKernel, Error> = Result {
        let metal = SkinProcessing.colorHelpers + """
        [[ stitchable ]] float4 autoPortraitTone(coreimage::sample_t p, float ev) {
            float3 rgb=p.rgb/max(p.a,0.000001);
            float y=dot(rgb,float3(0.2289745641,0.6917385218,0.0792869141));
            // Monotone, zero- and white-point preserving; extended highlights remain >1.
            float gain=exp2(ev);
            float mapped=y*gain/(1+max(y,0.0)*(gain-1));
            // Lift lightness while retaining measured Lab chroma; strong shadow
            // lifts must not turn pink clothing or cheeks into saturated red.
            float3 lab=toLab(rgb);
            lab.x=mapped>0.0088564517 ? 116*pow(mapped,1.0/3.0)-16 : 903.296296*mapped;
            return float4(fromLab(lab)*p.a,p.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建自动曝光算子")
        }
        return kernel
    }
    static func tone(_ image: CIImage, ev: Double) throws -> CIImage {
        guard ev > 0 else { return image }
        guard let result = try kernel.get().apply(extent: image.extent, arguments: [image, ev]) else {
            throw ImageError.maskFailed("自动曝光失败")
        }
        return result
    }
}
