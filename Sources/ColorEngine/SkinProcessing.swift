import CoreImage
import Foundation

enum SkinProcessing {
    static let colorHelpers = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    float f(float t) { return t > 0.0088564517 ? pow(t, 1.0/3.0) : (903.296296*t+16.0)/116.0; }
    float inv(float t) { return t > 0.2068965517 ? t*t*t : (116.0*t-16.0)/903.296296; }
    float3 toLab(float3 rgb) {
        float x=f(dot(rgb,float3(0.4865709486,0.2656676932,0.1982172852))/0.9504559271);
        float y=f(dot(rgb,float3(0.2289745641,0.6917385218,0.0792869141)));
        float z=f(dot(rgb,float3(0,0.0451133819,1.0439443689))/1.0890577508);
        return float3(116*y-16,500*(x-y),200*(y-z));
    }
    float3 fromLab(float3 lab) {
        float y=(lab.x+16)/116, x=y+lab.y/500, z=y-lab.z/200;
        float3 xyz=float3(0.9504559271*inv(x),inv(y),1.0890577508*inv(z));
        return float3(dot(xyz,float3(2.4934969119,-0.9313836179,-0.4027107845)),
                      dot(xyz,float3(-0.8294889696,1.7626640603,0.0236246858)),
                      dot(xyz,float3(0.0358458302,-0.0761723893,0.9568845240)));
    }
    """

    private static func kernel(_ source: String) -> Result<CIColorKernel, Error> {
        Result {
            guard let value = try CIKernel.kernels(withMetalString: colorHelpers + source).first as? CIColorKernel else {
                throw ImageError.maskFailed("无法创建皮肤处理算子")
            }
            return value
        }
    }
    private static let tone = kernel("""
    [[ stitchable ]] float4 skinTone(coreimage::sample_t p, coreimage::sample_t fine,
                                     float white, float yellow, float vitality, float blush,
                                     float edgeGuard, coreimage::sample_t cheekMask) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float3 mid=toLab(fine.rgb/max(fine.a,0.000001));
        // Do not carry whitening across hair, nostrils or the lip border when enabled.
        float edge=1-smoothstep(4.0,15.0,length(lab-mid))*clamp(edgeGuard,0.0,1.0);
        float protect=smoothstep(10.0,30.0,lab.x)*(1-smoothstep(85.0,100.0,lab.x));
        float whiteWeight=clamp(white,0.0,1.0)*edge;
        float toneWeight=protect*edge;
        // Positive-slope log-odds curve keeps highlight gradients and black/white endpoints.
        if(lab.x>0 && lab.x<100) {
            float t=lab.x/100;
            lab.x=100/(1+exp(-(log(t/(1-t))+whiteWeight*0.42)));
        }
        lab.z-=clamp(yellow,0.0,1.0)*min(8.0,max(0.0,lab.z-4.0))*toneWeight;
        float chroma=length(lab.yz);
        lab.yz*=1+clamp(vitality,0.0,1.0)*0.18*(1-smoothstep(25.0,45.0,chroma))*toneWeight;
        lab.y+=clamp(blush,-1.0,1.0)*5.0*cheekMask.r*toneWeight;
        return float4(fromLab(lab)*p.a,p.a);
    }
    """)
    private static let detail = kernel("""
    [[ stitchable ]] float4 skinDetail(coreimage::sample_t p, coreimage::sample_t fine, float amount) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float3 mid=toLab(fine.rgb/max(fine.a,0.000001));
        float protect=smoothstep(12.0,30.0,lab.x)*(1-smoothstep(82.0,97.0,lab.x));
        float high=lab.x-mid.x;
        // Strong local edges are left alone so sharpening does not create halos.
        float guard=1-smoothstep(8.0,24.0,abs(high));
        lab.x+=clamp(amount,0.0,1.0)*0.75*high*protect*guard;
        return float4(fromLab(lab)*p.a,p.a);
    }
    """)
    private static let texture = kernel("""
    [[ stitchable ]] float4 skinTexture(coreimage::sample_t p, coreimage::sample_t fine,
         coreimage::sample_t broad, float uniformity, float smoothing, float preserve, coreimage::sample_t cheekMask) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float3 low=toLab(broad.rgb/max(broad.a,0.000001));
        float3 mid=toLab(fine.rgb/max(fine.a,0.000001));
        // Reject cross-edge mixing; no attempt to classify moles or blemishes.
        float edge=1-smoothstep(4.0,15.0,length(lab-low));
        float protect=smoothstep(15.0,30.0,lab.x)*(1-smoothstep(85.0,100.0,lab.x));
        lab.yz+=clamp(uniformity,0.0,1.0)*0.65*(low.yz-lab.yz)*edge*protect*(1-0.8*cheekMask.r);
        float high=lab.x-mid.x;
        float correction=clamp(low.x-mid.x,-3.0,3.0)-high*(1-clamp(preserve,0.0,1.0));
        lab.x+=clamp(smoothing,0.0,1.0)*correction*edge*protect;
        return float4(fromLab(lab)*p.a,p.a);
    }
    """)
    private static let body = kernel("""
    [[ stitchable ]] float4 bodySkin(coreimage::sample_t p, float red, float yellow, float tolerance) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float distance=length((lab.yz-float2(red,yellow))/(float2(6,8)*max(1.0,tolerance)));
        float weight=(1-smoothstep(0.5,1.6,distance))*smoothstep(15.0,30.0,lab.x)*(1-smoothstep(94.0,100.0,lab.x));
        if(tolerance>1.1) weight*=smoothstep(3.0,7.0,lab.y)*smoothstep(0.0,4.0,lab.z);
        return float4(float3(weight),1);
    }
    """)
    private static let teeth = kernel("""
    [[ stitchable ]] float4 toothCandidate(coreimage::sample_t p) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float weight=smoothstep(45.0,75.0,lab.x)*(1-smoothstep(8.0,25.0,length(lab.yz)));
        return float4(float3(weight),1);
    }
    """)

    static func apply(_ image: CIImage, settings: ColorAdjustments, cheeks: CIImage?) throws -> CIImage {
        let toneActive = settings.skinWhitening != 0 || settings.skinYellowReduction != 0 ||
            settings.skinVitality != 0 || settings.cheekBlush != 0
        let textureActive = settings.skinUniformity > 0 || settings.skinSmoothing > 0
        let detailActive = settings.skinDetail > 0
        guard toneActive || textureActive || detailActive else { return image }
        let black = CIImage(color: .black).cropped(to: image.extent)
        let edge = max(image.extent.width, image.extent.height)
        let needsFine = textureActive || detailActive || (toneActive && settings.skinEdgeGuard > 0)
        let fine = needsFine ? image.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.6, edge * 0.00035)).cropped(to: image.extent) : image
        // Supply cheeks as a separate sample, keeping all skin controls independently editable.
        var result = image
        if textureActive {
            let broad = image.clampedToExtent()
                .applyingGaussianBlur(sigma: max(2, edge * 0.002)).cropped(to: image.extent)
            result = try applyWithCheek(texture, image: image, cheeks: cheeks ?? black, arguments: [fine, broad,
                settings.skinUniformity, settings.skinSmoothing, settings.texturePreservation])
        }
        if toneActive {
            result = try applyWithCheek(tone, image: result, cheeks: cheeks ?? black, arguments: [fine,
                settings.skinWhitening, settings.skinYellowReduction, settings.skinVitality,
                settings.cheekBlush, settings.skinEdgeGuard
            ])
        }
        if detailActive {
            guard let output = try detail.get().apply(extent: result.extent,
                                                      arguments: [result, fine, settings.skinDetail]) else {
                throw ImageError.maskFailed("皮肤细节回补失败")
            }
            result = output
        }
        return result
    }

    // CIColorKernel sample arguments are positional; convert the last sample to a weight
    // inside each compiled function so the CPU never reads a full-resolution mask.
    private static func applyWithCheek(_ value: Result<CIColorKernel, Error>, image: CIImage,
                                       cheeks: CIImage, arguments: [Any]) throws -> CIImage {
        guard let output = try value.get().apply(extent: image.extent, arguments: [image] + arguments + [cheeks]) else {
            throw ImageError.maskFailed("皮肤处理失败")
        }
        return output
    }
    private static let neutralShift = kernel("""
    [[ stitchable ]] float4 neutralCast(coreimage::sample_t p, float a, float b) {
        float3 lab=toLab(p.rgb/max(p.a,0.000001));
        float protect=smoothstep(10.0,35.0,lab.x)*(1-smoothstep(90.0,100.0,lab.x));
        lab.yz+=float2(a,b)*protect;
        return float4(fromLab(lab)*p.a,p.a);
    }
    """)
    static func correctNeutralCast(_ image: CIImage, deltaA: Double, deltaB: Double) throws -> CIImage {
        guard deltaA != 0 || deltaB != 0 else { return image }
        guard let result = try neutralShift.get().apply(extent: image.extent, arguments: [image, deltaA, deltaB]) else {
            throw ImageError.maskFailed("中性色偏色校正失败")
        }
        return result
    }

    static func bodyCandidate(_ image: CIImage, profile: SkinProfile, tolerance: Double = 1) throws -> CIImage {
        guard let output = try body.get().apply(extent: image.extent, arguments: [image, profile.redGreen.median, profile.yellowBlue.median, tolerance]) else {
            throw ImageError.maskFailed("身体皮肤候选生成失败")
        }
        return output
    }
    static func teethCandidate(_ image: CIImage) throws -> CIImage {
        guard let output = try teeth.get().apply(extent: image.extent, arguments: [image]) else {
            throw ImageError.maskFailed("牙齿候选生成失败")
        }
        return output
    }
}
