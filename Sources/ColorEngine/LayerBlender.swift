import CoreImage

enum LayerBlender {
    // Luminance/chroma blending in the engine's extended linear Display P3 space.
    // Extended highlight values remain available to subsequent adjustment layers.
    private static let kernel: Result<CIColorKernel, Error> = Result {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 blendSceneColor(coreimage::sample_t adjusted,
                                                coreimage::sample_t base,
                                                float colorMode) {
            const float epsilon = 0.000001;
            const float3 weights = float3(0.228975, 0.691739, 0.079286);
            float3 originalRGB = base.rgb / max(base.a, epsilon);
            float3 adjustedRGB = adjusted.rgb / max(adjusted.a, epsilon);
            float originalLuma = dot(originalRGB, weights);
            float adjustedLuma = dot(adjustedRGB, weights);
            float3 result;
            if (colorMode > 0.5) {
                result = adjustedLuma > epsilon
                    ? adjustedRGB * (originalLuma / adjustedLuma)
                    : float3(originalLuma);
            } else {
                result = originalLuma > epsilon
                    ? originalRGB * (adjustedLuma / originalLuma)
                    : float3(adjustedLuma);
            }
            return float4(result * base.a, base.a);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建明度与颜色混合算子")
        }
        return kernel
    }

    static func blend(_ adjusted: CIImage, over base: CIImage, mode: LayerBlendMode) throws -> CIImage {
        guard let output = try kernel.get().apply(
            extent: base.extent,
            arguments: [adjusted, base, mode == .color ? 1.0 : 0.0]
        ) else {
            throw ImageError.maskFailed("无法执行图层混合")
        }
        return output
    }
}
