import AppKit
import ColorEngine
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import UniformTypeIdentifiers
import Vision

/// A local, non-generative skin-colour reference experiment. Input should be a
/// developed 16-bit TIFF; the analysis image supplies the registered skin mask.
@main
struct ReferenceMatch {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Distribution: Codable {
        let p10: Double
        let p25: Double
        let median: Double
        let p75: Double
        let p90: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            func q(_ p: Double) -> Double {
                let position = p * Double(sorted.count - 1)
                let i = Int(position)
                let j = min(i + 1, sorted.count - 1)
                return sorted[i] + (sorted[j] - sorted[i]) * (position - Double(i))
            }
            p10 = q(0.10); p25 = q(0.25); median = q(0.5); p75 = q(0.75); p90 = q(0.90)
        }
    }

    struct Profile: Codable {
        let sampleCount: Int
        let faceWidthPixels: Double
        let lightness: Distribution
        let redGreen: Distribution
        let yellowBlue: Distribution
    }

    struct Recipe: Encodable {
        let source: Profile
        let reference: Profile
        let strength: Double
        let lightnessScale: Double
        let redScale: Double
        let yellowScale: Double
        let deltaL: Double
        let deltaA: Double
        let deltaB: Double
        let workingSpace = "CIELAB D65 via linear Display P3"
        let scope = "Largest face skin; excludes eyes, lips, hair, clothing and background"
        init(source: Profile, reference: Profile, strength: Double) {
            self.source = source; self.reference = reference; self.strength = strength
            func ratio(_ a: Distribution, _ b: Distribution, lower: Double) -> Double {
                if a.p75 - a.p25 < 1 || b.p75 - b.p25 < 1 { return 1 }
                return min(1.2, max(lower, (b.p75 - b.p25) / max(a.p75 - a.p25, 1)))
            }
            lightnessScale = ratio(source.lightness, reference.lightness, lower: 0.85)
            redScale = ratio(source.redGreen, reference.redGreen, lower: 0.70)
            yellowScale = ratio(source.yellowBlue, reference.yellowBlue, lower: 0.80)
            deltaL = min(14, max(-14, reference.lightness.median - source.lightness.median))
            deltaA = min(10, max(-10, reference.redGreen.median - source.redGreen.median))
            deltaB = min(10, max(-10, reference.yellowBlue.median - source.yellowBlue.median))
        }
    }

    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func load(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw Failure(message: "无法读取 \(url.path)")
        }
        return image
    }

    static func render(_ image: CIImage, context: CIContext, format: CIFormat = .RGBA8,
                       space: CGColorSpace = sRGB) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent.integral,
                                                 format: format, colorSpace: space) else {
            throw Failure(message: "图像渲染失败")
        }
        return result
    }

    static func faceBox(_ image: CIImage, context: CIContext) throws -> CGRect {
        let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: render(small, context: context)).perform([request])
        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), face.confidence >= 0.6 else { throw Failure(message: "未检测到可靠的人脸") }
        let box = face.boundingBox
        return CGRect(x: box.minX * image.extent.width, y: box.minY * image.extent.height,
                      width: box.width * image.extent.width, height: box.height * image.extent.height)
    }

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
        }
        let x = f((0.4865709486*r + 0.2656676932*g + 0.1982172852*b) / 0.9504559271)
        let y = f(0.2289745641*r + 0.6917385218*g + 0.0792869141*b)
        let z = f((0.0451133819*g + 1.0439443689*b) / 1.0890577508)
        return (116*y - 16, 500*(x-y), 200*(y-z))
    }

    static func profile(_ image: CIImage, mask: CIImage, box: CGRect,
                        context: CIContext) throws -> Profile {
        // Restrict statistics to the detected face, avoiding ears/neck shadows.
        // Erosion and a high mask threshold reject mixed hair/background edges.
        let rect = box.insetBy(dx: box.width * 0.035, dy: box.height * 0.035)
            .integral.intersection(image.extent)
        let factor = min(1, 420 / max(rect.width, rect.height))
        let transform = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
        let rgb = image.cropped(to: rect).transformed(by: transform)
        let selection = mask.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: max(1, box.width * 0.006)
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
        for index in stride(from: 0, to: colors.count, by: 4) where weights[index] > 0.95 {
            let (l, a, b) = lab(Double(colors[index]), Double(colors[index+1]), Double(colors[index+2]))
            if l.isFinite && a.isFinite && b.isFinite && l > 15 && l < 97 {
                ls.append(l); aa.append(a); bb.append(b)
            }
        }
        guard ls.count >= 200 else { throw Failure(message: "脸部皮肤有效采样不足，无法自动追色") }
        return Profile(sampleCount: ls.count, faceWidthPixels: box.width,
                       lightness: Distribution(ls), redGreen: Distribution(aa), yellowBlue: Distribution(bb))
    }

    static func transfer(_ image: CIImage, mask: CIImage, recipe: Recipe) throws -> CIImage {
        if recipe.strength == 0 { return image }
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
        guard let kernel = try CIKernel.kernels(withMetalString: metal).first as? CIColorKernel,
              let adjusted = kernel.apply(extent: image.extent, arguments: [
                image,
                CIVector(x: recipe.source.lightness.median, y: recipe.source.redGreen.median,
                         z: recipe.source.yellowBlue.median),
                CIVector(x: recipe.lightnessScale, y: recipe.redScale, z: recipe.yellowScale),
                CIVector(x: recipe.deltaL, y: recipe.deltaA, z: recipe.deltaB), recipe.strength
              ]) else { throw Failure(message: "无法创建追色算子") }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask.clampedToExtent()
                .applyingGaussianBlur(sigma: max(1, image.extent.height * 0.0005)).cropped(to: image.extent)
        ]).cropped(to: image.extent)
    }

    static func save(_ image: CGImage, url: URL, type: UTType, dpi: [CFString: Any] = [:]) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "输出已存在：\(url.path)")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID()).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(message: "无法创建输出")
        }
        var properties = dpi
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImageDestinationLossyCompressionQuality] = 0.96
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "输出失败") }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    static func board(_ items: [(String, CIImage, CGRect)], context: CIContext, url: URL) throws {
        let width = 460, height = 580, title = 48
        let canvas = CGContext(data: nil, width: width * items.count, height: height + title,
                               bitsPerComponent: 8, bytesPerRow: width * items.count * 4, space: sRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(gray: 0.1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width * items.count, height: height + title))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, item) in items.enumerated() {
            let crop = try render(item.1.cropped(to: item.2), context: context)
            canvas.interpolationQuality = .high
            let scale = min(Double(width) / Double(crop.width), Double(height) / Double(crop.height))
            let w = Double(crop.width) * scale, h = Double(crop.height) * scale
            canvas.draw(crop, in: CGRect(x: Double(index * width) + (Double(width)-w)/2,
                                         y: (Double(height)-h)/2, width: w, height: h))
            (item.0 as NSString).draw(at: CGPoint(x: index*width+16, y: height+15), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
            ])
        }
        try save(canvas.makeImage()!, url: url, type: .png)
    }

    static func main() async throws {
        var options: [String: String] = [:]
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args.isEmpty {
            print("""
            ReferenceMatch --input <已显影 TIFF/JPEG> --reference <参考图> --output <目录>
              --analysis <原始 JPEG>     与底稿相同尺寸、相同构图，用于自动皮肤选区
              --strength <0...1>          追色强度，默认 0.85
              --name <名称>              输出文件名，默认「参考肤色」；不会覆盖已有文件
              --diagnostic-only true     仅生成对比、选区检查和特征 JSON
            输入应为已显影的 RGB 文件。RAW 请先通过 PortraitRetouch 导出 16 位 TIFF。
            """)
            return
        }
        guard args.count % 2 == 0 else { throw Failure(message: "参数必须为 --名称 取值") }
        let known: Set<String> = ["--input", "--reference", "--output", "--analysis", "--strength", "--name", "--diagnostic-only"]
        for index in stride(from: 0, to: args.count, by: 2) {
            guard known.contains(args[index]) else { throw Failure(message: "未知参数：\(args[index])") }
            options[args[index]] = args[index+1]
        }
        func url(_ key: String) throws -> URL {
            guard let value = options[key] else { throw Failure(message: "缺少 \(key)") }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        let input = try url("--input"), referenceURL = try url("--reference"), output = try url("--output")
        let analysisURL = options["--analysis"].map { URL(fileURLWithPath: $0) } ?? input
        guard let strength = Double(options["--strength"] ?? "0.85"), strength.isFinite,
              (0...1).contains(strength) else { throw Failure(message: "强度必须为 0...1") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "追色需要 Metal GPU") }
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false
        ])
        let original = try load(input), reference = try load(referenceURL), analysis = try load(analysisURL)
        guard original.extent.size == analysis.extent.size else {
            throw Failure(message: "底稿与蒙版分析图的转正尺寸必须一致")
        }
        let engine = ColorEngine()
        var selections = Adjustments()
        let layer = AdjustmentLayer(mask: .skin)
        selections.layers = [layer]
        func mask(_ url: URL) async throws -> CIImage {
            let cg = try await engine.preview(url, adjustments: selections, maxEdge: nil,
                                               maskLayerID: layer.id, profile: .sRGB, preferRAW: false)
            return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        }
        let box = try faceBox(analysis, context: context), refBox = try faceBox(reference, context: context)
        func restrict(_ mask: CIImage, to box: CGRect, extent: CGRect) -> CIImage {
            let region = box.insetBy(dx: -box.width*0.25, dy: -box.height*0.35).intersection(extent)
            return mask.cropped(to: region).composited(over: CIImage(color: .black).cropped(to: extent))
        }
        let skin = restrict(try await mask(analysisURL), to: box, extent: original.extent)
        let referenceSkin = restrict(try await mask(referenceURL), to: refBox, extent: reference.extent)
        let before = try profile(original, mask: skin, box: box, context: context)
        let ref = try profile(reference, mask: referenceSkin, box: refBox, context: context)
        let recipe = Recipe(source: before, reference: ref, strength: strength)
        let result = try transfer(original, mask: skin, recipe: recipe)
        let after = try profile(result, mask: skin, box: box, context: context)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stem = options["--name"] ?? "参考肤色"
        func target(_ suffix: String) -> URL { output.appendingPathComponent(stem+suffix) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Encodable { let input: URL; let reference: URL; let recipe: Recipe; let result: Profile }
        // Create the diagnostic report before the optional full-sized exports.
        let report = target("-特征.json")
        guard !FileManager.default.fileExists(atPath: report.path) else { throw Failure(message: "输出已存在") }
        try encoder.encode(Report(input: input, reference: referenceURL, recipe: recipe, result: after))
            .write(to: report, options: .withoutOverwriting)
        func portrait(_ rect: CGRect, extent: CGRect) -> CGRect {
            let width = rect.width * 1.85
            return CGRect(x: rect.midX-width/2, y: rect.midY-width*0.65,
                          width: width, height: width*1.3).integral.intersection(extent)
        }
        let crop = portrait(box, extent: original.extent)
        try board([("参考图", reference, portrait(refBox, extent: reference.extent)),
                   ("681 · 现有 RAW 底稿", original, crop),
                   ("681 · 参考肤色", result, crop)], context: context, url: target("-对比.png"))
        // The selection is also exported so edge errors can be inspected.
        try board([("参考图 · 皮肤选区", referenceSkin, portrait(refBox, extent: reference.extent)),
                   ("681 · 皮肤选区", skin, crop)], context: context, url: target("-选区.png"))
        if options["--diagnostic-only"] != "true" {
            var dpi: [CFString: Any] = [:]
            if let source = CGImageSourceCreateWithURL(input as CFURL, nil),
               let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let rotated = (5...8).contains(metadata[kCGImagePropertyOrientation] as? Int ?? 1)
                dpi[kCGImagePropertyDPIWidth] = metadata[rotated ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth]
                dpi[kCGImagePropertyDPIHeight] = metadata[rotated ? kCGImagePropertyDPIWidth : kCGImagePropertyDPIHeight]
            }
            try save(render(result, context: context, format: .RGBA16, space: original.colorSpace ?? p3),
                     url: target(".tiff"), type: .tiff, dpi: dpi)
            try save(render(result, context: context), url: target(".jpg"), type: .jpeg, dpi: dpi)
        }
        for (name, profile) in [("参考", ref), ("底稿", before), ("追色", after)] {
            print(String(format: "%@ L*=%.2f a*=%.2f b*=%.2f Lp10–90=%.2f–%.2f n=%d", name,
                         profile.lightness.median, profile.redGreen.median, profile.yellowBlue.median,
                         profile.lightness.p10, profile.lightness.p90, profile.sampleCount))
        }
        print(target("-对比.png").path)
    }
}
