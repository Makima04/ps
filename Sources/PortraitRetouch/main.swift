import AppKit
import ColorEngine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Portrait retouching pipeline: ARW is the primary pixel source, JPEG remains a
// fully supported fallback. Run `swift run --disable-sandbox -c release PortraitRetouch --help`.
@main
struct PortraitRetouch {
    struct Recipe {
        // Skin: a modest lift plus highlight recovery instead of a flat +1 EV wash.
        var skinExposure = 0.45
        var skinRednessReduction = 0.22
        var skinHighlights = -0.12
        var skinShadows = 0.10
        var skinContrast = 0.02
        var skinHighlightProtection = 0.70
        var skinOpacity = 0.92
        // Lips: their own selection so a brightened face cannot leave a dark red mouth.
        // The hue operator keeps the red; exposure lifts the "dark" part.
        var lipExposure = 0.16
        var lipNaturalization = 0.60
        var lipSaturation = 0.0
        var lipOpacity = 0.90
    }

    struct Options {
        var input = ""
        var output = ""
        var name = "自然白皙"
        var candidates = false
        var jpegOnly = false
        var overwrite = false
        var skinEV = 0.45
        var lipAmount = 0.60
        var lipEV = 0.16
        var redness = 0.22
        // ARW's default develop is warmer than the camera JPEG. This mild global
        // correction brings cheek hue back to the subject's measured baseline
        // (h° 37) without washing out chroma the way a pure cooling would.
        var wbTemp = -600.0
        var wbTint = 15.0
        var skipTIFF = false
        var legacy = ""
        var qa = ""
        var adaptive = false
        var quick = false
        var reference = ""
        var settingsFile = ""
        var lipStyle: LipStyle = .original

        static let usage = """
        用法: PortraitRetouch --input <照片.JPG|.ARW> [选项]

          --input <路径>          必需。传入 JPG 会自动升级为同名 ARW 像素源。
          --output <目录>         成片输出目录，默认与输入同级的「成片」目录。
          --name <名称>           成片后缀，默认「自然白皙」。
          --candidates            只生成多组参数候选对比图，不导出成片。
          --jpeg-only             强制走 JPG 像素源，用于验证兼容路径。
          --overwrite             覆盖同名成片；默认遇到重名自动追加编号。
          --skin-ev <值>          脸部皮肤提亮 EV，默认 0.45。
          --lip <值>              唇色自然化强度 0...1，默认 0.60。
          --lip-ev <值>           唇部提亮 EV，默认 0.16。
          --redness <值>          脸部压低泛红强度 0...1，默认 0.22。
          --wb-temp <值>          全图相对色温，抵消 RAW 显影偏暖，默认 -600。
          --wb-tint <值>          全图相对色调，与色温配合保留红润，默认 +15。
          --skip-tiff             只输出 JPEG 与对比图，用于快速调参。
          --compare-legacy <路径> 把上一版成片加入前后对比图。
          --qa <目录>             候选/诊断图输出目录，默认 <output>/.qa。
          --adaptive              使用自适应肤色、身体协调与独立唇色控制。
          --quick                 使用与 GUI 快速修图相同的自然通透流程。
          --reference <路径>      自适应模式的参考成片，提取肤色与相对唇色。
          --lip-style <模式>      original / pink / rose / coral / reference，默认 original。
          --settings <JSON路径>   使用已保存的完整参数快照，可重复导出同一结果。
        """

        static func parse(_ arguments: [String]) throws -> Self {
            var options = Options()
            var index = 1
            while index < arguments.count {
                let flag = arguments[index]
                func value() throws -> String {
                    guard index + 1 < arguments.count else { throw RetouchError.missingValue(flag) }
                    let result = arguments[index + 1]
                    index += 2
                    return result
                }
                switch flag {
                case "--input": options.input = try value()
                case "--output": options.output = try value()
                case "--name": options.name = try value()
                case "--candidates": options.candidates = true; index += 1
                case "--jpeg-only": options.jpegOnly = true; index += 1
                case "--overwrite": options.overwrite = true; index += 1
                case "--skin-ev": options.skinEV = try Double(value()) ?? 0.45
                case "--lip": options.lipAmount = try Double(value()) ?? 0.60
                case "--lip-ev": options.lipEV = try Double(value()) ?? 0.16
                case "--redness": options.redness = try Double(value()) ?? 0.22
                case "--wb-temp": options.wbTemp = try Double(value()) ?? -600
                case "--wb-tint": options.wbTint = try Double(value()) ?? 15
                case "--skip-tiff": options.skipTIFF = true; index += 1
                case "--compare-legacy": options.legacy = try value()
                case "--qa": options.qa = try value()
                case "--adaptive": options.adaptive = true; index += 1
                case "--quick": options.quick = true; index += 1
                case "--reference": options.reference = try value()
                case "--settings": options.settingsFile = try value()
                case "--lip-style":
                    let name = try value()
                    guard let style = LipStyle(rawValue: name), style != .manual else { throw RetouchError.unknownOption(name) }
                    options.lipStyle = style
                case "--help", "-h": print(usage); exit(0)
                default: throw RetouchError.unknownOption(flag)
                }
            }
            guard !options.input.isEmpty else { throw RetouchError.missingInput }
            return options
        }
    }

    enum RetouchError: LocalizedError {
        case missingInput, missingValue(String), unknownOption(String), noFace
        var errorDescription: String? {
            switch self {
            case .missingInput: "缺少 --input 参数\n\(Options.usage)"
            case .missingValue(let flag): "\(flag) 缺少取值"
            case .unknownOption(let flag): "未知参数 \(flag)\n\(Options.usage)"
            case .noFace: "未在照片中检测到人脸"
            }
        }
    }

    /// The previous JPG-only recipe kept for comparison: it washed the skin out
    /// and left the lips dark because lips were excluded from the skin mask.
    static func legacySettings() -> Adjustments {
        var settings = Adjustments()
        var skin = AdjustmentLayer(mask: .skin)
        skin.name = "脸部皮肤调整（上一版）"
        skin.adjustments.exposure = 1.05
        skin.adjustments.rednessReduction = 0.40
        skin.highlightProtection = 0.35
        skin.feather = 0.001
        settings.layers.append(skin)
        return settings
    }

    static func settings(_ recipe: Recipe) -> Adjustments {
        var settings = Adjustments()
        var skin = AdjustmentLayer(mask: .skin)
        skin.name = "脸部皮肤 · 自然白皙"
        skin.adjustments.exposure = recipe.skinExposure
        skin.adjustments.rednessReduction = recipe.skinRednessReduction
        skin.adjustments.highlights = recipe.skinHighlights
        skin.adjustments.shadows = recipe.skinShadows
        skin.adjustments.contrast = recipe.skinContrast
        skin.highlightProtection = recipe.skinHighlightProtection
        skin.feather = 0.0003
        skin.opacity = recipe.skinOpacity
        settings.layers.append(skin)

        var lips = AdjustmentLayer(mask: .lips)
        lips.name = "嘴唇 · 自然唇色"
        lips.adjustments.exposure = recipe.lipExposure
        lips.adjustments.lipNaturalization = recipe.lipNaturalization
        lips.adjustments.saturation = recipe.lipSaturation
        lips.feather = 0.0004
        lips.opacity = recipe.lipOpacity
        settings.layers.append(lips)
        return settings
    }

    static func faceRect(_ image: CGImage) throws -> CGRect {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            throw RetouchError.noFace
        }
        let box = face.boundingBox
        let width = box.width * Double(image.width) * 2.0
        let height = width * 1.2
        return CGRect(x: box.midX * Double(image.width) - width / 2,
                      y: (1 - box.midY) * Double(image.height) - height / 2,
                      width: width, height: height).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func comparison(_ images: [CGImage], labels: [String], rect: CGRect,
                           output: URL, cellWidth: Int = 500) throws {
        let cellHeight = Int(Double(cellWidth) * rect.height / rect.width)
        guard let canvas = CGContext(data: nil, width: cellWidth * images.count,
                                     height: cellHeight + 50,
                                     bitsPerComponent: 8, bytesPerRow: cellWidth * images.count * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RetouchError.noFace
        }
        canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: cellWidth * images.count, height: cellHeight + 50))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, image) in images.enumerated() {
            canvas.interpolationQuality = .high
            guard let crop = image.cropping(to: rect) else { continue }
            canvas.draw(crop, in: CGRect(x: index * cellWidth, y: 0,
                                         width: cellWidth, height: cellHeight))
            (labels[index] as NSString).draw(
                at: CGPoint(x: index * cellWidth + 16, y: cellHeight + 15),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                 .foregroundColor: NSColor.white])
        }
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RetouchError.missingValue("无法创建 \(output.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RetouchError.missingValue("无法写入 \(output.lastPathComponent)")
        }
    }

    static func image(at path: String) throws -> CGImage? {
        guard !path.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments)
        let manager = FileManager.default
        let input = URL(fileURLWithPath: options.input).standardizedFileURL
        guard manager.fileExists(atPath: input.path) else {
            throw RetouchError.missingValue("输入文件不存在：\(input.path)")
        }
        let output = options.output.isEmpty
            ? input.deletingLastPathComponent().appendingPathComponent("成片")
            : URL(fileURLWithPath: options.output).standardizedFileURL
        let qa = options.qa.isEmpty
            ? output.appendingPathComponent(".qa")
            : URL(fileURLWithPath: options.qa).standardizedFileURL
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        try manager.createDirectory(at: qa, withIntermediateDirectories: true)

        let source = PhotoSource.resolve(input, preferRAW: !options.jpegOnly)
        let jpegFallback = PhotoSource.resolve(input, preferRAW: false)
        print("像素源    : \(source.label)")
        print("分析参考  : \(source.analysisURL.lastPathComponent)")
        print("JPG 回退  : \(jpegFallback.imageURL.lastPathComponent)")

        let engine = ColorEngine()
        let baseline = try await engine.preview(source, adjustments: Adjustments(),
                                                maxEdge: nil, profile: .sRGB)
        let rect = try faceRect(baseline)
        var recipe = Recipe()
        recipe.skinExposure = options.skinEV
        recipe.lipNaturalization = options.lipAmount
        recipe.lipExposure = options.lipEV
        recipe.skinRednessReduction = options.redness
        var finalSettings = settings(recipe)
        finalSettings.temperature = options.wbTemp
        finalSettings.tint = options.wbTint
        if options.adaptive {
            guard !options.candidates else { throw RetouchError.unknownOption("--adaptive 暂不使用旧版 --candidates") }
            finalSettings = Adjustments()
            finalSettings.temperature = options.wbTemp
            finalSettings.tint = options.wbTint
            var automatic = AutomaticBaseSettings()
            automatic.targetFaceLightness = 60
            automatic.maxGlobalEV = 0.3
            finalSettings.automaticBase = automatic
            var skin = AdjustmentLayer(mask: .skin)
            skin.name = "自然肤色 · 保留纹理"
            skin.adjustments.skinWhitening = 0.15
            skin.adjustments.skinUniformity = 0.16
            skin.adjustments.skinVitality = 0.12
            skin.adjustments.cheekBlush = 0.04
            skin.adjustments.skinSmoothing = 0.12
            skin.adjustments.texturePreservation = 0.9
            skin.adjustments.skinDetail = 0.12
            skin.adjustments.skinEdgeGuard = 1
            skin.feather = 0.0003
            skin.highlightProtection = 0.4
            var lips = AdjustmentLayer(mask: .lips)
            lips.name = "独立唇色 · 最终肤色协调"
            lips.adjustments.lipStyle = options.lipStyle
            lips.adjustments.lipAdaptation = 0.75
            lips.adjustments.lipSmoothing = 0.08
            lips.feather = 0.00025
            finalSettings.layers = [skin, lips]
            if !options.reference.isEmpty {
                let referenceURL = URL(fileURLWithPath: options.reference).standardizedFileURL
                let template = try await engine.makeSkinTemplate(referenceURL, name: "光月大青蛙 · 自然肤色与唇色")
                var application = SkinReferenceApplication(template: template)
                application.strength = 0.75
                application.bodyHarmonization = 0.65
                finalSettings.skinReference = application
                try encoder().encode(template).write(to: qa.appendingPathComponent("参考模板.json"), options: .atomic)
                print("参考肤色 L*a*b*: \(template.targetLightness), \(template.targetRed), \(template.targetYellow)")
                print("参考唇色: \(String(describing: template.lips))")
            }
        }

        if !options.settingsFile.isEmpty {
            guard !options.candidates else { throw RetouchError.unknownOption("--settings 不适用旧版 --candidates") }
            finalSettings = try JSONDecoder().decode(Adjustments.self, from: Data(contentsOf: URL(fileURLWithPath: options.settingsFile)))
        }

        if options.quick {
            guard !options.candidates && options.settingsFile.isEmpty else {
                throw RetouchError.unknownOption("--quick 不与 --candidates 或 --settings 同时使用")
            }
            finalSettings = try PortraitIntent().settings(existing:Adjustments())
            let analysis = try await engine.blemishCandidates(input,preferRAW:!options.jpegOnly)
            let repairs = analysis.candidates.filter(\.recommended).compactMap(\.repair)
            if !repairs.isEmpty { finalSettings.repairSpots = repairs }
            try Self.encoder().encode(analysis).write(to:qa.appendingPathComponent("瑕疵分析.json"))
        }

        if options.candidates {
            let stem = input.deletingPathExtension().lastPathComponent
            // First board: skin lift + redness balance, lips held at the default.
            let skinVariants: [(String, Double, Double)] = [
                ("EV 0.35 / 减红 0.14", 0.35, 0.14),
                ("EV 0.45 / 减红 0.22", 0.45, 0.22),
                ("EV 0.55 / 减红 0.30", 0.55, 0.30)
            ]
            var skinImages = [baseline]
            var skinLabels = ["ARW 原图"]
            for (label, exposure, redness) in skinVariants {
                var candidate = recipe
                candidate.skinExposure = exposure
                candidate.skinRednessReduction = redness
                skinImages.append(try await engine.preview(source, adjustments: settings(candidate),
                                                           maxEdge: nil, profile: .sRGB))
                skinLabels.append(label)
            }
            let skinTarget = qa.appendingPathComponent("\(stem)-肤色候选.png")
            try comparison(skinImages, labels: skinLabels, rect: rect, output: skinTarget, cellWidth: 420)

            // Second board: lip brightness / hue balance, skin held at the default.
            let lipVariants: [(String, Double, Double)] = [
                ("唇 EV 0.10 / 色 0.45", 0.10, 0.45),
                ("唇 EV 0.16 / 色 0.60", 0.16, 0.60),
                ("唇 EV 0.22 / 色 0.75", 0.22, 0.75)
            ]
            var lipImages = [baseline]
            var lipLabels = ["ARW 原图"]
            for (label, exposure, amount) in lipVariants {
                var candidate = recipe
                candidate.lipExposure = exposure
                candidate.lipNaturalization = amount
                lipImages.append(try await engine.preview(source, adjustments: settings(candidate),
                                                          maxEdge: nil, profile: .sRGB))
                lipLabels.append(label)
            }
            let lipTarget = qa.appendingPathComponent("\(stem)-唇色候选.png")
            try comparison(lipImages, labels: lipLabels, rect: rect, output: lipTarget, cellWidth: 420)
            print(skinTarget.path)
            print(lipTarget.path)
            return
        }

        let stem = input.deletingPathExtension().lastPathComponent
        var base = "\(stem)-\(options.name)"
        if options.overwrite {
            try? manager.removeItem(at: output.appendingPathComponent(base + ".tiff"))
            try? manager.removeItem(at: output.appendingPathComponent(base + ".jpg"))
        } else {
            var index = 2
            while manager.fileExists(atPath: output.appendingPathComponent(base + ".tiff").path)
                    || manager.fileExists(atPath: output.appendingPathComponent(base + ".jpg").path) {
                base = "\(stem)-\(options.name)-\(index)"
                index += 1
            }
        }
        let tiff = output.appendingPathComponent(base + ".tiff")
        let jpeg = output.appendingPathComponent(base + ".jpg")
        if !options.skipTIFF {
            try await engine.export(source, to: tiff, adjustments: finalSettings,
                                    format: .tiff, profile: .source)
        }
        try await engine.export(source, to: jpeg, adjustments: finalSettings,
                                format: .jpeg, profile: .sRGB)

        let rendered = try await engine.preview(source, adjustments: finalSettings,
                                                maxEdge: nil, profile: .sRGB)
        var images = [baseline, rendered]
        var labels = ["原图", "\(options.name) · ARW"]
        if let legacy = try image(at: options.legacy) {
            images.insert(legacy, at: 1)
            labels.insert("上一版 · JPG", at: 1)
        }
        let comparisonURL = (options.adaptive || options.quick ? qa : output).appendingPathComponent(base + "-对比.png")
        try comparison(images, labels: labels, rect: rect, output: comparisonURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let parameterURL = qa.appendingPathComponent("\(stem)-\(options.name)-参数.json")
        try encoder.encode(finalSettings).write(to: parameterURL, options: .atomic)
        if options.adaptive || options.quick {
            let reports = try await engine.lipAdaptationReports(input, adjustments: finalSettings, preferRAW: !options.jpegOnly)
            try encoder.encode(reports).write(to: qa.appendingPathComponent(base + "-唇色适配.json"), options: .atomic)
            let automatic = try await engine.automaticBaseReport(input,adjustments:finalSettings)
            try encoder.encode(automatic).write(to:qa.appendingPathComponent(base + "-自动补光.json"),options:.atomic)
            let skin = try await engine.skinReferenceReports(input,adjustments:finalSettings)
            try encoder.encode(skin).write(to:qa.appendingPathComponent(base + "-肤色适配.json"),options:.atomic)
        }
        if !options.skipTIFF { print(tiff.path) }
        print(jpeg.path)
        print(comparisonURL.path)
        print(parameterURL.path)
    }

    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }
}
