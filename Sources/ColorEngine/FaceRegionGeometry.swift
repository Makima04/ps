import CoreImage
import Foundation

/// Soft anatomical guides derived from detected eyes, intersected with parsed skin.
/// Left/right always refer to the image, so mirrored previews are unambiguous.
struct FaceRegionGeometry {
    let origin: CGPoint
    let unit: CGFloat
    let angle: CGFloat

    init(box: CGRect, eyeA: CGPoint, eyeB: CGPoint) {
        let a = CGPoint(x: box.minX + eyeA.x * box.width, y: box.minY + eyeA.y * box.height)
        let b = CGPoint(x: box.minX + eyeB.x * box.width, y: box.minY + eyeB.y * box.height)
        let left = a.x <= b.x ? a : b, right = a.x <= b.x ? b : a
        origin = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        unit = max(1, hypot(right.x - left.x, right.y - left.y))
        angle = atan2(right.y - left.y, right.x - left.x)
    }

    func mask(_ kind: MaskKind, extent: CGRect) -> CIImage {
        let guides: [(Double, Double, Double, Double)]
        switch kind {
        case .leftCheek: guides = [(-0.55, -0.63, 0.38, 0.40)]
        case .rightCheek: guides = [(0.55, -0.63, 0.38, 0.40)]
        case .forehead: guides = [(0, 0.62, 0.70, 0.40)]
        case .underEyes: guides = [(-0.5, -0.24, 0.36, 0.16), (0.5, -0.24, 0.36, 0.16)]
        case .noseSides: guides = [(-0.19, -0.46, 0.14, 0.32), (0.19, -0.46, 0.14, 0.32)]
        default: guides = []
        }
        var result = CIImage(color: .black).cropped(to: extent)
        for (x, y, rx, ry) in guides {
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.45, "inputRadius1": 1.0,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ])!.outputImage!
            let transform = CGAffineTransform(scaleX: unit * rx, y: unit * ry)
                .concatenating(CGAffineTransform(translationX: unit * x, y: unit * y))
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            let local = gradient.transformed(by: transform).cropped(to: extent)
            result = local.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: result])
        }
        return result
    }
}

/// Prevents a parsing crop that includes a neighbour from selecting both people.
enum FaceMaskOwnership {
    private static let kernel: Result<CIColorKernel, Error> = Result {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[ stitchable ]] float4 faceOwner(coreimage::sample_t mask, float4 own, float4 other,
                                          float preferOwn, coreimage::destination dest) {
            float2 p=dest.coord();
            float2 a=(p-own.xy)/max(own.zw,float2(1));
            float2 b=(p-other.xy)/max(other.zw,float2(1));
            float da=dot(a,a), db=dot(b,b);
            float keep=preferOwn>0.5 ? float(da<=db) : float(da<db);
            return float4(mask.rgb*keep,1);
        }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: source).first as? CIColorKernel else {
            throw ImageError.maskFailed("无法创建人物归属选区")
        }
        return kernel
    }
    static func restrict(_ mask: CIImage, index: Int, boxes: [CGRect]) throws -> CIImage {
        var result = mask
        func vector(_ box: CGRect) -> CIVector {
            CIVector(x: box.midX, y: box.midY, z: box.width, w: box.height)
        }
        for other in boxes.indices where other != index {
            guard let output = try kernel.get().apply(extent: mask.extent, arguments: [
                result, vector(boxes[index]), vector(boxes[other]), index < other ? 1.0 : 0.0
            ]) else { throw ImageError.maskFailed("人物选区隔离失败") }
            result = output
        }
        return result
    }
}
