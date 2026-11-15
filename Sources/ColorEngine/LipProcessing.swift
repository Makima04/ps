import CoreImage
import Foundation

public enum LipStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, original, pink, rose, coral, reference
    public var id: Self { self }
    public var label: String {
        switch self {
        case .manual: "手动微调"
        case .original: "保留原色 · 自动协调"
        case .pink: "自然粉"
        case .rose: "柔玫瑰"
        case .coral: "暖珊瑚"
        case .reference: "借鉴参考唇色"
        }
    }
}

/// Relative appearance, measured from the same reference face and lip selection.
public struct LipAppearance: Codable, Equatable, Sendable {
    public var lightness: Double
    public var redGreen: Double
    public var yellowBlue: Double
    public var skinLightness: Double
}

public struct LipReferenceTarget: Codable, Equatable, Sendable {
    public var lightnessDifference: Double
    public var hueDifference: Double
    public var chromaRatio: Double
    public var reliability: Double
    /// Optional in older templates. Absolute color prevents pale reference skin
    /// from amplifying lip chroma on a more colorful target face.
    public var appearance: LipAppearance?

    init(skin: SkinProfile, lips: SkinProfile) {
        lightnessDifference = lips.lightness.median - skin.lightness.median
        hueDifference = LipProcessing.angle(atan2(lips.yellowBlue.median, lips.redGreen.median)
            - atan2(skin.yellowBlue.median, skin.redGreen.median))
        chromaRatio = hypot(lips.redGreen.median, lips.yellowBlue.median)
            / max(8, hypot(skin.redGreen.median, skin.yellowBlue.median))
        reliability = min(skin.reliability, min(1, Double(lips.sampleCount) / 180))
        appearance = LipAppearance(lightness: lips.lightness.median, redGreen: lips.redGreen.median,
            yellowBlue: lips.yellowBlue.median, skinLightness: skin.lightness.median)
    }

    func validate() throws {
        if let appearance {
            guard [appearance.lightness, appearance.redGreen, appearance.yellowBlue, appearance.skinLightness].allSatisfy(\.isFinite),
                  (15...97).contains(appearance.lightness), (15...97).contains(appearance.skinLightness),
                  (-100...100).contains(appearance.redGreen), (-100...100).contains(appearance.yellowBlue) else {
                throw ImageError.maskFailed("参考唇色外观目标无效")
            }
        }
        guard [lightnessDifference, hueDifference, chromaRatio, reliability].allSatisfy(\.isFinite),
              (-100...100).contains(lightnessDifference), (-Double.pi...Double.pi).contains(hueDifference),
              (0...12).contains(chromaRatio), (0...1).contains(reliability) else {
            throw ImageError.maskFailed("参考唇色数据无效")
        }
    }
}

struct LipRecipe {
    var lightness = 0.0
    var hue = 0.0
    var chroma = 1.0
}

public struct LipAdaptationReport: Codable, Sendable {
    public let faceIndex: Int
    public let source: SkinProfile
    public let after: SkinProfile
    public let lightnessChange: Double
    public let hueChangeDegrees: Double
    public let chromaScale: Double
    public let referenceName: String?
}

enum LipProcessing {
    static func angle(_ value: Double) -> Double { atan2(sin(value), cos(value)) }

    static func validate(_ settings: ColorAdjustments) throws {
        let values = [settings.lipAdaptation, settings.lipBrightness, settings.lipHue,
                      settings.lipChroma, settings.lipSmoothing]
        guard values.allSatisfy(\.isFinite), (0...1).contains(settings.lipAdaptation),
              (-1...1).contains(settings.lipBrightness), (-1...1).contains(settings.lipHue),
              (-1...1).contains(settings.lipChroma), (0...1).contains(settings.lipSmoothing) else {
            throw ImageError.maskFailed("唇部参数超出范围")
        }
    }

    static func recipe(skin: SkinProfile, lips: SkinProfile, settings: ColorAdjustments,
                       reference: LipReferenceTarget?) throws -> LipRecipe {
        try validate(settings)
        let faceL = skin.lightness.median, lipL = lips.lightness.median
        let faceC = hypot(skin.redGreen.median, skin.yellowBlue.median)
        let lipC = hypot(lips.redGreen.median, lips.yellowBlue.median)
        let lipH = atan2(lips.yellowBlue.median, lips.redGreen.median)
        // Keep a range of natural lip/skin contrast instead of forcing one brightness.
        var targetL = min(faceL - 12, max(faceL - 25, lipL))
        var targetH = lipH
        var targetC = max(lipC, min(lipC * 1.15, faceC * 1.12))
        var maxLift = 6.0
        var strength = settings.lipStyle == .manual ? 0 : settings.lipAdaptation
        switch settings.lipStyle {
        case .pink: targetH = 8 * .pi / 180
        case .rose: targetH = 18 * .pi / 180
        case .coral: targetH = 34 * .pi / 180
        case .reference where strength > 0:
            guard let reference else { throw ImageError.maskFailed("当前参考模板没有可靠唇色，请重新导入参考图或选择其他模式") }
            try reference.validate()
            targetL = faceL + max(-30, min(-10, reference.lightnessDifference))
            targetH = atan2(skin.yellowBlue.median, skin.redGreen.median) + reference.hueDifference
            targetC = faceC * reference.chromaRatio
            if let appearance = reference.appearance {
                // A small scene-dependent brightness compensation preserves the
                // chosen appearance without copying one photo's adjustment amount.
                targetL = appearance.lightness + max(-3, min(3, (faceL - appearance.skinLightness) * 0.25))
                targetH = atan2(appearance.yellowBlue, appearance.redGreen)
                targetC = hypot(appearance.redGreen, appearance.yellowBlue)
                maxLift = 8
            }
            strength *= reference.reliability
        case .manual, .original, .reference: break
        }
        return LipRecipe(
            lightness: max(-4, min(maxLift, targetL - lipL)) * strength + settings.lipBrightness * 6,
            hue: max(-.pi / 10, min(.pi / 10, angle(targetH - lipH))) * strength + settings.lipHue * .pi / 10,
            chroma: (1 + (max(0.75, min(1.2, targetC / max(4, lipC))) - 1) * strength)
                * (1 + settings.lipChroma * 0.35))
    }

    private static let kernel: Result<CIColorKernel, Error> = Result {
        let source = SkinProcessing.colorHelpers + """
        [[ stitchable ]] float4 adjustLipAppearance(coreimage::sample_t p, coreimage::sample_t fine,
                coreimage::sample_t broad, float lightness, float hue, float chroma, float smoothing) {
            float3 lab=toLab(p.rgb/max(p.a,0.000001));
            float3 mid=toLab(fine.rgb/max(fine.a,0.000001));
            float3 low=toLab(broad.rgb/max(broad.a,0.000001));
            float protect=smoothstep(8.0,23.0,lab.x)*(1-smoothstep(74.0,95.0,lab.x));
            float border=1-smoothstep(5.0,16.0,length(lab.yz-low.yz));
            lab.x-=smoothing*0.3*(lab.x-mid.x)*border*protect;
            lab.x+=lightness*protect;
            float2 rotated=float2(cos(hue)*lab.y-sin(hue)*lab.z,
                                  sin(hue)*lab.y+cos(hue)*lab.z)*chroma;
            lab.yz=mix(lab.yz,rotated,protect);
            return float4(fromLab(lab)*p.a,p.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建独立唇部算子")
        }
        return kernel
    }

    static func apply(_ image: CIImage, recipe: LipRecipe, smoothing: Double) throws -> CIImage {
        guard recipe.lightness != 0 || recipe.hue != 0 || recipe.chroma != 1 || smoothing != 0 else { return image }
        let edge = max(image.extent.width, image.extent.height)
        let fine = image.clampedToExtent().applyingGaussianBlur(sigma: max(0.6, edge * 0.00025)).cropped(to: image.extent)
        let broad = image.clampedToExtent().applyingGaussianBlur(sigma: max(2, edge * 0.002)).cropped(to: image.extent)
        guard let output = try kernel.get().apply(extent: image.extent,
            arguments: [image, fine, broad, recipe.lightness, recipe.hue, recipe.chroma, smoothing]) else {
            throw ImageError.maskFailed("唇部调整失败")
        }
        return output
    }
}
