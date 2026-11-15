import AppKit
import ColorEngine
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct Compare {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, .workingFormat: CIFormat.RGBAf])
    struct Stage: Encodable {
        let label: String
        let settings: Adjustments
        let profile: SkinProfile
    }
    struct Report: Encodable {
        let input: URL
        let reference: URL
        let stages: [Stage]
        let faceBounds: [Double]
        let note: String
    }
    static func save(_ image: CGImage, _ url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "Output", code: 1) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "Output", code: 2) }
    }
    static func crop(_ image: CGImage, _ box: CGRect) throws -> CGImage {
        // CI/Vision use bottom-left coordinates, so crop with CI rather than CGImage.cropping.
        let ci = CIImage(cgImage: image)
        guard let result = context.createCGImage(ci, from: box.integral.intersection(ci.extent), format: .RGBA8, colorSpace: space) else { throw NSError(domain: "Crop", code: 1) }
        return result
    }
    static func text(_ string: String, x: Double, y: Double, size: Double, color: NSColor = .white, weight: NSFont.Weight = .regular) {
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    static func board(_ images: [CGImage], labels: [String], details: [String], title: String, subtitle: String,
                      cell: CGSize, footer: String, path: URL, nearest: Bool = false) throws {
        let pad = 24.0, gap = 18.0, header = 102.0, labelHeight = 66.0, bottom = 54.0
        let width = pad*2 + Double(images.count)*cell.width + Double(images.count-1)*gap
        let height = header + labelHeight + cell.height + bottom
        let bitmap = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                               bytesPerRow: Int(width)*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 0.065, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        text(title, x: pad, y: height-42, size: 25, weight: .semibold)
        text(subtitle, x: pad, y: height-73, size: 15, color: NSColor(white: 0.7, alpha: 1))
        for (i, image) in images.enumerated() {
            let x = pad + Double(i)*(cell.width+gap)
            text(labels[i], x: x, y: bottom+cell.height+35, size: 21, weight: .medium)
            text(details[i], x: x, y: bottom+cell.height+10, size: 14, color: NSColor(white: 0.7, alpha: 1))
            bitmap.setFillColor(CGColor(gray: 0.10, alpha: 1))
            bitmap.fill(CGRect(x: x, y: bottom, width: cell.width, height: cell.height))
            let scale = min(cell.width/Double(image.width), cell.height/Double(image.height))
            let w = Double(image.width)*scale, h = Double(image.height)*scale
            bitmap.interpolationQuality = nearest ? .none : .high
            bitmap.draw(image, in: CGRect(x: x+(cell.width-w)/2, y: bottom+(cell.height-h)/2, width: w, height: h))
        }
        text(footer, x: pad, y: 20, size: 14, color: NSColor(white: 0.7, alpha: 1))
        try save(bitmap.makeImage()!, path)
    }
    static func expanded(_ face: CGRect, image: CGImage) -> CGRect {
        let w = face.width * 1.65, h = face.height * 1.45
        return CGRect(x: face.midX-w/2, y: face.midY-h/2, width: w, height: h)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/Users/makima/program/Ps")
        let output = root.appendingPathComponent(".build/portrait-workflow-comparison")
        let reference = root.appendingPathComponent("PhotoLibrary/参考/单图追色/奶油肤色参考.png")
        let engine = ColorEngine()
        let template = try await engine.makeSkinTemplate(reference, name: "自然白皙参考")
        for stem in ["DSC00681", "DSC00753"] {
            let input = root.appendingPathComponent("PhotoLibrary/测试组/2025-09-29/JPEG/"+stem+".JPG")
            let faces = try await engine.faceRegions(input)
            guard let face = faces.max(by: { $0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height }) else { throw NSError(domain: "Face", code: 1) }
            let neutral = Adjustments()
            var local = neutral
            var skin = AdjustmentLayer(mask: .skin)
            skin.name = "肤色与纹理"
            skin.adjustments.skinWhitening = 0.3
            skin.adjustments.skinYellowReduction = 0.2
            skin.adjustments.skinUniformity = 0.25
            skin.adjustments.skinVitality = 0.2
            skin.adjustments.cheekBlush = 0.15
            skin.adjustments.skinSmoothing = 0.3
            local.layers = [skin]
            var matched = local
            matched.skinReference = SkinReferenceApplication(template: template)
            let settings = [neutral, local, matched]
            let labels = ["原始 RAW 显影", "肤色与纹理调整", "再加入参考肤色适配"]
            var images: [CGImage] = []
            var profiles: [SkinProfile] = []
            for (i, value) in settings.enumerated() {
                let image = try await engine.preview(input, adjustments: value, maxEdge: nil, profile: .sRGB)
                images.append(image)
                try save(image, output.appendingPathComponent(stem+"-stage-\(i).png"))
                var probe = value
                if probe.skinReference == nil {
                    probe.skinReference = SkinReferenceApplication(template: template)
                    probe.skinReference?.strength = 0
                }
                let reports = try await engine.skinReferenceReports(input, adjustments: probe)
                profiles.append(reports[face.index].after)
            }
            let details = profiles.map { String(format: "L* %.1f · a* %.1f · b* %.1f", $0.lightness.median, $0.redGreen.median, $0.yellowBlue.median) }
            try board(images, labels: labels, details: details, title: stem+" · 新工作流实际渲染对比",
                      subtitle: "同一 ARW / 同一裁切与色彩空间 / 右侧两列仅调整皮肤 / 未添加手动修复点",
                      cell: CGSize(width: 420, height: 630), footer: "参数：白皙 0.30 · 去黄 0.20 · 均匀 0.25 · 血色 0.20 · 红润 0.15 · 柔化 0.30 · 参考 0.75",
                      path: output.appendingPathComponent(stem+"-full-comparison.png"))
            let box = expanded(face.bounds, image: images[0])
            let crops = try images.map { try crop($0, box) }
            try board(crops, labels: labels, details: details, title: stem+" · 面部放大对比",
                      subtitle: "取自全尺寸渲染，三列裁切完全一致；统计限定在自动识别的脸部皮肤内",
                      cell: CGSize(width: 520, height: 650), footer: "未调整五官形状、眼睛、嘴唇和背景；参考仅用于肤色，未迁移参考纹理。",
                      path: output.appendingPathComponent(stem+"-face-comparison.png"))
            let stages = zip(labels, zip(settings, profiles)).map { Stage(label: $0.0, settings: $0.1.0, profile: $0.1.1) }
            let report = Report(input: input, reference: reference, stages: stages,
                                faceBounds: [face.bounds.minX,face.bounds.minY,face.bounds.width,face.bounds.height],
                                note: "Actual ColorEngine preview/export pipeline. Same source RAW and sRGB output for every stage. No manual repairs or geometry changes.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent(stem+"-parameters.json"))
            print(stem, details)
        }
        let refImage = try await engine.preview(reference, adjustments: Adjustments(), maxEdge: 900, profile: .sRGB, preferRAW: false)
        try save(refImage, output.appendingPathComponent("reference.png"))
    }
}
