import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
@testable import ColorEngine

final class ColorEngineTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func fixture(width: Int = 1024, height: Int = 32, orientation: Int = 1) throws -> URL {
        let url = folder.appendingPathComponent("original.tiff")
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt16(4096 + x * 50000 / max(width - 1, 1))
                pixels[offset + 1] = UInt16(8000 + x * 45000 / max(width - 1, 1))
                pixels[offset + 2] = UInt16(12000 + x * 40000 / max(width - 1, 1))
                pixels[offset + 3] = 65535
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: 300,
            kCGImagePropertyDPIHeight: 240,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func samples(_ url: URL) throws -> [UInt16] {
        let image = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        var pixels = [UInt16](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 8,
                           bounds: image.extent, format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        }
        return pixels
    }

    func testTIFFPreservesDimensionsBitDepthProfileAndOriginal() async throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        let target = folder.appendingPathComponent("export.tiff")
        try await ColorEngine().export(source, to: target, adjustments: Adjustments(), format: .tiff, profile: .source)
        let output = try properties(target)
        XCTAssertEqual(output[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(output[kCGImagePropertyPixelHeight] as? Int, 32)
        XCTAssertEqual(output[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(output[kCGImagePropertyProfileName] as? String, try properties(source)[kCGImagePropertyProfileName] as? String)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let tiff = try XCTUnwrap(output[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression] as? Int, 5)
        XCTAssertEqual(output[kCGImagePropertyDPIWidth] as? Double, 300)
        let before = try samples(source)
        let after = try samples(target)
        let maxError = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxError, 20, "Neutral color conversion should preserve the 16-bit gradient")
        XCTAssertGreaterThan(Set(stride(from: 0, to: after.count, by: 4).map { after[$0] }).count, 900)
    }

    func testJPEGConvertsToSRGBAtOriginalSize() async throws {
        let source = try fixture()
        let target = folder.appendingPathComponent("export.jpg")
        try await ColorEngine().export(source, to: target, adjustments: Adjustments(), format: .jpeg, profile: .sRGB)
        let output = try properties(target)
        XCTAssertEqual(output[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(output[kCGImagePropertyPixelHeight] as? Int, 32)
        XCTAssertEqual(output[kCGImagePropertyDepth] as? Int, 8)
        XCTAssertTrue((output[kCGImagePropertyProfileName] as? String ?? "").contains("sRGB"))
    }

    func testOrientationIsAppliedOnceAndDPIIsRotated() async throws {
        let source = try fixture(width: 80, height: 48, orientation: 6)
        let info = try PhotoInfo.read(source)
        XCTAssertEqual(info.width, 48)
        XCTAssertEqual(info.height, 80)
        let target = folder.appendingPathComponent("rotated.tiff")
        let engine = ColorEngine()
        let preview = try await engine.preview(source, adjustments: Adjustments(), maxEdge: nil)
        XCTAssertEqual(preview.width, 48)
        XCTAssertEqual(preview.height, 80)
        try await engine.export(source, to: target, adjustments: Adjustments(), format: .tiff, profile: .source)
        let output = try properties(target)
        XCTAssertEqual(output[kCGImagePropertyPixelWidth] as? Int, 48)
        XCTAssertEqual(output[kCGImagePropertyPixelHeight] as? Int, 80)
        XCTAssertEqual(output[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(output[kCGImagePropertyDPIWidth] as? Double, 240)
        XCTAssertEqual(output[kCGImagePropertyDPIHeight] as? Double, 300)
    }

    func testExposureChangesPixelsAndPreviewUsesSameGrade() async throws {
        let source = try fixture()
        let target = folder.appendingPathComponent("exposed.tiff")
        var settings = Adjustments()
        settings.exposure = 0.5
        let engine = ColorEngine()
        try await engine.export(source, to: target, adjustments: settings, format: .tiff, profile: .source)
        XCTAssertGreaterThan(try samples(target)[0], try samples(source)[0])
        let preview = try await engine.preview(source, adjustments: settings, maxEdge: nil)
        let exportedPreview = try await engine.preview(target, adjustments: Adjustments(), maxEdge: nil)
        XCTAssertEqual(preview.width, exportedPreview.width)
        let a = try XCTUnwrap(preview.dataProvider?.data) as Data
        let b = try XCTUnwrap(exportedPreview.dataProvider?.data) as Data
        XCTAssertEqual(a.count, b.count)
        let error = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(error, 1)
    }

    func testEachAdjustmentChangesPixels() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        let neutral = try await engine.preview(source, adjustments: Adjustments(), maxEdge: nil)
        let before = try XCTUnwrap(neutral.dataProvider?.data) as Data
        let keys: [WritableKeyPath<Adjustments, Double>] = [
            \.temperature, \.tint, \.contrast, \.shadows, \.highlights, \.saturation, \.curve
        ]
        let values = [800.0, 20, 0.25, 0.4, -0.5, -0.4, 0.08]
        for (key, value) in zip(keys, values) {
            var settings = Adjustments()
            settings[keyPath: key] = value
            let result = try await engine.preview(source, adjustments: settings, maxEdge: nil)
            XCTAssertNotEqual(before, try XCTUnwrap(result.dataProvider?.data) as Data)
        }
    }

    func testPreviewDownscalesAndFullRenderRemainsFullSize() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        let preview = try await engine.preview(source, adjustments: Adjustments(), maxEdge: 256)
        let full = try await engine.preview(source, adjustments: Adjustments(), maxEdge: nil)
        XCTAssertEqual(preview.width, 256)
        XCTAssertEqual(preview.height, 8)
        XCTAssertEqual(full.width, 1024)
        XCTAssertEqual(full.height, 32)
    }

    func testExistingDestinationIsPreserved() async throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        do {
            try await ColorEngine().export(source, to: source, adjustments: Adjustments(), format: .tiff, profile: .source)
            XCTFail("An existing output must be preserved")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    func testLargeImageExportsAtFullResolution() async throws {
        let source = folder.appendingPathComponent("large.tiff")
        let target = folder.appendingPathComponent("large-graded.tiff")
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 6000, y: 4000)
        gradient.color0 = CIColor(red: 0.08, green: 0.12, blue: 0.2)
        gradient.color1 = CIColor(red: 0.7, green: 0.55, blue: 0.3)
        let image = try XCTUnwrap(gradient.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        try CIContext().writeTIFFRepresentation(of: image, to: source, format: .RGBA16,
                                                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        var settings = Adjustments()
        settings.exposure = 0.3
        settings.curve = 0.02
        try await ColorEngine().export(source, to: target, adjustments: settings, format: .tiff, profile: .source)
        let info = try properties(target)
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 6000)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 4000)
        XCTAssertEqual(info[kCGImagePropertyDepth] as? Int, 16)
    }

    func testCancellationDoesNotLeavePartialOutput() async throws {
        let source = try fixture()
        let target = folder.appendingPathComponent("cancelled.tiff")
        let engine = ColorEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.export(source, to: target, adjustments: Adjustments(), format: .tiff, profile: .source)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled work should fail")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        }
    }

    func testLegacySettingsAndLayerRoundTrip() throws {
        let data = Data("""
        {"exposure":0.3,"temperature":200,"tint":2,"contrast":0.1,
         "shadows":0.2,"highlights":-0.2,"saturation":0.1,"curve":0.03}
        """.utf8)
        var settings = try JSONDecoder().decode(Adjustments.self, from: data)
        XCTAssertEqual(settings.exposure, 0.3)
        XCTAssertEqual(settings.temperature, 200)
        XCTAssertTrue(settings.layers.isEmpty)
        settings.layers = Adjustments.portraitLayers()
        let saved = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: saved), settings)
        XCTAssertEqual(try JSONDecoder().decode(ColorAdjustments.self, from: saved), settings.global)
    }

    private func rendered(_ engine: ColorEngine, _ source: URL, _ settings: Adjustments,
                          mask: UUID? = nil) async throws -> [UInt8] {
        let image = try await engine.preview(source, adjustments: settings, maxEdge: nil, maskLayerID: mask)
        return Array(try XCTUnwrap(image.dataProvider?.data) as Data)
    }

    func testLayersCanBeDisabledAndOpacityZeroIsIdentity() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        let neutral = try await rendered(engine, source, Adjustments())
        var layer = AdjustmentLayer(mask: .all)
        layer.adjustments.exposure = 1
        layer.opacity = 0
        var settings = Adjustments()
        settings.layers = [layer]
        let zero = try await rendered(engine, source, settings)
        XCTAssertEqual(zero, neutral)
        settings.layers[0].opacity = 1
        settings.layers[0].enabled = false
        let disabled = try await rendered(engine, source, settings)
        XCTAssertEqual(disabled, neutral)
        settings.layers[0].enabled = true
        let enabled = try await rendered(engine, source, settings)
        XCTAssertNotEqual(enabled, neutral)
    }

    func testHighlightMaskAndInversionTargetOppositeTones() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var layer = AdjustmentLayer(mask: .highlights)
        layer.feather = 0
        layer.rangeStart = 0.35
        layer.rangeEnd = 0.7
        layer.adjustments.exposure = -1
        var settings = Adjustments()
        settings.layers = [layer]
        let neutral = try await rendered(engine, source, Adjustments())
        let highlights = try await rendered(engine, source, settings)
        XCTAssertEqual(Array(highlights[0..<3]), Array(neutral[0..<3]))
        let last = (1024 - 1) * 4
        XCTAssertLessThan(highlights[last], neutral[last])
        settings.layers[0].inverted = true
        let inverted = try await rendered(engine, source, settings)
        XCTAssertLessThan(inverted[0], neutral[0])
        XCTAssertEqual(Array(inverted[last..<(last + 3)]), Array(neutral[last..<(last + 3)]))
        let mask = try await rendered(engine, source, settings, mask: layer.id)
        XCTAssertEqual(mask[0], 255)
        XCTAssertEqual(mask[last], 0)
    }

    func testOpacityInterpolatesAndLayerOrderMatters() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var exposure = AdjustmentLayer(mask: .all)
        exposure.adjustments.exposure = 0.6
        var settings = Adjustments()
        settings.layers = [exposure]
        let full = try await rendered(engine, source, settings)
        settings.layers[0].opacity = 0.5
        let half = try await rendered(engine, source, settings)
        let neutral = try await rendered(engine, source, Adjustments())
        XCTAssertGreaterThan(half[400], neutral[400])
        XCTAssertLessThan(half[400], full[400])
        var contrast = AdjustmentLayer(mask: .all)
        contrast.adjustments.contrast = 0.35
        settings.layers = [exposure, contrast]
        let forward = try await rendered(engine, source, settings)
        settings.layers.reverse()
        let reverse = try await rendered(engine, source, settings)
        XCTAssertNotEqual(forward, reverse)
    }

    func testHighlightProtectionAndFeatherHaveVisibleEffect() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var layer = AdjustmentLayer(mask: .all)
        layer.adjustments.exposure = 0.3
        var settings = Adjustments()
        settings.layers = [layer]
        let unprotected = try await rendered(engine, source, settings)
        settings.layers[0].highlightProtection = 1
        let protected = try await rendered(engine, source, settings)
        XCTAssertLessThan(protected[(1024 - 1) * 4], unprotected[(1024 - 1) * 4])
        settings.layers[0].mask = .highlights
        settings.layers[0].highlightProtection = 0
        settings.layers[0].rangeStart = 0.4
        settings.layers[0].rangeEnd = 0.5
        settings.layers[0].feather = 0
        let sharp = try await rendered(engine, source, settings, mask: layer.id)
        settings.layers[0].feather = 0.02
        let soft = try await rendered(engine, source, settings, mask: layer.id)
        XCTAssertNotEqual(sharp, soft)
    }

    func testLuminosityAndColorBlendModes() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var layer = AdjustmentLayer(mask: .all)
        layer.adjustments.saturation = -0.8
        layer.adjustments.exposure = 0.5
        var settings = Adjustments()
        settings.layers = [layer]
        let normal = try await rendered(engine, source, settings)
        settings.layers[0].blendMode = .luminosity
        let luma = try await rendered(engine, source, settings)
        settings.layers[0].blendMode = .color
        let color = try await rendered(engine, source, settings)
        XCTAssertNotEqual(luma, normal)
        XCTAssertNotEqual(color, normal)
        XCTAssertNotEqual(luma, color)
    }

    func testLuminosityBlendPreservesExtendedHighlightsForLaterLayers() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var brighten = AdjustmentLayer(mask: .all)
        brighten.blendMode = .luminosity
        brighten.adjustments.exposure = 2
        var darken = AdjustmentLayer(mask: .all)
        darken.adjustments.exposure = -2
        var settings = Adjustments()
        settings.layers = [brighten, darken]
        let restored = try await rendered(engine, source, settings)
        let original = try await rendered(engine, source, Adjustments())
        XCTAssertLessThanOrEqual(zip(restored, original).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
    }

    func testLayerPreviewAndTIFFExportAgree() async throws {
        let source = try fixture()
        let engine = ColorEngine()
        var settings = Adjustments()
        var layer = AdjustmentLayer(mask: .shadows)
        layer.adjustments.exposure = 0.4
        layer.opacity = 0.7
        layer.blendMode = .luminosity
        settings.layers = [layer]
        let target = folder.appendingPathComponent("layered.tiff")
        try await engine.export(source, to: target, adjustments: settings, format: .tiff, profile: .source)
        let preview = try await rendered(engine, source, settings)
        let exported = try await rendered(engine, target, Adjustments())
        XCTAssertLessThanOrEqual(zip(preview, exported).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        XCTAssertEqual(try properties(target)[kCGImagePropertyDepth] as? Int, 16)
    }

    func testPortraitMasksOnRealTestSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR to run the local portrait acceptance check")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(urls.count, 12)
        let engine = ColorEngine()
        for url in urls {
            try await checkPortrait(url, engine: engine)
        }
    }

    private func checkPortrait(_ source: URL, engine: ColorEngine) async throws {
        let before = try Data(contentsOf: source)
        var settings = Adjustments()
        settings.layers = Adjustments.portraitLayers()
        let personID = settings.layers[0].id
        let mask = try await engine.preview(source, adjustments: settings, maxEdge: 512, maskLayerID: personID)
        let bytes = Array(try XCTUnwrap(mask.dataProvider?.data) as Data)
        let red = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
        XCTAssertLessThan(red.min() ?? 255, 30, source.lastPathComponent)
        XCTAssertGreaterThan(red.max() ?? 0, 150, source.lastPathComponent)
        let output = try await engine.preview(source, adjustments: settings, maxEdge: 512)
        let original = try await engine.preview(source, adjustments: Adjustments(), maxEdge: 512)
        XCTAssertNotEqual(try XCTUnwrap(output.dataProvider?.data) as Data,
                          try XCTUnwrap(original.dataProvider?.data) as Data)
        if source.lastPathComponent == "DSC00681.JPG" {
            var inverse = settings
            inverse.layers[0].mask = .background
            inverse.layers[0].highlightProtection = 0
            inverse.layers[0].feather = 0
            var person = inverse
            person.layers[0].mask = .person
            let a = try await engine.preview(source, adjustments: person, maxEdge: 512, maskLayerID: personID)
            let b = try await engine.preview(source, adjustments: inverse, maxEdge: 512, maskLayerID: personID)
            let ap = Array(try XCTUnwrap(a.dataProvider?.data) as Data)
            let bp = Array(try XCTUnwrap(b.dataProvider?.data) as Data)
            let aRed = stride(from: 0, to: ap.count, by: 4).map { Double(ap[$0]) }
            let bRed = stride(from: 0, to: bp.count, by: 4).map { Double(bp[$0]) }
            let aMean = aRed.reduce(0, +) / Double(aRed.count)
            let bMean = bRed.reduce(0, +) / Double(bRed.count)
            let covariance = zip(aRed, bRed).reduce(0) { $0 + ($1.0 - aMean) * ($1.1 - bMean) }
            XCTAssertLessThan(covariance, 0, "Person and background masks should select opposing regions")
            let target = folder.appendingPathComponent("portrait-graded.tiff")
            try await engine.export(source, to: target, adjustments: settings, format: .tiff, profile: .source)
            let info = try properties(target)
            XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 4000)
            XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 6000)
            XCTAssertEqual(info[kCGImagePropertyDepth] as? Int, 16)
            if let outputPath = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
                let folder = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent("DSC00681-layered.tiff")
                try Data(contentsOf: target).write(to: copy, options: .atomic)
                let maskURL = folder.appendingPathComponent("DSC00681-mask.png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(maskURL as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, mask, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            // The JPEG path is upgraded to its paired ARW, so the embedded profile
            // follows the actual pixel source (Display P3), not the JPEG (sRGB).
            let resolved = PhotoSource.resolve(source)
            XCTAssertTrue(resolved.isRAW)
            XCTAssertEqual(info[kCGImagePropertyProfileName] as? String,
                           try properties(resolved.imageURL)[kCGImagePropertyProfileName] as? String)
            // The legacy JPEG-only path must still produce an sRGB file.
            let jpegTarget = folder.appendingPathComponent("portrait-graded-jpeg.tiff")
            try await engine.export(source, to: jpegTarget, adjustments: settings,
                                    format: .tiff, profile: .source, preferRAW: false)
            let jpegInfo = try properties(jpegTarget)
            XCTAssertEqual(jpegInfo[kCGImagePropertyProfileName] as? String,
                           try properties(source)[kCGImagePropertyProfileName] as? String)
            XCTAssertEqual(jpegInfo[kCGImagePropertyPixelWidth] as? Int, 4000)
            XCTAssertEqual(jpegInfo[kCGImagePropertyPixelHeight] as? Int, 6000)
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
        print("Portrait checked: \(source.lastPathComponent)")
    }

    func testSkinAndClothingMasksOnReference() async throws {
        guard let path = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for semantic segmentation checks")
        }
        let source = URL(fileURLWithPath: path).appendingPathComponent("DSC00681.JPG")
        let engine = ColorEngine()
        var skin = AdjustmentLayer(mask: .skin)
        skin.feather = 0
        var clothes = AdjustmentLayer(mask: .clothing)
        clothes.feather = 0
        var settings = Adjustments()
        settings.layers = [skin, clothes]
        let a = try await engine.preview(source, adjustments: settings, maxEdge: 768, maskLayerID: skin.id)
        let b = try await engine.preview(source, adjustments: settings, maxEdge: 768, maskLayerID: clothes.id)
        let aBytes = Array(try XCTUnwrap(a.dataProvider?.data) as Data)
        let bBytes = Array(try XCTUnwrap(b.dataProvider?.data) as Data)
        let skinCount = stride(from: 0, to: aBytes.count, by: 4).filter { aBytes[$0] > 128 }.count
        let clothCount = stride(from: 0, to: bBytes.count, by: 4).filter { bBytes[$0] > 128 }.count
        print("Semantic mask areas", skinCount, clothCount)
        XCTAssertGreaterThan(skinCount, 300)
        XCTAssertLessThan(skinCount, a.width * a.height / 5)
        XCTAssertGreaterThan(clothCount, 5000)
        let overlap = stride(from: 0, to: aBytes.count, by: 4).filter { aBytes[$0] > 200 && bBytes[$0] > 200 }.count
        XCTAssertLessThan(overlap, 100)
        if let output = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (image, name) in [(a, "skin"), (b, "clothing")] {
                let url = folder.appendingPathComponent("DSC00681-\(name).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }

    func testBrushCoordinatesAndStrokeOrder() async throws {
        let source = try fixture(width: 256, height: 256)
        let engine = ColorEngine()
        var layer = AdjustmentLayer(mask: .all)
        layer.feather = 0
        layer.brushStrokes = [MaskStroke(points: [MaskPoint(x: 0.25, y: 0.75)], radius: 0.05, erase: true)]
        var settings = Adjustments()
        settings.layers = [layer]
        let erased = try await rendered(engine, source, settings, mask: layer.id)
        let topQuarter = (64 * 256 + 64) * 4
        let bottomQuarter = (192 * 256 + 64) * 4
        XCTAssertEqual(erased[topQuarter], 0)
        XCTAssertEqual(erased[bottomQuarter], 255)
        settings.layers[0].brushStrokes?.append(MaskStroke(
            points: [MaskPoint(x: 0.25, y: 0.75)], radius: 0.03, erase: false))
        let painted = try await rendered(engine, source, settings, mask: layer.id)
        XCTAssertEqual(painted[topQuarter], 255)
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: encoded), settings)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var layers = try XCTUnwrap(legacy["layers"] as? [[String: Any]])
        layers[0].removeValue(forKey: "brushStrokes")
        legacy["layers"] = layers
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.layers[0].brushStrokes)
    }

    func testSkinAndClothingAdjustmentsAreIndependent() async throws {
        guard let path = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for semantic segmentation checks")
        }
        let source = URL(fileURLWithPath: path).appendingPathComponent("DSC00681.JPG")
        let original = try Data(contentsOf: source)
        let engine = ColorEngine()
        var skin = AdjustmentLayer(mask: .skin)
        skin.feather = 0
        var clothing = AdjustmentLayer(mask: .clothing)
        clothing.feather = 0
        var settings = Adjustments()
        settings.layers = [skin, clothing]
        let a = try await engine.preview(source, adjustments: settings, maxEdge: 512, maskLayerID: skin.id)
        let b = try await engine.preview(source, adjustments: settings, maxEdge: 512, maskLayerID: clothing.id)
        let skinMask = Array(try XCTUnwrap(a.dataProvider?.data) as Data)
        let clothMask = Array(try XCTUnwrap(b.dataProvider?.data) as Data)
        let neutral = try await engine.preview(source, adjustments: Adjustments(), maxEdge: 512)
        let neutralBytes = Array(try XCTUnwrap(neutral.dataProvider?.data) as Data)
        settings.layers[0].adjustments.exposure = 0.4
        settings.layers[0].adjustments.rednessReduction = 0.4
        let skinOnly = try await engine.preview(source, adjustments: settings, maxEdge: 512)
        let skinBytes = Array(try XCTUnwrap(skinOnly.dataProvider?.data) as Data)
        let clothingIndices = stride(from: 0, to: clothMask.count, by: 4).filter { clothMask[$0] > 200 && skinMask[$0] == 0 }
        XCTAssertGreaterThan(clothingIndices.count, 1000)
        let clothChange = clothingIndices.map { abs(Int(skinBytes[$0]) - Int(neutralBytes[$0])) }.max() ?? 0
        XCTAssertLessThanOrEqual(clothChange, 1)
        settings.layers[0].adjustments = ColorAdjustments()
        settings.layers[1].adjustments.saturation = -0.5
        let clothingOnly = try await engine.preview(source, adjustments: settings, maxEdge: 512)
        let clothBytes = Array(try XCTUnwrap(clothingOnly.dataProvider?.data) as Data)
        let skinIndices = stride(from: 0, to: skinMask.count, by: 4).filter { skinMask[$0] > 200 && clothMask[$0] == 0 }
        XCTAssertGreaterThan(skinIndices.count, 100)
        let skinChange = skinIndices.map { abs(Int(clothBytes[$0]) - Int(neutralBytes[$0])) }.max() ?? 0
        XCTAssertLessThanOrEqual(skinChange, 1)
        XCTAssertNotEqual(clothBytes, neutralBytes)
        let target = folder.appendingPathComponent("semantic.tiff")
        try await engine.export(source, to: target, adjustments: settings, format: .tiff, profile: .source)
        let info = try properties(target)
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 4000)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 6000)
        XCTAssertEqual(info[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSemanticMasksAcrossRealTestSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for semantic segmentation checks")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 12)
        let engine = ColorEngine()
        for source in files {
            let skin = AdjustmentLayer(mask: .skin)
            let clothing = AdjustmentLayer(mask: .clothing)
            var settings = Adjustments()
            settings.layers = [skin, clothing]
            for layer in settings.layers {
                let mask = try await engine.preview(source, adjustments: settings, maxEdge: 512, maskLayerID: layer.id)
                let bytes = Array(try XCTUnwrap(mask.dataProvider?.data) as Data)
                let selected = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 128 }.count
                XCTAssertGreaterThan(selected, layer.mask == .skin ? 5 : 500,
                                     "\(source.lastPathComponent) \(layer.mask.rawValue)")
                if let root = ProcessInfo.processInfo.environment["PS_QA_OUTPUT"] {
                    let folder = URL(fileURLWithPath: root).appendingPathComponent("Semantic")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + layer.mask.rawValue + ".png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, mask, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
            print("Semantic regions checked: \(source.lastPathComponent)")
        }
    }

    func testSelectiveRednessPreservesLuminanceAndNeutralColors() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        func pixel(_ color: CIColor, amount: Double) throws -> [Float] {
            let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            let adjusted = try SelectiveColor.reduceRedness(image, amount: amount)
            var result = [Float](repeating: 0, count: 4)
            result.withUnsafeMutableBytes {
                context.render(adjusted, toBitmap: $0.baseAddress!, rowBytes: 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: space)
            }
            return result
        }
        let pink = CIColor(red: 0.7, green: 0.24, blue: 0.27, alpha: 1, colorSpace: space)!
        let original = try pixel(pink, amount: 0)
        let corrected = try pixel(pink, amount: 0.5)
        XCTAssertLessThan(corrected[0] - corrected[1], original[0] - original[1])
        let weights: [Float] = [0.228975, 0.691739, 0.079286]
        let beforeLuma = zip(original, weights).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let afterLuma = zip(corrected, weights).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(beforeLuma, afterLuma, accuracy: 0.00001)
        for color in [CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1, colorSpace: space)!,
                      CIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 0.6, colorSpace: space)!] {
            let a = try pixel(color, amount: 0)
            let b = try pixel(color, amount: 1)
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.00001) }
        }
        let old = Data(#"{"exposure":0.2}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ColorAdjustments.self, from: old).rednessReduction, 0)
    }

    func testMissingInputFailsCleanly() async throws {
        do {
            _ = try await ColorEngine().preview(folder.appendingPathComponent("missing.jpg"), adjustments: Adjustments(), maxEdge: nil)
            XCTFail("Missing input should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法读取"))
        }
    }
}
