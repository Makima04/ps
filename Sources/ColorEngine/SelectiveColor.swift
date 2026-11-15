import CoreImage

enum SelectiveColor {
    private static let rednessKernel: Result<CIColorKernel, Error> = Result {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 reduceSkinRedness(coreimage::sample_t pixel, float amount) {
            const float epsilon = 0.000001;
            float3 rgb = pixel.rgb / max(pixel.a, epsilon);
            float3 perceptual = pow(max(rgb, float3(0.0)), float3(1.0 / 2.2));
            float maximum = max(perceptual.r, max(perceptual.g, perceptual.b));
            float minimum = min(perceptual.r, min(perceptual.g, perceptual.b));
            float redDominance = (perceptual.r - perceptual.g) /
                                 max(perceptual.r - perceptual.b, epsilon);
            float weight = smoothstep(0.55, 0.95, redDominance) *
                           smoothstep(0.02, 0.10, maximum - minimum) *
                           step(max(perceptual.g, perceptual.b), perceptual.r);
            float luminance = dot(rgb, float3(0.228975, 0.691739, 0.079286));
            float3 result = mix(rgb, float3(luminance), clamp(amount, 0.0, 1.0) * weight);
            return float4(result * pixel.a, pixel.a);
        }
        """
        guard let result = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建局部色彩算子")
        }
        return result
    }

    /// Turns a heavy, dark red mouth into a soft rose/coral tone without
    /// desaturating it into grey. Only the hue is nudged; brightness is handled
    /// by the lips layer's exposure, so lip lines and specular texture survive.
    /// The nudge is stronger in the darker parts, where the "dark red" lives.
    private static let lipsKernel: Result<CIColorKernel, Error> = Result {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 naturalizeLips(coreimage::sample_t pixel, float amount) {
            const float epsilon = 0.000001;
            float3 rgb = pixel.rgb / max(pixel.a, epsilon);
            float3 perceptual = pow(max(rgb, float3(0.0)), float3(1.0 / 2.2));
            float luma = dot(rgb, float3(0.228975, 0.691739, 0.079286));
            float brightness = pow(max(luma, 0.0), 1.0 / 2.2);
            float redExcess = perceptual.r - 0.5 * (perceptual.g + perceptual.b);
            float weight = smoothstep(0.02, 0.14, redExcess) *
                           step(perceptual.g, perceptual.r) *
                           step(perceptual.b, perceptual.r);
            float shade = 1.0 - smoothstep(0.35, 0.85, brightness);
            float3 target = perceptual;
            target.r -= redExcess * (0.05 + 0.05 * shade);
            target.g += redExcess * (0.10 + 0.06 * shade);
            target.b += redExcess * (0.06 + 0.04 * shade);
            float3 mixed = mix(perceptual, target,
                               clamp(amount, 0.0, 1.0) * weight);
            float3 result = pow(max(mixed, float3(0.0)), float3(2.2));
            return float4(result * pixel.a, pixel.a);
        }
        """
        guard let result = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建唇色算子")
        }
        return result
    }

    static func reduceRedness(_ image: CIImage, amount: Double) throws -> CIImage {
        guard let result = try rednessKernel.get().apply(extent: image.extent,
                                                         arguments: [image, amount]) else {
            throw ImageError.maskFailed("无法修正局部红色")
        }
        return result
    }

    static func naturalizeLips(_ image: CIImage, amount: Double) throws -> CIImage {
        guard let result = try lipsKernel.get().apply(extent: image.extent,
                                                      arguments: [image, amount]) else {
            throw ImageError.maskFailed("无法调整唇色")
        }
        return result
    }

    /// Lifts dark lips, shifts them toward a natural rose and reduces fine lip lines.
    /// The broad sample locates the vermilion border so the edge stays crisp, while
    /// the fine sample removes vertical creases without touching specular gloss.
    /// The caller supplies a lips mask layer; this kernel itself only sees pixels.
    private static let lipPolishKernel: Result<CIColorKernel, Error> = Result {
        let source = SkinProcessing.colorHelpers + """
        [[ stitchable ]] float4 polishLips(coreimage::sample_t p, coreimage::sample_t fine,
                                           coreimage::sample_t broad, float amount) {
            float epsilon = 0.000001;
            float3 lab=toLab(p.rgb/max(p.a,epsilon));
            float3 mid=toLab(fine.rgb/max(fine.a,epsilon));
            float3 low=toLab(broad.rgb/max(broad.a,epsilon));
            float a=clamp(amount,0.0,1.0);
            float protect=smoothstep(6.0,18.0,lab.x)*(1-smoothstep(90.0,98.0,lab.x));
            // A large chroma difference from the broad surrounding skin marks the lip edge.
            float border=1.0-smoothstep(5.0,16.0,length(lab.yz-low.yz));
            float gloss=1.0-smoothstep(70.0,92.0,lab.x);
            // Remove part of the fine lip-line contrast, keeping the border and highlights.
            lab.x-=a*0.35*(lab.x-mid.x)*border*gloss*protect;
            // Lift the darker parts and nudge the hue from brown-red toward rose.
            float dark=1.0-smoothstep(30.0,65.0,lab.x);
            lab.x+=a*4.0*dark*protect;
            lab.y+=a*1.4*protect;
            lab.z-=a*0.9*protect;
            return float4(fromLab(lab)*p.a,p.a);
        }
        """
        guard let result = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建唇部优化算子")
        }
        return result
    }

    static func polishLips(_ image: CIImage, amount: Double) throws -> CIImage {
        let edge = max(image.extent.width, image.extent.height)
        let fine = image.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.6, edge * 0.00025)).cropped(to: image.extent)
        let broad = image.clampedToExtent()
            .applyingGaussianBlur(sigma: max(2, edge * 0.002)).cropped(to: image.extent)
        guard let result = try lipPolishKernel.get().apply(extent: image.extent,
                                                           arguments: [image, fine, broad, amount]) else {
            throw ImageError.maskFailed("无法优化嘴唇")
        }
        return result
    }
}
