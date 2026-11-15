import AppKit
import ColorEngine
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Independent review output only. Does not write the user's project or sources.
/// Build against the SwiftPM ColorEngine objects; see Docs/总体框架.md.
@main
struct ColorSpotQA {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options:[.workingColorSpace:
        CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)!, .workingFormat:CIFormat.RGBAf])

    struct Report: Encodable {
        let input: String
        let sourceHashesBefore: [String:String]
        let sourceHashesAfter: [String:String]
        let candidateCounts: [String:Int]
        let demonstrationRepairs: Int
        let note: String
    }

    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func crop(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let ci = CIImage(cgImage:image)
        guard let result = context.createCGImage(ci,from:rect.integral.intersection(ci.extent),
            format:.RGBA8,colorSpace:space) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    @MainActor static func board(_ images: [CGImage], labels: [String], at url: URL,
                                 candidates: [BlemishCandidate] = [], imageSize: CGSize = .zero,
                                 cropRect: CGRect = .zero) throws {
        let cell = 480.0, pad = 20.0, header = 60.0
        let height = images.map { cell*Double($0.height)/Double($0.width) }.max()!+header+pad
        let width = Double(images.count)*(cell+pad)+pad
        guard let bitmap = CGContext(data:nil,width:Int(width),height:Int(height),bitsPerComponent:8,
            bytesPerRow:Int(width)*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.setFillColor(CGColor(gray:0.07,alpha:1)); bitmap.fill(CGRect(x:0,y:0,width:width,height:height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:bitmap,flipped:false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index,image) in images.enumerated() {
            let x = pad+Double(index)*(cell+pad), h = cell*Double(image.height)/Double(image.width)
            let rect = CGRect(x:x,y:pad,width:cell,height:h)
            bitmap.interpolationQuality = .high; bitmap.draw(image,in:rect)
            (labels[index] as NSString).draw(at:CGPoint(x:x,y:height-35),withAttributes:[
                .font:NSFont.systemFont(ofSize:17),.foregroundColor:NSColor.white])
            if index == 1 && !cropRect.isEmpty {
                for (n,candidate) in candidates.enumerated() {
                    let point = CGPoint(x:candidate.target.x*imageSize.width,y:candidate.target.y*imageSize.height)
                    guard cropRect.contains(point) else { continue }
                    let scale = cell/cropRect.width
                    let center = CGPoint(x:x+(point.x-cropRect.minX)*scale,y:pad+(point.y-cropRect.minY)*scale)
                    let radius = max(4,candidate.radius*max(imageSize.width,imageSize.height)*scale)
                    bitmap.setStrokeColor(NSColor.systemOrange.cgColor); bitmap.setLineWidth(1.5)
                    bitmap.strokeEllipse(in:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
                    ("\(n+1)" as NSString).draw(at:CGPoint(x:center.x+radius,y:center.y),withAttributes:[
                        .font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.systemOrange])
                }
            }
        }
        try save(bitmap.makeImage()!,to:url)
    }

    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, args[0] == "--output" else {
            print("ColorSpotQA --output <诊断目录> <照片>..."); return
        }
        let output = URL(fileURLWithPath:args[1])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let engine = ColorEngine()
        for path in args.dropFirst(2) {
            let input = URL(fileURLWithPath:path).standardizedFileURL
            let source = PhotoSource.resolve(input)
            let files = Set([source.imageURL,source.analysisURL])
            func hashes() throws -> [String:String] {
                try Dictionary(uniqueKeysWithValues:files.map {
                    ($0.path,SHA256.hash(data:try Data(contentsOf:$0)).map { String(format:"%02x",$0) }.joined())
                })
            }
            let beforeHashes = try hashes()
            let analysis = try await engine.blemishCandidates(input)
            let yellow = analysis.candidates.filter { $0.kind == .yellowSpot }
            let folder = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try encoder.encode(analysis).write(to:folder.appendingPathComponent("候选.json"),options:.atomic)
            var demonstration = Adjustments()
            demonstration.repairSpots = yellow.compactMap(\.repair)
            try encoder.encode(demonstration).write(to:folder.appendingPathComponent("仅诊断-黄褐色候选全选参数.json"),options:.atomic)
            let before = try await engine.preview(input,adjustments:Adjustments(),maxEdge:nil,profile:.sRGB)
            let after = try await engine.preview(input,adjustments:demonstration,maxEdge:nil,profile:.sRGB)
            let faces = try await engine.faceRegions(input)
            for face in faces {
                let box = face.bounds.insetBy(dx:-face.bounds.width*0.35,dy:-face.bounds.height*0.25)
                    .integral.intersection(CGRect(x:0,y:0,width:before.width,height:before.height))
                let a = try crop(before,rect:box), b = try crop(after,rect:box)
                try board([a,a,b],labels:["RAW 原始显影","黄褐色候选（需确认）","候选全选演示 · 非自动成片"],
                    at:folder.appendingPathComponent("人物\(face.index+1)-面部对照.png"),candidates:yellow,
                    imageSize:CGSize(width:before.width,height:before.height),cropRect:box)
            }
            for (index,candidate) in yellow.enumerated() {
                let r = max(45,candidate.radius*Double(max(before.width,before.height))*3)
                let rect = CGRect(x:candidate.target.x*Double(before.width)-r,y:candidate.target.y*Double(before.height)-r,
                    width:r*2,height:r*2).integral.intersection(CGRect(x:0,y:0,width:before.width,height:before.height))
                try save(crop(before,rect:rect),to:folder.appendingPathComponent("候选\(index+1)-前.png"))
                try save(crop(after,rect:rect),to:folder.appendingPathComponent("候选\(index+1)-后.png"))
            }
            let afterHashes = try hashes()
            guard beforeHashes == afterHashes else { throw CocoaError(.fileReadCorruptFile) }
            let counts = Dictionary(grouping:analysis.candidates,by:{ $0.kind.rawValue }).mapValues(\.count)
            let report = Report(input:input.path,sourceHashesBefore:beforeHashes,sourceHashesAfter:afterHashes,
                candidateCounts:counts,demonstrationRepairs:demonstration.repairSpots?.count ?? 0,
                note:"同一 RAW 原始显影，未套用快速修图。右列仅演示全部可取样黄褐色候选的效果，未经逐点人工确认；不代表推荐自动处理。候选编号对应候选.json 中的 yellowSpot 子集；项目和原片未修改。")
            try encoder.encode(report).write(to:folder.appendingPathComponent("核验.json"),options:.atomic)
            print(input.lastPathComponent,counts,"可取样黄褐色点",demonstration.repairSpots?.count ?? 0)
            fflush(stdout)
        }
    }
}
