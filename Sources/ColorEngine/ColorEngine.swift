import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import UniformTypeIdentifiers

public struct PhotoInfo: Sendable {
    public let width: Int
    public let height: Int
    public let profile: String?

    public static func read(_ url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageError.cannotRead(url.lastPathComponent)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return Self(width: rotated ? height : width, height: rotated ? width : height,
                    profile: properties[kCGImagePropertyProfileName] as? String)
    }
}

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case tiff, jpeg

    public var id: Self { self }
    public var label: String { self == .tiff ? "TIFF · 16 位无损" : "JPEG · 高画质" }
    public var fileExtension: String { self == .tiff ? "tiff" : "jpg" }
    var type: UTType { self == .tiff ? .tiff : .jpeg }
}

public enum OutputProfile: String, CaseIterable, Identifiable, Sendable {
    case source, sRGB

    public var id: Self { self }
    public var label: String { self == .source ? "保留输入 RGB 色域" : "转换为 sRGB" }
}

enum ImageError: LocalizedError {
    case cannotRead(String)
    case cannotRender
    case cannotWrite(String)
    case maskFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name): "无法读取「\(name)」"
        case .cannotRender: "无法渲染这张照片"
        case .cannotWrite(let name): "无法导出「\(name)」"
        case .maskFailed(let reason): "蒙版生成失败：\(reason)"
        }
    }
}

public actor ColorEngine {
    let context: CIContext
    let masks = MaskRenderer()
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Legacy entry point: a JPEG path is automatically upgraded to its paired ARW.
    public func preview(_ url: URL, adjustments: Adjustments, maxEdge: Int?,
                        maskLayerID: UUID? = nil, profile: OutputProfile = .source,
                        preferRAW: Bool = true, referenceMask: Bool = false, referenceBodyMask: Bool = false) throws -> CGImage {
        try preview(PhotoSource.resolve(url, preferRAW: preferRAW), adjustments: adjustments,
                    maxEdge: maxEdge, maskLayerID: maskLayerID, profile: profile, referenceMask: referenceMask, referenceBodyMask: referenceBodyMask)
    }

    public func preview(_ source: PhotoSource, adjustments: Adjustments, maxEdge: Int?,
                        maskLayerID: UUID? = nil, profile: OutputProfile = .source, referenceMask: Bool = false, referenceBodyMask: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        var image: CIImage
        if referenceMask, let application = adjustments.skinReference {
            let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: source.analysisURL, context: context)
            image = CIImage(color: .black).cropped(to: original.extent)
            if referenceBodyMask {
                image = try bodyCandidates(original, analysis: analysis, cacheURL: source.analysisURL, application: application, parsed: parsed)
            } else {
                for face in parsed.faces where application.faceIndex == nil || application.faceIndex == face.info.index {
                    let local = try referenceSelection(parsed: parsed, faceIndex: face.info.index, application: application,
                                                       original: original, analysis: analysis, cacheURL: source.analysisURL)
                    image = local.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: image])
                }
            }
        } else if let maskLayerID, let layer = adjustments.layers.first(where: { $0.id == maskLayerID }) {
            image = try masks.makeMask(for: layer, original: original, analysis: analysis,
                                       cacheURL: source.analysisURL, context: context)
        } else {
            image = try composite(original, analysis: analysis, with: adjustments,
                                  cacheURL: source.analysisURL)
        }
        if let maxEdge {
            let scale = min(1, CGFloat(maxEdge) / max(image.extent.width, image.extent.height))
            if scale < 1 {
                let resize = CIFilter.lanczosScaleTransform()
                resize.inputImage = image
                resize.scale = Float(scale)
                image = resize.outputImage ?? image
            }
        }
        try Task.checkCancellation()
        return try render(image, format: .RGBA8, colorSpace: outputSpace(for: original, profile: profile))
    }

    /// Legacy entry point: keeps JPEG-only projects working while preferring RAW pixels.
    public func export(_ sourceURL: URL, to target: URL, adjustments: Adjustments,
                       format: OutputFormat, profile: OutputProfile,
                       preferRAW: Bool = true) throws {
        try export(PhotoSource.resolve(sourceURL, preferRAW: preferRAW), to: target,
                   adjustments: adjustments, format: format, profile: profile)
    }

    public func export(_ source: PhotoSource, to target: URL, adjustments: Adjustments,
                       format: OutputFormat, profile: OutputProfile) throws {
        try Task.checkCancellation()
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        let colorSpace = outputSpace(for: original, profile: profile)
        var graded = try composite(original, analysis: analysis, with: adjustments,
                                   cacheURL: source.analysisURL)
        if format == .jpeg {
            let background = CIImage(color: .white).cropped(to: graded.extent)
            graded = graded.composited(over: background)
        }
        let image = try render(graded, format: format == .tiff ? .RGBA16 : .RGBA8,
                               colorSpace: colorSpace)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ImageError.cannotWrite(target.lastPathComponent)
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let imageSource = CGImageSourceCreateWithURL(source.metadataURL as CFURL, nil),
           let input = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            let rotated = (5...8).contains(input[kCGImagePropertyOrientation] as? Int ?? 1)
            properties[kCGImagePropertyDPIWidth] = input[rotated ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth]
            properties[kCGImagePropertyDPIHeight] = input[rotated ? kCGImagePropertyDPIWidth : kCGImagePropertyDPIHeight]
        }
        switch format {
        case .tiff:
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = 0.96
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.cannotWrite(target.lastPathComponent)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    /// Decodes the pixel source. Camera RAW files go through the full-quality
    /// CIRAWFilter demosaic (never draft mode), producing a Display P3 image with
    /// linear highlight headroom; its orientation is already normalised.
    func load(_ source: PhotoSource) throws -> CIImage {
        let image: CIImage?
        if source.isRAW {
            let filter = CIFilter(imageURL: source.imageURL, options: nil)
            filter?.setValue(false, forKey: "inputDraftMode")
            filter?.setValue(1.0, forKey: "inputScaleFactor")
            image = filter?.outputImage
        } else {
            image = CIImage(contentsOf: source.imageURL, options: [.applyOrientationProperty: true])
        }
        guard let image, !image.extent.isEmpty, !image.extent.isInfinite else {
            throw ImageError.cannotRead(source.imageURL.lastPathComponent)
        }
        return image
    }

    /// Masks are detected on the gamma-encoded camera JPEG when one is paired.
    /// Linear RAW output is too flat for Vision/Core ML detectors, and re-decoding
    /// the RAW twice is expensive. A lone ARW simply reuses the pixel source.
    func analysisImage(for source: PhotoSource, original: CIImage) throws -> CIImage {
        guard source.analysisURL != source.imageURL else { return original }
        guard let image = CIImage(contentsOf: source.analysisURL,
                                  options: [.applyOrientationProperty: true]),
              !image.extent.isEmpty else {
            return original
        }
        let target = original.extent
        let scaleX = target.width / image.extent.width
        let scaleY = target.height / image.extent.height
        guard abs(scaleX - 1) < 0.002, abs(scaleY - 1) < 0.002 else {
            return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: target)
        }
        return image.cropped(to: target)
    }

    private func outputSpace(for image: CIImage, profile: OutputProfile) -> CGColorSpace {
        if profile == .source, let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return sRGB
    }

    private func render(_ image: CIImage, format: CIFormat, colorSpace: CGColorSpace) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent.integral,
                                                 format: format, colorSpace: colorSpace) else {
            throw ImageError.cannotRender
        }
        return result
    }
}
