import CoreImage

/// Composite kernels may sample cropped inputs with clamped edges. Explicitly
/// zero outside the local face crop before combining it with a full-frame mask.
enum MaskBounds {
    private static let kernel: Result<CIColorKernel, Error> = Result {
        let metal = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[ stitchable ]] float4 boundedMask(coreimage::sample_t pixel, float4 box,
                                             coreimage::destination dest) {
            float2 p = dest.coord();
            float inside = step(box.x,p.x)*step(box.y,p.y)*
                           (1.0-step(box.z,p.x))*(1.0-step(box.w,p.y));
            return float4(pixel.rgb*inside,1.0);
        }
        """
        guard let result = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法限制选区边界")
        }
        return result
    }

    static func pad(_ image: CIImage, to extent: CGRect) throws -> CIImage {
        let box = image.extent
        guard let result = try kernel.get().apply(extent: extent, arguments: [
            image, CIVector(x: box.minX, y: box.minY, z: box.maxX, w: box.maxY)
        ]) else { throw ImageError.maskFailed("无法限制选区边界") }
        return result.cropped(to: extent)
    }
}
