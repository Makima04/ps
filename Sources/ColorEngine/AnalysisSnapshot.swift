import CoreGraphics
import Foundation

public struct AnalysisAlgorithmVersion: Codable, Equatable, Hashable, Sendable {
    public let semanticParser: String
    public let blemishDetector: String
    public let skinRefinement: String

    public static let current = AnalysisAlgorithmVersion(
        semanticParser: "0.4.3-faceparsing-clothseg",
        blemishDetector: "0.4.3-lab-spots",
        skinRefinement: "0.4.3-connected-neck-hand"
    )

    public init(semanticParser: String, blemishDetector: String, skinRefinement: String) {
        self.semanticParser = semanticParser
        self.blemishDetector = blemishDetector
        self.skinRefinement = skinRefinement
    }
}

public struct AnalysisInputFingerprint: Codable, Equatable, Hashable, Sendable {
    public let url: URL
    public let fileSize: Int64
    public let modifiedAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isRAW: Bool

    public init(url: URL, fileSize: Int64, modifiedAt: Date,
                pixelWidth: Int, pixelHeight: Int, isRAW: Bool) {
        self.url = url
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isRAW = isRAW
    }

    public static func capture(for url: URL, extent: CGRect, isRAW: Bool) -> AnalysisInputFingerprint {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return AnalysisInputFingerprint(
            url: url,
            fileSize: size,
            modifiedAt: modified,
            pixelWidth: Int(extent.width.rounded()),
            pixelHeight: Int(extent.height.rounded()),
            isRAW: isRAW
        )
    }
}

public struct FaceSnapshot: Codable, Equatable, Sendable {
    public let index: Int
    public let bounds: CGRect
    public let hasLandmarks: Bool
    public let availableRegions: [MaskKind]
    public let skipReason: String?

    public init(index: Int, bounds: CGRect, hasLandmarks: Bool,
                availableRegions: [MaskKind], skipReason: String? = nil) {
        self.index = index
        self.bounds = bounds
        self.hasLandmarks = hasLandmarks
        self.availableRegions = availableRegions
        self.skipReason = skipReason
    }
}

public struct AnalysisSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let input: AnalysisInputFingerprint
    public let algorithmVersion: AnalysisAlgorithmVersion
    public let faces: [FaceSnapshot]
    public let blemishSensitivity: Double?
    public let blemishes: BlemishAnalysis?
    public let warnings: [String]

    public init(schemaVersion: Int = 1, createdAt: Date = Date(),
                input: AnalysisInputFingerprint,
                algorithmVersion: AnalysisAlgorithmVersion = .current,
                faces: [FaceSnapshot],
                blemishSensitivity: Double? = nil,
                blemishes: BlemishAnalysis? = nil,
                warnings: [String] = []) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.input = input
        self.algorithmVersion = algorithmVersion
        self.faces = faces
        self.blemishSensitivity = blemishSensitivity
        self.blemishes = blemishes
        self.warnings = warnings
    }

    public func isValid(for candidateInput: AnalysisInputFingerprint,
                        version: AnalysisAlgorithmVersion = .current) -> Bool {
        input == candidateInput && algorithmVersion == version
    }
}
