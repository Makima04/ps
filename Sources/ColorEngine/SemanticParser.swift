import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import Vision

public struct FaceRegionInfo: Identifiable, Sendable {
    public let index: Int
    public let bounds: CGRect
    public let hasLandmarks: Bool
    public var id: Int { index }
}

struct SemanticFace {
    let info: FaceRegionInfo
    let regions: [MaskKind: CIImage]
}

struct SemanticMasks {
    let faces: [SemanticFace]
    let head: CIImage
    let clothing: CIImage
    let hands: CIImage
    let extent: CGRect

    func mask(_ kind: MaskKind, faceIndex: Int? = nil) -> CIImage {
        if kind == .clothing { return clothing }
        var result = CIImage(color: .black).cropped(to: extent)
        for face in faces where faceIndex == nil || face.info.index == faceIndex {
            guard let local = face.regions[kind] else { continue }
            result = local.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: result])
        }
        return result.cropped(to: extent)
    }
}

// Owned by MaskRenderer and accessed on the ColorEngine actor.
final class SemanticParser {
    private var faceModel: MLModel?
    private var clothingModel: MLModel?

    func masks(original: CIImage, context: CIContext) throws -> SemanticMasks {
        let faces = try faceMasks(original: original, context: context)
        try Task.checkCancellation()
        let model = try loadModel("ClothSegmentation", cached: &clothingModel)
        let input = try cgImage(original, rect: original.extent, context: context)
        let tensor = try predict(model, image: input, output: "probs")
        guard tensor.shape.map(\.intValue) == [1, 4, 768, 768] else {
            throw ImageError.maskFailed("服装模型输出尺寸异常")
        }
        let strides = tensor.strides.map(\.intValue)
        var pixels = [UInt8](repeating: 0, count: 768 * 768)
        for y in 0..<768 {
            for x in 0..<768 {
                let offset = y * strides[2] + x * strides[3]
                let background = number(tensor, at: offset)
                let upper = number(tensor, at: offset + strides[1])
                let lower = number(tensor, at: offset + 2 * strides[1])
                let dress = number(tensor, at: offset + 3 * strides[1])
                let strongest = max(upper, lower, dress)
                if strongest > background {
                    pixels[y * 768 + x] = UInt8((max(0, min(1, 1 - background)) * 255).rounded())
                }
            }
        }
        let small = try image(pixels, width: 768, height: 768)
        var clothing = try refine(small, guide: original, rect: original.extent)
        let excludeHead = faces.head.applyingFilter("CIColorInvert")
        clothing = clothing.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: excludeHead
        ])
        let hands = try BodyRegionGuide.hands(original,context:context)
        let refined = try faces.faces.map { face in
            try SkinMaskRefinement.refine(face, image: original, clothing: clothing, hands: hands, context: context)
        }
        let boxes = refined.map { $0.info.bounds }
        let owned = try refined.enumerated().map { index, face in
            SemanticFace(info: face.info, regions: try face.regions.mapValues {
                try FaceMaskOwnership.restrict($0,index:index,boxes:boxes)
            })
        }
        return SemanticMasks(faces: owned, head: faces.head, clothing: clothing.cropped(to: original.extent), hands: hands, extent: original.extent)
    }

    private func faceMasks(original: CIImage, context: CIContext) throws -> (faces: [SemanticFace], head: CIImage) {
        let extent = original.extent
        let scale = min(1, 1600 / max(extent.width, extent.height))
        let reduced = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let input = try cgImage(reduced, rect: reduced.extent, context: context)
        let handler = VNImageRequestHandler(cgImage: input)
        let detection = VNDetectFaceRectanglesRequest()
        try handler.perform([detection])
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = detection.results
        // Landmark failure must never remove a face that the existing detector found.
        try? handler.perform([request])
        var head = CIImage(color: .black).cropped(to: extent)
        var faces: [SemanticFace] = []
        let model = try loadModel("FaceParsing", cached: &faceModel)
        // CelebAMask-HQ: mouth interior is only a candidate, never a teeth label.
        let labelsByRegion: [MaskKind: Set<Int>] = [
            .skin: [1, 7, 8, 10, 14], .neck: [14], .lips: [12, 13],
            .eyes: [4, 5], .eyebrows: [2, 3], .hair: [17], .teeth: [11]
        ]
        let ordered = (detection.results ?? []).filter { $0.confidence >= 0.6 }.sorted {
            if abs($0.boundingBox.midX - $1.boundingBox.midX) > 0.01 {
                return $0.boundingBox.midX < $1.boundingBox.midX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        let boxes = ordered.map { face in
            CGRect(x: extent.minX + face.boundingBox.minX * extent.width,
                   y: extent.minY + face.boundingBox.minY * extent.height,
                   width: face.boundingBox.width * extent.width, height: face.boundingBox.height * extent.height)
        }
        for (index, face) in ordered.enumerated() {
            try Task.checkCancellation()
            let box = face.boundingBox
            let width = box.width * extent.width
            let height = box.height * extent.height
            let bounds = CGRect(x: extent.minX + box.minX * extent.width,
                                y: extent.minY + box.minY * extent.height, width: width, height: height)
            let side = max(width * 2.1, height * 1.8)
            let center = CGPoint(x: bounds.midX, y: bounds.midY + height * 0.05)
            let crop = CGRect(x: center.x - side / 2, y: center.y - side / 2,
                              width: side, height: side).integral.intersection(extent)
            let cropImage = try cgImage(original, rect: crop, context: context)
            let labels = try predict(model, image: cropImage, output: "argmax_out")
            guard labels.count == 512 * 512 else { throw ImageError.maskFailed("脸部模型输出尺寸异常") }
            var regions: [MaskKind: CIImage] = [:]
            for (kind, classes) in labelsByRegion {
                let pixels = (0..<labels.count).map { classes.contains(labels[$0].intValue) ? UInt8(255) : 0 }
                var local = try refine(image(pixels, width: 512, height: 512), guide: original, rect: crop)
                if kind == .teeth { local = try SkinProcessing.teethCandidate(original).applyingFilter(
                    "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: local]) }
                regions[kind] = try MaskBounds.pad(local.cropped(to: crop), to: extent)
            }
            let headPixels = (0..<labels.count).map { i -> UInt8 in
                let label = labels[i].intValue
                return label != 0 && label != 16 ? 255 : 0
            }
            let localHead = try MaskBounds.pad(refine(image(headPixels, width: 512, height: 512),
                                                     guide: original, rect: crop), to: extent)
            head = localHead.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: head])
            let landmarkFace = request.results?.first { observation in
                observation.uuid == face.uuid || observation.boundingBox.intersection(face.boundingBox).width *
                    observation.boundingBox.intersection(face.boundingBox).height > face.boundingBox.width * face.boundingBox.height * 0.7
            }
            if let landmarks = landmarkFace?.landmarks, let left = landmarks.leftEye, let right = landmarks.rightEye, left.pointCount > 0, right.pointCount > 0 {
                func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
                    let points = region.normalizedPoints
                    return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                   y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                }
                let geometry = FaceRegionGeometry(box: bounds, eyeA: center(left), eyeB: center(right))
                for kind in [MaskKind.forehead, .leftCheek, .rightCheek, .underEyes, .noseSides] {
                    let area = geometry.mask(kind, extent: extent)
                    regions[kind] = area.applyingFilter("CIMultiplyCompositing", parameters: [
                        kCIInputBackgroundImageKey: regions[.skin]!
                    ]).cropped(to: extent)
                }
            }
            for kind in Array(regions.keys) {
                regions[kind] = try FaceMaskOwnership.restrict(regions[kind]!, index: index, boxes: boxes)
            }
            faces.append(SemanticFace(info: FaceRegionInfo(index: index, bounds: bounds,
                                      hasLandmarks: regions[.leftCheek] != nil), regions: regions))
        }
        return (faces, head.cropped(to: extent))
    }

    private func loadModel(_ name: String, cached: inout MLModel?) throws -> MLModel {
        if let cached { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") else {
            throw ImageError.maskFailed("缺少 \(name) 模型，请运行模型准备脚本并重新构建")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: url, configuration: configuration)
        cached = model
        return model
    }

    private func predict(_ model: MLModel, image: CGImage, output: String) throws -> MLMultiArray {
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint else {
            throw ImageError.maskFailed("模型图像输入不可用")
        }
        let feature = try MLFeatureValue(cgImage: image, constraint: constraint,
                                        options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: feature]))
        guard let tensor = result.featureValue(for: output)?.multiArrayValue else {
            throw ImageError.maskFailed("模型结果不可用")
        }
        return tensor
    }

    private func cgImage(_ image: CIImage, rect: CGRect, context: CIContext) throws -> CGImage {
        guard let result = context.createCGImage(image, from: rect, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ImageError.maskFailed("无法读取图像")
        }
        return result
    }

    private func number(_ tensor: MLMultiArray, at offset: Int) -> Float {
        switch tensor.dataType {
        case .float32: tensor.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .float16: Float(tensor.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        case .double: Float(tensor.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        case .int32: Float(tensor.dataPointer.assumingMemoryBound(to: Int32.self)[offset])
        default: 0
        }
    }

    private func image(_ pixels: [UInt8], width: Int, height: Int) throws -> CIImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ImageError.maskFailed("无法创建区域选区")
        }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private func refine(_ small: CIImage, guide: CIImage, rect: CGRect) throws -> CIImage {
        let local = guide.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let refine = CIFilter.edgePreserveUpsample()
        refine.inputImage = local
        refine.smallImage = small
        refine.spatialSigma = 2
        refine.lumaSigma = 0.1
        guard let output = refine.outputImage else { throw ImageError.maskFailed("无法细化区域边缘") }
        return output.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).cropped(to: rect)
    }
}
