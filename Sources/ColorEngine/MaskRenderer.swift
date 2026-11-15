import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

// Accessed only from its owning ColorEngine actor.
final class MaskRenderer {
    private struct CacheKey: Hashable {
        let fingerprint: AnalysisInputFingerprint
        let version: AnalysisAlgorithmVersion
    }
    private let parser = SemanticParser()
    private var semanticMasks: [CacheKey: SemanticMasks] = [:]
    private var semanticOrder: [CacheKey] = []
    private var bodyGuides: [CacheKey: CIImage] = [:]
    private var personMasks: [CacheKey: CIImage] = [:]
    private var cacheOrder: [CacheKey] = []

    /// `original` is the pixel source (ARW when available); `analysis` is the
    /// gamma-encoded JPEG used for detectors. Luminance selections still use the
    /// pixel source so highlights/shadows match the actual graded image.
    func makeMask(for layer: AdjustmentLayer, original: CIImage, analysis: CIImage,
                  cacheURL: URL, context: CIContext) throws -> CIImage {
        let extent = original.extent
        var mask: CIImage
        switch layer.mask {
        case .all:
            mask = CIImage(color: .white).cropped(to: extent)
        case .person, .background:
            mask = try personMask(analysis: analysis, guide: original, cacheURL: cacheURL, context: context)
            if layer.mask == .background { mask = invert(mask) }
        case .bodySkin:
            let regions = try parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
            let person = try personMask(analysis: analysis, guide: original, cacheURL: cacheURL, context: context)
            // Color-assisted candidates are deliberately restricted to the person,
            // exclude clothing and all parsed heads, and remain brush editable.
            guard let face = regions.faces.max(by: { $0.info.bounds.width < $1.info.bounds.width }) else {
                mask = CIImage(color: .black).cropped(to: extent)
                break
            }
            let profile = try SkinColorMath.profile(analysis, mask: regions.mask(.skin, faceIndex: face.info.index),
                                                    box: face.info.bounds, context: context)
            mask = try SkinProcessing.bodyCandidate(analysis, profile: profile, tolerance: 1.5)
            let guide: CIImage
            // Same source freshness as semanticMasks: cache eviction is coupled below.
            let guideKey = CacheKey(
                fingerprint: AnalysisInputFingerprint.capture(for: cacheURL, extent: extent, isRAW: false),
                version: .current
            )
            if let cached = bodyGuides[guideKey] { guide = cached }
            else { guide = try BodyRegionGuide.make(analysis, context: context); bodyGuides[guideKey] = guide }
            let faceSkin = regions.mask(.skin).applyingFilter("CISubtractBlendMode", parameters: [
                kCIInputBackgroundImageKey: regions.mask(.neck)])
            let excludeFace = invert(faceSkin.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: regions.mask(.hair)]))
            let softGuide = guide.applyingGaussianBlur(sigma: max(1, face.info.bounds.width*0.012)).cropped(to: extent)
            for restriction in [person, softGuide, invert(regions.clothing), excludeFace] {
                mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: restriction])
            }
            let hands = regions.hands
            var handSkin = try SkinProcessing.bodyCandidate(analysis, profile: profile, tolerance: 2.2)
            // A hand in front of a head is frequently labelled hair by the face
            // parser. Reliable hand joints take precedence over that head label.
            for restriction in [hands, person] {
                handSkin = handSkin.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: restriction])
            }
            mask = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: handSkin])
        case .skin, .neck, .lips, .eyes, .eyebrows, .teeth, .hair, .forehead,
             .leftCheek, .rightCheek, .underEyes, .noseSides, .clothing:
            let regions = try parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
            mask = regions.mask(layer.mask, faceIndex: layer.faceIndex)
        case .highlights:
            mask = luminanceMask(original, low: layer.rangeStart, high: layer.rangeEnd)
        case .shadows:
            mask = invert(luminanceMask(original, low: layer.rangeStart, high: layer.rangeEnd))
        }
        mask = try paint(layer.brushStrokes ?? [], over: mask, extent: extent)
        if layer.inverted { mask = invert(mask) }
        let radius = max(0, min(0.02, layer.feather)) * max(extent.width, extent.height)
        if radius > 0 {
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        if layer.highlightProtection > 0 {
            let highlights = luminanceMask(original, low: 0.72, high: 0.98)
            let protection = invert(scale(highlights, by: min(1, layer.highlightProtection)))
            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = mask
            multiply.backgroundImage = protection
            mask = multiply.outputImage ?? mask
        }
        return scale(mask, by: max(0, min(1, layer.opacity))).cropped(to: extent)
    }

    func parsedMasks(analysis: CIImage, cacheURL: URL, context: CIContext) throws -> SemanticMasks {
        let key = CacheKey(
            fingerprint: AnalysisInputFingerprint.capture(for: cacheURL, extent: analysis.extent, isRAW: false),
            version: .current
        )
        if let cached = semanticMasks[key] { return cached }
        let result = try parser.masks(original: analysis, context: context)
        bodyGuides.removeValue(forKey: key)
        semanticMasks[key] = result
        semanticOrder.append(key)
        if semanticOrder.count > 2 {
            let evicted = semanticOrder.removeFirst()
            semanticMasks.removeValue(forKey: evicted)
            bodyGuides.removeValue(forKey: evicted)
        }
        return result
    }

    private func paint(_ strokes: [MaskStroke], over mask: CIImage, extent: CGRect) throws -> CIImage {
        guard !strokes.isEmpty else { return mask }
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageError.maskFailed("无法创建画笔蒙版")
        }
        bitmap.setLineCap(.round)
        bitmap.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let radius = max(0.0001, min(0.2, stroke.radius)) * max(extent.width, extent.height)
            let color = CGColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            bitmap.setFillColor(color)
            bitmap.setStrokeColor(color)
            bitmap.setLineWidth(radius * 2)
            let start = CGPoint(x: first.x * extent.width, y: first.y * extent.height)
            if stroke.points.count == 1 {
                bitmap.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius,
                                              width: radius * 2, height: radius * 2))
            } else {
                bitmap.beginPath()
                bitmap.move(to: start)
                for point in stroke.points.dropFirst() {
                    bitmap.addLine(to: CGPoint(x: point.x * extent.width, y: point.y * extent.height))
                }
                bitmap.strokePath()
            }
        }
        guard let overlay = bitmap.makeImage() else { throw ImageError.maskFailed("无法绘制蒙版") }
        let painted = CIImage(cgImage: overlay, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return painted.composited(over: mask).cropped(to: extent)
    }

    private func personMask(analysis: CIImage, guide: CIImage, cacheURL: URL,
                            context: CIContext) throws -> CIImage {
        let key = CacheKey(
            fingerprint: AnalysisInputFingerprint.capture(for: cacheURL, extent: analysis.extent, isRAW: false),
            version: .current
        )
        let smallMask: CIImage
        if let cached = personMasks[key] {
            smallMask = cached
        } else {
            try Task.checkCancellation()
            let factor = min(1, 1600 / max(analysis.extent.width, analysis.extent.height))
            let thumbnail = analysis.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            guard let input = context.createCGImage(thumbnail, from: thumbnail.extent,
                                                     format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw ImageError.maskFailed("无法读取人物图像")
            }
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
            do {
                try VNImageRequestHandler(cgImage: input).perform([request])
            } catch {
                throw ImageError.maskFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            guard let buffer = request.results?.first?.pixelBuffer else {
                throw ImageError.maskFailed("人物识别未返回结果")
            }
            smallMask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            personMasks[key] = smallMask
            cacheOrder.append(key)
            if cacheOrder.count > 4 { personMasks.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        let guideImage = guide.transformed(by: CGAffineTransform(translationX: -guide.extent.minX,
                                                                  y: -guide.extent.minY))
        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = guideImage
        upsample.smallImage = smallMask
        upsample.spatialSigma = 3
        upsample.lumaSigma = 0.15
        guard let refined = upsample.outputImage else {
            throw ImageError.maskFailed("无法细化人物边缘")
        }
        return refined.transformed(by: CGAffineTransform(translationX: guide.extent.minX,
                                                          y: guide.extent.minY))
            .cropped(to: guide.extent)
    }

    // Smooth tonal selection in an approximate perceptual brightness space.
    // The coefficients match the engine's linear Display P3 working primaries.
    private func luminanceMask(_ original: CIImage, low: Double, high: Double) -> CIImage {
        let grayscale = CIFilter.colorMatrix()
        grayscale.inputImage = original
        let luma = CIVector(x: 0.228975, y: 0.691739, z: 0.079286, w: 0)
        grayscale.rVector = luma
        grayscale.gVector = luma
        grayscale.bVector = luma
        grayscale.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        grayscale.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        var image = clamp(grayscale.outputImage ?? original)
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = image
        gamma.power = 1 / 2.2
        image = gamma.outputImage ?? image

        let start = max(0, min(0.99, low))
        let end = max(start + 0.01, min(1, high))
        let ramp = CIFilter.colorMatrix()
        ramp.inputImage = image
        let slope = 1 / (end - start)
        ramp.rVector = CIVector(x: slope, y: 0, z: 0, w: 0)
        ramp.gVector = CIVector(x: 0, y: slope, z: 0, w: 0)
        ramp.bVector = CIVector(x: 0, y: 0, z: slope, w: 0)
        ramp.biasVector = CIVector(x: -start * slope, y: -start * slope, z: -start * slope, w: 0)
        image = clamp(ramp.outputImage ?? image)
        let smooth = CIFilter.colorPolynomial()
        smooth.inputImage = image
        let coefficients = CIVector(x: 0, y: 0, z: 3, w: -2)
        smooth.redCoefficients = coefficients
        smooth.greenCoefficients = coefficients
        smooth.blueCoefficients = coefficients
        return smooth.outputImage ?? image
    }

    private func clamp(_ image: CIImage) -> CIImage {
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? image
    }

    private func invert(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorInvert")
    }

    private func scale(_ image: CIImage, by value: Double) -> CIImage {
        let scale = CIFilter.colorMatrix()
        scale.inputImage = image
        scale.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        scale.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        scale.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        return scale.outputImage ?? image
    }
}
