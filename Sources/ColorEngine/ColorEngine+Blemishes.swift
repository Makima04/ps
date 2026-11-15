import CoreImage
import Foundation

extension ColorEngine {
    public func analysisSnapshot(_ url: URL, existingRepairs: [RepairSpot] = [],
                                 blemishSensitivity: Double? = nil,
                                 preferRAW: Bool = true) throws -> AnalysisSnapshot {
        let source = PhotoSource.resolve(url, preferRAW: preferRAW)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        let fingerprint = AnalysisInputFingerprint.capture(
            for: source.analysisURL,
            extent: original.extent,
            isRAW: source.isRAW
        )
        let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: source.analysisURL, context: context)
        var warnings: [String] = []
        if parsed.faces.isEmpty {
            warnings.append("未检测到可靠人脸")
        }
        let faceSnapshots = parsed.faces.map { face in
            let regions = Array(face.regions.keys).sorted { $0.rawValue < $1.rawValue }
            let skipReason: String? = face.info.bounds.width < 120 ? "人脸宽度小于 120 像素，已跳过瑕疵分析" : nil
            return FaceSnapshot(
                index: face.info.index,
                bounds: face.info.bounds,
                hasLandmarks: face.info.hasLandmarks,
                availableRegions: regions,
                skipReason: skipReason
            )
        }
        let blemishes: BlemishAnalysis?
        if let blemishSensitivity {
            blemishes = try blemishCandidates(url, existingRepairs: existingRepairs,
                                              sensitivity: blemishSensitivity, preferRAW: preferRAW)
        } else {
            blemishes = nil
        }
        return AnalysisSnapshot(
            input: fingerprint,
            algorithmVersion: .current,
            faces: faceSnapshots,
            blemishSensitivity: blemishSensitivity,
            blemishes: blemishes,
            warnings: warnings
        )
    }

    public func blemishCandidates(_ url: URL, existingRepairs: [RepairSpot] = [], sensitivity: Double = 0.5,
                                  preferRAW: Bool = true) throws -> BlemishAnalysis {
        guard sensitivity.isFinite, (0...1).contains(sensitivity) else {
            throw ImageError.maskFailed("瑕疵分析灵敏度必须为 0 到 1")
        }
        let source = PhotoSource.resolve(url, preferRAW: preferRAW)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        let image = try SpotRepair.apply(existingRepairs, to: original)
        let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: source.analysisURL, context: context)
        guard !parsed.faces.isEmpty else { throw ImageError.maskFailed("未检测到可靠人脸，不能生成瑕疵候选") }
        var candidates: [BlemishCandidate] = [], warnings: [String] = []
        for face in parsed.faces {
            try Task.checkCancellation()
            guard face.info.bounds.width >= 120 else {
                warnings.append("人物 \(face.info.index + 1) 的人脸过小，已跳过瑕疵分析")
                continue
            }
            let radius = max(1, face.info.bounds.width * 0.012)
            var selection = parsed.mask(.skin, faceIndex: face.info.index)
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
            var protected = CIImage(color: .black).cropped(to: image.extent)
            for kind in [MaskKind.eyes, .eyebrows, .lips, .teeth, .hair, .underEyes, .noseSides] {
                protected = parsed.mask(kind, faceIndex: face.info.index).applyingFilter("CIMaximumCompositing",
                    parameters: [kCIInputBackgroundImageKey: protected])
            }
            protected = protected.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius * 2.5])
            selection = selection.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: protected.applyingFilter("CIColorInvert")])
            selection = try FaceMaskOwnership.restrict(selection, index: face.info.index,
                boxes: parsed.faces.map { $0.info.bounds })
            let local = try BlemishDetector.detect(image, permitted: selection, box: face.info.bounds,
                faceIndex: face.info.index, sensitivity: sensitivity, context: context)
            let long = max(image.extent.width, image.extent.height)
            candidates += local.filter { candidate in !existingRepairs.contains(where: { spot in
                hypot((candidate.target.x - spot.target.x) * image.extent.width,
                      (candidate.target.y - spot.target.y) * image.extent.height) < (candidate.radius + spot.radius) * long * 1.4
            }) }
        }
        candidates.sort { $0.score > $1.score }
        if candidates.isEmpty { warnings.append("没有找到符合当前阈值的小斑点，未进行修复") }
        return BlemishAnalysis(candidates: Array(candidates.prefix(40)), warnings: warnings)
    }
}
