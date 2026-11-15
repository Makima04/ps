import CoreImage
import Foundation

public enum SpotRepairMode: String, Codable, Sendable {
    case texture, sampledSkin
}

public struct RepairSpot: Codable, Equatable, Sendable {
    public var source: MaskPoint
    public var target: MaskPoint
    /// Radius relative to the original image's longest edge.
    public var radius: Double
    public var mode: SpotRepairMode
    public init(source: MaskPoint, target: MaskPoint, radius: Double, mode: SpotRepairMode = .texture) {
        self.source = source; self.target = target; self.radius = radius; self.mode = mode
    }

    private enum CodingKeys: String, CodingKey { case source, target, radius, mode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(MaskPoint.self, forKey: .source)
        target = try values.decode(MaskPoint.self, forKey: .target)
        radius = try values.decode(Double.self, forKey: .radius)
        mode = try values.decodeIfPresent(SpotRepairMode.self, forKey: .mode) ?? .texture
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(target, forKey: .target)
        try values.encode(radius, forKey: .radius)
        if mode != .texture { try values.encode(mode, forKey: .mode) }
    }

    public func isValid(in size: CGSize) -> Bool {
        guard [source.x, source.y, target.x, target.y, radius].allSatisfy(\.isFinite),
              (0.0001...0.03).contains(radius), size.width > 0, size.height > 0 else { return false }
        let r = radius * max(size.width, size.height)
        return [source, target].allSatisfy {
            $0.x * size.width >= r && $0.x * size.width <= size.width - r &&
            $0.y * size.height >= r && $0.y * size.height <= size.height - r
        }
    }
}

enum SpotRepair {
    /// Copy clean local texture and colour, compensating only broad illumination.
    /// A wider context reduces the defect's contribution to the retained colour.
    private static let sampledSkinKernel: Result<CIColorKernel, Error> = Result {
        let metal = SkinProcessing.colorHelpers + """
        [[ stitchable ]] float4 healSampledSkin(coreimage::sample_t base, coreimage::sample_t source,
            coreimage::sample_t sourceContext, coreimage::sample_t targetContext,
            float4 spot, coreimage::destination dest) {
            float distance=length(dest.coord()-spot.xy)/spot.z;
            float weight=1-smoothstep(0.55,1.0,distance);
            float3 sourceLab=toLab(source.rgb/max(source.a,0.000001));
            float3 delta=toLab(targetContext.rgb/max(targetContext.a,0.000001))
                        -toLab(sourceContext.rgb/max(sourceContext.a,0.000001));
            delta=clamp(delta,float3(-6.0,-4.0,-4.0),float3(6.0,4.0,4.0));
            float3 repaired=fromLab(sourceLab+delta);
            return float4(mix(base.rgb/max(base.a,0.000001),repaired,weight)*base.a,base.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建局部肤色修复算子")
        }
        return kernel
    }

    private static let kernel: Result<CIColorKernel, Error> = Result {
        let metal = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[ stitchable ]] float4 healSpot(coreimage::sample_t base, coreimage::sample_t source,
            coreimage::sample_t sourceLow, coreimage::sample_t targetLow, float4 spot, coreimage::destination dest) {
            float distance=length(dest.coord()-spot.xy)/spot.z;
            float weight=1-smoothstep(0.55,1.0,distance);
            float3 texture=source.rgb/max(source.a,0.000001)-sourceLow.rgb/max(sourceLow.a,0.000001);
            float3 repaired=texture+targetLow.rgb/max(targetLow.a,0.000001);
            float3 rgb=mix(base.rgb/max(base.a,0.000001),repaired,weight);
            return float4(rgb*base.a,base.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建手动修复算子")
        }
        return kernel
    }
    static func apply(_ spots: [RepairSpot], to original: CIImage) throws -> CIImage {
        var image = original
        let extent = original.extent
        for spot in spots {
            try Task.checkCancellation()
            guard spot.isValid(in: extent.size) else { throw ImageError.maskFailed("修复点超出边界，请缩小笔刷或重新取样") }
            let radius = spot.radius * max(extent.width, extent.height)
            let target = CGPoint(x: extent.minX + spot.target.x * extent.width, y: extent.minY + spot.target.y * extent.height)
            let offset = CGAffineTransform(translationX: (spot.target.x - spot.source.x) * extent.width,
                                          y: (spot.target.y - spot.source.y) * extent.height)
            let sigma = radius * (spot.mode == .sampledSkin ? 2.0 : 0.45)
            let low = image.clampedToExtent().applyingGaussianBlur(sigma: max(1, sigma)).cropped(to: extent)
            let operation = try (spot.mode == .sampledSkin ? sampledSkinKernel : kernel).get()
            guard let output = operation.apply(extent: extent, arguments: [image,
                image.transformed(by: offset), low.transformed(by: offset), low,
                CIVector(x: target.x, y: target.y, z: radius, w: 0)
            ]) else { throw ImageError.maskFailed("手动修复失败") }
            image = output.cropped(to: extent)
        }
        return image
    }
}
