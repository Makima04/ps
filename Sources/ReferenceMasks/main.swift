import ColorEngine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Export analysis masks only; source files are never re-encoded or modified.
@main
struct ReferenceMasks {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, args[0] == "--output" else {
            print("ReferenceMasks --output <目录> <图片>...")
            return
        }
        let root = URL(fileURLWithPath: args[1])
        let engine = ColorEngine()
        let regions: [(String, MaskKind)] = [("face", .skin), ("neck", .neck), ("lips", .lips),
            ("hair", .hair), ("body", .bodySkin), ("clothing", .clothing), ("person", .person)]
        for path in args.dropFirst(2) {
            let source = URL(fileURLWithPath: path)
            let folder = root.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, kind) in regions {
                let output = folder.appendingPathComponent(name+".png")
                if FileManager.default.fileExists(atPath: output.path) { continue }
                var settings = Adjustments()
                var layer = AdjustmentLayer(mask: kind)
                layer.feather = 0
                settings.layers = [layer]
                let image = try await engine.preview(source, adjustments: settings, maxEdge: 1100,
                    maskLayerID: layer.id, profile: .sRGB, preferRAW: false)
                guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            }
            print(source.lastPathComponent)
            fflush(stdout)
        }
    }
}
