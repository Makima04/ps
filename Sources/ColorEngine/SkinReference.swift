import CoreImage
import Foundation

public struct SkinDistribution: Codable, Equatable, Sendable {
    public var p10: Double
    public var p25: Double
    public var median: Double
    public var p75: Double
    public var p90: Double

    public init(_ values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        func q(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let position = fraction * Double(sorted.count - 1)
            let i = Int(position), j = min(i + 1, sorted.count - 1)
            return sorted[i] + (sorted[j] - sorted[i]) * (position - Double(i))
        }
        p10 = q(0.1); p25 = q(0.25); median = q(0.5); p75 = q(0.75); p90 = q(0.9)
    }
}

public struct SkinProfile: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let faceWidthPixels: Double
    public var lightness: SkinDistribution
    public var redGreen: SkinDistribution
    public var yellowBlue: SkinDistribution
    public let clippedFraction: Double

    public init(sampleCount: Int, faceWidthPixels: Double, lightness: SkinDistribution,
                redGreen: SkinDistribution, yellowBlue: SkinDistribution, clippedFraction: Double = 0) {
        self.sampleCount = sampleCount; self.faceWidthPixels = faceWidthPixels
        self.lightness = lightness; self.redGreen = redGreen; self.yellowBlue = yellowBlue
        self.clippedFraction = clippedFraction
    }

    public var warnings: [String] {
        var result: [String] = []
        if faceWidthPixels < 160 { result.append("参考人脸较小，仅借鉴肤色；不提取纹理") }
        if sampleCount < 600 { result.append("有效皮肤采样较少，已降低参考权重") }
        if clippedFraction > 0.03 { result.append("皮肤高光存在溢出，已降低参考权重") }
        if lightness.p90 - lightness.p10 < 6 { result.append("参考明暗层次较少，保留原片层次") }
        return result
    }
    public var reliability: Double {
        let samples = min(1, Double(sampleCount) / 600)
        let size = min(1, max(0.45, faceWidthPixels / 160))
        return max(0.2, samples * size * (clippedFraction > 0.03 ? 0.6 : 1))
    }
}

/// A reusable appearance target, never an inference of another editor's parameters.
public struct SkinStyleTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var version = 1
    public var name: String
    public var reference: SkinProfile
    public var targetLightness: Double
    public var targetRed: Double
    public var targetYellow: Double
    public var maxLightnessChange = 12.0
    public var maxColorChange = 8.0
    public var preserveContrast = true
    public var protectCheeks = true
    public var scene = "未分组"
    public var lips: LipReferenceTarget?

    public init(name: String, reference: SkinProfile) {
        self.name = name; self.reference = reference
        targetLightness = reference.lightness.median
        targetRed = reference.redGreen.median
        targetYellow = reference.yellowBlue.median
    }

    public func validate() throws {
        try lips?.validate()
        let values = [targetLightness, targetRed, targetYellow, maxLightnessChange, maxColorChange,
                      reference.faceWidthPixels, reference.clippedFraction, reference.reliability]
        let distributions = [reference.lightness, reference.redGreen, reference.yellowBlue]
        guard version == 1, values.allSatisfy(\.isFinite), reference.sampleCount >= 200,
              reference.faceWidthPixels > 0, (0...1).contains(reference.clippedFraction),
              (15...95).contains(targetLightness), (-30...50).contains(targetRed),
              (-30...60).contains(targetYellow), (0...14).contains(maxLightnessChange),
              (0...10).contains(maxColorChange), distributions.allSatisfy({ d in
                  let q = [d.p10, d.p25, d.median, d.p75, d.p90]
                  return q.allSatisfy(\.isFinite) && zip(q, q.dropFirst()).allSatisfy { $0 <= $1 }
              }) else { throw ImageError.maskFailed("参考模板数据或版本无效") }
    }
}

public struct SkinReferenceApplication: Codable, Equatable, Sendable {
    public var template: SkinStyleTemplate
    public var strength = 0.75
    public var lightnessAmount = 1.0
    public var colorAmount = 1.0
    public var includeNeck = true
    public var faceIndex: Int?
    public var brushStrokes: [MaskStroke]?
    /// nil in older projects: body coordination is explicitly opt-in there.
    public var bodyHarmonization: Double? = 0.8
    public var bodyBrushStrokes: [MaskStroke]?
    /// 0...1 automatic chroma compensation after a large lift. nil on older
    /// projects keeps the previous output; new applications opt in.
    public var chromaCompensation: Double?
    public init(template: SkinStyleTemplate) {
        self.template = template
        self.chromaCompensation = 0.8
    }
}

public struct SkinAdaptation: Codable, Equatable, Sendable {
    public let source: SkinProfile
    public let templateID: UUID
    public var strength: Double
    public let lightnessScale: Double
    public let redScale: Double
    public let yellowScale: Double
    public let deltaL: Double
    public let deltaA: Double
    public let deltaB: Double

    public init(source: SkinProfile, application: SkinReferenceApplication, preserveColorSpread: Bool = false) throws {
        try application.template.validate()
        guard [application.strength, application.lightnessAmount, application.colorAmount]
            .allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              application.bodyHarmonization.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw ImageError.maskFailed("参考强度必须为 0 到 1")
        }
        let target = application.template
        self.source = source; templateID = target.id
        strength = application.strength * target.reference.reliability
        func ratio(_ a: SkinDistribution, _ b: SkinDistribution, lower: Double) -> Double {
            if a.p75 - a.p25 < 1 || b.p75 - b.p25 < 1 { return 1 }
            return min(1.2, max(lower, (b.p75 - b.p25) / (a.p75 - a.p25)))
        }
        lightnessScale = target.preserveContrast ? 1 : 1 + (ratio(source.lightness, target.reference.lightness, lower: 0.85) - 1) * application.lightnessAmount
        redScale = preserveColorSpread ? 1 : 1 + (ratio(source.redGreen, target.reference.redGreen, lower: 0.85) - 1) * application.colorAmount
        yellowScale = preserveColorSpread ? 1 : 1 + (ratio(source.yellowBlue, target.reference.yellowBlue, lower: 0.85) - 1) * application.colorAmount
        deltaL = max(-target.maxLightnessChange, min(target.maxLightnessChange, target.targetLightness - source.lightness.median)) * application.lightnessAmount
        deltaA = max(-target.maxColorChange, min(target.maxColorChange, target.targetRed - source.redGreen.median)) * application.colorAmount
        deltaB = max(-target.maxColorChange, min(target.maxColorChange, target.targetYellow - source.yellowBlue.median)) * application.colorAmount
    }
}

public struct BodySkinReport: Encodable, Sendable {
    public let before: SkinProfile
    public let after: SkinProfile
    public let targetLightness: Double
    public let targetRed: Double
    public let targetYellow: Double
}

public struct SkinAdaptationReport: Encodable, Sendable {
    public let before: SkinProfile
    public let after: SkinProfile
    public let adaptation: SkinAdaptation
    public let warnings: [String]
    public var bodyReports: [BodySkinReport] = []
}

enum SkinColorMath {
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let x = f((0.4865709486*r + 0.2656676932*g + 0.1982172852*b) / 0.9504559271)
        let y = f(0.2289745641*r + 0.6917385218*g + 0.0792869141*b)
        let z = f((0.0451133819*g + 1.0439443689*b) / 1.0890577508)
        return (116*y - 16, 500*(x-y), 200*(y-z))
    }

    static func profile(_ image: CIImage, mask: CIImage, box: CGRect, context: CIContext,
                        maxEdge: Double = 420, threshold: Float = 0.95, minimumSamples: Int = 200,
                        erosion: Double? = nil) throws -> SkinProfile {
        let rect = box.insetBy(dx: box.width * 0.035, dy: box.height * 0.035).integral.intersection(image.extent)
        guard !rect.isEmpty else { throw ImageError.maskFailed("人脸区域为空") }
        let factor = min(1, maxEdge / max(rect.width, rect.height))
        let transform = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
        let rgb = image.cropped(to: rect).transformed(by: transform)
        let selection = mask.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: erosion ?? max(1, box.width * 0.006)
        ]).cropped(to: rect).transformed(by: transform)
        let bounds = rgb.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var colors = [Float](repeating: 0, count: width * height * 4)
        var weights = colors
        colors.withUnsafeMutableBytes {
            context.render(rgb, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linearP3)
        }
        weights.withUnsafeMutableBytes {
            context.render(selection, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linearP3)
        }
        var ls: [Double] = [], aa: [Double] = [], bb: [Double] = []
        var total = 0, clipped = 0
        for i in stride(from: 0, to: colors.count, by: 4) where weights[i] > threshold && colors[i+3] > 0.99 {
            let (l, a, b) = lab(Double(colors[i]), Double(colors[i+1]), Double(colors[i+2]))
            guard l.isFinite && a.isFinite && b.isFinite else { continue }
            total += 1
            if l >= 97 { clipped += 1 }
            if l > 15 && l < 97 { ls.append(l); aa.append(a); bb.append(b) }
        }
        guard ls.count >= minimumSamples else { throw ImageError.maskFailed("脸部皮肤有效采样不足，不能自动适配") }
        return SkinProfile(sampleCount: ls.count, faceWidthPixels: box.width,
                           lightness: SkinDistribution(ls), redGreen: SkinDistribution(aa),
                           yellowBlue: SkinDistribution(bb), clippedFraction: Double(clipped) / Double(max(1, total)))
    }

    private static let kernel: Result<CIColorKernel, Error> = Result {
        let metal = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        float lab_f(float t) { return t > 0.0088564517 ? pow(t, 1.0/3.0) : (903.296296*t+16.0)/116.0; }
        float lab_inv(float t) { return t > 0.2068965517 ? t*t*t : (116.0*t-16.0)/903.296296; }
        [[ stitchable ]] float4 skinReference(coreimage::sample_t pixel, float3 anchor,
                                               float3 scale, float3 delta, float amount) {
            float3 rgb = pixel.rgb / max(pixel.a, 0.000001);
            float x = lab_f(dot(rgb, float3(0.4865709486,0.2656676932,0.1982172852))/0.9504559271);
            float y = lab_f(dot(rgb, float3(0.2289745641,0.6917385218,0.0792869141)));
            float z = lab_f(dot(rgb, float3(0.0,0.0451133819,1.0439443689))/1.0890577508);
            float3 lab = float3(116.0*y-16.0,500.0*(x-y),200.0*(y-z));
            float3 change = (lab-anchor)*(scale-1.0)+delta;
            // A positive-slope curve in log-odds lightness preserves local
            // ordering and fixes black/white endpoints, even for large lifts.
            if (lab.x > 0.0 && lab.x < 100.0) {
                float t = clamp(lab.x/100.0,0.000001,0.999999);
                float s = clamp(anchor.x/100.0,0.001,0.999);
                float d = clamp((anchor.x+delta.x)/100.0,0.001,0.999);
                float odds = (log(t/(1.0-t))-log(s/(1.0-s)))*scale.x+log(d/(1.0-d));
                float mapped = 100.0/(1.0+exp(-odds));
                lab.x = mix(lab.x,mapped,amount);
            }
            // Chroma correction tapers at specular highlights and deep shadows.
            float protection = smoothstep(8.0,25.0,lab.x)*(1.0-smoothstep(85.0,100.0,lab.x));
            lab.yz += change.yz * amount * protection;
            y = (lab.x+16.0)/116.0;
            x = y+lab.y/500.0; z = y-lab.z/200.0;
            float3 xyz = float3(0.9504559271*lab_inv(x),lab_inv(y),1.0890577508*lab_inv(z));
            rgb = float3(dot(xyz,float3(2.4934969119,-0.9313836179,-0.4027107845)),
                         dot(xyz,float3(-0.8294889696,1.7626640603,0.0236246858)),
                         dot(xyz,float3(0.0358458302,-0.0761723893,0.9568845240)));
            return float4(rgb*pixel.a,pixel.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建参考肤色算子")
        }
        return kernel
    }

    static func transfer(_ image: CIImage, recipe: SkinAdaptation) throws -> CIImage {
        guard recipe.strength > 0 else { return image }
        guard let result = try kernel.get().apply(extent: image.extent, arguments: [
            image,
            CIVector(x: recipe.source.lightness.median, y: recipe.source.redGreen.median,
                     z: recipe.source.yellowBlue.median),
            CIVector(x: recipe.lightnessScale, y: recipe.redScale, z: recipe.yellowScale),
            CIVector(x: recipe.deltaL, y: recipe.deltaA, z: recipe.deltaB), recipe.strength
        ]) else { throw ImageError.maskFailed("参考肤色渲染失败") }
        return result
    }

    private static let chromaKernel: Result<CIColorKernel, Error> = Result {
        let metal = SkinProcessing.colorHelpers + """
        [[ stitchable ]] float4 skinChromaCompensation(coreimage::sample_t p, float gain,
                                                       float bBoost, float maxChroma) {
            float3 lab=toLab(p.rgb/max(p.a,0.000001));
            float protect=smoothstep(8.0,25.0,lab.x)*(1-smoothstep(88.0,100.0,lab.x));
            float2 ab=lab.yz*gain;
            ab.y+=bBoost;
            float c=length(ab);
            if(c>maxChroma && c>0.001) ab*=maxChroma/c;
            lab.yz=mix(lab.yz,ab,protect);
            return float4(fromLab(lab)*p.a,p.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建肤色浓度补偿算子")
        }
        return kernel
    }

    /// Restores chroma after a large lightness lift. A tone curve that preserves
    /// a*/b* while raising L* makes skin look grey, especially on underexposed
    /// photos; this scales chroma toward the template target inside the face mask.
    static func compensateChroma(_ image: CIImage, mask: CIImage, gain: Double, bBoost: Double,
                                 maxChroma: Double) throws -> CIImage {
        guard let adjusted = try chromaKernel.get().apply(extent: image.extent, arguments: [
            image, gain, bBoost, maxChroma
        ]) else { throw ImageError.maskFailed("肤色浓度补偿失败") }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }
}
